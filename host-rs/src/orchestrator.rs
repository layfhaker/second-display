//! Passive orchestrator state machine, mirroring the C# `Orchestrator` (with the resilience
//! fixes: ignore transient adb blips while the stream is alive, never restart adb while streaming,
//! tolerate adb-shell timeouts, keep re-applying reverse + relaunching the client before giving up).

use crate::adb::AdbController;
use crate::display_config::{self, SavedLayout};
use crate::logline;
use crate::options::Options;
use crate::streaming::StreamingSession;
use crate::vdd::VddController;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

const POLL_INTERVAL_MS: u64 = 1000;
const MISSING_POLLS_BEFORE_TEARDOWN: u32 = 2;
const STABLE_CONNECT_POLLS: u32 = 2;
const MAX_NO_CLIENT_POLLS: u32 = 12;

pub struct Orchestrator {
    opts: Options,
    adb: AdbController,
    vdd: VddController,
}

impl Orchestrator {
    pub fn new(opts: Options, adb: AdbController, vdd: VddController) -> Self {
        Self { opts, adb, vdd }
    }

    pub fn run(&self, ct: &AtomicBool) {
        let _ = self.vdd.disable();
        display_config::restore_extend();

        self.adb.start_server();
        self.adb.restart_server("startup");
        logline!("[orchestrator] Passive — waiting for tablet...");

        let mut last_reason = String::new();
        let mut last_reason_time = Instant::now();

        while !ct.load(Ordering::SeqCst) {
            match self.poll_for_qualifying_device(ct, &mut last_reason, &mut last_reason_time) {
                Some(serial) => self.run_connecting_and_streaming(&serial, ct),
                None => continue,
            }
        }

        let _ = self.vdd.disable();
        display_config::restore_extend();
    }

    fn sleep_respecting(ct: &AtomicBool, ms: u64) {
        let end = Instant::now() + Duration::from_millis(ms);
        while Instant::now() < end {
            if ct.load(Ordering::SeqCst) {
                return;
            }
            std::thread::sleep(Duration::from_millis(50));
        }
    }

    fn poll_for_qualifying_device(
        &self,
        ct: &AtomicBool,
        last_reason: &mut String,
        last_reason_time: &mut Instant,
    ) -> Option<String> {
        let mut candidate: Option<String> = None;
        let mut stable = 0u32;
        while !ct.load(Ordering::SeqCst) {
            let found = self.find_first_qualifying(last_reason, last_reason_time);
            if found.is_some() && found == candidate {
                stable += 1;
                if stable >= STABLE_CONNECT_POLLS {
                    return candidate;
                }
            } else {
                candidate = found.clone();
                stable = if found.is_some() { 1 } else { 0 };
                if let Some(s) = &found {
                    logline!("[orchestrator] Device {s} detected — waiting for USB mode to settle...");
                }
            }
            Self::sleep_respecting(ct, POLL_INTERVAL_MS);
        }
        None
    }

    fn find_first_qualifying(
        &self,
        last_reason: &mut String,
        last_reason_time: &mut Instant,
    ) -> Option<String> {
        let devices = self.adb.list_devices();
        for serial in devices {
            if !self.adb.has_app(&serial) {
                continue;
            }
            let readiness = self.adb.get_device_readiness(&serial);
            if !readiness.ready {
                if *last_reason != readiness.reason || last_reason_time.elapsed().as_secs() >= 10 {
                    *last_reason = readiness.reason.clone();
                    *last_reason_time = Instant::now();
                    logline!("[orchestrator] Device {serial} waiting: {}", readiness.reason);
                }
                continue;
            }
            return Some(serial);
        }
        None
    }

