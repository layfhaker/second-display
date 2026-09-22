//! Thin wrapper over `adb.exe`, mirroring the C# `AdbController`.

use crate::adblink;
use crate::device_readiness::DeviceReadiness;
use crate::logline;
use std::os::windows::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::Mutex;
use std::time::{Duration, Instant};

/// CREATE_NO_WINDOW: don't flash a console window for every spawned adb/pnputil/powershell process.
pub const CREATE_NO_WINDOW: u32 = 0x0800_0000;

const DEFAULT_TIMEOUT_MS: u64 = 10_000;
const DEVICES_TIMEOUT_MS: u64 = 3_000;
const SHELL_TIMEOUT_MS: u64 = 6_000;
const REVERSE_REMOVE_TIMEOUT_MS: u64 = 3_000;
const TIMEOUT_RESTART_MIN_INTERVAL_SECS: u64 = 20;
const UNAUTHORIZED_RESTART_MIN_INTERVAL_SECS: u64 = 30;

pub struct CommandResult {
    pub code: i32,
    pub stdout: String,
    pub stderr: String,
    pub timed_out: bool,
}

pub struct AdbController {
    adb: String,
    package: String,
    port: u16,
    consecutive_timeouts: AtomicU32,
    last_timeout_restart: Mutex<Option<Instant>>,
    last_unauthorized_restart: Mutex<Option<Instant>>,
    /// When false, adb-server auto-restarts are suppressed (never during an active stream:
    /// `kill-server` tears down the `adb reverse` tunnel and kills the client).
    pub auto_restart_enabled: AtomicBool,
    /// Persistent `host:track-devices` feed from the adb server (zero-spawn hot path).
    tracker: adblink::DeviceTracker,
}

impl AdbController {
    pub fn new(adb_override: Option<String>, package: &str, port: u16) -> Self {
        Self {
            adb: resolve_adb_path(adb_override),
            package: package.to_string(),
            port,
            consecutive_timeouts: AtomicU32::new(0),
            last_timeout_restart: Mutex::new(None),
            last_unauthorized_restart: Mutex::new(None),
            auto_restart_enabled: AtomicBool::new(true),
            tracker: adblink::DeviceTracker::start(),
        }
    }

    pub fn adb_path(&self) -> &str {
        &self.adb
    }

    fn run_adb(&self, args: &[&str]) -> CommandResult {
        self.run_adb_timeout(args, DEFAULT_TIMEOUT_MS)
    }

    fn run_adb_timeout(&self, args: &[&str], timeout_ms: u64) -> CommandResult {
        let quiet = args.len() == 1 && args[0] == "devices";
        if !quiet {
            logline!("[adb] {} {}", self.adb, args.join(" "));
        }
        let r = run_process(&self.adb, args, timeout_ms);
        if r.timed_out {
            logline!("[adb] Process timeout ({timeout_ms}ms): {} {}", self.adb, args.join(" "));
            self.consecutive_timeouts.fetch_add(1, Ordering::SeqCst);
        } else {
            self.consecutive_timeouts.store(0, Ordering::SeqCst);
            if r.code != 0 {
                logline!("[adb] Exit code {}: {} {}", r.code, self.adb, args.join(" "));
            }
        }
        r
    }

    pub fn start_server(&self) {
        let _ = self.run_adb(&["start-server"]);
    }

    pub fn restart_server(&self, reason: &str) {
        logline!("[adb] Restarting adb server ({reason})...");
        let _ = self.run_adb(&["kill-server"]);
        let _ = self.run_adb(&["start-server"]);
        logline!("[adb] adb server restarted.");
    }

    pub fn list_devices(&self) -> Vec<String> {
        // Fast path: the persistent track-devices feed (no spawn, no per-poll handshake).
        // Falls through to socket query, then to `adb.exe`, on any gap.
        if let Some(pairs) = self.tracker.snapshot() {
            let devices = Self::authorized_from_pairs(&pairs);
            if devices.is_empty() && pairs.iter().any(|(_, s)| s == "unauthorized") {
                self.maybe_restart_for_unauthorized();
            }
            return devices;
        }
        match adblink::query("host:devices", DEVICES_TIMEOUT_MS) {
            Ok(payload) => {
                let pairs = adblink::parse_device_pairs(&payload);
                self.consecutive_timeouts.store(0, Ordering::SeqCst);
                let devices = Self::authorized_from_pairs(&pairs);
                if devices.is_empty() && pairs.iter().any(|(_, s)| s == "unauthorized") {
                    self.maybe_restart_for_unauthorized();
                }
                devices
            }
            Err(_) => self.list_devices_via_exe(),
        }
    }

