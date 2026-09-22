const std = @import("std");
const w = @import("win.zig");
const cap = @import("capture.zig");

pub const PKT_TOUCH: u8 = 0x20;
pub const PKT_SCROLL: u8 = 0x21;
pub const PKT_KEY: u8 = 0x22;
pub const PKT_CURSOR: u8 = 0x11;

// ------------------------------------------------------------------ keymap

const KeyMapping = struct {
    vk: u16,
    scan: u16,
    extended: bool,
};

// Android keycode -> (VK, PS/2 set-1 scancode, isExtended).
// Ported from the reference C# InputInjector (same data as the asm/HolyC tables).
var key_map = buildKeyMap();

// Fallback: evdev scancode (from the client) -> set-1 extended scancode.
const EvdevExt = struct { code: u16, scan: u16, ext: bool };
const evdev_extended = [_]EvdevExt{
    .{ .code = 96, .scan = 0x1C, .ext = true }, // KEY_KPENTER
    .{ .code = 97, .scan = 0x1D, .ext = true }, // KEY_RIGHTCTRL
    .{ .code = 98, .scan = 0x35, .ext = true }, // KEY_KPSLASH
    .{ .code = 100, .scan = 0x38, .ext = true }, // KEY_RIGHTALT
    .{ .code = 102, .scan = 0x47, .ext = true }, // KEY_HOME
    .{ .code = 103, .scan = 0x48, .ext = true }, // KEY_UP
    .{ .code = 104, .scan = 0x49, .ext = true }, // KEY_PAGEUP
    .{ .code = 105, .scan = 0x4B, .ext = true }, // KEY_LEFT
    .{ .code = 106, .scan = 0x4D, .ext = true }, // KEY_RIGHT
    .{ .code = 107, .scan = 0x4F, .ext = true }, // KEY_END
    .{ .code = 108, .scan = 0x50, .ext = true }, // KEY_DOWN
    .{ .code = 109, .scan = 0x51, .ext = true }, // KEY_PAGEDOWN
    .{ .code = 110, .scan = 0x52, .ext = true }, // KEY_INSERT
    .{ .code = 111, .scan = 0x53, .ext = true }, // KEY_DELETE
    .{ .code = 125, .scan = 0x5B, .ext = true }, // KEY_LEFTMETA
    .{ .code = 126, .scan = 0x5C, .ext = true }, // KEY_RIGHTMETA
};

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

