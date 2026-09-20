//! MikeTheTech Virtual Display Driver control, mirroring the C# `VddController`.

use crate::adb::run_process;
use crate::display_config::{self, MonitorInfo};
use crate::logline;
use windows::core::PCWSTR;
use windows::Win32::Graphics::Gdi::{ChangeDisplaySettingsExW, EnumDisplayDevicesW, DISPLAY_DEVICEW};

const PNPUTIL_TIMEOUT_MS: u64 = 8_000;
const POWERSHELL_TIMEOUT_MS: u64 = 15_000;

pub struct VddController {
    friendly_name: String,
    instance_id: String,
}

impl VddController {
    pub fn new() -> Self {
        Self {
            friendly_name: "Virtual Display Driver".to_string(),
            instance_id: r"ROOT\DISPLAY\0000".to_string(),
        }
    }

    fn run_pnputil(&self, arg: &str) -> bool {
        let r = run_process("pnputil.exe", &[arg, &self.instance_id], PNPUTIL_TIMEOUT_MS);
        if r.timed_out {
            logline!("[vdd] pnputil timeout ({arg})");
            return false;
        }
        r.code == 0 || r.code == 3010
    }

    fn run_powershell(&self, command: &str) -> (i32, String, String) {
        logline!("[vdd] {command}");
        let r = run_process(
            "powershell.exe",
            &["-NoProfile", "-NonInteractive", "-Command", command],
            POWERSHELL_TIMEOUT_MS,
        );
        (r.code, r.stdout, r.stderr)
    }

    pub fn enable(&self) {
        if self.run_pnputil("/enable-device") {
            logline!("[vdd] VDD enabled (fast pnputil).");
            return;
        }
        let cmd = format!(
            "$d = Get-PnpDevice -FriendlyName '{}' -ErrorAction SilentlyContinue; if ($d) {{ Enable-PnpDevice -InstanceId $d.InstanceId -Confirm:$false; 'OK' }} else {{ 'NOTFOUND' }}",
            self.friendly_name
        );
        let (code, stdout, stderr) = self.run_powershell(&cmd);
        if code != 0 && stderr.to_ascii_lowercase().contains("access is denied") {
            logline!("[vdd] Enable failed — needs administrator.");
        } else if stdout.contains("NOTFOUND") {
            logline!("[vdd] Enable: device not found");
        }
    }

    pub fn disable(&self) {
        self.remove_vdd_monitors();
        if self.run_pnputil("/disable-device") {
            logline!("[vdd] VDD disabled (fast pnputil).");
            return;
        }
        let cmd = format!(
            "$d = Get-PnpDevice -FriendlyName '{}' -ErrorAction SilentlyContinue; if ($d) {{ Disable-PnpDevice -InstanceId $d.InstanceId -Confirm:$false; 'OK' }} else {{ 'NOTFOUND' }}",
            self.friendly_name
        );
        let (code, stdout, stderr) = self.run_powershell(&cmd);
        if code != 0 && stderr.to_ascii_lowercase().contains("access is denied") {
            logline!("[vdd] Disable failed — needs administrator.");
        } else if stdout.contains("NOTFOUND") {
            logline!("[vdd] Disable: device not found");
        }
    }

    /// Poll until a monitor that wasn't in `before` appears (the VDD), or timeout.
    pub fn wait_for_monitor(&self, before: &[MonitorInfo], timeout_ms: u64) -> Option<MonitorInfo> {
        use std::time::{Duration, Instant};
        let start = Instant::now();
        let before_devices: Vec<&str> = before.iter().map(|m| m.device.as_str()).collect();
        loop {
            let current = display_config::get_monitors();
            let mut news: Vec<&MonitorInfo> =
                current.iter().filter(|m| !before_devices.contains(&m.device.as_str())).collect();
            if news.len() >= 1 {
                let chosen = choose_new_monitor(&mut news);
                return Some(chosen.clone());
            }
            if start.elapsed() > Duration::from_millis(timeout_ms) {
                // A leftover VDD phantom may already be present — reuse it.
                if let Some(f) = display_config::find_vdd_monitor(&current) {
                    logline!("[vdd] VDD phantom already present: {} {}x{} — reusing", f.device, f.width, f.height);
                    return Some(f);
                }
                logline!("[vdd] WaitForMonitor timeout");
                return None;
            }
            std::thread::sleep(Duration::from_millis(250));
        }
    }

    /// Names of the VDD's display devices (`\\.\DISPLAYn`) that the desktop currently sees.
    pub fn active_monitors(&self) -> Vec<String> {
        let mut names: Vec<String> = Vec::new();
        unsafe {
            let mut i = 0u32;
            loop {
                let mut dd = DISPLAY_DEVICEW::default();
                dd.cb = std::mem::size_of::<DISPLAY_DEVICEW>() as u32;
                if !EnumDisplayDevicesW(PCWSTR::null(), i, &mut dd, 0).as_bool() {
                    break;
                }
                let dev_name = wide(&dd.DeviceName);
                let mut mon = DISPLAY_DEVICEW::default();
                mon.cb = std::mem::size_of::<DISPLAY_DEVICEW>() as u32;
                if EnumDisplayDevicesW(PCWSTR(dd.DeviceName.as_ptr()), 0, &mut mon, 0).as_bool() {
                    let id = wide(&mon.DeviceID).to_ascii_uppercase();
                    if id.contains("MTT") {
                        names.push(dev_name);
                    }
                }
                i += 1;
            }
        }
        names
    }

    fn remove_vdd_monitors(&self) {
        let names = self.active_monitors();
        for n in &names {
            logline!("[vdd] Removing phantom monitor: {n}");
            let w: Vec<u16> = n.encode_utf16().chain(std::iter::once(0)).collect();
            const CDS_DETACH: u32 = 0x08;
            unsafe {
                let _ = ChangeDisplaySettingsExW(
                    PCWSTR(w.as_ptr()),
                    None,
                    None,
                    windows::Win32::Graphics::Gdi::CDS_TYPE(CDS_DETACH),
                    None,
                );
            }
        }
        if !names.is_empty() {
            std::thread::sleep(std::time::Duration::from_millis(100));
        }
    }
}

fn wide(buf: &[u16]) -> String {
    let end = buf.iter().position(|&c| c == 0).unwrap_or(buf.len());
    String::from_utf16_lossy(&buf[..end])
}

/// Among new monitors prefer a ~3:2 aspect (the tablet), else the first.
fn choose_new_monitor<'a>(news: &mut Vec<&'a MonitorInfo>) -> &'a MonitorInfo {
    news.sort_by(|a, b| a.device.cmp(&b.device));
    if let Some(pref) = news.iter().find(|m| {
        let ar = m.width as f64 / m.height as f64;
        (1.3..=1.55).contains(&ar)
    }) {
        return pref;
    }
    news[0]
}
