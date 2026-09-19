//! SecondDisplay host (Rust rewrite).
//!
//! A staged port of the C# host (`host/SecondDisplay.Host`). Both live side by side; the C# host
//! remains the reference/working build while this one reaches parity.

mod adb;
mod convert;
mod device_readiness;
mod display_config;
mod dxgi;
mod gpu_convert;
mod hevc;
mod input;
mod log;
mod options;
mod orchestrator;
mod protocol;
mod server;
mod single_instance;
mod streaming;
mod vdd;

use options::{get_arg, has_flag, Options};
use std::sync::atomic::AtomicBool;
use std::sync::Arc;

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();

    // --probe: exercise monitor enumeration + adb without touching the log file, the single-instance
    // mutex or port 27315 (so it can run alongside the C# host).
    if has_flag(&args, "--probe") {
        println!("SecondDisplay Host (Rust) probe");
        let monitors = display_config::get_monitors();
        println!("monitors: {}", monitors.len());
        for m in &monitors {
            println!(
                "  [{}] {} {}x{} @ ({},{}){}",
                m.index,
                m.device,
                m.width,
                m.height,
                m.x,
                m.y,
                if m.primary { "  PRIMARY" } else { "" }
            );
        }
        let adb = adb::AdbController::new(get_arg(&args, "--adb"), "com.seconddisplay.client", 27315);
        println!("adb = {}", adb.adb_path());
        println!("adb devices: {:?}", adb.list_devices());
        return;
    }

    if has_flag(&args, "--selftest-hevc") {
        selftest_hevc();
        return;
    }
    if let Some(v) = get_arg(&args, "--selftest-gpu") {
        let idx: i32 = v.parse().unwrap_or(-1);
        let secs: u64 = get_arg(&args, "--selftest-seconds").and_then(|s| s.parse().ok()).unwrap_or(5);
        selftest_gpu(idx, secs, !has_flag(&args, "--cpu"));
        return;
    }

    // Single-instance guard first, like the C# host.
    let _single = match single_instance::SingleInstance::acquire() {
        Some(s) => s,
        None => {
            println!("Another SecondDisplay host is already running.");
            return;
        }
    };

    // High priority so the async HEVC MFT and the capture loop are not starved on a busy machine.
    unsafe { set_high_priority() };

    log::init(&log::default_log_path());
    logline!("SecondDisplay Host (Rust) v{}", env!("CARGO_PKG_VERSION"));
    logline!("=================================================");

    let opts = Options::from_args(&args);
    logline!("options: {opts:?}");

    let adb =
        adb::AdbController::new(get_arg(&args, "--adb"), "com.seconddisplay.client", 27315);
    logline!("adb = {}", adb.adb_path());

    if has_flag(&args, "--auto") {
        let vdd = vdd::VddController::new();
        orchestrator::Orchestrator::new(opts, adb, vdd).run(&AtomicBool::new(false));
        return;
    }

    // ---- manual mode ----
    let monitors = display_config::get_monitors();
    logline!("Available monitors:");
    for m in &monitors {
        logline!(
            "  [{}] {} {}x{} @ ({},{}){}",
            m.index,
            m.device,
            m.width,
            m.height,
            m.x,
            m.y,
            if m.primary { "  PRIMARY" } else { "" }
        );
    }

    let target = get_arg(&args, "--display")
        .and_then(|v| v.parse::<usize>().ok())
        .and_then(|i| monitors.get(i).cloned())
        .or_else(|| monitors.iter().find(|m| m.primary).cloned())
        .or_else(|| monitors.first().cloned());

    let Some(t) = target else {
        logline!("No monitors found.");
        return;
    };
    logline!("Capturing monitor [{}] {}", t.index, t.device);

    let session = match streaming::StreamingSession::new(
        t.x,
        t.y,
        t.width,
        t.height,
        Some(t.device.clone()),
        opts,
    ) {
        Ok(s) => s,
        Err(e) => {
            logline!("Cannot start session: {e}");
            return;
        }
    };

    logline!("Waiting for client... (Ctrl+C to stop)");
    session.run(Arc::new(AtomicBool::new(false)), None);
}

/// Best-effort High priority (ignored if not permitted).
unsafe fn set_high_priority() {
    use windows::Win32::System::Threading::{
        GetCurrentProcess, SetPriorityClass, HIGH_PRIORITY_CLASS,
    };
    unsafe {
        let _ = SetPriorityClass(GetCurrentProcess(), HIGH_PRIORITY_CLASS);
    }
}

