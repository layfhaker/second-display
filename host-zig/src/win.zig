const std = @import("std");

pub const BOOL = i32;
pub const DWORD = u32;
pub const HRESULT = i32;
pub const ULONG = u32;
pub const UINT = u32;
pub const LONG = i32;

pub const Guid = extern struct {
    data1: u32,
    data2: u16,
    data3: u16,
    data4: [8]u8,
};

pub fn guidEql(a: *const Guid, b: *const Guid) bool {
    return std.mem.eql(u8, std.mem.asBytes(a), std.mem.asBytes(b));
}

pub fn hrOk(hr: HRESULT) bool {
    return hr >= 0;
}

pub fn hrIs(hr: HRESULT, code: u32) bool {
    return @as(u32, @bitCast(hr)) == code;
}

// ---------------------------------------------------------------- kernel32

pub extern "kernel32" fn Sleep(ms: DWORD) void;
pub extern "kernel32" fn GetModuleFileNameA(h: ?*anyopaque, buf: [*]u8, size: DWORD) DWORD;
pub extern "kernel32" fn GetFileAttributesA(path: [*:0]const u8) DWORD;
pub extern "kernel32" fn CreateProcessA(
    app: ?[*:0]const u8,
    cmd: [*:0]u8,
    proc_attr: ?*anyopaque,
    thread_attr: ?*anyopaque,
    inherit: BOOL,
    flags: DWORD,
    env: ?*anyopaque,
    cwd: ?[*:0]const u8,
    si: *StartupInfo,
    pi: *ProcessInfo,
) BOOL;
pub extern "kernel32" fn CloseHandle(h: ?*anyopaque) BOOL;
pub extern "kernel32" fn WaitForSingleObject(h: ?*anyopaque, ms: DWORD) DWORD;
pub extern "kernel32" fn CreateMutexA(attr: ?*anyopaque, owner: BOOL, name: [*:0]const u8) ?*anyopaque;
pub extern "kernel32" fn GetLastError() DWORD;
pub extern "kernel32" fn LoadLibraryA(name: [*:0]const u8) ?*anyopaque;
pub extern "kernel32" fn GetProcAddress(mod: ?*anyopaque, name: [*:0]const u8) ?*anyopaque;
pub extern "kernel32" fn QueryPerformanceCounter(v: *i64) BOOL;
pub extern "kernel32" fn QueryPerformanceFrequency(v: *i64) BOOL;
pub extern "kernel32" fn CreatePipe(read: *?*anyopaque, write: *?*anyopaque, sa: *SecurityAttr, size: DWORD) BOOL;
pub extern "kernel32" fn SetHandleInformation(h: ?*anyopaque, mask: DWORD, flags: DWORD) BOOL;
pub extern "kernel32" fn ReadFile(h: ?*anyopaque, buf: ?*anyopaque, len: DWORD, read: *DWORD, overlapped: ?*anyopaque) BOOL;
pub extern "kernel32" fn GetStdHandle(which: DWORD) ?*anyopaque;
pub extern "kernel32" fn WriteFile(h: ?*anyopaque, buf: ?*const anyopaque, len: DWORD, written: *DWORD, overlapped: ?*anyopaque) BOOL;
pub extern "kernel32" fn SetConsoleCtrlHandler(handler: ?*const fn (DWORD) callconv(.C) BOOL, add: BOOL) BOOL;

pub const ERROR_ALREADY_EXISTS: DWORD = 183;

pub const StartupInfo = extern struct {
    cb: DWORD,
    lp_reserved: ?[*:0]u8,
    lp_desktop: ?[*:0]u8,
    lp_title: ?[*:0]u8,
    dw_x: DWORD,
    dw_y: DWORD,
    dw_x_size: DWORD,
    dw_y_size: DWORD,
    dw_x_count_chars: DWORD,
    dw_y_count_chars: DWORD,
    dw_fill_attribute: DWORD,
    dw_flags: DWORD,
    w_show_window: u16,
    cb_reserved2: u16,
    lp_reserved2: ?[*]u8,
    h_std_input: ?*anyopaque,
    h_std_output: ?*anyopaque,
    h_std_error: ?*anyopaque,
};

pub const ProcessInfo = extern struct {
    h_process: ?*anyopaque,
    h_thread: ?*anyopaque,
    process_id: DWORD,
    thread_id: DWORD,
};