    fn run_connecting_and_streaming(&self, serial: &str, ct: &AtomicBool) {
        logline!("[orchestrator] Connecting — device {serial} has our app.");

        let before = display_config::get_monitors();
        let saved = SavedLayout::save();
        self.vdd.enable();

        let monitor = match self.vdd.wait_for_monitor(&before, 8000) {
            Some(m) => m,
            None => {
                logline!("[orchestrator] WaitForMonitor timed out — no VDD monitor appeared.");
                return;
            }
        };

        // If the VDD stole the primary role, give it back.
        if monitor.primary {
            if let Some(orig) = before.iter().find(|m| m.primary) {
                logline!("[orchestrator] VDD took primary — giving it back to {}", orig.device);
                display_config::set_primary(&orig.device);
            }
        }

        if display_config::try_set_mode(&monitor.device, 1920, 1280, 60) {
            std::thread::sleep(Duration::from_millis(500));
        }

        // Park the VDD to the right of the primary (avoids DWM skipping → black frames).
        let monitors = display_config::get_monitors();
        let primary = monitors.iter().find(|m| m.primary).cloned();
        let current = monitors.iter().find(|m| m.device == monitor.device).cloned().unwrap_or(monitor.clone());
        if let Some(p) = primary {
            let target_x = p.x + p.width;
            if current.x != target_x || current.y != 0 {
                logline!("[orchestrator] Moving VDD from ({},{}) to ({target_x},0)", current.x, current.y);
                display_config::move_to(&monitor.device, target_x, 0);
                std::thread::sleep(Duration::from_millis(500));
            }
        }
        let monitor = display_config::get_monitors()
            .into_iter()
            .find(|m| m.device == monitor.device)
            .unwrap_or(monitor);

        if let Err(e) = self.adb.setup_reverse(serial) {
            logline!("[orchestrator] SetupReverse failed: {e}");
            return;
        }

        let session = match StreamingSession::new(
            monitor.x,
            monitor.y,
            monitor.width,
            monitor.height,
            Some(monitor.device.clone()),
            self.opts.clone(),
        ) {
            Ok(s) => Arc::new(s),
            Err(e) => {
                logline!("[orchestrator] Cannot start session: {e}");
                return;
            }
        };

        let stop = Arc::new(AtomicBool::new(false));
        let session_run = Arc::clone(&session);
        let stop_run = Arc::clone(&stop);
        let serial_owned = serial.to_string();
        let adb_launch = format!("{} -s {} shell am start -n com.seconddisplay.client/.MainActivity", self.adb.adb_path(), serial);
        let _ = &adb_launch;
        // on_server_ready: launch the client (via adb) once the listener is up.
        let launch_serial = serial.to_string();
        let adb2 = AdbLauncher::new(self.adb.adb_path().to_string(), launch_serial);
        let handle = std::thread::Builder::new()
            .name("StreamingSession".into())
            .spawn(move || {
                let cb: Box<dyn Fn() + Send> = Box::new(move || adb2.launch());
                session_run.run(stop_run, Some(cb));
            });

        let handle = match handle {
            Ok(h) => h,
            Err(e) => {
                logline!("[orchestrator] Cannot spawn session thread: {e}");
                return;
            }
        };

        let connected = self.wait_for_client(&session, serial, ct);
        if !connected {
            logline!("[orchestrator] No tablet client connected — tearing down.");
            self.teardown(serial, &stop, handle, &saved, true);
            return;
        }

        logline!(
            "[orchestrator] Streaming to {serial} on {} {}x{}",
            monitor.device,
            monitor.width,
            monitor.height
        );

        self.run_streaming_loop(serial, &session, ct);
        self.teardown(serial, &stop, handle, &saved, true);
        let _ = serial_owned;
    }

    fn wait_for_client(&self, session: &Arc<StreamingSession>, serial: &str, ct: &AtomicBool) -> bool {
        let start = Instant::now();
        let mut last_retry = Instant::now() - Duration::from_secs(10);
        let mut consecutive_missing = 0u32;

        while !ct.load(Ordering::SeqCst) && start.elapsed() < Duration::from_secs(15) {
            if session.has_clients() {
                return true;
            }
            let devices = self.adb.list_devices();
            if !devices.iter().any(|d| d == serial) {
                consecutive_missing += 1;
                if consecutive_missing >= MISSING_POLLS_BEFORE_TEARDOWN {
                    logline!("[orchestrator] Device {serial} gone while waiting for client.");
                    return false;
                }
            } else {
                consecutive_missing = 0;
                let readiness = self.adb.get_device_readiness(serial);
                if !readiness.ready && !readiness.is_adb_transient() {
                    logline!(
                        "[orchestrator] Tablet {serial} is no longer ready ({}) — aborting connection.",
                        readiness.reason
                    );
                    return false;
                }
            }

            if last_retry.elapsed() >= Duration::from_millis(2500) {
                last_retry = Instant::now();
                logline!("[orchestrator] Waiting for tablet — re-applying reverse + relaunching client...");
                let _ = self.adb.setup_reverse(serial);
                self.adb.launch_client(serial);
            }
            Self::sleep_respecting(ct, 1000);
        }
        session.has_clients()
    }

