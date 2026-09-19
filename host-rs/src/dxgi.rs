//! DXGI Desktop Duplication capture, mirroring the C# `DxgiCapture`.
//!
//! Desktop Duplication does not include the mouse cursor, so we fetch the pointer shape and
//! composite it ourselves (the client draws it as an overlay).

use crate::logline;
use windows::core::{Interface, PCWSTR};
use windows::Win32::Foundation::POINT;
use windows::Win32::Graphics::Direct3D::D3D_DRIVER_TYPE_UNKNOWN;
use windows::Win32::Graphics::Direct3D11::{
    D3D11CreateDevice, ID3D11Device, ID3D11DeviceContext, ID3D11Texture2D,
    D3D11_BIND_SHADER_RESOURCE, D3D11_CPU_ACCESS_READ, D3D11_CREATE_DEVICE_BGRA_SUPPORT,
    D3D11_MAP_READ, D3D11_MAPPED_SUBRESOURCE, D3D11_SDK_VERSION, D3D11_TEXTURE2D_DESC,
    D3D11_USAGE_DEFAULT, D3D11_USAGE_STAGING,
};
use windows::Win32::Graphics::Direct3D::D3D_FEATURE_LEVEL_11_0;
use windows::Win32::Graphics::Dxgi::Common::{DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_SAMPLE_DESC};
use windows::Win32::Graphics::Dxgi::{
    CreateDXGIFactory1, IDXGIAdapter1, IDXGIOutput1, IDXGIOutputDuplication, IDXGIResource,
    DXGI_ERROR_ACCESS_DENIED, DXGI_ERROR_ACCESS_LOST, DXGI_ERROR_WAIT_TIMEOUT,
    DXGI_OUTDUPL_FRAME_INFO, DXGI_OUTDUPL_POINTER_SHAPE_INFO,
};

pub struct Monitor {
    pub device: String,
    pub width: u32,
    pub height: u32,
}

pub struct DxgiCapture {
    device: ID3D11Device,
    context: ID3D11DeviceContext,
    output1: IDXGIOutput1,
    dup: Option<IDXGIOutputDuplication>,
    staging: ID3D11Texture2D,
    desktop_tex: Option<ID3D11Texture2D>,
    pub width: u32,
    pub height: u32,
    pub stride: u32,
    frame: Vec<u8>,
    ready: bool,
    dup_lost_tick: u64,
    reinit_fail_streak: u32,

    pub cur_visible: bool,
    pub cur_x: i32,
    pub cur_y: i32,
    pub cur_w: u32,
    pub cur_h: u32,
    pub cur_bgra: Vec<u8>,
    pub cursor_shape_dirty: bool,
    shape_buf: Vec<u8>,
}

fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}