fn buildKeyMap() [256]KeyMapping {
    var m = [_]KeyMapping{.{ .vk = 0, .scan = 0, .extended = false }} ** 256;

    // A-Z (Android 29..54), set-1 scancodes in alphabetical order
    const letter_scans = [_]u16{
        0x1E, 0x30, 0x2E, 0x20, 0x12, 0x21, 0x22, 0x23, 0x17, 0x24, 0x25, 0x26, 0x32,
        0x31, 0x18, 0x19, 0x10, 0x13, 0x1F, 0x14, 0x16, 0x2F, 0x11, 0x2D, 0x15, 0x2C,
    };
    for (letter_scans, 0..) |scan, i| {
        m[29 + i] = .{ .vk = @intCast('A' + i), .scan = scan, .extended = false };
    }

    // 0-9 (Android 7..16)
    for (0..10) |d| {
        m[7 + d] = .{
            .vk = @intCast('0' + d),
            .scan = if (d == 0) 0x0B else @intCast(1 + d),
            .extended = false,
        };
    }

    // F1-F12 (Android 131..142)
    const f_scans = [_]u16{ 0x3B, 0x3C, 0x3D, 0x3E, 0x3F, 0x40, 0x41, 0x42, 0x43, 0x44, 0x57, 0x58 };
    for (f_scans, 0..) |scan, i| {
        m[131 + i] = .{ .vk = VK_F1 + @as(u16, @intCast(i)), .scan = scan, .extended = false };
    }

    // Numpad 0-9 (Android 144..153)
    const num_scans = [_]u16{ 0x52, 0x4F, 0x50, 0x51, 0x4B, 0x4C, 0x4D, 0x47, 0x48, 0x49 };
    for (num_scans, 0..) |scan, i| {
        m[144 + i] = .{ .vk = VK_NUMPAD0 + @as(u16, @intCast(i)), .scan = scan, .extended = false };
    }

    m[19] = .{ .vk = VK_UP, .scan = 0x48, .extended = true };
    m[20] = .{ .vk = VK_DOWN, .scan = 0x50, .extended = true };
    m[21] = .{ .vk = VK_LEFT, .scan = 0x4B, .extended = true };
    m[22] = .{ .vk = VK_RIGHT, .scan = 0x4D, .extended = true };
    m[55] = .{ .vk = VK_OEM_COMMA, .scan = 0x33, .extended = false };
    m[56] = .{ .vk = VK_OEM_PERIOD, .scan = 0x34, .extended = false };
    m[57] = .{ .vk = VK_LMENU, .scan = 0x38, .extended = false };
    m[58] = .{ .vk = VK_RMENU, .scan = 0x38, .extended = true };
    m[59] = .{ .vk = VK_LSHIFT, .scan = 0x2A, .extended = false };
    m[60] = .{ .vk = VK_RSHIFT, .scan = 0x36, .extended = false };
    m[61] = .{ .vk = VK_TAB, .scan = 0x0F, .extended = false };
    m[62] = .{ .vk = VK_SPACE, .scan = 0x39, .extended = false };
    m[66] = .{ .vk = VK_RETURN, .scan = 0x1C, .extended = false };
    m[67] = .{ .vk = VK_BACK, .scan = 0x0E, .extended = false };
    m[68] = .{ .vk = VK_OEM_3, .scan = 0x29, .extended = false };
    m[69] = .{ .vk = VK_OEM_MINUS, .scan = 0x0C, .extended = false };
    m[70] = .{ .vk = VK_OEM_PLUS, .scan = 0x0D, .extended = false };
    m[71] = .{ .vk = VK_OEM_4, .scan = 0x1A, .extended = false };
    m[72] = .{ .vk = VK_OEM_6, .scan = 0x1B, .extended = false };
    m[73] = .{ .vk = VK_OEM_5, .scan = 0x2B, .extended = false };
    m[74] = .{ .vk = VK_OEM_1, .scan = 0x27, .extended = false };
    m[75] = .{ .vk = VK_OEM_7, .scan = 0x28, .extended = false };
    m[76] = .{ .vk = VK_OEM_2, .scan = 0x35, .extended = false };
    m[92] = .{ .vk = VK_PRIOR, .scan = 0x49, .extended = true };
    m[93] = .{ .vk = VK_NEXT, .scan = 0x51, .extended = true };
    m[4] = .{ .vk = VK_ESCAPE, .scan = 0x01, .extended = false }; // BACK
    m[111] = .{ .vk = VK_ESCAPE, .scan = 0x01, .extended = false }; // ESCAPE
    m[112] = .{ .vk = VK_DELETE, .scan = 0x53, .extended = true };
    m[113] = .{ .vk = VK_LCONTROL, .scan = 0x1D, .extended = false };
    m[114] = .{ .vk = VK_RCONTROL, .scan = 0x1D, .extended = true };
    m[115] = .{ .vk = VK_CAPITAL, .scan = 0x3A, .extended = false };
    m[117] = .{ .vk = VK_LWIN, .scan = 0x5B, .extended = true };
    m[118] = .{ .vk = VK_RWIN, .scan = 0x5C, .extended = true };
    m[122] = .{ .vk = VK_HOME, .scan = 0x47, .extended = true };
    m[123] = .{ .vk = VK_END, .scan = 0x4F, .extended = true };
    m[124] = .{ .vk = VK_INSERT, .scan = 0x52, .extended = true };
    m[154] = .{ .vk = VK_DIVIDE, .scan = 0x35, .extended = true };
    m[155] = .{ .vk = VK_MULTIPLY, .scan = 0x37, .extended = false };
    m[156] = .{ .vk = VK_SUBTRACT, .scan = 0x4A, .extended = false };
    m[157] = .{ .vk = VK_ADD, .scan = 0x4E, .extended = false };
    m[158] = .{ .vk = VK_DECIMAL, .scan = 0x53, .extended = false };
    m[160] = .{ .vk = VK_RETURN, .scan = 0x1C, .extended = true };
    m[161] = .{ .vk = VK_OEM_PLUS, .scan = 0x59, .extended = false };
    return m;
}

fn isModifierKey(vk: u16) bool {
    return vk == VK_LSHIFT or vk == VK_RSHIFT or
        vk == VK_LMENU or vk == VK_RMENU or
        vk == VK_LCONTROL or vk == VK_RCONTROL or
        vk == VK_LWIN or vk == VK_RWIN;
}

// Pressed keys, keyed by Android keycode.
var down_keys = [_]?KeyMapping{null} ** 256;
// Synthetic modifiers pressed on behalf of a key (released with that key).
var synth_mods = [_][4]?KeyMapping{[_]?KeyMapping{null} ** 4} ** 256;
var synth_counts = [_]u8{0} ** 256;

pub var injected_touches: i64 = 0;
pub var injected_keys: i64 = 0;

