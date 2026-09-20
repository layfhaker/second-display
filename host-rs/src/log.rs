//! Logging: mirror stdout to `%LOCALAPPDATA%\SecondDisplay\host.log`, like the C# `TeeTextWriter`.
//!
//! Writes are handed to a dedicated background thread so latency-critical code (the capture/encode
//! loop, the input pump) never blocks on disk I/O.

use std::fs::{File, OpenOptions};
use std::io::Write;
use std::path::PathBuf;
use std::sync::mpsc::{self, Sender};
use std::sync::OnceLock;

struct Entry {
    text: String,
    line: bool,
}

static SENDER: OnceLock<Sender<Entry>> = OnceLock::new();
static LOG_PATH: OnceLock<PathBuf> = OnceLock::new();

/// Default log path: `%LOCALAPPDATA%\SecondDisplay\host.log`.
pub fn default_log_path() -> PathBuf {
    let base = std::env::var_os("LOCALAPPDATA")
        .map(PathBuf::from)
        .unwrap_or_else(std::env::temp_dir);
    base.join("SecondDisplay").join("host.log")
}

/// Write one line straight to the log file, bypassing the writer thread. Anything logged just before
/// the process exits (the memory watchdog does exactly that) would otherwise be dropped with the
/// queued entries, leaving a restart with no explanation in the log.
pub fn log_sync(msg: &str) {
    let Some(path) = LOG_PATH.get() else {
        return;
    };
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    if let Ok(mut f) = OpenOptions::new().create(true).append(true).open(path) {
        let _ = writeln!(f, "[exit @{now}] {msg}");
        let _ = f.flush();
    }
}

/// Start the background logger. The previous run's file is kept as `<name>.prev` so a crash can
/// still be diagnosed after the host restarts (truncating it destroyed the evidence every time).
pub fn init(path: &PathBuf) {
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    if path.exists() {
        let mut prev = path.clone();
        let name = path
            .file_name()
            .map(|n| n.to_string_lossy().to_string())
            .unwrap_or_else(|| "host.log".into());
        prev.set_file_name(format!("{name}.prev"));
        let _ = std::fs::rename(path, &prev);
    }
    let file: File = OpenOptions::new()
        .create(true)
        .write(true)
        .truncate(true)
        .open(path)
        .or_else(|_| OpenOptions::new().create(true).append(true).open(path))
        .expect("open log file");
    let _ = LOG_PATH.set(path.clone());

    let (tx, rx) = mpsc::channel::<Entry>();
    let _ = SENDER.set(tx);

    std::thread::Builder::new()
        .name("LogWriter".into())
        .spawn(move || {
            let mut file = file;
            while let Ok(e) = rx.recv() {
                if e.line {
                    println!("{}", e.text);
                    let ts = timestamp();
                    let _ = writeln!(file, "[{ts}] {}", e.text);
                } else {
                    print!("{}", e.text);
                    let _ = write!(file, "{}", e.text);
                }
                let _ = file.flush();
            }
        })
        .expect("spawn LogWriter");
}

fn timestamp() -> String {
    // Local wall-clock time (matches the C# host's log format).
    use windows::Win32::System::SystemInformation::GetLocalTime;
    let t = unsafe { GetLocalTime() };
    format!(
        "{:02}:{:02}:{:02}.{:03}",
        t.wHour, t.wMinute, t.wSecond, t.wMilliseconds
    )
}

/// Print + log one line. Use everywhere instead of `println!`.
#[macro_export]
macro_rules! logline {
    ($($arg:tt)*) => {{
        $crate::log::write_line(&format!($($arg)*));
    }};
}

pub fn write_line(text: &str) {
    if let Some(tx) = SENDER.get() {
        let _ = tx.send(Entry { text: text.to_string(), line: true });
    } else {
        println!("{text}");
    }
}