    fn authorized_from_pairs(pairs: &[(String, String)]) -> Vec<String> {
        let mut devices = Vec::new();
        for (serial, status) in pairs {
            if status == "device" {
                devices.push(serial.clone());
            } else if matches!(status.as_str(), "unauthorized" | "offline" | "no permissions") {
                logline!("[adb] device {serial} status={status}, skipping");
            }
        }
        devices.sort();
        devices
    }

    fn list_devices_via_exe(&self) -> Vec<String> {
        let r = self.run_adb_timeout(&["devices"], DEVICES_TIMEOUT_MS);
        if r.code != 0 {
            self.maybe_restart_for_timeouts();
            return Vec::new();
        }
        let mut devices = Vec::new();
        let mut in_list = false;
        let mut saw_unauthorized = false;
        for line in r.stdout.lines() {
            let t = line.trim_end();
            if t.trim() == "List of devices attached" {
                in_list = true;
                continue;
            }
            if !in_list || t.trim().is_empty() {
                continue;
            }
            let mut parts = t.split('\t');
            let serial = parts.next().unwrap_or("").trim().to_string();
            let status = parts.next().unwrap_or("").trim().to_string();
            if serial.is_empty() {
                continue;
            }
            if status == "device" {
                devices.push(serial);
            } else if matches!(status.as_str(), "unauthorized" | "offline" | "no permissions") {
                logline!("[adb] device {serial} status={status}, skipping");
                if status == "unauthorized" {
                    saw_unauthorized = true;
                }
            }
        }
        if saw_unauthorized && devices.is_empty() {
            self.maybe_restart_for_unauthorized();
        }
        devices.sort();
        devices
    }

    pub fn has_app(&self, serial: &str) -> bool {
        let local = format!("shell:pm list packages {}", self.package);
        if let Ok(out) = adblink::transport_exec(serial, &local, DEFAULT_TIMEOUT_MS, 65536) {
            return String::from_utf8_lossy(&out).contains(&format!("package:{}", self.package));
        }
        let r = self.run_adb(&["-s", serial, "shell", "pm", "list", "packages", &self.package]);
        r.code == 0 && r.stdout.contains(&format!("package:{}", self.package))
    }

    pub fn setup_reverse(&self, serial: &str) -> Result<(), String> {
        let local = format!("reverse:forward:tcp:{0};tcp:{0}", self.port);
        if adblink::transport_exec(serial, &local, DEFAULT_TIMEOUT_MS, 64).is_ok() {
            return Ok(());
        }
        let port = format!("tcp:{}", self.port);
        let r = self.run_adb(&["-s", serial, "reverse", &port, &port]);
        if r.code != 0 {
            return Err(format!("SetupReverse failed for {serial}: {}", r.stderr));
        }
        Ok(())
    }

    pub fn remove_reverse(&self, serial: &str) {
        let local = format!("reverse:killforward:tcp:{}", self.port);
        if adblink::transport_exec(serial, &local, REVERSE_REMOVE_TIMEOUT_MS, 64).is_ok() {
            return;
        }
        let port = format!("tcp:{}", self.port);
        let _ = self.run_adb_timeout(
            &["-s", serial, "reverse", "--remove", &port],
            REVERSE_REMOVE_TIMEOUT_MS,
        );
    }

    pub fn launch_client(&self, serial: &str) {
        let component = format!("{}/.MainActivity", self.package);
        let local = format!("shell:am start -n {component}");
        if adblink::transport_exec(serial, &local, DEFAULT_TIMEOUT_MS, 4096).is_ok() {
            return;
        }
        let r = self.run_adb(&["-s", serial, "shell", "am", "start", "-n", &component]);
        if r.code != 0 {
            logline!("[adb] LaunchClient warning: exit code {}", r.code);
        }
    }

    /// Awake + unlocked (USB mode is NOT required — the tablet often stays in "adb only").
    pub fn get_device_readiness(&self, serial: &str) -> DeviceReadiness {
        let script = "w=$(dumpsys power 2>/dev/null | grep -m1 'mWakefulness=');\
case \"$w\" in *Awake*) ;; *) echo \"SCREEN_OFF\"; exit 0;; esac;\
l=$(cmd statusbar is-keyguard-locked 2>/dev/null);\
if [ \"$l\" = \"true\" ]; then echo \"LOCKED\"; exit 0; fi;\
echo \"READY\"";
        if let Ok(out) = adblink::transport_exec(serial, &format!("shell:{script}"), SHELL_TIMEOUT_MS, 1024) {
            return DeviceReadiness::parse(&String::from_utf8_lossy(&out));
        }
        let r = self.run_adb_timeout(&["-s", serial, "shell", script], SHELL_TIMEOUT_MS);
        if r.code != 0 {
            return DeviceReadiness { ready: false, reason: "adb shell command failed".into() };
        }
        DeviceReadiness::parse(&r.stdout)
    }