pub const SecurityAttr = extern struct {
    n_length: DWORD,
    lp_security_descriptor: ?*anyopaque,
    b_inherit_handle: BOOL,
};

pub const STARTF_USESHOWWINDOW: DWORD = 0x00000001;
pub const STARTF_USESTDHANDLES: DWORD = 0x00000100;
pub const CREATE_NO_WINDOW: DWORD = 0x08000000;
pub const SW_HIDE: u16 = 0;
pub const HANDLE_FLAG_INHERIT: DWORD = 0x00000001;

// ------------------------------------------------------------------ ole32

pub extern "ole32" fn CoInitializeEx(reserved: ?*anyopaque, flags: DWORD) HRESULT;
pub extern "ole32" fn CoUninitialize() void;
pub extern "ole32" fn CoTaskMemFree(p: ?*anyopaque) void;

pub const COINIT_MULTITHREADED: DWORD = 0x0;

// ------------------------------------------------------------------ user32

pub const Point = extern struct { x: LONG, y: LONG };

pub const MouseInput = extern struct {
    dx: LONG,
    dy: LONG,
    mouse_data: LONG,
    dw_flags: DWORD,
    time: DWORD,
    dw_extra_info: usize,
};

pub const KeybdInput = extern struct {
    w_vk: u16,
    w_scan: u16,
    dw_flags: DWORD,
    time: DWORD,
    dw_extra_info: usize,
};

pub const InputUnion = extern union {
    mi: MouseInput,
    ki: KeybdInput,
};

pub const Input = extern struct {
    type: DWORD,
    u: InputUnion,
};

pub const CursorInfo = extern struct {
    cb_size: DWORD,
    flags: DWORD,
    h_cursor: ?*anyopaque,
    pt_screen_pos: Point,
};

pub const DisplayDeviceA = extern struct {
    cb: DWORD,
    device_name: [32]u8,
    device_string: [128]u8,
    state_flags: DWORD,
    device_id: [128]u8,
    device_key: [128]u8,
};

pub extern "user32" fn SendInput(n: UINT, inputs: [*]const Input, cb: i32) UINT;
pub extern "user32" fn GetSystemMetrics(idx: i32) i32;
pub extern "user32" fn GetCursorPos(pt: *Point) BOOL;
pub extern "user32" fn GetCursorInfo(ci: *CursorInfo) BOOL;
pub extern "user32" fn LoadCursorA(inst: ?*anyopaque, name: [*:0]const u8) ?*anyopaque;
pub extern "user32" fn DrawIconEx(hdc: ?*anyopaque, x: i32, y: i32, hicon: ?*anyopaque, w: i32, h: i32, step: u32, brush: ?*anyopaque, flags: u32) BOOL;
pub extern "user32" fn GetDC(hwnd: ?*anyopaque) ?*anyopaque;
pub extern "user32" fn ReleaseDC(hwnd: ?*anyopaque, hdc: ?*anyopaque) i32;
pub extern "user32" fn OpenDesktopA(name: [*:0]const u8, flags: DWORD, inherit: BOOL, access: DWORD) ?*anyopaque;
pub extern "user32" fn SetThreadDesktop(hdesk: ?*anyopaque) BOOL;
pub extern "user32" fn EnumDisplayDevicesA(dev: ?[*:0]const u8, idx: DWORD, dd: *DisplayDeviceA, flags: DWORD) BOOL;
pub extern "user32" fn ChangeDisplaySettingsExA(dev: ?[*:0]const u8, mode: ?*anyopaque, hwnd: ?*anyopaque, flags: DWORD, param: ?*anyopaque) i32;
pub extern "user32" fn MapVirtualKeyW(code: u32, map_type: u32) u32;
pub extern "user32" fn SetDisplayConfig(count: u32, paths: ?*anyopaque, modes: u32, mode_info: ?*anyopaque, flags: u64) HRESULT;

pub const INPUT_MOUSE: DWORD = 0;
pub const INPUT_KEYBOARD: DWORD = 1;
pub const MOUSEEVENTF_MOVE: DWORD = 0x0001;
pub const MOUSEEVENTF_LEFTDOWN: DWORD = 0x0002;
pub const MOUSEEVENTF_LEFTUP: DWORD = 0x0004;
pub const MOUSEEVENTF_WHEEL: DWORD = 0x0800;
pub const MOUSEEVENTF_VIRTUALDESK: DWORD = 0x4000;
pub const MOUSEEVENTF_ABSOLUTE: DWORD = 0x8000;
pub const KEYEVENTF_EXTENDEDKEY: DWORD = 0x0001;
pub const KEYEVENTF_KEYUP: DWORD = 0x0002;
pub const KEYEVENTF_SCANCODE: DWORD = 0x0008;

