//! Device readiness parsing, mirroring the C# `DeviceReadiness`.

#[derive(Debug, Clone)]
pub struct DeviceReadiness {
    pub ready: bool,
    pub reason: String,
}

impl DeviceReadiness {
    pub fn parse(output: &str) -> Self {
        let trimmed = output.trim();
        if trimmed.is_empty() {
            return Self { ready: false, reason: "No response from device".into() };
        }
        if trimmed == "READY" {
            return Self { ready: true, reason: "Ready (unlocked)".into() };
        }
        if trimmed.eq_ignore_ascii_case("SCREEN_OFF") {
            return Self { ready: false, reason: "Screen is off / asleep".into() };
        }
        if trimmed.eq_ignore_ascii_case("LOCKED") {
            return Self { ready: false, reason: "Device is locked".into() };
        }
        Self { ready: false, reason: format!("Device not ready ({trimmed})") }
    }

    /// True when the failure is just adb being slow/timing out, not a real device state.
    pub fn is_adb_transient(&self) -> bool {
        let r = self.reason.to_ascii_lowercase();
        r.contains("adb shell command failed") || r.contains("readiness check failed")
    }
}
