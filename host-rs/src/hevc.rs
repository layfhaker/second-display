//! Hardware HEVC encoder via the Windows Media Foundation encoder MFT (QuickSync on Intel),
//! mirroring the C# `HevcEncoder`.
//!
//! Two input modes:
//!   * CPU: NV12 in memory (`submit_frame`) — used by the CPU path;
//!   * zero-copy: an NV12 D3D11 texture (`submit_texture`) — used by the GPU path. Requires the
//!     shared D3D11 device (the MFT gets an IMFDXGIDeviceManager).
//! Output: raw HEVC Annex-B access units via a callback, driven by the async MFT event loop.

use crate::logline;
use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::Duration;
use windows::core::{GUID, HRESULT, Interface};
use windows::Win32::Graphics::Direct3D11::ID3D11Texture2D;
use windows::Win32::Media::MediaFoundation::{
    IMF2DBuffer, IMFActivate, IMFAttributes, IMFDXGIDeviceManager, IMFMediaEventGenerator,
    IMFMediaType, IMFSample, IMFTransform, MFCreateDXGIDeviceManager, MFCreateDXGISurfaceBuffer,
    MFCreateMediaType, MFCreateMemoryBuffer, MFCreateSample, MFShutdown, MFStartup, MFTEnumEx,
    MFT_CATEGORY_VIDEO_ENCODER, MFT_ENUM_FLAG_HARDWARE, MFT_ENUM_FLAG_SORTANDFILTER,
    MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, MFT_MESSAGE_NOTIFY_END_OF_STREAM,
    MFT_MESSAGE_NOTIFY_START_OF_STREAM, MFT_MESSAGE_SET_D3D_MANAGER, MFT_OUTPUT_DATA_BUFFER,
    MFT_REGISTER_TYPE_INFO, MEDIA_EVENT_GENERATOR_GET_EVENT_FLAGS, MEDIATYPE_Video,
    MFVideoFormat_HEVC, MFVideoFormat_NV12, MF_MT_AVG_BITRATE, MF_MT_FRAME_RATE, MF_MT_FRAME_SIZE,
    MF_MT_INTERLACE_MODE, MF_MT_MAJOR_TYPE, MF_MT_PIXEL_ASPECT_RATIO, MF_MT_SUBTYPE, MF_LOW_LATENCY,
    MF_TRANSFORM_ASYNC_UNLOCK,
};
use windows::Win32::System::Com::CoTaskMemFree;

const MF_E_TRANSFORM_NEED_MORE_INPUT: HRESULT = HRESULT(0xC00D6D72u32 as i32);
// MF_E_NO_EVENTS_AVAILABLE (mfapi.h) — returned by GetEvent with MF_EVENT_FLAG_NO_WAIT when idle.
const MF_E_NO_EVENTS_AVAILABLE: HRESULT = HRESULT(0xC00D3E80u32 as i32);
const METRANSFORM_NEED_INPUT: u32 = 601;
const METRANSFORM_HAVE_OUTPUT: u32 = 602;
const MFVIDEO_INTERLACE_PROGRESSIVE: u32 = 2;
const IID_ID3D11TEXTURE2D: GUID = GUID::from_u128(0x6f15aaf2_d208_4e89_9ab4_489535d34f9c);

fn pack(high: u32, low: u32) -> u64 {
    ((high as u64) << 32) | low as u64
}

/// Wrapper so the (exclusively-used-by-one-thread) COM interfaces can be moved into the event thread.
/// Getters are used so the closure captures the whole wrapper (Rust 2024 precise capture would
/// otherwise capture `.0`, i.e. the !Send interface, bypassing this Send impl).
struct SendTransform(IMFTransform);
unsafe impl Send for SendTransform {}
impl SendTransform {
    fn get(&self) -> &IMFTransform {
        &self.0
    }
}
struct SendEventGen(IMFMediaEventGenerator);
unsafe impl Send for SendEventGen {}
impl SendEventGen {
    fn get(&self) -> &IMFMediaEventGenerator {
        &self.0
    }
}
/// A D3D11 texture passed across the submit→event thread boundary.
struct SendTex(ID3D11Texture2D);
unsafe impl Send for SendTex {}

