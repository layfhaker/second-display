const std = @import("std");
const w = @import("win.zig");

pub const ADB_PORT: u16 = 5037;

var adb_path_buf: [512]u8 = undefined;
var adb_path: []const u8 = "adb.exe";
var adb_path_ready = false;

/// Resolve the adb shipped next to the host (<app>\platform-tools\adb.exe).
pub fn adbPathInit() void {
    if (adb_path_ready) return;
    var exe: [520]u8 = undefined;
    const n = w.GetModuleFileNameA(null, &exe, exe.len);
    if (n > 0 and n < exe.len) {
        if (std.mem.lastIndexOfScalar(u8, exe[0..n], '\\')) |slash| {
            const dir = exe[0 .. slash + 1];
            const rel = "platform-tools\\adb.exe";
            if (dir.len + rel.len < adb_path_buf.len) {
                @memcpy(adb_path_buf[0..dir.len], dir);
                @memcpy(adb_path_buf[dir.len .. dir.len + rel.len], rel);
                adb_path = adb_path_buf[0 .. dir.len + rel.len];
                adb_path_ready = true;
                var z: [513]u8 = undefined;
                if (adb_path.len < z.len) {
                    @memcpy(z[0..adb_path.len], adb_path);
                    z[adb_path.len] = 0;
                    if (w.GetFileAttributesA(z[0.. :0]) != 0xFFFFFFFF) {
                        w.logz("Using bundled adb: {s}\n", .{adb_path});
                        return;
                    }
                }
            }
        }
    }
    adb_path = "adb.exe";
    adb_path_ready = true;
    w.logz("Using PATH adb: {s}\n", .{adb_path});
}

fn hexNibble(v: u32, shift: u5) u8 {
    const d = @as(u8, @truncate(v >> shift)) & 0x0F;
    return if (d < 10) '0' + d else 'a' + (d - 10);
}

/// Connect to the local adb server with a timeout (non-blocking connect + select).
pub fn linkConnect(timeout_ms: i32) w.Socket {
    const s = w.socket(w.AF_INET, w.SOCK_STREAM, w.IPPROTO_TCP);
    if (s == w.INVALID_SOCKET) return -1;

    var to: u32 = @intCast(timeout_ms);
    _ = w.setsockopt(s, w.SOL_SOCKET, w.SO_RCVTIMEO, std.mem.asBytes(&to), 4);
    _ = w.setsockopt(s, w.SOL_SOCKET, w.SO_SNDTIMEO, std.mem.asBytes(&to), 4);

    var addr: w.SockAddrIn = std.mem.zeroes(w.SockAddrIn);
    addr.sin_family = w.AF_INET;
    addr.sin_addr = w.htonl(0x7F000001);
    addr.sin_port = w.htons(ADB_PORT);

    var nb: u32 = 1;
    _ = w.ioctlsocket(s, w.FIONBIO, &nb);
    const cr = w.connect(s, &addr, @sizeOf(w.SockAddrIn));
    if (cr != 0) {
        const e = w.WSAGetLastError();
        if (e != w.WSAEWOULDBLOCK and e != w.WSAEINPROGRESS) {
            w.sockClose(s);
            return -1;
        }
        var wf: w.FdSet = std.mem.zeroes(w.FdSet);
        wf.fd_count = 1;
        wf.fd_array[0] = s;
        var tv: w.TimeVal = .{ .tv_sec = @divTrunc(timeout_ms, 1000), .tv_usec = @intCast(@rem(timeout_ms, 1000) * 1000) };
        const r = w.select(0, null, &wf, null, &tv);
        if (r <= 0) {
            w.sockClose(s);
            return -1;
        }
    }
    nb = 0;
    _ = w.ioctlsocket(s, w.FIONBIO, &nb);
    return s;
}

/// Send one adb-framed service string (4 hex digits + payload).
pub fn linkSendService(s: w.Socket, service: []const u8) bool {
    if (service.len == 0 or service.len > 512) return false;
    var frame: [516]u8 = undefined;
    const n: u32 = @intCast(service.len);
    frame[0] = hexNibble(n, 12);
    frame[1] = hexNibble(n, 8);
    frame[2] = hexNibble(n, 4);
    frame[3] = hexNibble(n, 0);
    @memcpy(frame[4 .. 4 + n], service);
    return w.sockWrite(s, frame[0 .. 4 + n]) == @as(i64, 4 + n);
}

