//! Capture → convert → encode → broadcast loop, mirroring the C# `StreamingSession`.
//!
//! Default is the GPU zero-copy path (DXGI capture → D3D11 VPP → NV12 texture straight into the
//! encoder); `--cpu` selects the CPU path (DXGI capture + `bgra_to_nv12` + memory input).

use crate::convert::bgra_to_nv12;
use crate::dxgi::DxgiCapture;
use crate::gpu_convert::GpuColorConverter;
use crate::hevc::HevcEncoder;
use crate::input;
use crate::logline;
use crate::options::Options;
use crate::server::{CursorState, Server};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

pub struct StreamingSession {
    origin_x: i32,
    origin_y: i32,
    cap_w: i32,
    cap_h: i32,
    capture_device: Option<String>,
    opts: Options,
    server: Arc<Server>,
}

impl StreamingSession {
    pub fn new(
        origin_x: i32,
        origin_y: i32,
        cap_w: i32,
        cap_h: i32,
        capture_device: Option<String>,
        opts: Options,
    ) -> std::io::Result<Self> {
        let server = Arc::new(Server::new(27315)?);
        Ok(Self { origin_x, origin_y, cap_w, cap_h, capture_device, opts, server })
    }

    pub fn has_clients(&self) -> bool {
        self.server.has_clients()
    }

