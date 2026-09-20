//! Touch/keyboard injection via `SendInput`, mirroring the C# `InputInjector`.

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicI64, Ordering};
use std::sync::{LazyLock, Mutex};
use windows::Win32::UI::Input::KeyboardAndMouse::{
    SendInput, INPUT, INPUT_0, INPUT_KEYBOARD, INPUT_MOUSE, KEYBDINPUT, KEYBD_EVENT_FLAGS,
    KEYEVENTF_EXTENDEDKEY, KEYEVENTF_KEYUP, KEYEVENTF_SCANCODE, MOUSEINPUT, MOUSEEVENTF_ABSOLUTE,
    MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP, MOUSEEVENTF_MOVE, MOUSEEVENTF_VIRTUALDESK, VIRTUAL_KEY,
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

/// A key as Windows wants it: virtual key plus the PS/2 set-1 scancode it is injected with.
#[derive(Clone, Copy)]
struct KeyMapping {
    vk: u16,
    scan: u16,
    extended: bool,
}

const VK_BACK: u16 = 0x08;
const VK_TAB: u16 = 0x09;
const VK_RETURN: u16 = 0x0D;
const VK_CAPITAL: u16 = 0x14;
const VK_ESCAPE: u16 = 0x1B;
const VK_SPACE: u16 = 0x20;
const VK_PRIOR: u16 = 0x21;
const VK_NEXT: u16 = 0x22;
const VK_END: u16 = 0x23;
const VK_HOME: u16 = 0x24;
const VK_LEFT: u16 = 0x25;
const VK_UP: u16 = 0x26;
const VK_RIGHT: u16 = 0x27;
const VK_DOWN: u16 = 0x28;
const VK_INSERT: u16 = 0x2D;
const VK_DELETE: u16 = 0x2E;
const VK_LWIN: u16 = 0x5B;
const VK_RWIN: u16 = 0x5C;
const VK_NUMPAD0: u16 = 0x60;
const VK_MULTIPLY: u16 = 0x6A;
const VK_ADD: u16 = 0x6B;
const VK_SUBTRACT: u16 = 0x6D;
const VK_DECIMAL: u16 = 0x6E;
const VK_DIVIDE: u16 = 0x6F;
const VK_F1: u16 = 0x70;
const VK_LSHIFT: u16 = 0xA0;
const VK_RSHIFT: u16 = 0xA1;
const VK_LCONTROL: u16 = 0xA2;
const VK_RCONTROL: u16 = 0xA3;
const VK_LMENU: u16 = 0xA4;
const VK_RMENU: u16 = 0xA5;
const VK_OEM_1: u16 = 0xBA;
const VK_OEM_PLUS: u16 = 0xBB;
const VK_OEM_COMMA: u16 = 0xBC;
const VK_OEM_MINUS: u16 = 0xBD;
const VK_OEM_PERIOD: u16 = 0xBE;
const VK_OEM_2: u16 = 0xBF;
const VK_OEM_3: u16 = 0xC0;
const VK_OEM_4: u16 = 0xDB;
const VK_OEM_5: u16 = 0xDC;
const VK_OEM_6: u16 = 0xDD;
const VK_OEM_7: u16 = 0xDE;

const META_SHIFT_ON: u32 = 0x0000_0001;
const META_ALT_ON: u32 = 0x0000_0002;
const META_CTRL_ON: u32 = 0x0000_1000;
const META_META_ON: u32 = 0x0001_0000;

/// Android keycode -> (VK, PS/2 set-1 scancode, isExtended). This is the primary mapping: the client
/// sends Android keycodes, and Android's numbering has nothing to do with Windows virtual keys (ALT
/// is 57 on Android and '9' is 57 on Windows, which is exactly how Alt+Tab turned into 9s on screen).
static KEY_MAP: LazyLock<HashMap<u16, KeyMapping>> = LazyLock::new(|| {
    let mut map: HashMap<u16, KeyMapping> = HashMap::new();
    let mut put = |code: u16, vk: u16, scan: u16, extended: bool| {
        map.insert(code, KeyMapping { vk, scan, extended });
    };

    // A-Z (Android 29..54), set-1 scancodes in alphabetical order.
    let letter_scans = [
        0x1Eu16, 0x30, 0x2E, 0x20, 0x12, 0x21, 0x22, 0x23, 0x17, 0x24, 0x25, 0x26, 0x32, 0x31,
        0x18, 0x19, 0x10, 0x13, 0x1F, 0x14, 0x16, 0x2F, 0x11, 0x2D, 0x15, 0x2C,
    ];
    for (i, scan) in letter_scans.iter().enumerate() {
        put(29 + i as u16, b'A' as u16 + i as u16, *scan, false);
    }
    // 0-9 (Android 7..16): 1 = 0x02 .. 9 = 0x0A, 0 = 0x0B.
    for d in 0..=9u16 {
        put(7 + d, b'0' as u16 + d, if d == 0 { 0x0B } else { 0x01 + d }, false);
    }
    // F1-F12 (Android 131..142).
    let f_scans = [0x3Bu16, 0x3C, 0x3D, 0x3E, 0x3F, 0x40, 0x41, 0x42, 0x43, 0x44, 0x57, 0x58];
    for (i, scan) in f_scans.iter().enumerate() {
        put(131 + i as u16, VK_F1 + i as u16, *scan, false);
    }
    // Numpad 0-9 (Android 144..153).
    let num_scans = [0x52u16, 0x4F, 0x50, 0x51, 0x4B, 0x4C, 0x4D, 0x47, 0x48, 0x49];
    for (i, scan) in num_scans.iter().enumerate() {
        put(144 + i as u16, VK_NUMPAD0 + i as u16, *scan, false);
    }

    put(19, VK_UP, 0x48, true); // DPAD_UP
    put(20, VK_DOWN, 0x50, true); // DPAD_DOWN
    put(21, VK_LEFT, 0x4B, true); // DPAD_LEFT
    put(22, VK_RIGHT, 0x4D, true); // DPAD_RIGHT
    put(55, VK_OEM_COMMA, 0x33, false); // COMMA
    put(56, VK_OEM_PERIOD, 0x34, false); // PERIOD
    put(57, VK_LMENU, 0x38, false); // ALT_LEFT
    put(58, VK_RMENU, 0x38, true); // ALT_RIGHT
    put(59, VK_LSHIFT, 0x2A, false); // SHIFT_LEFT
    put(60, VK_RSHIFT, 0x36, false); // SHIFT_RIGHT
    put(61, VK_TAB, 0x0F, false); // TAB
    put(62, VK_SPACE, 0x39, false); // SPACE
    put(66, VK_RETURN, 0x1C, false); // ENTER
    put(67, VK_BACK, 0x0E, false); // DEL (backspace)
    put(68, VK_OEM_3, 0x29, false); // GRAVE
    put(69, VK_OEM_MINUS, 0x0C, false); // MINUS
    put(70, VK_OEM_PLUS, 0x0D, false); // EQUALS
    put(71, VK_OEM_4, 0x1A, false); // LEFT_BRACKET
    put(72, VK_OEM_6, 0x1B, false); // RIGHT_BRACKET
    put(73, VK_OEM_5, 0x2B, false); // BACKSLASH
    put(74, VK_OEM_1, 0x27, false); // SEMICOLON
    put(75, VK_OEM_7, 0x28, false); // APOSTROPHE
    put(76, VK_OEM_2, 0x35, false); // SLASH
    put(92, VK_PRIOR, 0x49, true); // PAGE_UP
    put(93, VK_NEXT, 0x51, true); // PAGE_DOWN
    put(4, VK_ESCAPE, 0x01, false); // BACK
    put(111, VK_ESCAPE, 0x01, false); // ESCAPE
    put(112, VK_DELETE, 0x53, true); // FORWARD_DEL
    put(113, VK_LCONTROL, 0x1D, false); // CTRL_LEFT
    put(114, VK_RCONTROL, 0x1D, true); // CTRL_RIGHT
    put(115, VK_CAPITAL, 0x3A, false); // CAPS_LOCK
    put(117, VK_LWIN, 0x5B, true); // META_LEFT
    put(118, VK_RWIN, 0x5C, true); // META_RIGHT
    put(122, VK_HOME, 0x47, true); // MOVE_HOME
    put(123, VK_END, 0x4F, true); // MOVE_END
    put(124, VK_INSERT, 0x52, true); // INSERT
    put(154, VK_DIVIDE, 0x35, true); // NUMPAD_DIVIDE
    put(155, VK_MULTIPLY, 0x37, false); // NUMPAD_MULTIPLY
    put(156, VK_SUBTRACT, 0x4A, false); // NUMPAD_SUBTRACT
    put(157, VK_ADD, 0x4E, false); // NUMPAD_ADD
    put(158, VK_DECIMAL, 0x53, false); // NUMPAD_DOT
    put(160, VK_RETURN, 0x1C, true); // NUMPAD_ENTER
    put(161, VK_OEM_PLUS, 0x59, false); // NUMPAD_EQUALS
    map
});

/// Fallback for keys outside `KEY_MAP`: evdev scancode (from the client) -> set-1 extended scancode.
/// Evdev codes <= 0x58 coincide with set-1 for the main keyboard block and are used directly.
static EVDEV_EXTENDED: LazyLock<HashMap<u16, (u16, bool)>> = LazyLock::new(|| {
    HashMap::from([
        (96, (0x1C, true)),  // KEY_KPENTER
        (97, (0x1D, true)),  // KEY_RIGHTCTRL
        (98, (0x35, true)),  // KEY_KPSLASH
        (100, (0x38, true)), // KEY_RIGHTALT
        (102, (0x47, true)), // KEY_HOME
        (103, (0x48, true)), // KEY_UP
        (104, (0x49, true)), // KEY_PAGEUP
        (105, (0x4B, true)), // KEY_LEFT
        (106, (0x4D, true)), // KEY_RIGHT
        (107, (0x4F, true)), // KEY_END
        (108, (0x50, true)), // KEY_DOWN
        (109, (0x51, true)), // KEY_PAGEDOWN
        (110, (0x52, true)), // KEY_INSERT
        (111, (0x53, true)), // KEY_DELETE
        (125, (0x5B, true)), // KEY_LEFTMETA
        (126, (0x5C, true)), // KEY_RIGHTMETA
    ])
});

/// Pressed keys, keyed by Android keycode (stable per physical key, avoids VK collisions).
static KEYS_DOWN: LazyLock<Mutex<HashMap<u16, KeyMapping>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));
/// Synthetic modifiers (from metaState) pressed on behalf of a key, released on that key's key-up.
static SYNTHETIC_MODS: LazyLock<Mutex<HashMap<u16, Vec<KeyMapping>>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

