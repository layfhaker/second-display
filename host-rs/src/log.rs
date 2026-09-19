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

/// Default log path: `%LOCALAPPDATA%\SecondDisplay\host.log`.
pub fn default_log_path() -> PathBuf {
    let base = std::env::var_os("LOCALAPPDATA")
        .map(PathBuf::from)
        .unwrap_or_else(std::env::temp_dir);
    base.join("SecondDisplay").join("host.log")
}

/// Start the background logger. Truncates the file, like the C# host does on start.
pub fn init(path: &PathBuf) {
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let file: File = OpenOptions::new()
        .create(true)
        .write(true)
        .truncate(true)
        .open(path)
        .or_else(|_| OpenOptions::new().create(true).append(true).open(path))
        .expect("open log file");

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
    // HH:MM:SS.mmm local time via the system clock.
    use std::time::{SystemTime, UNIX_EPOCH};
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default();
    let secs = now.as_secs();
    let ms = now.subsec_millis();
    let (h, m, s) = (secs / 3600 % 24, secs / 60 % 60, secs % 60);
    format!("{h:02}:{m:02}:{s:02}.{ms:03}")
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
