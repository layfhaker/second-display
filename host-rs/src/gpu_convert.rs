//! GPU BGRA→NV12 conversion via `ID3D11VideoProcessor` (the fixed-function VPP on the Intel iGPU),
//! mirroring the C# `GpuColorConverter`.
//!
//! Keeps the tract in video memory: DXGI desktop texture → VPP → NV12 texture → encoder (zero-copy).
//! The cursor is NOT composited here; the client draws it as an overlay (see `streaming.rs`).

use crate::logline;
use windows::core::Interface;
use windows::Win32::Graphics::Direct3D11::{
    ID3D11Device, ID3D11DeviceContext, ID3D11Texture2D, ID3D11VideoContext, ID3D11VideoDevice,
    ID3D11VideoProcessor, ID3D11VideoProcessorEnumerator, ID3D11VideoProcessorInputView,
    ID3D11VideoProcessorOutputView, D3D11_BIND_RENDER_TARGET, D3D11_CPU_ACCESS_FLAG,
    D3D11_RESOURCE_MISC_FLAG, D3D11_TEX2D_VPIV, D3D11_TEX2D_VPOV, D3D11_TEXTURE2D_DESC,
    D3D11_USAGE_DEFAULT, D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE,
    D3D11_VIDEO_PROCESSOR_CONTENT_DESC, D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC,
    D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC, D3D11_VIDEO_PROCESSOR_STREAM,
    D3D11_VIDEO_USAGE_OPTIMAL_SPEED, D3D11_VPIV_DIMENSION_TEXTURE2D,
    D3D11_VPOV_DIMENSION_TEXTURE2D,
};
use windows::Win32::Graphics::Dxgi::Common::{DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_FORMAT_NV12, DXGI_RATIONAL, DXGI_SAMPLE_DESC};

const RING: usize = 8;

pub struct GpuColorConverter {
    device: ID3D11Device,
    video_device: ID3D11VideoDevice,
    video_context: ID3D11VideoContext,
    processor: ID3D11VideoProcessor,
    enumerator: ID3D11VideoProcessorEnumerator,
    input_w: u32,
    input_h: u32,
    width: u32,
    height: u32,
    nv12: Vec<ID3D11Texture2D>,
    out_views: Vec<ID3D11VideoProcessorOutputView>,
    ring: usize,
    desktop_view: Option<ID3D11VideoProcessorInputView>,
    desktop_raw: isize,
}

impl GpuColorConverter {
    pub fn new(
        device: &ID3D11Device,
        context: &ID3D11DeviceContext,
        input_w: u32,
        input_h: u32,
        width: u32,
        height: u32,
        fps: u32,
    ) -> Result<Self, String> {
        let input_w = input_w & !1;
        let input_h = input_h & !1;
        let width = width & !1;
        let height = height & !1;

        let video_device: ID3D11VideoDevice = device.cast().map_err(|e| e.to_string())?;
        let video_context: ID3D11VideoContext = context.cast().map_err(|e| e.to_string())?;

        let content = D3D11_VIDEO_PROCESSOR_CONTENT_DESC {
            InputFrameFormat: D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE,
            InputFrameRate: DXGI_RATIONAL { Numerator: fps, Denominator: 1 },
            InputWidth: input_w,
            InputHeight: input_h,
            OutputFrameRate: DXGI_RATIONAL { Numerator: fps, Denominator: 1 },
            OutputWidth: width,
            OutputHeight: height,
            Usage: D3D11_VIDEO_USAGE_OPTIMAL_SPEED,
        };
        let enumerator = unsafe {
            video_device
                .CreateVideoProcessorEnumerator(&content)
                .map_err(|e| e.to_string())?
        };
        let processor = unsafe {
            video_device
                .CreateVideoProcessor(&enumerator, 0)
                .map_err(|e| e.to_string())?
        };

        // Full-range RGB input, BT.601 output (matches the CPU path's coefficients).
        let in_space = windows::Win32::Graphics::Direct3D11::D3D11_VIDEO_PROCESSOR_COLOR_SPACE {
            _bitfield: 0,
        };
        let out_space = windows::Win32::Graphics::Direct3D11::D3D11_VIDEO_PROCESSOR_COLOR_SPACE {
            _bitfield: 2, // Nominal_Range = 2 (0-255)
        };
        unsafe {
            video_context.VideoProcessorSetStreamColorSpace(&processor, 0, &in_space);
            video_context.VideoProcessorSetOutputColorSpace(&processor, &out_space);
            video_context.VideoProcessorSetStreamFrameFormat(
                &processor,
                0,
                D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE,
            );
        }

        let mut nv12 = Vec::with_capacity(RING);
        let mut out_views = Vec::with_capacity(RING);
        for _ in 0..RING {
            let tex = create_texture(
                device,
                width,
                height,
                DXGI_FORMAT_NV12,
                D3D11_BIND_RENDER_TARGET,
                D3D11_CPU_ACCESS_FLAG(0),
                D3D11_RESOURCE_MISC_FLAG(0),
            )?;
            let mut desc = D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC::default();
            desc.ViewDimension = D3D11_VPOV_DIMENSION_TEXTURE2D;
            desc.Anonymous.Texture2D = D3D11_TEX2D_VPOV { MipSlice: 0 };
            let mut view: Option<ID3D11VideoProcessorOutputView> = None;
            unsafe {
                video_device
                    .CreateVideoProcessorOutputView(&tex, &enumerator, &desc, Some(&mut view))
                    .map_err(|e| e.to_string())?;
            }
            out_views.push(view.ok_or("null output view")?);
            nv12.push(tex);
        }

        logline!("GPU VPP: BGRA {input_w}x{input_h}->NV12 {width}x{height}");

        Ok(Self {
            device: device.clone(),
            video_device,
            video_context,
            processor,
            enumerator,
            input_w,
            input_h,
            width,
            height,
            nv12,
            out_views,
            ring: 0,
            desktop_view: None,
            desktop_raw: 0,
        })
    }