enum Input {
    Cpu(Vec<u8>),
    Tex(SendTex),
}

/// Bounded (cap 2), drop-oldest frame queue.
struct Queue {
    inner: Mutex<VecDeque<(Input, i64)>>,
    cv: Condvar,
}

impl Queue {
    fn new() -> Self {
        Self { inner: Mutex::new(VecDeque::with_capacity(3)), cv: Condvar::new() }
    }
    fn push(&self, item: (Input, i64)) {
        let mut q = self.inner.lock().unwrap();
        while q.len() >= 2 {
            q.pop_front();
        }
        q.push_back(item);
        self.cv.notify_one();
    }
    fn pop_timeout(&self, ms: u64) -> Option<(Input, i64)> {
        let mut q = self.inner.lock().unwrap();
        if q.is_empty() {
            let (nq, _) = self.cv.wait_timeout(q, Duration::from_millis(ms)).unwrap();
            q = nq;
        }
        q.pop_front()
    }
    fn wake(&self) {
        self.cv.notify_all();
    }
}

pub struct HevcEncoder {
    queue: Arc<Queue>,
    running: Arc<AtomicBool>,
    faulted: Arc<AtomicBool>,
    frame_duration_hns: i64,
    join: Option<std::thread::JoinHandle<()>>,
}

