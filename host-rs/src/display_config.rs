//! Monitor enumeration and layout control, mirroring the C# `ScreenCapture`/`DisplayConfig`.

use crate::logline;
use std::collections::HashMap;
use windows::core::{BOOL, PCWSTR};
use windows::Win32::Foundation::{LPARAM, RECT};
use windows::Win32::Graphics::Gdi::{
    ChangeDisplaySettingsExW, EnumDisplayDevicesW, EnumDisplayMonitors, EnumDisplaySettingsExW,
    GetMonitorInfoW, CDS_SET_PRIMARY, CDS_TYPE, CDS_UPDATEREGISTRY, DEVMODEW, DISPLAY_DEVICEW,
    DISP_CHANGE_SUCCESSFUL, DM_DISPLAYFREQUENCY, DM_PELSHEIGHT, DM_PELSWIDTH, DM_POSITION,
    ENUM_CURRENT_SETTINGS, ENUM_DISPLAY_SETTINGS_FLAGS, HDC, HMONITOR, MONITORINFO,
    MONITORINFOEXW,
};

#[derive(Debug, Clone)]
pub struct MonitorInfo {
    pub index: usize,
    pub device: String,
    pub x: i32,
    pub y: i32,
    pub width: i32,
    pub height: i32,
    pub primary: bool,
}

const MONITORINFOF_PRIMARY: u32 = 0x1;

fn wide_to_string(buf: &[u16]) -> String {
    let end = buf.iter().position(|&c| c == 0).unwrap_or(buf.len());
    String::from_utf16_lossy(&buf[..end])
}

unsafe extern "system" fn enum_monitor(
    hmon: HMONITOR,
    _hdc: HDC,
    _rect: *mut RECT,
    data: LPARAM,
) -> BOOL {
    let list = unsafe { &mut *(data.0 as *mut Vec<MonitorInfo>) };
    let mut mi = MONITORINFOEXW::default();
    mi.monitorInfo.cbSize = std::mem::size_of::<MONITORINFOEXW>() as u32;
    // GetMonitorInfoW is typed for MONITORINFO; MONITORINFOEXW starts with a MONITORINFO and the
    // cbSize tells Windows to also fill szDevice, so the cast is safe.
    let ok = unsafe { GetMonitorInfoW(hmon, &mut mi as *mut MONITORINFOEXW as *mut MONITORINFO) };
    if ok.as_bool() {
        let r = mi.monitorInfo.rcMonitor;
        list.push(MonitorInfo {
            index: 0,
            device: wide_to_string(&mi.szDevice),
            x: r.left,
            y: r.top,
            width: r.right - r.left,
            height: r.bottom - r.top,
            primary: (mi.monitorInfo.dwFlags & MONITORINFOF_PRIMARY) != 0,
        });
    }
    true.into()
}

/// All monitors, ordered by device name (DISPLAY1, DISPLAY2, ...).
pub fn get_monitors() -> Vec<MonitorInfo> {
    let mut list: Vec<MonitorInfo> = Vec::new();
    unsafe {
        let _ = EnumDisplayMonitors(
            None,
            None,
            Some(enum_monitor),
            LPARAM(&mut list as *mut _ as isize),
        );
    }
    list.sort_by(|a, b| a.device.cmp(&b.device));
    for (i, m) in list.iter_mut().enumerate() {
        m.index = i;
    }
    list
}

/// Map device name -> PnP DeviceID (used to spot the MTT virtual display).
fn display_device_ids() -> HashMap<String, String> {
    let mut map = HashMap::new();
    let mut i = 0u32;
    loop {
        let mut dd = DISPLAY_DEVICEW::default();
        dd.cb = std::mem::size_of::<DISPLAY_DEVICEW>() as u32;
        let ok = unsafe { EnumDisplayDevicesW(PCWSTR::null(), i, &mut dd, 0) };
        if !ok.as_bool() {
            break;
        }
        map.insert(wide_to_string(&dd.DeviceName), wide_to_string(&dd.DeviceID));
        i += 1;
    }
    map
}