const META_SHIFT_ON: u32 = 0x00000001;
const META_ALT_ON: u32 = 0x00000002;
const META_CTRL_ON: u32 = 0x00001000;
const META_META_ON: u32 = 0x00010000;

fn isAnyDownVk(vk: u16) bool {
    for (&down_keys) |*slot| {
        if (slot.*) |m| if (m.vk == vk) return true;
    }
    return false;
}

fn sendKey(m: KeyMapping, key_up: bool) void {
    var inp: w.Input = std.mem.zeroes(w.Input);
    inp.type = w.INPUT_KEYBOARD;
    inp.u.ki.w_vk = m.vk;
    inp.u.ki.w_scan = m.scan;
    var flags = w.KEYEVENTF_SCANCODE;
    if (m.extended) flags |= w.KEYEVENTF_EXTENDEDKEY;
    if (key_up) flags |= w.KEYEVENTF_KEYUP;
    inp.u.ki.dw_flags = flags;
    _ = w.SendInput(1, @ptrCast(&inp), @sizeOf(w.Input));
}

pub fn injectTouch(action: u8, x: f32, y: f32) void {
    injected_touches += 1;
    if (action != 1 and (injected_touches <= 5 or @mod(injected_touches, 50) == 0)) {
        w.logz("Touch event #{d}: action={d} pos={d:.3},{d:.3}\n", .{ injected_touches, action, x, y });
    }

    const sx = cap.origin_x + @as(i32, @intFromFloat(x * @as(f32, @floatFromInt(cap.cap_w))));
    const sy = cap.origin_y + @as(i32, @intFromFloat(y * @as(f32, @floatFromInt(cap.cap_h))));

    const vs_x = w.GetSystemMetrics(w.SM_XVIRTUALSCREEN);
    const vs_y = w.GetSystemMetrics(w.SM_YVIRTUALSCREEN);
    const vs_w = w.GetSystemMetrics(w.SM_CXVIRTUALSCREEN);
    const vs_h = w.GetSystemMetrics(w.SM_CYVIRTUALSCREEN);
    if (vs_w <= 0 or vs_h <= 0) return;

    const abs_x: i32 = @intFromFloat(@as(f64, @floatFromInt(sx - vs_x)) * 65535.0 / @as(f64, @floatFromInt(vs_w)));
    const abs_y: i32 = @intFromFloat(@as(f64, @floatFromInt(sy - vs_y)) * 65535.0 / @as(f64, @floatFromInt(vs_h)));

    var inp: w.Input = std.mem.zeroes(w.Input);
    inp.type = w.INPUT_MOUSE;
    inp.u.mi.dx = abs_x;
    inp.u.mi.dy = abs_y;
    inp.u.mi.dw_flags = w.MOUSEEVENTF_ABSOLUTE | w.MOUSEEVENTF_VIRTUALDESK | w.MOUSEEVENTF_MOVE;
    if (action == 0) {
        inp.u.mi.dw_flags |= w.MOUSEEVENTF_LEFTDOWN;
    } else if (action == 2) {
        inp.u.mi.dw_flags |= w.MOUSEEVENTF_LEFTUP;
    }
    _ = w.SendInput(1, @ptrCast(&inp), @sizeOf(w.Input));
}

fn tryResolve(key_code: u16, client_scan: u16) ?KeyMapping {
    if (key_code < 256) {
        const m = key_map[key_code];
        if (m.vk != 0 or m.scan != 0) return m;
    }
    // Fallback: hardware scancode reported by the client (evdev).
    if (client_scan == 0) return null;
    if (client_scan <= 0x58) return .{ .vk = 0, .scan = client_scan, .extended = false };
    for (evdev_extended) |e| {
        if (e.code == client_scan) return .{ .vk = 0, .scan = e.scan, .extended = e.ext };
    }
    return null;
}