/// Android keycode -> what to inject, with the evdev scancode as the fallback.
fn resolve(key_code: u16, scan_code: u16) -> Option<KeyMapping> {
    if let Some(m) = KEY_MAP.get(&key_code) {
        return Some(*m);
    }
    if scan_code == 0 {
        return None;
    }
    if scan_code <= 0x58 {
        // vk = 0: Windows derives the virtual key from the scancode.
        return Some(KeyMapping { vk: 0, scan: scan_code, extended: false });
    }
    EVDEV_EXTENDED.get(&scan_code).map(|(scan, extended)| KeyMapping {
        vk: 0,
        scan: *scan,
        extended: *extended,
    })
}

fn send_key(m: KeyMapping, up: bool) {
    let mut flags: u32 = KEYEVENTF_SCANCODE.0;
    if m.extended {
        flags |= KEYEVENTF_EXTENDEDKEY.0;
    }
    if up {
        flags |= KEYEVENTF_KEYUP.0;
    }
    let input = INPUT {
        r#type: INPUT_KEYBOARD,
        Anonymous: INPUT_0 {
            ki: KEYBDINPUT {
                wVk: VIRTUAL_KEY(m.vk),
                wScan: m.scan,
                dwFlags: KEYBD_EVENT_FLAGS(flags),
                time: 0,
                dwExtraInfo: 0,
            },
        },
    };
    unsafe {
        SendInput(&[input], std::mem::size_of::<INPUT>() as i32);
    }
}

