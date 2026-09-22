const std = @import("std");
const w = @import("win.zig");
const cap = @import("capture.zig");
const enc = @import("encoder.zig");
const inp = @import("input.zig");
const adb = @import("adblink.zig");
const vdd = @import("vdd.zig");

pub const PORT: u16 = 27315;
const PKT_HELLO: u8 = 0x01;
const PKT_READY: u8 = 0x02;
const PKT_VIDEO: u8 = 0x10;
const PKT_PING: u8 = 0x30;
const CODEC_H265: u8 = 2;

var client_alive = std.atomic.Value(bool).init(false);

// ---------------------------------------------------------------- packets

fn sendPacket(sock: w.Socket, pkt_type: u8, payload: []const u8) bool {
    var hdr: [5]u8 = undefined;
    hdr[0] = pkt_type;
    inp.writeU32(hdr[1..5], @intCast(payload.len));
    if (w.sockWrite(sock, &hdr) <= 0) return false;
    if (payload.len > 0) {
        if (w.sockWrite(sock, payload) <= 0) return false;
    }
    return true;
}

fn sendVideo(sock: w.Socket, pts_us: i64, key: u8, data: []const u8) void {
    if (!client_alive.load(.acquire)) return;
    var hdr: [5]u8 = undefined;
    hdr[0] = PKT_VIDEO;
    inp.writeU32(hdr[1..5], @intCast(9 + data.len));
    var meta: [9]u8 = undefined;
    @memcpy(meta[0..8], std.mem.asBytes(&pts_us));
    meta[8] = key;
    if (w.sockWrite(sock, &hdr) <= 0 or w.sockWrite(sock, &meta) <= 0 or
        (data.len > 0 and w.sockWrite(sock, data) <= 0))
    {
        client_alive.store(false, .release);
    }
}

fn sendReady(sock: w.Socket) void {
    var buf: [13]u8 = undefined;
    inp.writeU32(buf[0..4], cap.STREAM_W);
    inp.writeU32(buf[4..8], cap.STREAM_H);
    inp.writeU32(buf[8..12], cap.STREAM_REFRESH);
    buf[12] = CODEC_H265;
    if (sendPacket(sock, PKT_READY, &buf)) {
        w.logz("READY sent ({d}x{d} refresh={d} codec={d})\n", .{ cap.STREAM_W, cap.STREAM_H, cap.STREAM_REFRESH, CODEC_H265 });
    }
}

fn handshake(sock: w.Socket) bool {
    var hdr: [5]u8 = undefined;
    if (!w.sockReadAll(sock, &hdr)) return false;
    const pkt_type = hdr[0];
    const len = inp.readU32(hdr[1..5]);
    if (len > 256) return false;
    var body: [256]u8 = undefined;
    if (len > 0 and !w.sockReadAll(sock, body[0..len])) return false;

    w.logz("Handshake: packet type=0x{X:0>2} len={d}\n", .{ pkt_type, len });
    if (pkt_type != PKT_HELLO) return false;
    if (len >= 8) {
        const cw = inp.readU32(body[0..4]);
        const ch = inp.readU32(body[4..8]);
        w.logz("Client HELLO: wants {d}x{d}\n", .{ cw, ch });
    }
    return true;
}

// ------------------------------------------------------------- input pump

const InputArgs = struct { sock: w.Socket };

fn inputThreadMain(arg: InputArgs) void {
    const sock = arg.sock;
    var hdr: [5]u8 = undefined;
    var pay: [1024]u8 = undefined;

    while (client_alive.load(.acquire)) {
        if (!w.sockReadAll(sock, &hdr)) break;
        const pkt_type = hdr[0];
        const len = inp.readU32(hdr[1..5]);
        if (len > pay.len) break;
        if (len > 0 and !w.sockReadAll(sock, pay[0..len])) break;

        if (pkt_type == inp.PKT_TOUCH) {
            if (len >= 10) {
                inp.injectTouch(pay[0], inp.readF32(pay[2..6]), inp.readF32(pay[6..10]));
            }
        } else if (pkt_type == inp.PKT_KEY) {
            if (len >= 7) {
                const key_code = inp.readU16(pay[1..3]);
                const meta = inp.readU32(pay[3..7]);
                const scan: u16 = if (len >= 9) inp.readU16(pay[7..9]) else 0;
                inp.injectKey(pay[0], key_code, meta, scan);
            }
        } else if (pkt_type == inp.PKT_SCROLL) {
            if (len >= 8) {
                inp.injectScroll(inp.readF32(pay[0..4]), inp.readF32(pay[4..8]));
            }
        }
        // PING and unknown types: payload consumed, nothing to do.
    }

    client_alive.store(false, .release);
}