impl HevcEncoder {
    /// `d3d_device` = Some for zero-copy texture input (GPU path), None for CPU memory input.
    pub fn new(
        width: u32,
        height: u32,
        fps: u32,
        bitrate: u32,
        d3d_device: Option<&windows::Win32::Graphics::Direct3D11::ID3D11Device>,
        on_frame: Arc<dyn Fn(&[u8], i64, bool) + Send + Sync>,
    ) -> Result<Self, String> {
        unsafe {
            MFStartup(0x0002_0070, 0).map_err(|e| e.to_string())?;
        }

        let out_info = MFT_REGISTER_TYPE_INFO {
            guidMajorType: MEDIATYPE_Video,
            guidSubtype: MFVideoFormat_HEVC,
        };
        let mut activates: *mut Option<IMFActivate> = std::ptr::null_mut();
        let mut count: u32 = 0;
        unsafe {
            MFTEnumEx(
                MFT_CATEGORY_VIDEO_ENCODER,
                MFT_ENUM_FLAG_HARDWARE | MFT_ENUM_FLAG_SORTANDFILTER,
                None,
                Some(&out_info),
                &mut activates,
                &mut count,
            )
            .map_err(|e| e.to_string())?;
        }
        if count == 0 || activates.is_null() {
            return Err("No hardware HEVC encoder MFT found".into());
        }
        let activate = unsafe { (*activates).clone().ok_or("null IMFActivate")? };
        unsafe { CoTaskMemFree(Some(activates as *const core::ffi::c_void)) };

        let transform: IMFTransform =
            unsafe { activate.ActivateObject().map_err(|e| e.to_string())? };

        let attrs: IMFAttributes = unsafe { transform.GetAttributes().map_err(|e| e.to_string())? };
        unsafe {
            let _ = attrs.SetUINT32(&MF_TRANSFORM_ASYNC_UNLOCK, 1);
            let _ = attrs.SetUINT32(&MF_LOW_LATENCY, 1);
        }

        // Zero-copy: hand the shared D3D11 device to the MFT via an IMFDXGIDeviceManager.
        if let Some(dev) = d3d_device {
            let mut token = 0u32;
            let mut manager: Option<IMFDXGIDeviceManager> = None;
            unsafe {
                MFCreateDXGIDeviceManager(&mut token, &mut manager).map_err(|e| e.to_string())?;
            }
            let manager = manager.ok_or("MFCreateDXGIDeviceManager returned null")?;
            unsafe {
                manager
                    .ResetDevice(dev, token)
                    .map_err(|e| e.to_string())?;
                transform
                    .ProcessMessage(
                        MFT_MESSAGE_SET_D3D_MANAGER,
                        manager.as_raw() as usize,
                    )
                    .map_err(|e| e.to_string())?;
            }
            // The MFT now holds its own reference; we do not keep the (!Send) manager on the struct.
        }

        // Output (HEVC) then input (NV12).
        let out_type: IMFMediaType = unsafe { MFCreateMediaType().map_err(|e| e.to_string())? };
        unsafe {
            out_type.SetGUID(&MF_MT_MAJOR_TYPE, &MEDIATYPE_Video).map_err(|e| e.to_string())?;
            out_type.SetGUID(&MF_MT_SUBTYPE, &MFVideoFormat_HEVC).map_err(|e| e.to_string())?;
            out_type.SetUINT32(&MF_MT_AVG_BITRATE, bitrate).map_err(|e| e.to_string())?;
            out_type.SetUINT32(&MF_MT_INTERLACE_MODE, MFVIDEO_INTERLACE_PROGRESSIVE).ok();
            out_type.SetUINT64(&MF_MT_FRAME_SIZE, pack(width, height)).map_err(|e| e.to_string())?;
            out_type.SetUINT64(&MF_MT_FRAME_RATE, pack(fps, 1)).map_err(|e| e.to_string())?;
            out_type.SetUINT64(&MF_MT_PIXEL_ASPECT_RATIO, pack(1, 1)).ok();
            transform.SetOutputType(0, &out_type, 0).map_err(|e| e.to_string())?;
        }

        let in_type: IMFMediaType = unsafe { MFCreateMediaType().map_err(|e| e.to_string())? };
        unsafe {
            in_type.SetGUID(&MF_MT_MAJOR_TYPE, &MEDIATYPE_Video).map_err(|e| e.to_string())?;
            in_type.SetGUID(&MF_MT_SUBTYPE, &MFVideoFormat_NV12).map_err(|e| e.to_string())?;
            in_type.SetUINT32(&MF_MT_INTERLACE_MODE, MFVIDEO_INTERLACE_PROGRESSIVE).ok();
            in_type.SetUINT64(&MF_MT_FRAME_SIZE, pack(width, height)).map_err(|e| e.to_string())?;
            in_type.SetUINT64(&MF_MT_FRAME_RATE, pack(fps, 1)).map_err(|e| e.to_string())?;
            in_type.SetUINT64(&MF_MT_PIXEL_ASPECT_RATIO, pack(1, 1)).ok();
            transform.SetInputType(0, &in_type, 0).map_err(|e| e.to_string())?;
        }

        let osi = unsafe { transform.GetOutputStreamInfo(0).map_err(|e| e.to_string())? };
        // MFT_OUTPUT_STREAM_PROVIDES_SAMPLES(0x100) | MFT_OUTPUT_STREAM_CAN_PROVIDE_SAMPLES(0x200)
        let provides_samples = (osi.dwFlags & (0x100 | 0x200)) != 0;
        let out_buffer_size = osi.cbSize.max(width * height * 2);

        let event_gen: IMFMediaEventGenerator =
            unsafe { transform.cast().map_err(|e| e.to_string())? };

        unsafe {
            let _ = transform.ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0);
            let _ = transform.ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0);
        }

        let queue = Arc::new(Queue::new());
        let running = Arc::new(AtomicBool::new(true));
        let faulted = Arc::new(AtomicBool::new(false));
        let frame_duration_hns = 10_000_000i64 / fps.max(1) as i64;

        logline!(
            "HEVC encoder: MF hardware encoder MFT ({count} found, {})",
            if d3d_device.is_some() { "zero-copy D3D11 input" } else { "CPU NV12 input" }
        );

        let q = Arc::clone(&queue);
        let run = Arc::clone(&running);
        let fault = Arc::clone(&faulted);
        let st = SendTransform(transform);
        let se = SendEventGen(event_gen);
        let join = std::thread::Builder::new()
            .name("HevcEncoderEvents".into())
            .spawn(move || {
                event_loop(st.get(), se.get(), &q, &run, &fault, frame_duration_hns, provides_samples, out_buffer_size, on_frame);
            })
            .map_err(|e| e.to_string())?;

        Ok(Self { queue, running, faulted, frame_duration_hns, join: Some(join) })
    }

    /// CPU input: NV12 bytes. Non-blocking (drop-oldest keeps latency minimal).
    pub fn submit_frame(&self, nv12: Vec<u8>, pts_micros: i64) {
        if !self.running.load(Ordering::SeqCst) {
            return;
        }
        self.queue.push((Input::Cpu(nv12), pts_micros));
    }

    /// Zero-copy input: an NV12 D3D11 texture (owned by the converter ring).
    pub fn submit_texture(&self, tex: ID3D11Texture2D, pts_micros: i64) {
        if !self.running.load(Ordering::SeqCst) {
            return;
        }
        self.queue.push((Input::Tex(SendTex(tex)), pts_micros));
    }

    pub fn faulted(&self) -> bool {
        self.faulted.load(Ordering::SeqCst)
    }

    pub fn frame_duration_hns(&self) -> i64 {
        self.frame_duration_hns
    }

    pub fn dispose(&mut self) {
        self.running.store(false, Ordering::SeqCst);
        self.queue.wake();
        if let Some(j) = self.join.take() {
            let _ = j.join();
        }
        unsafe {
            let _ = MFShutdown();
        }
    }
}