    /// Run until `stop` is set. Calls `on_server_ready` once after the listener is up.
    pub fn run(&self, stop: Arc<AtomicBool>, on_server_ready: Option<Box<dyn Fn() + Send>>) {
        let device = match &self.capture_device {
            Some(d) => d.clone(),
            None => {
                logline!("StreamingSession requires a capture device for DXGI");
                return;
            }
        };
        let mut dxgi = match DxgiCapture::new(&device) {
            Ok(d) => d,
            Err(e) => {
                logline!("DXGI capture failed: {e}");
                return;
            }
        };
        let cap_w = dxgi.width as i32;
        let cap_h = dxgi.height as i32;

        let mut target_fps = if self.opts.adaptive { self.opts.max_adaptive_fps } else { self.opts.target_fps };
        let enc_w = (if self.opts.requested_enc_w > 0 {
            self.opts.requested_enc_w.min(cap_w as u32)
        } else {
            cap_w as u32
        }) & !1;
        let enc_h = (if self.opts.requested_enc_h > 0 {
            self.opts.requested_enc_h.min(cap_h as u32)
        } else if enc_w != cap_w as u32 {
            ((enc_w as f64 * cap_h as f64 / cap_w as f64).round() as u32) & !1
        } else {
            cap_h as u32
        }) & !1;

        let mut gpu = !self.opts.force_cpu;
        logline!(
            "Capturing: {cap_w}x{cap_h} @ {target_fps} fps, HEVC {enc_w}x{enc_h} ({})",
            if gpu { "GPU zero-copy" } else { "DXGI capture + CPU convert" }
        );

        self.server.start(enc_w, enc_h);
        if let Some(cb) = on_server_ready {
            cb();
        }

        // Input pump: inject touch/keys on a dedicated thread (independent of video stalls).
        let input_server = Arc::clone(&self.server);
        let input_stop = Arc::clone(&stop);
        let (ox, oy, cw, ch) = (self.origin_x, self.origin_y, cap_w, cap_h);
        let input_thread = std::thread::Builder::new()
            .name("InputPump".into())
            .spawn(move || {
                while !input_stop.load(Ordering::SeqCst) {
                    let mut did = false;
                    while let Some(t) = input_server.poll_touch() {
                        input::inject_touch(t.action, t.x, t.y, ox, oy, cw, ch);
                        did = true;
                    }
                    while let Some(k) = input_server.poll_key() {
                        input::inject_key(k.action, k.key_code);
                        did = true;
                    }
                    if !did {
                        std::thread::sleep(Duration::from_millis(1));
                    }
                }
            })
            .ok();

        let mut nv12 = vec![0u8; (enc_w * enc_h * 3 / 2) as usize];
        let mut encoder: Option<HevcEncoder> = None;
        let mut converter: Option<GpuColorConverter> = None;
        let mut last_output = Instant::now();
        let mut captured = 0u64;
        let mut last_stat = Instant::now();
        let mut last_client_count = 0usize;
        let mut last_cur: Option<CursorState> = None;

        while !stop.load(Ordering::SeqCst) {
            let frame_start = Instant::now();

            if !self.server.has_clients() {
                input::release_all_keys();
                if encoder.is_some() {
                    encoder = None;
                    converter = None;
                    logline!("No clients — encoder released");
                }
                std::thread::sleep(Duration::from_millis(100));
                continue;
            }

            // Adaptive fps from the client's reported refresh.
            if self.opts.adaptive {
                let pref = self.server.preferred_refresh_rate();
                let lo = 15u32.min(self.opts.max_adaptive_fps);
                let desired = pref.clamp(lo, self.opts.max_adaptive_fps.max(lo));
                if desired != target_fps {
                    target_fps = desired;
                    encoder = None;
                    converter = None;
                    logline!("Adaptive fps -> {target_fps}");
                }
            }

            // Watchdog: recreate a faulted or wedged encoder (hard stalls never self-recover).
            if let Some(enc) = &encoder {
                if enc.faulted() || last_output.elapsed() > Duration::from_millis(6000) {
                    let faulted = enc.faulted();
                    let idle = last_output.elapsed().as_millis();
                    logline!("Encoder unhealthy (faulted={faulted}, idle={idle}ms) — releasing");
                    encoder = None;
                    converter = None;
                    logline!("Encoder released — rebuilding");
                }
            }

            // Fresh keyframe for a newly joined client.
            let cc = self.server.client_count();
            if cc > last_client_count && encoder.is_some() {
                logline!("New client — releasing encoder for a fresh keyframe");
                encoder = None;
                converter = None;
                logline!("Old encoder released");
            }
            last_client_count = cc;

            if encoder.is_none() {
                if gpu {
                    match GpuColorConverter::new(dxgi.device(), dxgi.context(), cap_w as u32, cap_h as u32, enc_w, enc_h, target_fps) {
                        Ok(c) => converter = Some(c),
                        Err(e) => {
                            logline!("GPU VPP init failed ({e}); falling back to CPU convert");
                            gpu = false;
                        }
                    }
                }
                let d3d = if gpu { Some(dxgi.device()) } else { None };
                let server = Arc::clone(&self.server);
                let sent_c = Arc::new(std::sync::atomic::AtomicU64::new(0));
                let bytes_c = Arc::new(std::sync::atomic::AtomicU64::new(0));
                let sent2 = Arc::clone(&sent_c);
                let bytes2 = Arc::clone(&bytes_c);
                let cb = Arc::new(move |data: &[u8], pts: i64, key: bool| {
                    sent2.fetch_add(1, Ordering::Relaxed);
                    bytes2.fetch_add(data.len() as u64, Ordering::Relaxed);
                    server.broadcast_frame(pts, key, data);
                });
                match HevcEncoder::new(enc_w, enc_h, target_fps, 12_000_000, d3d, cb) {
                    Ok(e) => {
                        last_output = Instant::now();
                        encoder = Some(e);
                    }
                    Err(e) => {
                        logline!("Encoder create failed: {e}");
                        std::thread::sleep(Duration::from_millis(500));
                        continue;
                    }
                }
            }

            // Capture + convert + submit.
            let ts = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_micros() as i64)
                .unwrap_or(0);
            if gpu {
                if let Some(tex) = dxgi.update_gpu(12) {
                    if let Some(conv) = converter.as_mut() {
                        match conv.convert(&tex) {
                            Ok(nv) => {
                                if let Some(enc) = &encoder {
                                    enc.submit_texture(nv, ts);
                                    last_output = Instant::now();
                                    captured += 1;
                                }
                            }
                            Err(e) => logline!("VPP convert failed: {e}"),
                        }
                    }
                }
            } else if dxgi.update(12) && dxgi.ready() {
                bgra_to_nv12(dxgi.frame(), dxgi.stride as usize, &mut nv12, enc_w as usize, enc_h as usize);
                if let Some(enc) = &encoder {
                    enc.submit_frame(nv12.clone(), ts);
                    last_output = Instant::now();
                    captured += 1;
                }
            }

            // Cursor overlay packet (scaled to encode resolution).
            {
                let cw = scale(dxgi.cur_w as i32, enc_w as i32, cap_w);
                let ch = scale(dxgi.cur_h as i32, enc_h as i32, cap_h);
                let cx = scale(dxgi.cur_x, enc_w as i32, cap_w);
                let cy = scale(dxgi.cur_y, enc_h as i32, cap_h);
                let changed = last_cur.as_ref().map(|c| {
                    c.visible != dxgi.cur_visible || c.x != cx || c.y != cy || c.w != cw || c.h != ch
                }) != Some(false);
                if changed || dxgi.cursor_shape_dirty {
                    let bgra = if dxgi.cur_visible {
                        Arc::new(scale_bgra(&dxgi.cur_bgra, dxgi.cur_w as i32, dxgi.cur_h as i32, cw, ch))
                    } else {
                        Arc::new(Vec::new())
                    };
                    let st = CursorState { visible: dxgi.cur_visible, x: cx, y: cy, w: cw, h: ch, bgra };
                    self.server.broadcast_cursor(st.clone());
                    last_cur = Some(st);
                    dxgi.cursor_shape_dirty = false;
                }
            }

            // Stats every 5s.
            if last_stat.elapsed() >= Duration::from_secs(5) {
                let secs = last_stat.elapsed().as_secs_f64().max(0.001);
                logline!(
                    "  capture {:.1} fps (#{}) | input {} keys {} touch",
                    captured as f64 / secs,
                    captured,
                    input::injected_keys(),
                    input::injected_touches()
                );
                captured = 0;
                last_stat = Instant::now();
            }

            let frame_ms = 1000.0 / target_fps.max(1) as f64;
            let elapsed = frame_start.elapsed().as_secs_f64() * 1000.0;
            if elapsed < frame_ms {
                std::thread::sleep(Duration::from_micros(((frame_ms - elapsed) * 1000.0) as u64));
            }
        }