/// Feed synthetic NV12 frames through the MF HEVC encoder (no capture, no port, no mutex).
fn selftest_hevc() {
    use std::sync::atomic::Ordering;
    println!("=== HEVC encoder self-test (synthetic NV12) ===");
    let encoded = Arc::new(std::sync::atomic::AtomicU64::new(0));
    let bytes = Arc::new(std::sync::atomic::AtomicU64::new(0));
    let e2 = Arc::clone(&encoded);
    let b2 = Arc::clone(&bytes);
    let cb: Arc<dyn Fn(&[u8], i64, bool) + Send + Sync> = Arc::new(move |data: &[u8], _pts: i64, _key: bool| {
        e2.fetch_add(1, Ordering::Relaxed);
        b2.fetch_add(data.len() as u64, Ordering::Relaxed);
    });

    let (w, h) = (1280u32, 720u32);
    let mut enc = match hevc::HevcEncoder::new(w, h, 30, 12_000_000, None, cb) {
        Ok(e) => e,
        Err(e) => {
            println!("FAIL: {e}");
            return;
        }
    };

    let mut nv12 = vec![0u8; (w * h * 3 / 2) as usize];
    for i in 0..120u32 {
        for y in 0..h {
            for x in 0..w {
                nv12[(y * w + x) as usize] = ((x + i * 3) % 256) as u8;
            }
        }
        let ts = (i as i64) * 1_000_000 / 30;
        enc.submit_frame(nv12.clone(), ts);
        std::thread::sleep(std::time::Duration::from_millis(33));
    }
    std::thread::sleep(std::time::Duration::from_millis(800));
    enc.dispose();

    let n = encoded.load(Ordering::Relaxed);
    let b = bytes.load(Ordering::Relaxed);
    println!("encoded {n} frames, {b} bytes");
    println!("RESULT: {}", if n > 0 { "HEVC encoder OK." } else { "NO output — investigate." });
}

/// DXGI capture (+ VPP zero-copy or CPU convert) → MF HEVC, on one monitor (no port/mutex).
fn selftest_gpu(index: i32, seconds: u64, gpu: bool) {
    use std::sync::atomic::Ordering;
    println!(
        "=== GPU pipeline self-test (DXGI + {} + MF HEVC) ===",
        if gpu { "VPP zero-copy" } else { "CPU convert" }
    );
    let monitors = display_config::get_monitors();
    let target = if index >= 0 && (index as usize) < monitors.len() {
        monitors[index as usize].clone()
    } else {
        monitors.iter().find(|m| m.primary).cloned().unwrap_or_else(|| monitors[0].clone())
    };
    println!("target: [{}] {} {}x{}", target.index, target.device, target.width, target.height);

    let mut dxgi = match dxgi::DxgiCapture::new(&target.device) {
        Ok(d) => d,
        Err(e) => {
            println!("FAIL: {e}");
            return;
        }
    };
    let w = dxgi.width & !1;
    let h = dxgi.height & !1;

    let encoded = Arc::new(std::sync::atomic::AtomicU64::new(0));
    let e2 = Arc::clone(&encoded);
    let cb: Arc<dyn Fn(&[u8], i64, bool) + Send + Sync> = Arc::new(move |_d: &[u8], _p: i64, _k: bool| {
        e2.fetch_add(1, Ordering::Relaxed);
    });

    let mut converter = None;
    let mut enc = if gpu {
        match gpu_convert::GpuColorConverter::new(dxgi.device(), dxgi.context(), w, h, w, h, 30) {
            Ok(c) => converter = Some(c),
            Err(e) => {
                println!("FAIL: {e}");
                return;
            }
        }
        match hevc::HevcEncoder::new(w, h, 30, 12_000_000, Some(dxgi.device()), cb) {
            Ok(e) => e,
            Err(e) => {
                println!("FAIL: {e}");
                return;
            }
        }
    } else {
        match hevc::HevcEncoder::new(w, h, 30, 12_000_000, None, cb) {
            Ok(e) => e,
            Err(e) => {
                println!("FAIL: {e}");
                return;
            }
        }
    };

    let mut nv12 = vec![0u8; (w * h * 3 / 2) as usize];
    let start = std::time::Instant::now();
    let mut captured = 0u64;
    while start.elapsed().as_secs() < seconds {
        let ts = start.elapsed().as_micros() as i64;
        if gpu {
            if let Some(tex) = dxgi.update_gpu(12) {
                let conv = converter.as_mut().unwrap();
                if let Ok(nv) = conv.convert(&tex) {
                    enc.submit_texture(nv, ts);
                }
                captured += 1;
            }
        } else if dxgi.update(12) && dxgi.ready() {
            convert::bgra_to_nv12(dxgi.frame(), dxgi.stride as usize, &mut nv12, w as usize, h as usize);
            enc.submit_frame(nv12.clone(), ts);
            captured += 1;
        }
        std::thread::sleep(std::time::Duration::from_millis(33));
    }
    std::thread::sleep(std::time::Duration::from_millis(800));
    enc.dispose();

    let el = start.elapsed().as_secs_f64();
    let n = encoded.load(Ordering::Relaxed);
    println!("captured {captured} ({:.1} fps), encoded {n} ({:.1} fps)", captured as f64 / el, n as f64 / el);
    println!("RESULT: {}", if n > 0 { "pipeline OK." } else { "NO output - investigate." });
}
