//! Touch/keyboard injection via `SendInput`, mirroring the C# `InputInjector`.

use std::sync::atomic::{AtomicBool, AtomicI64, Ordering};
use windows::Win32::UI::Input::KeyboardAndMouse::{
    SendInput, INPUT, INPUT_0, INPUT_KEYBOARD, INPUT_MOUSE, KEYBDINPUT, KEYBD_EVENT_FLAGS,
    KEYEVENTF_KEYUP, MOUSEINPUT, MOUSEEVENTF_ABSOLUTE, MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP,
    MOUSEEVENTF_MOVE, MOUSEEVENTF_VIRTUALDESK, VIRTUAL_KEY,
};
use windows::Win32::UI::WindowsAndMessaging::{
    GetSystemMetrics, SM_CXVIRTUALSCREEN, SM_CYVIRTUALSCREEN, SM_XVIRTUALSCREEN, SM_YVIRTUALSCREEN,
};

static INJECTED_KEYS: AtomicI64 = AtomicI64::new(0);
static INJECTED_TOUCHES: AtomicI64 = AtomicI64::new(0);
static LEFT_DOWN: AtomicBool = AtomicBool::new(false);

pub fn injected_keys() -> i64 {
    INJECTED_KEYS.swap(0, Ordering::SeqCst)
}
pub fn injected_touches() -> i64 {
    INJECTED_TOUCHES.swap(0, Ordering::SeqCst)
}

/// Normalised (0..1) touch → absolute mouse. `origin/cap` describe the captured monitor.
pub fn inject_touch(action: u8, x: f32, y: f32, origin_x: i32, origin_y: i32, cap_w: i32, cap_h: i32) {
    let vx = unsafe { GetSystemMetrics(SM_XVIRTUALSCREEN) };
    let vy = unsafe { GetSystemMetrics(SM_YVIRTUALSCREEN) };
    let vw = unsafe { GetSystemMetrics(SM_CXVIRTUALSCREEN) }.max(1);
    let vh = unsafe { GetSystemMetrics(SM_CYVIRTUALSCREEN) }.max(1);

    let px = origin_x + (x.clamp(0.0, 1.0) * cap_w as f32) as i32;
    let py = origin_y + (y.clamp(0.0, 1.0) * cap_h as f32) as i32;
    let nx = (((px - vx) as f64 / vw as f64) * 65535.0) as i32;
    let ny = (((py - vy) as f64 / vh as f64) * 65535.0) as i32;

    let mut flags = MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK | MOUSEEVENTF_MOVE;
    match action {
        0 => {
            flags |= MOUSEEVENTF_LEFTDOWN;
            LEFT_DOWN.store(true, Ordering::SeqCst);
        }
        2 => {
            flags |= MOUSEEVENTF_LEFTUP;
            LEFT_DOWN.store(false, Ordering::SeqCst);
        }
        _ => {}
    }

    let input = INPUT {
        r#type: INPUT_MOUSE,
        Anonymous: INPUT_0 {
            mi: MOUSEINPUT {
                dx: nx,
                dy: ny,
                mouseData: 0,
                dwFlags: flags,
                time: 0,
                dwExtraInfo: 0,
            },
        },
    };
    unsafe {
        SendInput(&[input], std::mem::size_of::<INPUT>() as i32);
    }
    INJECTED_TOUCHES.fetch_add(1, Ordering::SeqCst);
}

/// A single key press/release. `action`: 0 = down, 1 = up.
pub fn inject_key(action: u8, key_code: u16) {
    let flags: KEYBD_EVENT_FLAGS = if action == 1 { KEYEVENTF_KEYUP } else { KEYBD_EVENT_FLAGS(0) };
    let input = INPUT {
        r#type: INPUT_KEYBOARD,
        Anonymous: INPUT_0 {
            ki: KEYBDINPUT {
                wVk: VIRTUAL_KEY(key_code),
                wScan: 0,
                dwFlags: flags,
                time: 0,
                dwExtraInfo: 0,
            },
        },
    };
    unsafe {
        SendInput(&[input], std::mem::size_of::<INPUT>() as i32);
    }
    INJECTED_KEYS.fetch_add(1, Ordering::SeqCst);
}

/// Release the left button if we think it's held (avoids stuck drags when a client vanishes).
pub fn release_all_keys() {
    if LEFT_DOWN.swap(false, Ordering::SeqCst) {
        let input = INPUT {
            r#type: INPUT_MOUSE,
            Anonymous: INPUT_0 {
                mi: MOUSEINPUT {
                    dx: 0,
                    dy: 0,
                    mouseData: 0,
                    dwFlags: MOUSEEVENTF_LEFTUP,
                    time: 0,
                    dwExtraInfo: 0,
                },
            },
        };
        unsafe {
            SendInput(&[input], std::mem::size_of::<INPUT>() as i32);
        }
    }
}