// --------------------------------------------------------------- session

fn serveOnce(listen_sock: w.Socket) void {
    var addr: w.SockAddrIn = std.mem.zeroes(w.SockAddrIn);
    var addr_len: i32 = @sizeOf(w.SockAddrIn);
    const client = w.accept(listen_sock, &addr, &addr_len);
    if (client == w.INVALID_SOCKET or client < 0) return;

    var opt: i32 = 1;
    _ = w.setsockopt(client, w.IPPROTO_TCP, w.TCP_NODELAY, std.mem.asBytes(&opt), 4);
    const sndbuf: i32 = 524288;
    _ = w.setsockopt(client, w.SOL_SOCKET, w.SO_SNDBUF, std.mem.asBytes(&sndbuf), 4);

    w.logz("Client connected\n", .{});

    if (!handshake(client)) {
        w.logz("Handshake failed with client\n", .{});
        w.sockClose(client);
        return;
    }

    client_alive.store(true, .release);
    sendReady(client);

    if (!cap.captureInit()) {
        w.logz("CaptureInit failed\n", .{});
        captureFailCleanup();
        w.sockClose(client);
        return;
    }

    if (!enc.encoderInit(cap.STREAM_W, cap.STREAM_H, cap.STREAM_REFRESH, 12_000_000, sendVideo)) {
        w.logz("EncoderInit failed\n", .{});
        enc.encoderCleanup();
        captureFailCleanup();
        w.sockClose(client);
        return;
    }

    var input_thread: ?std.Thread = null;
    if (std.Thread.spawn(.{}, inputThreadMain, .{InputArgs{ .sock = client }})) |t| {
        input_thread = t;
    } else |e| {
        w.logz("Warning: input thread spawn failed: {s}\n", .{@errorName(e)});
    }

    // Warmup: let the desktop compositor initialize.
    var warm: i32 = 0;
    while (warm < 5) : (warm += 1) {
        _ = cap.captureScreen();
        w.Sleep(16);
    }

    const qpc_start = w.qpcNow();
    var qpc_last_progress = w.qpcNow();
    var last_ping = w.qpcNow();
    var last_bytes: i64 = enc.bytes_encoded;
    var frame_idx: i64 = 0;

    w.logz("Starting video streaming loop @{d} fps...\n", .{cap.STREAM_REFRESH});

    while (client_alive.load(.acquire)) {
        // Cursor first: zero-latency pointer response.
        var alive = client_alive.load(.acquire);
        inp.sendCursorPacket(client, &alive);
        if (!alive) {
            client_alive.store(false, .release);
            break;
        }

        const now = w.qpcNow();
        const pts_us = @divTrunc((now - qpc_start) * 1_000_000, w.qpcFreq());

        enc.encoderPollEvents(client);

        if (enc.enc_need_input) {
            if (cap.captureScreen()) {
                if (enc.encoderFeedNv12(cap.frame_nv12[0..], pts_us, 166_666)) {
                    frame_idx += 1;
                }
            }
        }

        if (!enc.enc_is_async) {
            enc.encoderDrainOutput(client);
        }

        // Watchdog + ping: keep the client's read timeout satisfied during stalls.
        if (enc.bytes_encoded != last_bytes) {
            last_bytes = enc.bytes_encoded;
            qpc_last_progress = now;
        } else if (frame_idx > 5) {
            const stall_us = @divTrunc((now - qpc_last_progress) * 1_000_000, w.qpcFreq());
            if (stall_us > 1_000_000 and @divTrunc((now - last_ping) * 1_000_000, w.qpcFreq()) > 1_000_000) {
                _ = sendPacket(client, PKT_PING, &[_]u8{});
                last_ping = now;
            }
            if (stall_us > 2_500_000) {
                w.logz("Watchdog: streaming stall detected (>2.5s), resetting session...\n", .{});
                client_alive.store(false, .release);
                break;
            }
        }

        w.Sleep(8);
    }

    w.logz("Client session ended\n", .{});
    client_alive.store(false, .release);

    w.sockClose(client);
    if (input_thread) |t| {
        t.join();
        inp.releaseAllKeys();
    }

    enc.encoderCleanup();
    cap.captureCleanup();
}

fn captureFailCleanup() void {
    cap.captureCleanup();
}

// --------------------------------------------------------------- watcher