    fn run_streaming_loop(&self, serial: &str, session: &Arc<StreamingSession>, ct: &AtomicBool) {
        // Never let adb auto-restart while streaming (kill-server would drop the reverse tunnel).
        self.adb.auto_restart_enabled.store(false, Ordering::SeqCst);

        let mut consecutive_missing = 0u32;
        let mut consecutive_unready = 0u32;
        let mut no_client = 0u32;

        while !ct.load(Ordering::SeqCst) {
            let devices = self.adb.list_devices();
            if !devices.iter().any(|d| d == serial) {
                if session.has_clients() {
                    consecutive_missing = 0;
                    logline!(
                        "[orchestrator] Device {serial} missing from adb list but the stream is alive — ignoring (transient adb blip)"
                    );
                } else {
                    consecutive_missing += 1;
                    logline!(
                        "[orchestrator] Device {serial} missing from adb list ({consecutive_missing}/{MISSING_POLLS_BEFORE_TEARDOWN})"
                    );
                    if consecutive_missing >= MISSING_POLLS_BEFORE_TEARDOWN {
                        logline!("[orchestrator] Device {serial} confirmed gone — tearing down.");
                        return;
                    }
                }
            } else {
                consecutive_missing = 0;
                let readiness = self.adb.get_device_readiness(serial);
                if readiness.ready || readiness.is_adb_transient() {
                    consecutive_unready = 0;
                } else {
                    consecutive_unready += 1;
                    logline!(
                        "[orchestrator] Device {serial} not ready ({}) ({consecutive_unready}/{MISSING_POLLS_BEFORE_TEARDOWN})",
                        readiness.reason
                    );
                    if consecutive_unready >= MISSING_POLLS_BEFORE_TEARDOWN {
                        logline!("[orchestrator] Tablet {serial} is no longer active ({}) — tearing down.", readiness.reason);
                        return;
                    }
                }

                if !session.has_clients() {
                    no_client += 1;
                    if no_client == 1 {
                        logline!("[orchestrator] Client disconnected while tablet is connected. Checking Android crash logs...");
                        self.adb.dump_crash_logs(serial, 25);
                    }
                    if no_client <= MAX_NO_CLIENT_POLLS {
                        if readiness.ready || readiness.is_adb_transient() {
                            logline!("[orchestrator] Relaunching client ({no_client}/{MAX_NO_CLIENT_POLLS})...");
                            let _ = self.adb.setup_reverse(serial);
                            self.adb.launch_client(serial);
                        }
                    } else {
                        logline!("[orchestrator] Client did not reconnect — tearing down.");
                        return;
                    }
                } else {
                    no_client = 0;
                }
            }

            Self::sleep_respecting(ct, POLL_INTERVAL_MS);
        }
    }

    fn teardown(
        &self,
        serial: &str,
        stop: &Arc<AtomicBool>,
        handle: std::thread::JoinHandle<()>,
        saved: &SavedLayout,
        vdd_enabled: bool,
    ) {
        logline!("[orchestrator] Tearing down...");
        self.adb.auto_restart_enabled.store(true, Ordering::SeqCst);
        stop.store(true, Ordering::SeqCst);
        let _ = handle.join();

        self.adb.remove_reverse(serial);
        if vdd_enabled {
            let _ = self.vdd.disable();
            if !saved.restore() {
                display_config::restore_extend();
            }
        }
        logline!("[orchestrator] Passive — waiting for tablet...");
    }
}

/// Small helper so the session thread can launch the client without borrowing the orchestrator.
struct AdbLauncher {
    adb_path: String,
    serial: String,
}
impl AdbLauncher {
    fn new(adb_path: String, serial: String) -> Self {
        Self { adb_path, serial }
    }
    fn launch(&self) {
        use std::os::windows::process::CommandExt;
        let _ = std::process::Command::new(&self.adb_path)
            .args(["-s", &self.serial, "shell", "am", "start", "-n", "com.seconddisplay.client/.MainActivity"])
            .creation_flags(crate::adb::CREATE_NO_WINDOW)
            .status();
    }
}