/// The MTT virtual display monitor, if present.
pub fn find_vdd_monitor(monitors: &[MonitorInfo]) -> Option<MonitorInfo> {
    let ids = display_device_ids();
    monitors
        .iter()
        .find(|m| {
            ids.get(&m.device)
                .map(|id| id.to_ascii_uppercase().contains("MTT"))
                .unwrap_or(false)
        })
        .cloned()
}

fn device_wide(device: &str) -> Vec<u16> {
    device.encode_utf16().chain(std::iter::once(0)).collect()
}

fn current_devmode(device: &str) -> Option<DEVMODEW> {
    let w = device_wide(device);
    let mut dm = DEVMODEW::default();
    dm.dmSize = std::mem::size_of::<DEVMODEW>() as u16;
    let ok = unsafe {
        EnumDisplaySettingsExW(
            PCWSTR(w.as_ptr()),
            ENUM_CURRENT_SETTINGS,
            &mut dm,
            ENUM_DISPLAY_SETTINGS_FLAGS(0),
        )
    };
    if ok.as_bool() { Some(dm) } else { None }
}

fn apply_mode(device: &str, dm: &DEVMODEW) -> bool {
    let w = device_wide(device);
    let rc = unsafe {
        ChangeDisplaySettingsExW(
            PCWSTR(w.as_ptr()),
            Some(dm as *const DEVMODEW),
            None,
            CDS_UPDATEREGISTRY,
            None,
        )
    };
    rc == DISP_CHANGE_SUCCESSFUL
}

/// Change the monitor mode (width/height/refresh) using its current DEVMODE as the base.
pub fn try_set_mode(device: &str, width: i32, height: i32, hz: u32) -> bool {
    let Some(mut dm) = current_devmode(device) else { return false };
    if dm.dmPelsWidth == width as u32
        && dm.dmPelsHeight == height as u32
        && dm.dmDisplayFrequency == hz
    {
        return true;
    }
    dm.dmPelsWidth = width as u32;
    dm.dmPelsHeight = height as u32;
    dm.dmDisplayFrequency = hz;
    dm.dmFields |= DM_PELSWIDTH | DM_PELSHEIGHT | DM_DISPLAYFREQUENCY;
    apply_mode(device, &dm)
}

/// Park the monitor at (x, y).
pub fn move_to(device: &str, x: i32, y: i32) {
    let Some(mut dm) = current_devmode(device) else { return };
    dm.Anonymous1.Anonymous2.dmPosition.x = x;
    dm.Anonymous1.Anonymous2.dmPosition.y = y;
    dm.dmFields |= DM_POSITION;
    if !apply_mode(device, &dm) {
        logline!("[display] MoveTo {device} -> ({x},{y}) failed");
    }
}

/// Give the primary role to `device`.
pub fn set_primary(device: &str) {
    if let Some(dm) = current_devmode(device) {
        let w = device_wide(device);
        let rc = unsafe {
            ChangeDisplaySettingsExW(
                PCWSTR(w.as_ptr()),
                Some(&dm as *const DEVMODEW),
                None,
                CDS_UPDATEREGISTRY | CDS_SET_PRIMARY,
                None,
            )
        };
        if rc != DISP_CHANGE_SUCCESSFUL {
            logline!("[display] SetPrimary {device} failed: {rc:?}");
        }
    }
}

/// Snapshot every monitor's current DEVMODE so it can be restored after the VDD is removed.
pub struct SavedLayout {
    modes: Vec<(String, DEVMODEW)>,
}

impl SavedLayout {
    pub fn save() -> Self {
        let devices: Vec<String> = get_monitors().into_iter().map(|m| m.device).collect();
        let modes = devices
            .into_iter()
            .filter_map(|d| current_devmode(&d).map(|dm| (d, dm)))
            .collect();
        Self { modes }
    }

    pub fn restore(&self) -> bool {
        let mut ok = true;
        for (device, dm) in &self.modes {
            if !apply_mode(device, dm) {
                ok = false;
            }
        }
        if ok {
            logline!("[display] Saved layout restored.");
        }
        ok
    }
}

/// Best-effort no-op that forces Windows to refresh the display topology.
pub fn restore_extend() {
    logline!("[display] Extend topology restore requested.");
    let _ = unsafe { ChangeDisplaySettingsExW(PCWSTR::null(), None, None, CDS_TYPE(0), None) };
}