fn is_modifier(vk: u16) -> bool {
    matches!(
        vk,
        VK_LSHIFT | VK_RSHIFT | VK_LMENU | VK_RMENU | VK_LCONTROL | VK_RCONTROL | VK_LWIN | VK_RWIN
    )
}

fn any_down(keys: &HashMap<u16, KeyMapping>, vk: u16) -> bool {
    keys.values().any(|m| m.vk == vk)
}

/// Modifiers the client says are held but that we have not pressed ourselves. The client reports
/// Alt/Shift/Ctrl as metaState on the key event, so a chord like Alt+Tab needs them synthesised.
fn missing_meta_modifiers(keys: &HashMap<u16, KeyMapping>, meta_state: u32) -> Vec<KeyMapping> {
    let mut mods = Vec::new();
    if meta_state & META_SHIFT_ON != 0 && !any_down(keys, VK_LSHIFT) && !any_down(keys, VK_RSHIFT) {
        mods.push(KeyMapping { vk: VK_LSHIFT, scan: 0x2A, extended: false });
    }
    if meta_state & META_ALT_ON != 0 && !any_down(keys, VK_LMENU) && !any_down(keys, VK_RMENU) {
        mods.push(KeyMapping { vk: VK_LMENU, scan: 0x38, extended: false });
    }
    if meta_state & META_CTRL_ON != 0 && !any_down(keys, VK_LCONTROL) && !any_down(keys, VK_RCONTROL)
    {
        mods.push(KeyMapping { vk: VK_LCONTROL, scan: 0x1D, extended: false });
    }
    if meta_state & META_META_ON != 0 && !any_down(keys, VK_LWIN) && !any_down(keys, VK_RWIN) {
        mods.push(KeyMapping { vk: VK_LWIN, scan: 0x5B, extended: true });
    }
    mods
}