    fn desktop_input_view(&mut self, desktop: &ID3D11Texture2D) -> Result<ID3D11VideoProcessorInputView, String> {
        let raw = desktop.as_raw() as isize;
        if self.desktop_view.is_some() && self.desktop_raw == raw {
            return Ok(self.desktop_view.clone().unwrap());
        }
        let mut desc = D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC::default();
        desc.FourCC = 0;
        desc.ViewDimension = D3D11_VPIV_DIMENSION_TEXTURE2D;
        desc.Anonymous.Texture2D = D3D11_TEX2D_VPIV { MipSlice: 0, ArraySlice: 0 };
        let mut view: Option<ID3D11VideoProcessorInputView> = None;
        unsafe {
            self.video_device
                .CreateVideoProcessorInputView(desktop, &self.enumerator, &desc, Some(&mut view))
                .map_err(|e| e.to_string())?;
        }
        self.desktop_view = view;
        self.desktop_raw = raw;
        Ok(self.desktop_view.clone().unwrap())
    }

    /// Convert the desktop texture to NV12 and return the ring texture. Valid for `RING` calls.
    pub fn convert(&mut self, desktop: &ID3D11Texture2D) -> Result<ID3D11Texture2D, String> {
        let slot = self.ring;
        self.ring = (self.ring + 1) % RING;

        let view = self.desktop_input_view(desktop)?;

        let full_in = windows::Win32::Foundation::RECT { left: 0, top: 0, right: self.input_w as i32, bottom: self.input_h as i32 };
        let full_out = windows::Win32::Foundation::RECT { left: 0, top: 0, right: self.width as i32, bottom: self.height as i32 };
        unsafe {
            self.video_context
                .VideoProcessorSetStreamSourceRect(&self.processor, 0, true, Some(&full_in));
            self.video_context
                .VideoProcessorSetStreamDestRect(&self.processor, 0, true, Some(&full_out));
        }

        let stream = D3D11_VIDEO_PROCESSOR_STREAM {
            Enable: true.into(),
            pInputSurface: std::mem::ManuallyDrop::new(Some(view)),
            ..Default::default()
        };
        unsafe {
            self.video_context
                .VideoProcessorBlt(&self.processor, &self.out_views[slot], 0, &[stream])
                .map_err(|e| e.to_string())?;
        }
        Ok(self.nv12[slot].clone())
    }
}

fn create_texture(
    device: &ID3D11Device,
    w: u32,
    h: u32,
    format: windows::Win32::Graphics::Dxgi::Common::DXGI_FORMAT,
    bind: windows::Win32::Graphics::Direct3D11::D3D11_BIND_FLAG,
    cpu: D3D11_CPU_ACCESS_FLAG,
    misc: D3D11_RESOURCE_MISC_FLAG,
) -> Result<ID3D11Texture2D, String> {
    let desc = D3D11_TEXTURE2D_DESC {
        Width: w,
        Height: h,
        MipLevels: 1,
        ArraySize: 1,
        Format: format,
        SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
        Usage: D3D11_USAGE_DEFAULT,
        BindFlags: bind.0 as u32,
        CPUAccessFlags: cpu.0 as u32,
        MiscFlags: misc.0 as u32,
    };
    let mut tex: Option<ID3D11Texture2D> = None;
    unsafe { device.CreateTexture2D(&desc, None, Some(&mut tex)).map_err(|e| e.to_string())?; }
    tex.ok_or_else(|| "CreateTexture2D null".to_string())
}

// Keep the unused-import checker happy for the BGRA constant (used by the capture side).
#[allow(dead_code)]
fn _unused() -> windows::Win32::Graphics::Dxgi::Common::DXGI_FORMAT {
    DXGI_FORMAT_B8G8R8A8_UNORM
}