pub const CURSOR_SHOWING: DWORD = 0x00000001;
pub const DI_NORMAL: u32 = 0x0003;
pub const DESKTOP_READOBJECTS: DWORD = 0x0001;
pub const DESKTOP_WRITEOBJECTS: DWORD = 0x0080;
pub const DESKTOP_SWITCHDESKTOP: DWORD = 0x0100;

pub const SM_XVIRTUALSCREEN: i32 = 76;
pub const SM_YVIRTUALSCREEN: i32 = 77;
pub const SM_CXVIRTUALSCREEN: i32 = 78;
pub const SM_CYVIRTUALSCREEN: i32 = 79;

// ------------------------------------------------------------------- gdi32

pub const BitmapInfoHeader = extern struct {
    bi_size: DWORD,
    bi_width: LONG,
    bi_height: LONG,
    bi_planes: u16,
    bi_bit_count: u16,
    bi_compression: DWORD,
    bi_size_image: DWORD,
    bi_x_pels_per_meter: LONG,
    bi_y_pels_per_meter: LONG,
    bi_clr_used: DWORD,
    bi_clr_important: DWORD,
};

pub const BitmapInfo = extern struct {
    bmi_header: BitmapInfoHeader,
    bmi_colors: [1]u32,
};

pub extern "gdi32" fn CreateCompatibleDC(hdc: ?*anyopaque) ?*anyopaque;
pub extern "gdi32" fn CreateDIBSection(hdc: ?*anyopaque, bmi: *const BitmapInfo, usage: u32, bits: *?*anyopaque, section: ?*anyopaque, offset: DWORD) ?*anyopaque;
pub extern "gdi32" fn SelectObject(hdc: ?*anyopaque, obj: ?*anyopaque) ?*anyopaque;

pub const BI_RGB: DWORD = 0;
pub const DIB_RGB_COLORS: u32 = 0;

// ------------------------------------------------------------------ ws2_32

pub const Socket = isize;
pub const INVALID_SOCKET: Socket = ~@as(Socket, 0);

pub const WsaData = extern struct {
    bytes: [408]u8 align(8),
};

pub const SockAddrIn = extern struct {
    sin_family: u16,
    sin_port: u16,
    sin_addr: u32,
    sin_zero: [8]u8,
};

pub const FdSet = extern struct {
    fd_count: u32,
    fd_array: [64]Socket,
};

pub const TimeVal = extern struct {
    tv_sec: i32,
    tv_usec: i32,
};

pub extern "ws2_32" fn WSAStartup(ver: u16, data: *WsaData) i32;
pub extern "ws2_32" fn WSACleanup() i32;
pub extern "ws2_32" fn WSAGetLastError() i32;
pub extern "ws2_32" fn socket(af: i32, type: i32, proto: i32) Socket;
pub extern "ws2_32" fn bind(s: Socket, addr: *const SockAddrIn, len: i32) i32;
pub extern "ws2_32" fn listen(s: Socket, backlog: i32) i32;
pub extern "ws2_32" fn accept(s: Socket, addr: ?*SockAddrIn, len: ?*i32) Socket;
pub extern "ws2_32" fn recv(s: Socket, buf: [*]u8, len: i32, flags: i32) i32;
pub extern "ws2_32" fn send(s: Socket, buf: [*]const u8, len: i32, flags: i32) i32;
pub extern "ws2_32" fn closesocket(s: Socket) i32;
pub extern "ws2_32" fn setsockopt(s: Socket, level: i32, opt: i32, val: [*]const u8, len: i32) i32;
pub extern "ws2_32" fn connect(s: Socket, addr: *const SockAddrIn, len: i32) i32;
pub extern "ws2_32" fn select(nfds: i32, read: ?*FdSet, write: ?*FdSet, except: ?*FdSet, timeout: ?*TimeVal) i32;
pub extern "ws2_32" fn ioctlsocket(s: Socket, cmd: u32, argp: *u32) i32;

