//! Direct ADB-server socket fast path (adb-link).
//!
//! Talks to the adb server on 127.0.0.1:5037 with the same framing `adb.exe` itself uses
//! (4 hex chars length + payload, `OKAY`/`FAIL` status), so the hot poll (`host:devices`)
//! costs one ~2ms TCP round-trip instead of spawning `adb.exe` (~30-50ms + a process).
//! Every socket op degrades gracefully: callers fall back to the `adb.exe` subprocess path
//! on any error, so a dead/old server never breaks the host.
//!
//! Protocol reference: platform/system/adb SERVICES.TXT (`host:devices`, `host:track-devices`,
//! `host:transport:<serial>` + local `shell:` / `reverse:` services, `host:kill`).

use std::io::{Read, Write};
use std::net::{SocketAddr, TcpStream};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

const ADB_ADDR: &str = "127.0.0.1:5037";
const CONNECT_TIMEOUT: Duration = Duration::from_millis(1500);

fn open(timeout_ms: u64) -> Result<TcpStream, String> {
    let addr: SocketAddr = ADB_ADDR.parse().map_err(|e| format!("bad adb addr: {e}"))?;
    let s = TcpStream::connect_timeout(&addr, CONNECT_TIMEOUT)
        .map_err(|e| format!("connect 5037: {e}"))?;
    let to = Duration::from_millis(timeout_ms);
    s.set_read_timeout(Some(to))
        .map_err(|e| format!("read timeout: {e}"))?;
    s.set_write_timeout(Some(to))
        .map_err(|e| format!("write timeout: {e}"))?;
    Ok(s)
}

fn send_service(s: &mut TcpStream, service: &str) -> Result<(), String> {
    let frame = format!("{:04x}{service}", service.len());
    s.write_all(frame.as_bytes())
        .map_err(|e| format!("send: {e}"))
}

fn read_n(s: &mut TcpStream, n: usize) -> Result<Vec<u8>, String> {
    let mut buf = vec![0u8; n];
    let mut got = 0;
    while got < n {
        match s.read(&mut buf[got..]) {
            Ok(0) => return Err("unexpected EOF".to_string()),
            Ok(m) => got += m,
            Err(e) => return Err(format!("recv: {e}")),
        }
    }
    Ok(buf)
}

fn read_status(s: &mut TcpStream) -> Result<[u8; 4], String> {
    let v = read_n(s, 4)?;
    Ok([v[0], v[1], v[2], v[3]])
}

fn read_hex_len(s: &mut TcpStream) -> Result<usize, String> {
    let v = read_n(s, 4)?;
    let text = String::from_utf8_lossy(&v);
    usize::from_str_radix(text.trim(), 16).map_err(|_| format!("bad length '{text}'"))
}

/// Single-shot host service (`host:devices`, `host:version`, `host:list-forward`, ...).
/// Returns the payload on OKAY, Err(server message) on FAIL.
pub fn query(service: &str, timeout_ms: u64) -> Result<Vec<u8>, String> {
    let mut s = open(timeout_ms)?;
    send_service(&mut s, service)?;
    match read_status(&mut s)? {
        [b'O', b'K', b'A', b'Y'] => {
            let len = read_hex_len(&mut s)?.min(1 << 20);
            read_n(&mut s, len)
        }
        [b'F', b'A', b'I', b'L'] => {
            let len = read_hex_len(&mut s)?.min(4096);
            let msg = read_n(&mut s, len).unwrap_or_default();
            Err(String::from_utf8_lossy(&msg).into_owned())
        }
        other => Err(format!("bad status '{}'", String::from_utf8_lossy(&other))),
    }
}

/// Two-step device service: `host:transport:<serial>` then a local service
/// (`shell:<cmd>`, `reverse:forward:<local>;<remote>`, `reverse:killforward:<local>`).
/// Returns the streamed output (shell stdout, or `OKAY...` for reverse ops).
pub fn transport_exec(serial: &str, local: &str, timeout_ms: u64, max_bytes: usize) -> Result<Vec<u8>, String> {
    let mut s = open(timeout_ms)?;
    send_service(&mut s, &format!("host:transport:{serial}"))?;
    if read_status(&mut s)? != [b'O', b'K', b'A', b'Y'] {
        return Err("transport rejected".to_string());
    }
    send_service(&mut s, local)?;
    match read_status(&mut s)? {
        [b'O', b'K', b'A', b'Y'] => {}
        [b'F', b'A', b'I', b'L'] => {
            let len = read_hex_len(&mut s)?.min(4096);
            let msg = read_n(&mut s, len).unwrap_or_default();
            return Err(String::from_utf8_lossy(&msg).into_owned());
        }
        other => return Err(format!("bad local status '{}'", String::from_utf8_lossy(&other))),
    }
    // Stream until the server closes (command done). A read timeout here just ends
    // the stream with what we have — the command already completed server-side.
    let mut out = Vec::new();
    let mut buf = [0u8; 4096];
    loop {
        match s.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => {
                out.extend_from_slice(&buf[..n]);
                if out.len() >= max_bytes {
                    break;
                }
            }
            Err(_) => break,
        }
    }
    Ok(out)
}