        input::release_all_keys();
        stop.store(true, Ordering::SeqCst);
        if let Some(h) = input_thread {
            let _ = h.join();
        }
        self.server.dispose();
    }
}

fn scale(value: i32, output: i32, input: i32) -> i32 {
    if input <= 0 {
        return value;
    }
    ((value as f64 * output as f64 / input as f64).round()) as i32
}

/// Nearest-neighbour rescale of a straight-BGRA cursor bitmap (see C# `StreamingSession.ScaleBgra`).
fn scale_bgra(src: &[u8], sw: i32, sh: i32, dw: i32, dh: i32) -> Vec<u8> {
    if sw == dw && sh == dh {
        return src.to_vec();
    }
    if sw <= 0 || sh <= 0 || dw <= 0 || dh <= 0 {
        return src.to_vec();
    }
    let (sw, sh, dw, dh) = (sw as usize, sh as usize, dw as usize, dh as usize);
    let mut dst = vec![0u8; dw * dh * 4];
    for y in 0..dh {
        let sy = y * sh / dh;
        for x in 0..dw {
            let sx = x * sw / dw;
            let si = (sy * sw + sx) * 4;
            let di = (y * dw + x) * 4;
            dst[di..di + 4].copy_from_slice(&src[si..si + 4]);
        }
    }
    dst
}