pub const AF_INET: i32 = 2;
pub const SOCK_STREAM: i32 = 1;
pub const IPPROTO_TCP: i32 = 6;
pub const SOL_SOCKET: i32 = 0xFFFF;
pub const SO_REUSEADDR: i32 = 2;
pub const SO_SNDBUF: i32 = 0x1001;
pub const SO_RCVTIMEO: i32 = 0x1006;
pub const SO_SNDTIMEO: i32 = 0x1005;
pub const TCP_NODELAY: i32 = 1;
pub const FIONBIO: u32 = 0x8004667E;
pub const WSAEWOULDBLOCK: i32 = 10035;
pub const WSAEINPROGRESS: i32 = 10036;

pub fn htons(v: u16) u16 {
    return std.mem.nativeToBig(u16, v);
}

pub fn htonl(v: u32) u32 {
    return std.mem.nativeToBig(u32, v);
}

/// Read exactly n bytes; false on disconnect/error.
pub fn sockReadAll(s: Socket, buf: []u8) bool {
    var got: usize = 0;
    while (got < buf.len) {
        const r = recv(s, buf.ptr + got, @intCast(buf.len - got), 0);
        if (r <= 0) return false;
        got += @intCast(r);
    }
    return true;
}

/// Write exactly n bytes; bytes sent (<=0 on error).
pub fn sockWrite(s: Socket, buf: []const u8) i64 {
    var sent: usize = 0;
    while (sent < buf.len) {
        const r = send(s, buf.ptr + sent, @intCast(buf.len - sent), 0);
        if (r <= 0) return r;
        sent += @intCast(r);
    }
    return @intCast(sent);
}

pub fn sockClose(s: Socket) void {
    if (s != 0 and s != INVALID_SOCKET) _ = closesocket(s);
}

// --------------------------------------------------------------- utilities

var log_buf: [4096]u8 = undefined;

pub fn logz(comptime fmt: []const u8, args: anytype) void {
    const msg = std.fmt.bufPrint(&log_buf, fmt, args) catch return;
    const h = GetStdHandle(0xFFFFFFF5); // STD_OUTPUT_HANDLE
    var written: DWORD = 0;
    _ = WriteFile(h, msg.ptr, @intCast(msg.len), &written, null);
}

/// Fire-and-forget hidden process: no console window flash.
pub fn runHidden(cmd: []const u8) void {
    var buf: [1024]u8 = undefined;
    if (cmd.len >= buf.len) return;
    @memcpy(buf[0..cmd.len], cmd);
    buf[cmd.len] = 0;
    var si: StartupInfo = std.mem.zeroes(StartupInfo);
    si.cb = @sizeOf(StartupInfo);
    si.dw_flags = STARTF_USESHOWWINDOW;
    si.w_show_window = SW_HIDE;
    var pi: ProcessInfo = undefined;
    if (CreateProcessA(null, buf[0.. :0], null, null, 0, CREATE_NO_WINDOW, null, null, &si, &pi) != 0) {
        _ = CloseHandle(pi.h_process);
        _ = CloseHandle(pi.h_thread);
    }
}

var qpc_freq: i64 = 0;

pub fn qpcInit() void {
    _ = QueryPerformanceFrequency(&qpc_freq);
    if (qpc_freq == 0) qpc_freq = 1;
}

pub fn qpcNow() i64 {
    var v: i64 = 0;
    _ = QueryPerformanceCounter(&v);
    return v;
}

pub fn qpcFreq() i64 {
    return qpc_freq;
}

/// COM vtable base: the object's first field stores the pointer to its vtable.
pub fn vtbl(obj: ?*anyopaque) [*]?*const anyopaque {
    const holder: *const [*]?*const anyopaque = @ptrCast(@alignCast(obj.?));
    return holder.*;
}

pub fn vfn(comptime F: type, obj: ?*anyopaque, comptime slot: usize) F {
    const p = vtbl(obj)[slot] orelse unreachable;
    return @ptrCast(p);
}

// Dynamically resolve an exported function from a system DLL (avoids
// depending on import libraries for mfplat/dxgi/d3d11).
pub fn loadSym(comptime F: type, dll: [*:0]const u8, name: [*:0]const u8) ?F {
    const mod = LoadLibraryA(dll);
    if (mod == null) return null;
    const p = GetProcAddress(mod.?, name) orelse return null;
    return @ptrCast(p);
}
