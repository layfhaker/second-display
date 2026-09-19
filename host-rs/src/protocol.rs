//! Wire protocol (see `docs/PROTOCOL.md`): 5-byte header (type + u32 LE length) + payload.

use std::io::{self, Read, Write};
use std::net::TcpStream;

pub const HELLO: u8 = 0x01;
pub const READY: u8 = 0x02;
pub const VIDEO: u8 = 0x10;
pub const CURSOR: u8 = 0x11;
pub const TOUCH: u8 = 0x20;
pub const SCROLL: u8 = 0x21;
pub const KEY: u8 = 0x22;
/// Keep-alive sent while no video flows (encoder stalled or being recreated).
pub const PING: u8 = 0x30;

pub const CODEC_H265: u8 = 2;

const HEADER_SIZE: usize = 5;
const MAX_PACKET: usize = 16 * 1024 * 1024;

#[derive(Debug, Clone, Copy)]
pub struct Hello {
    pub width: u32,
    pub height: u32,
    pub density: u32,
    pub refresh_rate: u32,
}

#[derive(Debug, Clone, Copy)]
pub struct Ready {
    pub width: u32,
    pub height: u32,
    pub refresh_rate: u32,
    pub codec: u8,
}

#[derive(Debug, Clone, Copy)]
pub struct Touch {
    pub action: u8,
    pub pointer_id: u8,
    pub x: f32,
    pub y: f32,
}

#[derive(Debug, Clone, Copy)]
pub struct Key {
    pub action: u8,
    pub key_code: u16,
    pub meta_state: u32,
    pub scan_code: u16,
}

pub fn write_packet(w: &mut impl Write, ty: u8, payload: &[u8]) -> io::Result<()> {
    let mut header = [0u8; HEADER_SIZE];
    header[0] = ty;
    header[1..5].copy_from_slice(&(payload.len() as u32).to_le_bytes());
    w.write_all(&header)?;
    w.write_all(payload)?;
    Ok(())
}

pub fn write_ready(w: &mut impl Write, w_: u32, h: u32, refresh: u32) -> io::Result<()> {
    let mut buf = [0u8; 13];
    buf[0..4].copy_from_slice(&w_.to_le_bytes());
    buf[4..8].copy_from_slice(&h.to_le_bytes());
    buf[8..12].copy_from_slice(&refresh.to_le_bytes());
    buf[12] = CODEC_H265;
    write_packet(w, READY, &buf)
}

pub fn write_video_frame(
    w: &mut impl Write,
    pts_micros: i64,
    keyframe: bool,
    data: &[u8],
) -> io::Result<()> {
    let mut meta = [0u8; 9];
    meta[0..8].copy_from_slice(&pts_micros.to_le_bytes());
    meta[8] = if keyframe { 1 } else { 0 };

    let mut header = [0u8; HEADER_SIZE];
    header[0] = VIDEO;
    header[1..5].copy_from_slice(&((9 + data.len()) as u32).to_le_bytes());
    w.write_all(&header)?;
    w.write_all(&meta)?;
    w.write_all(data)?;
    Ok(())
}

pub fn write_cursor(
    w: &mut impl Write,
    visible: bool,
    x: i32,
    y: i32,
    cw: i32,
    ch: i32,
    bgra: &[u8],
) -> io::Result<()> {
    let mut meta = [0u8; 17];
    meta[0] = if visible { 1 } else { 0 };
    meta[1..5].copy_from_slice(&x.to_le_bytes());
    meta[5..9].copy_from_slice(&y.to_le_bytes());
    meta[9..13].copy_from_slice(&cw.to_le_bytes());
    meta[13..17].copy_from_slice(&ch.to_le_bytes());

    let mut header = [0u8; HEADER_SIZE];
    header[0] = CURSOR;
    header[1..5].copy_from_slice(&((17 + bgra.len()) as u32).to_le_bytes());
    w.write_all(&header)?;
    w.write_all(&meta)?;
    w.write_all(bgra)?;
    Ok(())
}

pub fn write_ping(w: &mut impl Write) -> io::Result<()> {
    write_packet(w, PING, &[])
}

fn read_exact(s: &mut impl Read, buf: &mut [u8]) -> io::Result<()> {
    s.read_exact(buf)
}

/// Read one packet. Returns `(type, payload)`.
pub fn read_packet(s: &mut impl Read) -> io::Result<(u8, Vec<u8>)> {
    let mut header = [0u8; HEADER_SIZE];
    read_exact(s, &mut header)?;
    let ty = header[0];
    let len = u32::from_le_bytes(header[1..5].try_into().unwrap()) as usize;
    if len > MAX_PACKET {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "packet too large"));
    }
    let mut payload = vec![0u8; len];
    read_exact(s, &mut payload)?;
    Ok((ty, payload))
}

pub fn parse_hello(p: &[u8]) -> Hello {
    Hello {
        width: u32::from_le_bytes(p[0..4].try_into().unwrap()),
        height: u32::from_le_bytes(p[4..8].try_into().unwrap()),
        density: u32::from_le_bytes(p[8..12].try_into().unwrap()),
        refresh_rate: u32::from_le_bytes(p[12..16].try_into().unwrap()),
    }
}

pub fn parse_touch(p: &[u8]) -> Touch {
    Touch {
        action: p[0],
        pointer_id: p[1],
        x: f32::from_le_bytes(p[2..6].try_into().unwrap()),
        y: f32::from_le_bytes(p[6..10].try_into().unwrap()),
    }
}

pub fn parse_key(p: &[u8]) -> Key {
    let scan_code = if p.len() >= 9 {
        u16::from_le_bytes(p[7..9].try_into().unwrap())
    } else {
        0
    };
    Key {
        action: p[0],
        key_code: u16::from_le_bytes(p[1..3].try_into().unwrap()),
        meta_state: u32::from_le_bytes(p[3..7].try_into().unwrap()),
        scan_code,
    }
}

/// Set the socket read timeout (used by client sessions).
pub fn set_read_timeout(sock: &TcpStream, ms: u64) {
    let _ = sock.set_read_timeout(Some(std::time::Duration::from_millis(ms)));
}