pub fn injectKey(action: u8, key_code: u16, meta_state: u32, client_scan: u16) void {
    const code: usize = if (key_code < 256) key_code else 0;

    if (action == 1) {
        // Key up: release the key exactly as it went down, plus synthetic mods.
        const down = down_keys[code] orelse return;
        down_keys[code] = null;
        sendKey(down, true);
        var i: usize = synth_counts[code];
        while (i > 0) {
            i -= 1;
            if (synth_mods[code][i]) |m| sendKey(m, true);
            synth_mods[code][i] = null;
        }
        synth_counts[code] = 0;
        injected_keys += 1;
        return;
    }

    const m = tryResolve(key_code, client_scan) orelse {
        w.logz("[input] key UNMAPPED android={d} scan={d}\n", .{ key_code, client_scan });
        return;
    };
    injected_keys += 1;
    if (injected_keys <= 5 or @mod(injected_keys, 20) == 0) {
        w.logz("[input] key down android={d} vk=0x{X:0>2} scan=0x{X:0>2}{s}\n", .{ key_code, m.vk, m.scan, if (m.extended) " ext" else "" });
    }

    const already_down = down_keys[code] != null;
    var n_mods: usize = 0;
    if (!already_down and !isModifierKey(m.vk)) {
        // Press missing meta modifiers; they stay held until this key's key-up.
        const want_shift = (meta_state & META_SHIFT_ON) != 0 and !isAnyDownVk(VK_LSHIFT) and !isAnyDownVk(VK_RSHIFT);
        const want_alt = (meta_state & META_ALT_ON) != 0 and !isAnyDownVk(VK_LMENU) and !isAnyDownVk(VK_RMENU);
        const want_ctrl = (meta_state & META_CTRL_ON) != 0 and !isAnyDownVk(VK_LCONTROL) and !isAnyDownVk(VK_RCONTROL);
        const want_meta = (meta_state & META_META_ON) != 0 and !isAnyDownVk(VK_LWIN) and !isAnyDownVk(VK_RWIN);
        if (want_shift) {
            synth_mods[code][n_mods] = .{ .vk = VK_LSHIFT, .scan = 0x2A, .extended = false };
            sendKey(synth_mods[code][n_mods].?, false);
            n_mods += 1;
        }
        if (want_alt) {
            synth_mods[code][n_mods] = .{ .vk = VK_LMENU, .scan = 0x38, .extended = false };
            sendKey(synth_mods[code][n_mods].?, false);
            n_mods += 1;
        }
        if (want_ctrl) {
            synth_mods[code][n_mods] = .{ .vk = VK_LCONTROL, .scan = 0x1D, .extended = false };
            sendKey(synth_mods[code][n_mods].?, false);
            n_mods += 1;
        }
        if (want_meta) {
            synth_mods[code][n_mods] = .{ .vk = VK_LWIN, .scan = 0x5B, .extended = true };
            sendKey(synth_mods[code][n_mods].?, false);
            n_mods += 1;
        }
    }
    synth_counts[code] = @intCast(n_mods);
    sendKey(m, false);
    down_keys[code] = m;
}

/// Release every pressed key (call on client disconnect).
pub fn releaseAllKeys() void {
    for (&down_keys, 0..) |*slot, code| {
        if (slot.*) |m| {
            sendKey(m, true);
            slot.* = null;
        }
        synth_counts[code] = 0;
        for (&synth_mods[code]) |*s| s.* = null;
    }
}

pub fn injectScroll(dx: f32, dy: f32) void {
    if (dy == 0) return;
    var inp: w.Input = std.mem.zeroes(w.Input);
    inp.type = w.INPUT_MOUSE;
    inp.u.mi.mouse_data = @intFromFloat(dy * 120.0); // WHEEL_DELTA units
    inp.u.mi.dw_flags = w.MOUSEEVENTF_WHEEL;
    _ = w.SendInput(1, @ptrCast(&inp), @sizeOf(w.Input));
    _ = dx;
}

// ------------------------------------------------------------------ cursor

var hdc_mem: ?*anyopaque = null;
var hbm_dib: ?*anyopaque = null;
var p_dib_bits: ?[*]u32 = null;

fn initCursorRenderer() void {
    if (hdc_mem != null) return;
    var bmi: w.BitmapInfo = std.mem.zeroes(w.BitmapInfo);
    bmi.bmi_header.bi_size = @sizeOf(w.BitmapInfoHeader);
    bmi.bmi_header.bi_width = 32;
    bmi.bmi_header.bi_height = -32;
    bmi.bmi_header.bi_planes = 1;
    bmi.bmi_header.bi_bit_count = 32;
    bmi.bmi_header.bi_compression = w.BI_RGB;

    const hdc_screen = w.GetDC(null);
    hdc_mem = w.CreateCompatibleDC(hdc_screen);
    hbm_dib = w.CreateDIBSection(hdc_mem, &bmi, w.DIB_RGB_COLORS, @ptrCast(&p_dib_bits), null, 0);
    _ = w.SelectObject(hdc_mem, hbm_dib);
    _ = w.ReleaseDC(null, hdc_screen);
}

var last_hcur: ?*anyopaque = null;
var last_x: i32 = -9999;
var last_y: i32 = -9999;
var last_vis: u8 = 255;
var client_has_shape = false;