impl DxgiCapture {
    pub fn new(target_device: &str) -> Result<Self, String> {
        unsafe {
            let factory: windows::Win32::Graphics::Dxgi::IDXGIFactory1 =
                CreateDXGIFactory1().map_err(|e| e.to_string())?;

            let mut chosen_adapter: Option<IDXGIAdapter1> = None;
            let mut chosen_output: Option<IDXGIOutput1> = None;
            let mut width = 0u32;
            let mut height = 0u32;

            let mut ai = 0u32;
            'adapters: while let Ok(adapter) = factory.EnumAdapters1(ai) {
                let mut oi = 0u32;
                while let Ok(output) = adapter.EnumOutputs(oi) {
                    let desc = output.GetDesc().map_err(|e| e.to_string())?;
                    let name = String::from_utf16_lossy(&desc.DeviceName)
                        .trim_end_matches('\0')
                        .to_string();
                    if name == target_device {
                        let c = desc.DesktopCoordinates;
                        width = (c.right - c.left) as u32;
                        height = (c.bottom - c.top) as u32;
                        chosen_output = Some(output.cast::<IDXGIOutput1>().map_err(|e| e.to_string())?);
                        chosen_adapter = Some(adapter.clone());
                        break 'adapters;
                    }
                    oi += 1;
                }
                ai += 1;
            }

            let adapter = chosen_adapter.ok_or_else(|| format!("DXGI output '{target_device}' not found"))?;
            let output1 = chosen_output.ok_or_else(|| format!("DXGI output '{target_device}' not found"))?;

            let mut device: Option<ID3D11Device> = None;
            let mut context: Option<ID3D11DeviceContext> = None;
            let levels = [D3D_FEATURE_LEVEL_11_0];
            D3D11CreateDevice(
                &adapter,
                D3D_DRIVER_TYPE_UNKNOWN,
                Default::default(),
                D3D11_CREATE_DEVICE_BGRA_SUPPORT,
                Some(&levels),
                D3D11_SDK_VERSION,
                Some(&mut device),
                None,
                Some(&mut context),
            )
            .map_err(|e| e.to_string())?;
            let device = device.ok_or("D3D11 device creation returned null")?;
            let context = context.ok_or("D3D11 context creation returned null")?;

            let dup = output1.DuplicateOutput(&device).map_err(|e| e.to_string())?;

            let desc = D3D11_TEXTURE2D_DESC {
                Width: width,
                Height: height,
                MipLevels: 1,
                ArraySize: 1,
                Format: DXGI_FORMAT_B8G8R8A8_UNORM,
                SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
                Usage: D3D11_USAGE_STAGING,
                BindFlags: 0,
                CPUAccessFlags: D3D11_CPU_ACCESS_READ.0 as u32,
                MiscFlags: 0,
            };
            let staging = create_texture(&device, &desc)?;

            logline!("DXGI capture: {target_device} {width}x{height} (GPU Desktop Duplication, cursor overlay)");

            Ok(Self {
                device,
                context,
                output1,
                dup: Some(dup),
                staging,
                desktop_tex: None,
                width,
                height,
                stride: width * 4,
                frame: vec![0u8; (width * height * 4) as usize],
                ready: false,
                dup_lost_tick: 0,
                reinit_fail_streak: 0,
                cur_visible: false,
                cur_x: 0,
                cur_y: 0,
                cur_w: 0,
                cur_h: 0,
                cur_bgra: Vec::new(),
                cursor_shape_dirty: false,
                shape_buf: Vec::new(),
            })
        }
    }

    pub fn ready(&self) -> bool {
        self.ready
    }

    pub fn frame(&self) -> &[u8] {
        &self.frame
    }

    pub fn device(&self) -> &ID3D11Device {
        &self.device
    }

    pub fn context(&self) -> &ID3D11DeviceContext {
        &self.context
    }

    /// GPU-path update: keep the desktop (BGRA) in a Default-usage texture and return it.
    /// The cursor is not composited (the client draws it as an overlay).
    pub fn update_gpu(&mut self, timeout_ms: u32) -> Option<ID3D11Texture2D> {
        unsafe {
            if self.desktop_tex.is_none() {
                let desc = D3D11_TEXTURE2D_DESC {
                    Width: self.width,
                    Height: self.height,
                    MipLevels: 1,
                    ArraySize: 1,
                    Format: DXGI_FORMAT_B8G8R8A8_UNORM,
                    SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
                    Usage: D3D11_USAGE_DEFAULT,
                    BindFlags: (windows::Win32::Graphics::Direct3D11::D3D11_BIND_SHADER_RESOURCE.0
                        | windows::Win32::Graphics::Direct3D11::D3D11_BIND_RENDER_TARGET.0)
                        as u32,
                    CPUAccessFlags: 0,
                    MiscFlags: 0,
                };
                match create_texture(&self.device, &desc) {
                    Ok(t) => self.desktop_tex = Some(t),
                    Err(_) => return None,
                }
            }

            if self.dup.is_none() {
                if now_ms() < self.dup_lost_tick {
                    return self.desktop_tex.clone();
                }
                self.reinit_duplication();
                if self.dup.is_none() {
                    return self.desktop_tex.clone();
                }
            }
            let dup = self.dup.as_ref().unwrap().clone();
            let mut info = DXGI_OUTDUPL_FRAME_INFO::default();
            let mut resource: Option<IDXGIResource> = None;
            let wait = if self.ready { timeout_ms } else { timeout_ms.max(500) };
            match dup.AcquireNextFrame(wait, &mut info, &mut resource) {
                Ok(()) => {}
                Err(e) if e.code() == DXGI_ERROR_WAIT_TIMEOUT => return self.desktop_tex.clone(),
                Err(e) if e.code() == DXGI_ERROR_ACCESS_LOST || e.code() == DXGI_ERROR_ACCESS_DENIED => {
                    self.reinit_duplication();
                    return self.desktop_tex.clone();
                }
                Err(_) => return self.desktop_tex.clone(),
            }

            if info.LastPresentTime != 0 {
                if let Some(res) = &resource {
                    if let (Ok(tex), Some(dst)) =
                        (res.cast::<ID3D11Texture2D>(), self.desktop_tex.as_ref())
                    {
                        self.context.CopyResource(dst, &tex);
                    }
                }
            }
            if info.LastMouseUpdateTime != 0 {
                self.cur_visible = info.PointerPosition.Visible.as_bool();
                self.cur_x = info.PointerPosition.Position.x;
                self.cur_y = info.PointerPosition.Position.y;
                if info.PointerShapeBufferSize > 0 {
                    self.fetch_cursor_shape(info.PointerShapeBufferSize, &dup);
                }
            }
            let _ = dup.ReleaseFrame();
            self.ready = true;
            self.desktop_tex.clone()
        }
    }

    fn reinit_duplication(&mut self) {
        self.dup = None;
        let res = unsafe { self.output1.DuplicateOutput(&self.device) };
        match res {
            Ok(d) => {
                self.dup = Some(d);
                self.reinit_fail_streak = 0;
                logline!("DXGI duplication re-acquired");
            }
            Err(e) => {
                self.reinit_fail_streak = (self.reinit_fail_streak + 1).min(10);
                self.dup_lost_tick = now_ms() + (self.reinit_fail_streak as u64) * 1000;
                if self.reinit_fail_streak <= 2 || self.reinit_fail_streak % 5 == 0 {
                    logline!("DXGI re-duplicate failed (backoff {}s): {e}", self.reinit_fail_streak + 1);
                }
            }
        }
    }

    /// Poll for a frame. Returns true when `frame()` holds a usable BGRA image.
    pub fn update(&mut self, timeout_ms: u32) -> bool {
        unsafe {
            if self.dup.is_none() {
                if now_ms() < self.dup_lost_tick {
                    return self.ready;
                }
                self.reinit_duplication();
                if self.dup.is_none() {
                    return self.ready;
                }
            }
            let dup = self.dup.as_ref().unwrap().clone();
            let mut info = DXGI_OUTDUPL_FRAME_INFO::default();
            let mut resource: Option<IDXGIResource> = None;
            match dup.AcquireNextFrame(timeout_ms, &mut info, &mut resource) {
                Ok(()) => {}
                Err(e) if e.code() == DXGI_ERROR_WAIT_TIMEOUT => return self.ready,
                Err(e) if e.code() == DXGI_ERROR_ACCESS_LOST || e.code() == DXGI_ERROR_ACCESS_DENIED => {
                    self.reinit_duplication();
                    return self.ready;
                }
                Err(_) => return self.ready,
            }

            if info.LastPresentTime != 0 {
                if let Some(res) = &resource {
                    if let Ok(tex) = res.cast::<ID3D11Texture2D>() {
                        self.context.CopyResource(&self.staging, &tex);
                        let mut mapped = D3D11_MAPPED_SUBRESOURCE::default();
                        if self
                            .context
                            .Map(&self.staging, 0, D3D11_MAP_READ, 0, Some(&mut mapped))
                            .is_ok()
                        {
                            let src = mapped.pData as *const u8;
                            let pitch = mapped.RowPitch as usize;
                            let row = self.stride as usize;
                            for y in 0..self.height as usize {
                                std::ptr::copy_nonoverlapping(
                                    src.add(y * pitch),
                                    self.frame.as_mut_ptr().add(y * row),
                                    row,
                                );
                            }
                            self.context.Unmap(&self.staging, 0);
                        }
                    }
                }
            }

            if info.LastMouseUpdateTime != 0 {
                self.cur_visible = info.PointerPosition.Visible.as_bool();
                self.cur_x = info.PointerPosition.Position.x;
                self.cur_y = info.PointerPosition.Position.y;
                if info.PointerShapeBufferSize > 0 {
                    self.fetch_cursor_shape(info.PointerShapeBufferSize, &dup);
                }
            }

            let _ = dup.ReleaseFrame();
            self.ready = true;
            true
        }
    }

    unsafe fn fetch_cursor_shape(&mut self, size: u32, dup: &IDXGIOutputDuplication) {
        if self.shape_buf.len() < size as usize {
            self.shape_buf = vec![0u8; size as usize];
        }
        let mut info = DXGI_OUTDUPL_POINTER_SHAPE_INFO::default();
        let mut required = 0u32;
        let ok = unsafe {
            dup.GetFramePointerShape(
                size,
                self.shape_buf.as_mut_ptr() as *mut core::ffi::c_void,
                &mut required,
                &mut info,
            )
        };
        if ok.is_err() {
            return;
        }
        self.cursor_shape_dirty = true;

        const TYPE_COLOR: u32 = 2;
        const TYPE_MASKED: u32 = 4;
        let w = info.Width as usize;
        let pitch = info.Pitch as usize;

        if info.Type == TYPE_COLOR || info.Type == TYPE_MASKED {
            let h = info.Height as usize;
            self.cur_w = info.Width;
            self.cur_h = info.Height;
            self.cur_bgra = vec![0u8; w * h * 4];
            for y in 0..h {
                for x in 0..w {
                    let si = y * pitch + x * 4;
                    let di = (y * w + x) * 4;
                    if si + 3 >= self.shape_buf.len() {
                        continue;
                    }
                    let b = self.shape_buf[si];
                    let g = self.shape_buf[si + 1];
                    let r = self.shape_buf[si + 2];
                    let mut a = self.shape_buf[si + 3];
                    if info.Type == TYPE_MASKED {
                        a = if a == 0 { 255 } else { 0 };
                    }
                    self.cur_bgra[di] = b;
                    self.cur_bgra[di + 1] = g;
                    self.cur_bgra[di + 2] = r;
                    self.cur_bgra[di + 3] = a;
                }
            }
        } else {
            // Monochrome: top half AND mask, bottom half XOR mask, 1bpp.
            let h = info.Height as usize / 2;
            self.cur_w = info.Width;
            self.cur_h = h as u32;
            self.cur_bgra = vec![0u8; w * h * 4];
            for y in 0..h {
                for x in 0..w {
                    let and_bit = (self.shape_buf[y * pitch + (x >> 3)] >> (7 - (x & 7))) & 1;
                    let xor_bit = (self.shape_buf[(y + h) * pitch + (x >> 3)] >> (7 - (x & 7))) & 1;
                    let di = (y * w + x) * 4;
                    let (v, a) = if and_bit == 0 {
                        ((if xor_bit == 1 { 255 } else { 0 }) as u8, 255u8)
                    } else if xor_bit == 1 {
                        (0u8, 255u8)
                    } else {
                        (255u8, 0u8)
                    };
                    self.cur_bgra[di] = v;
                    self.cur_bgra[di + 1] = v;
                    self.cur_bgra[di + 2] = v;
                    self.cur_bgra[di + 3] = a;
                }
            }
        }
    }
}

fn create_texture(
    device: &ID3D11Device,
    desc: &D3D11_TEXTURE2D_DESC,
) -> Result<ID3D11Texture2D, String> {
    let mut tex: Option<ID3D11Texture2D> = None;
    unsafe {
        device
            .CreateTexture2D(desc, None, Some(&mut tex))
            .map_err(|e| e.to_string())?;
    }
    tex.ok_or_else(|| "CreateTexture2D returned null".to_string())
}

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

// Silence unused imports that are only needed on some code paths.
#[allow(dead_code)]
fn _unused(_: POINT, _: PCWSTR, _: u32) {
    let _ = D3D11_BIND_SHADER_RESOURCE;
}