fn recvExact(s: w.Socket, buf: []u8) bool {
    return w.sockReadAll(s, buf);
}

/// Receive "OKAY" + 4 hex digits + payload. Returns payload length or -1.
pub fn linkRecvOkPayload(s: w.Socket, out: []u8) i64 {
    var st: [4]u8 = undefined;
    if (!recvExact(s, &st)) return -1;
    if (!std.mem.eql(u8, &st, "OKAY")) return -1;
    var lb: [4]u8 = undefined;
    if (!recvExact(s, &lb)) return -1;
    const len = std.fmt.parseInt(usize, &lb, 16) catch return -1;
    const take = @min(len, out.len);
    if (take > 0 and !recvExact(s, out[0..take])) return -1;
    // drain anything beyond our buffer so the connection stays sane
    var drain: [256]u8 = undefined;
    var rest = len - take;
    while (rest > 0) {
        const chunk = @min(rest, drain.len);
        if (!recvExact(s, drain[0..chunk])) break;
        rest -= chunk;
    }
    return @intCast(take);
}

/// Single-shot host service (host:devices, ...). Returns payload length or -1.
pub fn devicesQuery(out: []u8, timeout_ms: i32) i64 {
    const s = linkConnect(timeout_ms);
    if (s < 0) return -1;
    defer w.sockClose(s);
    if (!linkSendService(s, "host:devices")) return -1;
    return linkRecvOkPayload(s, out);
}

/// Two-step device service: host:transport:<serial>, then a local service.
/// Returns streamed byte count or -1.
pub fn transportExec(serial: []const u8, local: []const u8, out: []u8, timeout_ms: i32) i64 {
    const s = linkConnect(timeout_ms);
    if (s < 0) return -1;
    defer w.sockClose(s);

    var svc: [300]u8 = undefined;
    const head = "host:transport:";
    if (head.len + serial.len > svc.len) return -1;
    @memcpy(svc[0..head.len], head);
    @memcpy(svc[head.len .. head.len + serial.len], serial);

    if (!linkSendService(s, svc[0 .. head.len + serial.len])) return -1;
    var st: [4]u8 = undefined;
    if (!recvExact(s, &st) or !std.mem.eql(u8, &st, "OKAY")) return -1;

    if (!linkSendService(s, local)) return -1;
    if (!recvExact(s, &st) or !std.mem.eql(u8, &st, "OKAY")) return -1;

    var total: usize = 0;
    while (total < out.len) {
        const r = w.recv(s, out.ptr + total, @intCast(out.len - total), 0);
        if (r <= 0) break;
        total += @intCast(r);
    }
    return @intCast(total);
}

/// Parse one host:devices payload for the first serial in "device" state.
pub fn firstDevice(out: []u8, timeout_ms: i32) bool {
    var buf: [1024]u8 = undefined;
    const len_i = devicesQuery(buf[0 .. buf.len - 1], timeout_ms);
    if (len_i <= 0) return false;
    const len: usize = @intCast(len_i);
    buf[len] = 0;

    var it = std.mem.splitScalar(u8, buf[0..len], '\n');
    while (it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, "\r ");
        if (line.len == 0) continue;
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
        const serial = line[0..tab];
        const state = std.mem.trim(u8, line[tab + 1 ..], " \t\r");
        if (serial.len > 0 and std.mem.eql(u8, state, "device")) {
            const n = @min(serial.len, out.len - 1);
            @memcpy(out[0..n], serial[0..n]);
            out[n] = 0;
            return true;
        }
    }
    return false;
}

/// True when adb reports a connected, authorized tablet.
pub fn tabletPresent() bool {
    var serial: [64]u8 = undefined;
    if (firstDevice(&serial, 1500)) return true;
    return adbSpawnDetect();
}