pub fn sendCursorPacket(sock: w.Socket, alive: *bool) void {
    if (!alive.*) return;

    var ci: w.CursorInfo = std.mem.zeroes(w.CursorInfo);
    ci.cb_size = @sizeOf(w.CursorInfo);

    var rel_x: i32 = 0;
    var rel_y: i32 = 0;
    var visible: u8 = 0;

    var pt: w.Point = std.mem.zeroes(w.Point);
    if (w.GetCursorPos(&pt) != 0) {
        rel_x = pt.x - cap.origin_x;
        rel_y = pt.y - cap.origin_y;
        if (rel_x >= 0 and rel_x < cap.cap_w and rel_y >= 0 and rel_y < cap.cap_h) visible = 1;
    }
    if (w.GetCursorInfo(&ci) != 0) {
        if (ci.flags & w.CURSOR_SHOWING != 0) {
            rel_x = ci.pt_screen_pos.x - cap.origin_x;
            rel_y = ci.pt_screen_pos.y - cap.origin_y;
            if (rel_x >= 0 and rel_x < cap.cap_w and rel_y >= 0 and rel_y < cap.cap_h) visible = 1;
        }
        if (ci.h_cursor != last_hcur and ci.h_cursor != null) {
            last_hcur = ci.h_cursor;
            client_has_shape = false;
        }
    }

    const need_shape = (!client_has_shape and visible != 0);
    if (!need_shape and rel_x == last_x and rel_y == last_y and visible == last_vis) return;

    last_x = rel_x;
    last_y = rel_y;
    last_vis = visible;

    var bgra_len: usize = 0;
    if (need_shape) {
        initCursorRenderer();
        var h_to_draw = last_hcur;
        if (h_to_draw == null) h_to_draw = w.LoadCursorA(null, @ptrFromInt(32512)); // IDC_ARROW

        var buf_black: [32 * 32]u32 = undefined;
        var buf_white: [32 * 32]u32 = undefined;
        const bits = p_dib_bits orelse return;

        // Pass 1: render onto pure black, pass 2: onto pure white, combine for true ARGB.
        @memset(bits[0 .. 32 * 32], 0);
        _ = w.DrawIconEx(hdc_mem, 0, 0, h_to_draw, 32, 32, 0, null, w.DI_NORMAL);
        @memcpy(&buf_black, bits[0 .. 32 * 32]);

        @memset(bits[0 .. 32 * 32], 0x00FFFFFF);
        _ = w.DrawIconEx(hdc_mem, 0, 0, h_to_draw, 32, 32, 0, null, w.DI_NORMAL);
        @memcpy(&buf_white, bits[0 .. 32 * 32]);

        var pxi: usize = 0;
        while (pxi < 32 * 32) : (pxi += 1) {
            const b = buf_black[pxi] & 0x00FFFFFF;
            const qw = buf_white[pxi] & 0x00FFFFFF;
            if (b == qw) {
                bits[pxi] = 0xFF000000 | b;
            } else if (b == 0 and qw == 0x00FFFFFF) {
                bits[pxi] = 0;
            } else {
                bits[pxi] = 0xFF000000 | b;
            }
        }
        bgra_len = 32 * 32 * 4;
        client_has_shape = true;
    }

    var hdr: [22]u8 = undefined;
    hdr[0] = PKT_CURSOR;
    writeU32(hdr[1..5], @intCast(17 + bgra_len));
    hdr[5] = visible;
    writeU32(hdr[6..10], @bitCast(rel_x));
    writeU32(hdr[10..14], @bitCast(rel_y));
    writeU32(hdr[14..18], 32);
    writeU32(hdr[18..22], 32);

    if (w.sockWrite(sock, &hdr) <= 0) {
        alive.* = false;
        return;
    }
    if (bgra_len > 0) {
        const bits = p_dib_bits.?;
        const bytes: [*]const u8 = @ptrCast(bits);
        if (w.sockWrite(sock, bytes[0..bgra_len]) <= 0) {
            alive.* = false;
            return;
        }
    }
}

pub fn writeU32(dst: []u8, v: u32) void {
    dst[0] = @truncate(v);
    dst[1] = @truncate(v >> 8);
    dst[2] = @truncate(v >> 16);
    dst[3] = @truncate(v >> 24);
}

pub fn readU32(src: []const u8) u32 {
    return @as(u32, src[0]) |
        (@as(u32, src[1]) << 8) |
        (@as(u32, src[2]) << 16) |
        (@as(u32, src[3]) << 24);
}

pub fn readU16(src: []const u8) u16 {
    return @as(u16, src[0]) | (@as(u16, src[1]) << 8);
}

pub fn readF32(src: []const u8) f32 {
    return @bitCast(readU32(src));
}