/// Split a `host:devices` payload into (serial, state) pairs.
pub fn parse_device_pairs(payload: &[u8]) -> Vec<(String, String)> {
    let text = String::from_utf8_lossy(payload);
    let mut pairs = Vec::new();
    for line in text.lines() {
        let t = line.trim_end();
        if t.is_empty() {
            continue;
        }
        let mut parts = t.split('\t');
        let serial = parts.next().unwrap_or("").trim();
        let state = parts.next().unwrap_or("").trim();
        if serial.is_empty() || state.is_empty() {
            continue;
        }
        pairs.push((serial.to_string(), state.to_string()));
    }
    pairs
}

struct Tracked {
    pairs: Vec<(String, String)>,
    have_data: bool,
    alive: bool,
}

fn read_exact4(s: &mut TcpStream, buf: &mut [u8]) -> bool {
    let mut got = 0;
    while got < buf.len() {
        match s.read(&mut buf[got..]) {
            Ok(0) => return false,
            Ok(n) => got += n,
            Err(_) => return false,
        }
    }
    true
}

/// Persistent `host:track-devices` feed: the server pushes a new device list on every
/// connect/disconnect/state change, so the hot path reads a cached snapshot with zero
/// TCP handshakes and zero process spawns. Reconnects quietly if the server restarts.
pub struct DeviceTracker {
    state: Arc<Mutex<Tracked>>,
}

impl DeviceTracker {
    pub fn start() -> Self {
        let state = Arc::new(Mutex::new(Tracked {
            pairs: Vec::new(),
            have_data: false,
            alive: false,
        }));
        let worker = Arc::clone(&state);
        let _ = std::thread::Builder::new()
            .name("AdbTrack".into())
            .spawn(move || Self::run(worker));
        Self { state }
    }

    /// Cached device list if the track feed is live (any age — the server pushes every
    /// change, so a live feed is never stale). None while (re)connecting.
    pub fn snapshot(&self) -> Option<Vec<(String, String)>> {
        let st = self.state.lock().ok()?;
        if st.alive && st.have_data {
            Some(st.pairs.clone())
        } else {
            None
        }
    }

    fn run(state: Arc<Mutex<Tracked>>) {
        loop {
            Self::session(&state);
            if let Ok(mut st) = state.lock() {
                st.alive = false;
            }
            std::thread::sleep(Duration::from_secs(1));
        }
    }

    fn session(state: &Arc<Mutex<Tracked>>) {
        let addr: SocketAddr = match ADB_ADDR.parse() {
            Ok(a) => a,
            Err(_) => return,
        };
        let mut s = match TcpStream::connect_timeout(&addr, CONNECT_TIMEOUT) {
            Ok(s) => s,
            Err(_) => return,
        };
        // Blocking reads: this thread does nothing else. A dead server surfaces as a
        // read error and lands us back in the reconnect loop.
        let _ = s.set_read_timeout(None);
        let _ = s.set_write_timeout(Some(Duration::from_secs(5)));
        let frame = format!("{:04x}host:track-devices", "host:track-devices".len());
        if s.write_all(frame.as_bytes()).is_err() {
            return;
        }
        let mut st = [0u8; 4];
        if !read_exact4(&mut s, &mut st) || &st != b"OKAY" {
            return;
        }
        if let Ok(mut tracked) = state.lock() {
            tracked.alive = true;
        }
        let mut lb = [0u8; 4];
        loop {
            if !read_exact4(&mut s, &mut lb) {
                return;
            }
            let text = String::from_utf8_lossy(&lb);
            let len = match usize::from_str_radix(text.trim(), 16) {
                Ok(n) => n.min(1 << 20),
                Err(_) => return,
            };
            let mut payload = vec![0u8; len];
            let mut got = 0;
            while got < len {
                match s.read(&mut payload[got..]) {
                    Ok(0) => return,
                    Ok(n) => got += n,
                    Err(_) => return,
                }
            }
            let pairs = parse_device_pairs(&payload);
            if let Ok(mut tracked) = state.lock() {
                tracked.pairs = pairs;
                tracked.have_data = true;
                tracked.alive = true;
            }
            let _ = Instant::now();
        }
    }
}