impl Drop for HevcEncoder {
    fn drop(&mut self) {
        self.dispose();
    }
}

#[allow(clippy::too_many_arguments)]
fn event_loop(
    transform: &IMFTransform,
    event_gen: &IMFMediaEventGenerator,
    queue: &Queue,
    running: &AtomicBool,
    faulted: &AtomicBool,
    frame_duration_hns: i64,
    provides_samples: bool,
    out_buffer_size: u32,
    on_frame: Arc<dyn Fn(&[u8], i64, bool) + Send + Sync>,
) {
    while running.load(Ordering::SeqCst) {
        // MF_EVENT_FLAG_NO_WAIT(0x1): never block here — a blocking GetEvent would wedge the loop.
        let ev = match unsafe { event_gen.GetEvent(MEDIA_EVENT_GENERATOR_GET_EVENT_FLAGS(1)) } {
            Ok(ev) => ev,
            Err(e) => {
                if e.code() == MF_E_NO_EVENTS_AVAILABLE {
                    std::thread::sleep(Duration::from_millis(1));
                    continue;
                }
                logline!("Encoder event loop fault: {e:?} — flagging for restart");
                faulted.store(true, Ordering::SeqCst);
                return;
            }
        };
        let ty = unsafe { ev.GetType() }.unwrap_or(0);

        if ty == METRANSFORM_NEED_INPUT {
            // Must fulfil the request; wait for input (queue is fed by the capture loop).
            loop {
                if !running.load(Ordering::SeqCst) {
                    return;
                }
                if let Some((input, pts)) = queue.pop_timeout(500) {
                    let res = match input {
                        Input::Cpu(nv12) => feed_input(transform, &nv12, pts, frame_duration_hns),
                        Input::Tex(t) => feed_texture(transform, &t.0, pts, frame_duration_hns),
                    };
                    if let Err(e) = res {
                        logline!("Encoder ProcessInput failed: {e:?} — flagging for restart");
                        faulted.store(true, Ordering::SeqCst);
                        return;
                    }
                    break;
                }
            }
        } else if ty == METRANSFORM_HAVE_OUTPUT {
            if let Err(e) = drain_output(transform, provides_samples, out_buffer_size, &on_frame) {
                logline!("Encoder ProcessOutput failed: {e:?} — flagging for restart");
                faulted.store(true, Ordering::SeqCst);
                return;
            }
        }
    }
    unsafe {
        let _ = transform.ProcessMessage(MFT_MESSAGE_NOTIFY_END_OF_STREAM, 0);
    }
}