    pub fn dump_crash_logs(&self, serial: &str, lines: u32) {
        let local = format!("shell:logcat -d -v time -t {lines} -s SecondDisplay:V AndroidRuntime:E CRASH:E DEBUG:E");
        if let Ok(out) = adblink::transport_exec(serial, &local, DEFAULT_TIMEOUT_MS, 65536) {
            Self::print_logcat(serial, &String::from_utf8_lossy(&out));
            return;
        }
        let n = lines.to_string();
        let r = self.run_adb(&[
            "-s", serial, "logcat", "-d", "-v", "time", "-t", &n, "-s", "SecondDisplay:V",
            "AndroidRuntime:E", "CRASH:E", "DEBUG:E",
        ]);
        if r.code == 0 {
            Self::print_logcat(serial, &r.stdout);
        }
    }

    fn print_logcat(serial: &str, stdout: &str) {
        if stdout.trim().is_empty() {
            return;
        }
        logline!("[adb-logcat] Recent Android logs from {serial}:");
        for l in stdout.lines() {
            let t = l.trim();
            if !t.is_empty() {
                logline!("  [tablet] {t}");
            }
        }
    }

    fn maybe_restart_for_unauthorized(&self) {
        if !self.auto_restart_enabled.load(Ordering::SeqCst) {
            return;
        }
        let mut last = self.last_unauthorized_restart.lock().unwrap();
        if let Some(t) = *last {
            if t.elapsed() < Duration::from_secs(UNAUTHORIZED_RESTART_MIN_INTERVAL_SECS) {
                return;
            }
        }
        *last = Some(Instant::now());
        drop(last);
        self.restart_server("device unauthorized");
    }

    fn maybe_restart_for_timeouts(&self) {
        if !self.auto_restart_enabled.load(Ordering::SeqCst) {
            return;
        }
        let n = self.consecutive_timeouts.load(Ordering::SeqCst);
        if n < 3 {
            return;
        }
        let mut last = self.last_timeout_restart.lock().unwrap();
        if let Some(t) = *last {
            if t.elapsed() < Duration::from_secs(TIMEOUT_RESTART_MIN_INTERVAL_SECS) {
                return;
            }
        }
        *last = Some(Instant::now());
        self.consecutive_timeouts.store(0, Ordering::SeqCst);
        drop(last);
        self.restart_server(&format!("{n} consecutive adb timeouts"));
    }
}

fn resolve_adb_path(adb_override: Option<String>) -> String {
    if let Some(p) = adb_override {
        if Path::new(&p).is_file() {
            return p;
        }
    }
    // Prefer the adb shipped next to the host (installer layout: <app>\platform-tools\adb.exe).
    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            let bundled = dir.join("platform-tools").join("adb.exe");
            if bundled.is_file() {
                return bundled.to_string_lossy().into_owned();
            }
        }
    }
    if run_process("adb", &["version"], 5_000).code == 0 {
        return "adb".to_string();
    }
    let default = PathBuf::from(r"C:\Users\admin\android-build\sdk\platform-tools\adb.exe");
    if default.is_file() {
        return default.to_string_lossy().into_owned();
    }
    "adb".to_string()
}

/// Run a process with a timeout, capturing stdout/stderr.
pub fn run_process(file: &str, args: &[&str], timeout_ms: u64) -> CommandResult {
    let mut child = match Command::new(file)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .creation_flags(CREATE_NO_WINDOW)
        .spawn()
    {
        Ok(c) => c,
        Err(e) => {
            return CommandResult { code: 1, stdout: String::new(), stderr: e.to_string(), timed_out: false };
        }
    };

    let deadline = Instant::now() + Duration::from_millis(timeout_ms);
    loop {
        match child.try_wait() {
            Ok(Some(_)) => break,
            Ok(None) => {
                if Instant::now() >= deadline {
                    let _ = child.kill();
                    let _ = child.wait();
                    return CommandResult { code: 1, stdout: String::new(), stderr: "Process timeout".into(), timed_out: true };
                }
                std::thread::sleep(Duration::from_millis(15));
            }
            Err(e) => {
                return CommandResult { code: 1, stdout: String::new(), stderr: e.to_string(), timed_out: false };
            }
        }
    }

    match child.wait_with_output() {
        Ok(out) => CommandResult {
            code: out.status.code().unwrap_or(0),
            stdout: String::from_utf8_lossy(&out.stdout).into_owned(),
            stderr: String::from_utf8_lossy(&out.stderr).into_owned(),
            timed_out: false,
        },
        Err(e) => CommandResult { code: 1, stdout: String::new(), stderr: e.to_string(), timed_out: false },
    }
}