/// Fallback: spawn `adb devices` hidden and scan its output for a device row.
fn adbSpawnDetect() bool {
    adbPathInit();
    var cmd: [600]u8 = undefined;
    const q = "\"";
    const n = q.len + adb_path.len + " devices".len;
    if (n + 2 >= cmd.len) return false;
    @memcpy(cmd[0..q.len], q);
    @memcpy(cmd[q.len .. q.len + adb_path.len], adb_path);
    @memcpy(cmd[q.len + adb_path.len .. n], " devices");
    cmd[n] = '"';
    cmd[n + 1] = 0;

    var sa: w.SecurityAttr = .{
        .n_length = @sizeOf(w.SecurityAttr),
        .lp_security_descriptor = null,
        .b_inherit_handle = 1,
    };
    var h_read: ?*anyopaque = null;
    var h_write: ?*anyopaque = null;
    if (w.CreatePipe(&h_read, &h_write, &sa, 0) == 0) return false;
    _ = w.SetHandleInformation(h_read.?, w.HANDLE_FLAG_INHERIT, 0);

    var si: w.StartupInfo = std.mem.zeroes(w.StartupInfo);
    si.cb = @sizeOf(w.StartupInfo);
    si.h_std_output = h_write;
    si.h_std_error = h_write;
    si.dw_flags = w.STARTF_USESTDHANDLES | w.STARTF_USESHOWWINDOW;
    si.w_show_window = w.SW_HIDE;
    var pi: w.ProcessInfo = undefined;

    var found = false;
    if (w.CreateProcessA(null, cmd[0 .. n + 1 :0], null, null, 1, w.CREATE_NO_WINDOW, null, null, &si, &pi) != 0) {
        _ = w.CloseHandle(h_write);
        h_write = null;
        var out: [4096]u8 = undefined;
        var total: u32 = 0;
        var br: u32 = 0;
        while (total < out.len - 1) {
            if (w.ReadFile(h_read.?, out[0..].ptr + total, @intCast(out.len - 1 - total), &br, null) == 0 or br == 0) break;
            total += br;
        }
        const data = out[0..total];
        var pos: usize = 0;
        while (std.mem.indexOfPos(u8, data, pos, "device")) |at| {
            const before_ok = at == 0 or data[at - 1] == '\t' or data[at - 1] == ' ';
            const after_idx = at + 6;
            const after_ok = after_idx >= data.len or data[after_idx] == '\r' or data[after_idx] == '\n' or data[after_idx] == 0x00 or data[after_idx] == ' ';
            if (before_ok and after_ok) {
                found = true;
                break;
            }
            pos = at + 6;
        }
        _ = w.WaitForSingleObject(pi.h_process, 5000);
        _ = w.CloseHandle(pi.h_process);
        _ = w.CloseHandle(pi.h_thread);
    }
    if (h_write) |h| _ = w.CloseHandle(h);
    _ = w.CloseHandle(h_read.?);
    return found;
}

pub const PORT: u16 = 27315;

/// Run adb reverse tcp:27315 tcp:27315 (socket first, hidden exe fallback).
pub fn setupReverse() void {
    adbPathInit();
    var serial: [64]u8 = undefined;
    if (firstDevice(&serial, 1500)) {
        var out: [64]u8 = undefined;
        const cmd = "reverse:forward:tcp:27315;tcp:27315";
        if (transportExec(serial[0..std.mem.indexOfScalar(u8, &serial, 0) orelse serial.len], cmd, &out, 10000) >= 0) return;
    }
    var cmd: [600]u8 = undefined;
    const prefix = "\"";
    const suffix = "\" reverse tcp:27315 tcp:27315";
    const n = prefix.len + adb_path.len + suffix.len;
    if (n >= cmd.len) return;
    @memcpy(cmd[0..prefix.len], prefix);
    @memcpy(cmd[prefix.len .. prefix.len + adb_path.len], adb_path);
    @memcpy(cmd[prefix.len + adb_path.len .. n], suffix);
    w.runHidden(cmd[0..n]);
}

/// Run adb shell am start for the client (socket first, hidden exe fallback).
pub fn amStartClient() void {
    adbPathInit();
    var serial: [64]u8 = undefined;
    if (firstDevice(&serial, 1500)) {
        var out: [256]u8 = undefined;
        const cmd = "shell:am start -n com.seconddisplay.client/.MainActivity";
        if (transportExec(serial[0..std.mem.indexOfScalar(u8, &serial, 0) orelse serial.len], cmd, &out, 10000) >= 0) return;
    }
    var buf: [700]u8 = undefined;
    const prefix = "\"";
    const suffix = "\" shell am start -n com.seconddisplay.client/.MainActivity";
    const n = prefix.len + adb_path.len + suffix.len;
    if (n >= buf.len) return;
    @memcpy(buf[0..prefix.len], prefix);
    @memcpy(buf[prefix.len .. prefix.len + adb_path.len], adb_path);
    @memcpy(buf[prefix.len + adb_path.len .. n], suffix);
    w.runHidden(buf[0..n]);
}
