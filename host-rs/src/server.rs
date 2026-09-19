//! TCP server + per-client sessions, mirroring the C# `Server`/`ClientSession`.
//!
//! Each client gets a bounded frame queue with drop-oldest semantics (low latency) and a send
//! thread that emits a `PING` heartbeat whenever no video has flowed for 2s (so the client
//! survives an encoder stall/recreate without reconnecting).

use crate::logline;
use crate::protocol::{self, Key, Touch};
use std::collections::VecDeque;
use std::io::Write;
use std::net::{TcpListener, TcpStream};
use std::sync::atomic::{AtomicBool, AtomicI64, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::Duration;

pub const PING_IDLE_MS: u64 = 2_000;

#[derive(Clone)]
pub struct VideoPacket {
    pub pts_micros: i64,
    pub keyframe: bool,
    pub data: Arc<Vec<u8>>,
}

#[derive(Clone, Default)]
pub struct CursorState {
    pub visible: bool,
    pub x: i32,
    pub y: i32,
    pub w: i32,
    pub h: i32,
    pub bgra: Arc<Vec<u8>>,
}

/// Bounded, drop-oldest frame queue (capacity 2) with a condvar for the send thread.
struct FrameQueue {
    inner: Mutex<VecDeque<VideoPacket>>,
    cv: Condvar,
    closed: AtomicBool,
}

impl FrameQueue {
    fn new(cap: usize) -> Self {
        Self {
            inner: Mutex::new(VecDeque::with_capacity(cap + 1)),
            cv: Condvar::new(),
            closed: AtomicBool::new(false),
        }
    }

    fn push(&self, p: VideoPacket) {
        let mut q = self.inner.lock().unwrap();
        while q.len() >= 2 {
            q.pop_front();
        }
        q.push_back(p);
        self.cv.notify_one();
    }

    /// Wait up to `timeout` for a frame.
    fn pop_timeout(&self, timeout: Duration) -> Option<VideoPacket> {
        let mut q = self.inner.lock().unwrap();
        if q.is_empty() {
            let (nq, _) = self.cv.wait_timeout(q, timeout).unwrap();
            q = nq;
        }
        q.pop_front()
    }

    fn close(&self) {
        self.closed.store(true, Ordering::SeqCst);
        self.cv.notify_all();
    }

    fn is_closed(&self) -> bool {
        self.closed.load(Ordering::SeqCst)
    }
}

pub struct ClientSession {
    read_stream: TcpStream,
    writer: Mutex<TcpStream>,
    queue: Arc<FrameQueue>,
    touches: Mutex<VecDeque<Touch>>,
    keys: Mutex<VecDeque<Key>>,
    cursor: Mutex<Option<CursorState>>,
    cursor_seq: AtomicI64,
    refresh_rate: u32,
    pub remote: String,
    closed: AtomicBool,
}

impl ClientSession {
    pub fn send_frame(&self, p: VideoPacket) {
        if self.closed.load(Ordering::SeqCst) {
            return;
        }
        self.queue.push(p);
    }

    pub fn send_cursor(&self, c: CursorState) {
        if self.closed.load(Ordering::SeqCst) {
            return;
        }
        *self.cursor.lock().unwrap() = Some(c);
        self.cursor_seq.fetch_add(1, Ordering::SeqCst);
    }

    fn try_pop_touch(&self) -> Option<Touch> {
        self.touches.lock().unwrap().pop_front()
    }
    fn try_pop_key(&self) -> Option<Key> {
        self.keys.lock().unwrap().pop_front()
    }

    fn close(&self) {
        if self.closed.swap(true, Ordering::SeqCst) {
            return;
        }
        self.queue.close();
        let _ = self.read_stream.shutdown(std::net::Shutdown::Both);
        let _ = self.writer.lock().unwrap().shutdown(std::net::Shutdown::Both);
    }

    fn receive_loop(&self) {
        let mut stream = self.read_stream.try_clone().expect("clone read stream");
        loop {
            match protocol::read_packet(&mut stream) {
                Ok((ty, payload)) => match ty {
                    protocol::TOUCH if payload.len() >= 10 => {
                        self.touches.lock().unwrap().push_back(protocol::parse_touch(&payload));
                    }
                    protocol::KEY if payload.len() >= 7 => {
                        self.keys.lock().unwrap().push_back(protocol::parse_key(&payload));
                    }
                    _ => {}
                },
                Err(_) => break,
            }
        }
        self.close();
    }

    fn send_loop(&self) {
        let mut sent_cursor_seq = i64::MIN;
        loop {
            if self.queue.is_closed() {
                break;
            }
            match self.queue.pop_timeout(Duration::from_millis(PING_IDLE_MS)) {
                Some(frame) => {
                    let cursor = {
                        let seq = self.cursor_seq.load(Ordering::SeqCst);
                        if seq != sent_cursor_seq {
                            sent_cursor_seq = seq;
                            self.cursor.lock().unwrap().clone()
                        } else {
                            None
                        }
                    };
                    let mut w = self.writer.lock().unwrap();
                    if let Some(c) = cursor {
                        if protocol::write_cursor(&mut *w, c.visible, c.x, c.y, c.w, c.h, &c.bgra)
                            .is_err()
                        {
                            break;
                        }
                    }
                    if protocol::write_video_frame(&mut *w, frame.pts_micros, frame.keyframe, &frame.data)
                        .is_err()
                    {
                        break;
                    }
                    let _ = w.flush();
                }
                None => {
                    let mut w = self.writer.lock().unwrap();
                    if protocol::write_ping(&mut *w).is_err() {
                        break;
                    }
                    let _ = w.flush();
                }
            }
        }
        self.close();
    }
}

pub struct Server {
    listener: TcpListener,
    clients: Mutex<Vec<Arc<ClientSession>>>,
    port: u16,
}

impl Server {
    pub fn new(port: u16) -> std::io::Result<Self> {
        let listener = TcpListener::bind(("0.0.0.0", port))?;
        Ok(Self { listener, clients: Mutex::new(Vec::new()), port })
    }

    pub fn start(self: &Arc<Self>, capture_w: u32, capture_h: u32) {
        logline!("Server listening on 0.0.0.0:{}", self.port);
        let me = Arc::clone(self);
        std::thread::Builder::new()
            .name("TcpAccept".into())
            .spawn(move || {
                for stream in me.listener.incoming() {
                    let Ok(stream) = stream else { break };
                    let _ = stream.set_nodelay(true);
                    if let Some(session) = me.handshake(stream, capture_w, capture_h) {
                        logline!("Client connected: {}", session.remote);
                        me.clients.lock().unwrap().push(Arc::clone(&session));
                        let recv = Arc::clone(&session);
                        let send = Arc::clone(&session);
                        std::thread::Builder::new()
                            .name("ClientRecv".into())
                            .spawn(move || recv.receive_loop())
                            .ok();
                        std::thread::Builder::new()
                            .name("ClientSend".into())
                            .spawn(move || send.send_loop())
                            .ok();
                    }
                }
            })
            .ok();
    }

    fn handshake(
        &self,
        stream: TcpStream,
        capture_w: u32,
        capture_h: u32,
    ) -> Option<Arc<ClientSession>> {
        let mut rd = stream.try_clone().ok()?;
        let (ty, payload) = protocol::read_packet(&mut rd).ok()?;
        if ty != protocol::HELLO || payload.len() < 16 {
            return None;
        }
        let hello = protocol::parse_hello(&payload);
        logline!(
            "Client: {}x{} @ {}Hz, {}dpi",
            hello.width,
            hello.height,
            hello.refresh_rate,
            hello.density
        );

        let mut wr = stream.try_clone().ok()?;
        protocol::write_ready(&mut wr, capture_w, capture_h, hello.refresh_rate).ok()?;
        wr.flush().ok()?;

        Some(Arc::new(ClientSession {
            read_stream: stream,
            writer: Mutex::new(wr),
            queue: Arc::new(FrameQueue::new(2)),
            touches: Mutex::new(VecDeque::new()),
            keys: Mutex::new(VecDeque::new()),
            cursor: Mutex::new(None),
            cursor_seq: AtomicI64::new(0),
            refresh_rate: hello.refresh_rate,
            remote: "client".to_string(),
            closed: AtomicBool::new(false),
        }))
    }

    /// Drop sessions whose socket died.
    fn prune(&self) {
        let mut clients = self.clients.lock().unwrap();
        clients.retain(|c| !c.closed.load(Ordering::SeqCst));
    }

    pub fn broadcast_frame(&self, pts_micros: i64, keyframe: bool, data: &[u8]) {
        let pkt = VideoPacket {
            pts_micros,
            keyframe,
            data: Arc::new(data.to_vec()),
        };
        self.prune();
        for c in self.clients.lock().unwrap().iter() {
            c.send_frame(pkt.clone());
        }
    }

    pub fn broadcast_cursor(&self, c: CursorState) {
        let clients = self.clients.lock().unwrap();
        for cl in clients.iter() {
            cl.send_cursor(c.clone());
        }
    }

    pub fn poll_touch(&self) -> Option<Touch> {
        for c in self.clients.lock().unwrap().iter() {
            if let Some(t) = c.try_pop_touch() {
                return Some(t);
            }
        }
        None
    }

    pub fn poll_key(&self) -> Option<Key> {
        for c in self.clients.lock().unwrap().iter() {
            if let Some(k) = c.try_pop_key() {
                return Some(k);
            }
        }
        None
    }

    pub fn has_clients(&self) -> bool {
        self.prune();
        !self.clients.lock().unwrap().is_empty()
    }

    pub fn client_count(&self) -> usize {
        self.prune();
        self.clients.lock().unwrap().len()
    }

    pub fn preferred_refresh_rate(&self) -> u32 {
        self.clients
            .lock()
            .unwrap()
            .iter()
            .map(|c| c.refresh_rate)
            .max()
            .unwrap_or(0)
    }

    pub fn dispose(&self) {
        for c in self.clients.lock().unwrap().iter() {
            c.close();
        }
        self.clients.lock().unwrap().clear();
    }
}

// Silence the unused-writer import when the trait method is inlined.
#[allow(dead_code)]
fn _use_write(_: &dyn Write) {}