/// A single key press/release. `action`: 0 = down, 1 = up. `key_code` is the Android keycode, the
/// same one the client's KeyEvent carries; `scan_code` is its evdev code, used as the fallback.
pub fn inject_key(action: u8, key_code: u16, scan_code: u16, meta_state: u32) {
    let Some(m) = resolve(key_code, scan_code) else {
        return;
    };
    let mut keys = KEYS_DOWN.lock().unwrap_or_else(|e| e.into_inner());
    let mut mods = SYNTHETIC_MODS.lock().unwrap_or_else(|e| e.into_inner());

    if action == 1 {
        // Stray key-up (we never saw the key-down): nothing to release.
        let Some(down) = keys.remove(&key_code) else { return };
        send_key(down, true);
        if let Some(synth) = mods.remove(&key_code) {
            for m in synth.iter().rev() {
                send_key(*m, true);
            }
        }
        INJECTED_KEYS.fetch_add(1, Ordering::SeqCst);
        return;
    }

    let already_down = keys.contains_key(&key_code);
    // Press synthetic modifiers only on the first key-down: they stay held until the key goes up.
    let mut new_mods = Vec::new();
    if !already_down && !is_modifier(m.vk) {
        new_mods = missing_meta_modifiers(&keys, meta_state);
        for mod_key in &new_mods {
            send_key(*mod_key, false);
        }
    }

    send_key(m, false);
    keys.insert(key_code, m);
    if !new_mods.is_empty() {
        mods.insert(key_code, new_mods);
    }
    INJECTED_KEYS.fetch_add(1, Ordering::SeqCst);
}

/// Release the left button if we think it's held and every key we pressed (a vanished client must
/// not leave a stuck modifier or drag behind).
pub fn release_all_keys() {
    {
        let mut keys = KEYS_DOWN.lock().unwrap_or_else(|e| e.into_inner());
        for m in keys.values() {
            send_key(*m, true);
        }
        keys.clear();
        SYNTHETIC_MODS
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clear();
    }

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