fn feed_input(
    transform: &IMFTransform,
    nv12: &[u8],
    pts_micros: i64,
    frame_duration_hns: i64,
) -> windows::core::Result<()> {
    unsafe {
        let buffer = MFCreateMemoryBuffer(nv12.len() as u32)?;
        let mut ptr: *mut u8 = std::ptr::null_mut();
        let mut max_len = 0u32;
        buffer.Lock(&mut ptr, Some(&mut max_len), None)?;
        std::ptr::copy_nonoverlapping(nv12.as_ptr(), ptr, nv12.len());
        buffer.Unlock()?;
        buffer.SetCurrentLength(nv12.len() as u32)?;

        let sample: IMFSample = MFCreateSample()?;
        sample.AddBuffer(&buffer)?;
        sample.SetSampleTime(pts_micros * 10)?;
        sample.SetSampleDuration(frame_duration_hns)?;
        transform.ProcessInput(0, &sample, 0)
    }
}

/// Zero-copy: wrap the NV12 D3D11 texture as a surface-backed sample (no RAM copy).
fn feed_texture(
    transform: &IMFTransform,
    tex: &ID3D11Texture2D,
    pts_micros: i64,
    frame_duration_hns: i64,
) -> windows::core::Result<()> {
    unsafe {
        let buffer = MFCreateDXGISurfaceBuffer(&IID_ID3D11TEXTURE2D, tex, 0, false)?;
        let b2d: IMF2DBuffer = buffer.cast()?;
        buffer.SetCurrentLength(b2d.GetContiguousLength()?)?;

        let sample: IMFSample = MFCreateSample()?;
        sample.AddBuffer(&buffer)?;
        sample.SetSampleTime(pts_micros * 10)?;
        sample.SetSampleDuration(frame_duration_hns)?;
        transform.ProcessInput(0, &sample, 0)
    }
}

fn drain_output(
    transform: &IMFTransform,
    provides_samples: bool,
    out_buffer_size: u32,
    on_frame: &Arc<dyn Fn(&[u8], i64, bool) + Send + Sync>,
) -> windows::core::Result<()> {
    unsafe {
        let sample: Option<IMFSample> = if provides_samples {
            None
        } else {
            let s: IMFSample = MFCreateSample()?;
            let b = MFCreateMemoryBuffer(out_buffer_size)?;
            s.AddBuffer(&b)?;
            Some(s)
        };
        let mut odb = MFT_OUTPUT_DATA_BUFFER {
            dwStreamID: 0,
            pSample: std::mem::ManuallyDrop::new(sample),
            dwStatus: 0,
            pEvents: std::mem::ManuallyDrop::new(None),
        };
        let mut status = 0u32;
        let res = transform.ProcessOutput(0, std::slice::from_mut(&mut odb), &mut status);
        if let Err(e) = res {
            if e.code() == MF_E_TRANSFORM_NEED_MORE_INPUT {
                return Ok(());
            }
            return Err(e);
        }

        let out_sample = (*odb.pSample).clone();
        let Some(out_sample) = out_sample else {
            return Ok(());
        };
        let pts_micros = out_sample.GetSampleTime().unwrap_or(0) / 10;
        let contiguous = out_sample.ConvertToContiguousBuffer()?;
        let mut ptr: *mut u8 = std::ptr::null_mut();
        let mut cur_len = 0u32;
        contiguous.Lock(&mut ptr, None, Some(&mut cur_len))?;
        let data = std::slice::from_raw_parts(ptr, cur_len as usize).to_vec();
        contiguous.Unlock()?;

        on_frame(&data, pts_micros, is_hevc_keyframe(&data));
        Ok(())
    }
}

fn is_hevc_keyframe(data: &[u8]) -> bool {
    let mut i = 0usize;
    while i + 5 < data.len() {
        let sc = if data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1 {
            3
        } else if i + 3 < data.len() && data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 0 && data[i + 3] == 1 {
            4
        } else {
            0
        };
        if sc == 0 {
            i += 1;
            continue;
        }
        let nal_header = i + sc;
        if nal_header >= data.len() {
            break;
        }
        let nal_type = (data[nal_header] >> 1) & 0x3F;
        if matches!(nal_type, 19 | 20 | 32 | 33 | 34) {
            return true;
        }
        i = nal_header + 1;
    }
    false
}