fn watcherMain() void {
    var was_connected = adb.tabletPresent();
    if (!was_connected) {
        // First adb round-trip can race the server waking up: recheck once
        // before deciding to flap the virtual display off.
        w.Sleep(700);
        was_connected = adb.tabletPresent();
    }
    if (was_connected) {
        w.logz("Startup: tablet connected. Ensuring VDD enabled...\n", .{});
        vdd.enable();
        adb.setupReverse();
    } else {
        w.logz("Startup: no tablet connected. Ensuring VDD disabled (passive mode)...\n", .{});
        vdd.disable();
    }
    var missing_polls: i32 = 0;
    var present_polls: i32 = 0;
    var poll_cycle: i64 = 0;

    while (true) {
        w.Sleep(500);
        poll_cycle += 1;

        const has_tablet = adb.tabletPresent();
        if (!has_tablet) {
            missing_polls += 1;
            present_polls = 0;
        } else {
            missing_polls = 0;
            present_polls += 1;
        }

        if (has_tablet) {
            // Debounce the connect edge: USB re-enumeration flaps adb for a poll or two.
            if (!was_connected and present_polls >= 2) {
                w.logz("Tablet connection detected! Enabling Virtual Display Driver...\n", .{});
                vdd.enable();
                w.Sleep(1500);
                adb.setupReverse();
                adb.amStartClient();
                was_connected = true;
            } else if (was_connected and !client_alive.load(.acquire)) {
                if (@mod(poll_cycle, 6) == 0) {
                    adb.setupReverse();
                    adb.amStartClient();
                }
            }
        } else {
            if (was_connected and missing_polls >= 1) {
                w.logz("Tablet disconnected! Disabling Virtual Display Driver...\n", .{});
                client_alive.store(false, .release);
                vdd.disable();
                was_connected = false;
            }
        }
    }
}

// ------------------------------------------------------------------ main

fn ctrlHandler(ctrl_type: u32) callconv(.C) w.BOOL {
    _ = ctrl_type;
    w.logz("Process terminating -> Disabling Virtual Display Driver...\n", .{});
    vdd.disable();
    return 0;
}

pub fn main() !void {
    w.qpcInit();
    // DXGI and MF both expect an initialized COM apartment on the calling thread.
    _ = w.CoInitializeEx(null, w.COINIT_MULTITHREADED);

    const mutex = w.CreateMutexA(null, 1, "Global\\SecondDisplayHost");
    if (w.GetLastError() == w.ERROR_ALREADY_EXISTS) {
        w.logz("Another instance of SecondDisplay Host is already running.\n", .{});
        if (mutex) |m| _ = w.CloseHandle(m);
        return;
    }

    w.logz("=== SecondDisplay Zig Host (Windows target) ===\n", .{});

    _ = w.SetConsoleCtrlHandler(ctrlHandler, 1);

    if (std.Thread.spawn(.{}, watcherMain, .{})) |t| {
        t.detach();
    } else |e| {
        w.logz("Warning: watcher thread spawn failed: {s}\n", .{@errorName(e)});
    }

    var wsa: w.WsaData = std.mem.zeroes(w.WsaData);
    if (w.WSAStartup(0x0202, &wsa) != 0) {
        w.logz("WSAStartup failed\n", .{});
        return;
    }

    const listen_sock = w.socket(w.AF_INET, w.SOCK_STREAM, w.IPPROTO_TCP);
    if (listen_sock < 0 or listen_sock == w.INVALID_SOCKET) {
        w.logz("Socket creation failed\n", .{});
        _ = w.WSACleanup();
        return;
    }

    var opt: i32 = 1;
    _ = w.setsockopt(listen_sock, w.SOL_SOCKET, w.SO_REUSEADDR, std.mem.asBytes(&opt), 4);

    var addr: w.SockAddrIn = std.mem.zeroes(w.SockAddrIn);
    addr.sin_family = w.AF_INET;
    addr.sin_addr = 0; // INADDR_ANY
    addr.sin_port = w.htons(PORT);

    if (w.bind(listen_sock, &addr, @sizeOf(w.SockAddrIn)) != 0) {
        w.logz("Bind to 0.0.0.0:{d} failed\n", .{PORT});
        w.sockClose(listen_sock);
        _ = w.WSACleanup();
        return;
    }
    if (w.listen(listen_sock, 128) != 0) {
        w.logz("Listen failed\n", .{});
        w.sockClose(listen_sock);
        _ = w.WSACleanup();
        return;
    }

    w.logz("TCP Server listening on 0.0.0.0:{d}\n", .{PORT});

    while (true) {
        serveOnce(listen_sock);
    }
}
