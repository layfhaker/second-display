const std = @import("std");
const w = @import("win.zig");
const cap = @import("capture.zig");

// ------------------------------------------------------------------ GUIDs

const MFT_CATEGORY_VIDEO_ENCODER = w.Guid{ .data1 = 0xf79eac7d, .data2 = 0xe545, .data3 = 0x4387, .data4 = .{ 0xbd, 0xee, 0xd6, 0x47, 0xd7, 0xbd, 0xe4, 0x2a } };
const MF_LOW_LATENCY = w.Guid{ .data1 = 0x9C27891A, .data2 = 0xED7A, .data3 = 0x40e1, .data4 = .{ 0x88, 0xE8, 0xB2, 0x27, 0x27, 0xA0, 0x24, 0xEE } };
const MF_TRANSFORM_ASYNC_UNLOCK = w.Guid{ .data1 = 0xe5666d6b, .data2 = 0x3422, .data3 = 0x4eb6, .data4 = .{ 0xa4, 0x21, 0xda, 0x7d, 0xb1, 0xf8, 0xe2, 0x07 } };
const IID_IMFTRANSFORM = w.Guid{ .data1 = 0xbf94c121, .data2 = 0x5b05, .data3 = 0x4e6f, .data4 = .{ 0x80, 0x00, 0xba, 0x59, 0x89, 0x61, 0x41, 0x4d } };
const IID_IMFMEDIAEVENTGENERATOR = w.Guid{ .data1 = 0x2CD0BD52, .data2 = 0xBCD5, .data3 = 0x4B89, .data4 = .{ 0xB6, 0x2C, 0xEA, 0xDC, 0x0C, 0x03, 0x1E, 0x7D } };

// MF_MT_* attribute keys (from um\mfapi.h GUID comments)
const MF_MT_MAJOR_TYPE = w.Guid{ .data1 = 0x48eba18e, .data2 = 0xf8c9, .data3 = 0x4687, .data4 = .{ 0xbf, 0x11, 0x0a, 0x74, 0xc9, 0xf9, 0x6a, 0x8f } };
const MF_MT_SUBTYPE = w.Guid{ .data1 = 0xf7e34c9a, .data2 = 0x42e8, .data3 = 0x4714, .data4 = .{ 0xb7, 0x4b, 0xcb, 0x29, 0xd7, 0x2c, 0x35, 0xe5 } };
const MF_MT_INTERLACE_MODE = w.Guid{ .data1 = 0xe2724bb8, .data2 = 0xe676, .data3 = 0x4806, .data4 = .{ 0xb4, 0xb2, 0xa8, 0xd6, 0xef, 0xb4, 0x4c, 0xcd } };
const MF_MT_FRAME_SIZE = w.Guid{ .data1 = 0x1652c33d, .data2 = 0xd6b2, .data3 = 0x4012, .data4 = .{ 0xb8, 0x34, 0x72, 0x03, 0x08, 0x49, 0xa3, 0x7d } };
const MF_MT_FRAME_RATE = w.Guid{ .data1 = 0xc459a2e8, .data2 = 0x3d2c, .data3 = 0x4e44, .data4 = .{ 0xb1, 0x32, 0xfe, 0xe5, 0x15, 0x6c, 0x7b, 0xb0 } };
const MF_MT_PIXEL_ASPECT_RATIO = w.Guid{ .data1 = 0xc6376a1e, .data2 = 0x8d0a, .data3 = 0x4027, .data4 = .{ 0xbe, 0x45, 0x6d, 0x9a, 0x0a, 0xd3, 0x9b, 0xb6 } };
const MF_MT_AVG_BITRATE = w.Guid{ .data1 = 0x20332624, .data2 = 0xfb0d, .data3 = 0x4d9e, .data4 = .{ 0xbd, 0x0d, 0xcb, 0xf6, 0x78, 0x6c, 0x10, 0x2e } };

// FCC-style media type GUIDs: {FCC,0000,0010,80,00,00,AA,00,38,9B,71}
fn fourccGuid(code: u32) w.Guid {
    return .{ .data1 = code, .data2 = 0, .data3 = 0x0010, .data4 = .{ 0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71 } };
}
const MFMediaType_Video = fourccGuid(('v') | ('i' << 8) | ('d' << 16) | ('s' << 24)); // 0x73646976
const MFVideoFormat_NV12 = fourccGuid(('N') | ('V' << 8) | ('1' << 16) | ('2' << 24)); // 0x3231564E
const MFVideoFormat_HEVC = fourccGuid(('H') | ('E' << 8) | ('V' << 16) | ('C' << 24)); // 0x43564548

// --------------------------------------------------------------- constants

const MF_VERSION: u32 = 0x00020070; // (MF_SDK_VERSION<<16)|MF_API_VERSION, retry 0x00010070
const MFSTARTUP_NOSOCKET: u32 = 0x1;
const MFT_ENUM_FLAG_HARDWARE: u32 = 0x00000004;
const MFT_ENUM_FLAG_SORTANDFILTER: u32 = 0x00000040;
const MFT_ENUM_FLAG_ALL: u32 = 0x0000003F;
const MFT_MESSAGE_NOTIFY_BEGIN_STREAMING: u32 = 0x10000000;
const MFT_MESSAGE_NOTIFY_START_OF_STREAM: u32 = 0x10000003;
const MFT_MESSAGE_NOTIFY_END_OF_STREAM: u32 = 0x10000002;
const MFVideoInterlace_Progressive: u32 = 2;
const MF_EVENT_FLAG_NO_WAIT: u32 = 0x00000001;
const MF_E_NO_EVENTS_AVAILABLE: u32 = 0xC00D3E80;
const MEError: u32 = 1;
const METransformNeedInput: u32 = 601;
const METransformHaveOutput: u32 = 602;

// ---------------------------------------------------------- vtable slots
// Element indices (byte_offset = index * 8), verified live by src/probe.c:
//   IMFTransform:  GetOutputStreamInfo=56/7, GetAttributes=64/8,
//     SetInputType=120/15, SetOutputType=128/16, ProcessMessage=184/23,
//     ProcessInput=192/24, ProcessOutput=200/25
//   IMFAttributes: SetUINT32=168/21, SetUINT64=176/22, SetGUID=192/24
//   IMFSample:     GetSampleTime=280/35, SetSampleTime=288/36,
//     SetSampleDuration=304/38, ConvertToContiguousBuffer=328/41, AddBuffer=336/42
//   IMFMediaBuffer: Lock=24/3, Unlock=32/4, SetCurrentLength=48/6
//   EventGen:      GetEvent=24/3; IMFMediaEvent.GetType=264/33; ActivateObject=264/33
const SLOT_QI: usize = 0;
const SLOT_RELEASE: usize = 2;
const SLOT_GET_OUT_STREAM_INFO: usize = 7;
const SLOT_GET_ATTRIBUTES: usize = 8;
const SLOT_SET_INPUT_TYPE: usize = 15;
const SLOT_SET_OUTPUT_TYPE: usize = 16;
const SLOT_PROCESS_MESSAGE: usize = 23;
const SLOT_PROCESS_INPUT: usize = 24;
const SLOT_PROCESS_OUTPUT: usize = 25;
const SLOT_ATTR_SET_UINT32: usize = 21;
const SLOT_ATTR_SET_UINT64: usize = 22;
const SLOT_ATTR_SET_GUID: usize = 24;
const SLOT_SAMPLE_GET_TIME: usize = 35;
const SLOT_SAMPLE_SET_TIME: usize = 36;
const SLOT_SAMPLE_SET_DURATION: usize = 38;
const SLOT_SAMPLE_TO_CONTIGUOUS: usize = 41;
const SLOT_SAMPLE_ADD_BUFFER: usize = 42;
const SLOT_BUFFER_LOCK: usize = 3;
const SLOT_BUFFER_UNLOCK: usize = 4;
const SLOT_BUFFER_SET_LEN: usize = 6;
const SLOT_EVENT_GET: usize = 3;
const SLOT_EVENT_GET_TYPE: usize = 33;
const SLOT_ACTIVATE_OBJECT: usize = 33;

// ------------------------------------------------------------- flat structs

const RegisterTypeInfo = extern struct {
    major: w.Guid,
    subtype: w.Guid,
};

const OutputDataBuffer = extern struct {
    stream_id: u32,
    sample: ?*anyopaque,
    status: u32,
    events: ?*anyopaque,
};

const OutputStreamInfo = extern struct {
    flags: u32,
    cb_size: u32,
    cb_alignment: u32,
};

const MediaTypeT = opaque {}; // IMFMediaType
const SampleT = opaque {};
const BufferT = opaque {};
const EventT = opaque {};
const ActivateT = opaque {};

// ------------------------------------------------------------ flat functions

const MFTEnumExFn = *const fn (
    category: *const w.Guid,
    flags: u32,
    in_type: ?*const RegisterTypeInfo,
    out_type: *const RegisterTypeInfo,
    activates: *?[*]?*anyopaque,
    count: *u32,
) w.HRESULT;
const MFStartupFn = *const fn (version: u32, flags: u32) w.HRESULT;
const MFShutdownFn = *const fn () w.HRESULT;
const MFCreateMediaTypeFn = *const fn (mt: *?*anyopaque) w.HRESULT;
const MFCreateSampleFn = *const fn (s: *?*anyopaque) w.HRESULT;
const MFCreateMemoryBufferFn = *const fn (max: u32, b: *?*anyopaque) w.HRESULT;

var p_MFTEnumEx: ?MFTEnumExFn = null;
var p_MFStartup: ?MFStartupFn = null;
var p_MFShutdown: ?MFShutdownFn = null;
var p_MFCreateMediaType: ?MFCreateMediaTypeFn = null;
var p_MFCreateSample: ?MFCreateSampleFn = null;
var p_MFCreateMemoryBuffer: ?MFCreateMemoryBufferFn = null;

fn loadFlat() bool {
    if (p_MFTEnumEx != null) return true;
    p_MFTEnumEx = w.loadSym(MFTEnumExFn, "mfplat.dll", "MFTEnumEx");
    p_MFStartup = w.loadSym(MFStartupFn, "mfplat.dll", "MFStartup");
    p_MFShutdown = w.loadSym(MFShutdownFn, "mfplat.dll", "MFShutdown");
    p_MFCreateMediaType = w.loadSym(MFCreateMediaTypeFn, "mfplat.dll", "MFCreateMediaType");
    p_MFCreateSample = w.loadSym(MFCreateSampleFn, "mfplat.dll", "MFCreateSample");
    p_MFCreateMemoryBuffer = w.loadSym(MFCreateMemoryBufferFn, "mfplat.dll", "MFCreateMemoryBuffer");
    return p_MFTEnumEx != null and p_MFStartup != null and p_MFShutdown != null and
        p_MFCreateMediaType != null and p_MFCreateSample != null and p_MFCreateMemoryBuffer != null;
}

// -------------------------------------------------------------------- state

var p_transform: ?*anyopaque = null;
var p_event_gen: ?*anyopaque = null;
pub var enc_is_async = false;
pub var enc_need_input = true;
pub var bytes_encoded: i64 = 0;
var frames_encoded: i64 = 0;

pub const SendVideoFn = *const fn (sock: w.Socket, pts_us: i64, key: u8, data: []const u8) void;
var send_video: ?SendVideoFn = null;

fn rel(obj: ?*anyopaque) void {
    if (obj == null) return;
    const F = *const fn (?*anyopaque) u32;
    const f: F = @ptrCast(w.vtbl(obj)[SLOT_RELEASE].?);
    _ = f(obj);
}

fn qi(obj: ?*anyopaque, iid: *const w.Guid, out: *?*anyopaque) bool {
    const F = *const fn (?*anyopaque, *const w.Guid, *?*anyopaque) i32;
    const f: F = @ptrCast(w.vtbl(obj)[SLOT_QI].?);
    return f(obj, iid, out) >= 0;
}

fn packU64(hi: u32, lo: u32) u64 {
    return (@as(u64, hi) << 32) | lo;
}

// ---------------------------------------------------------------- keyframes

/// HEVC keyframe detection: VPS=32 SPS=33 PPS=34 IDR_W_RADL=19 IDR_N_LP=20
fn isHevcKeyframe(data: []const u8) bool {
    var i: usize = 0;
    while (i + 5 < data.len) {
        var sc: usize = 0;
        if (data[i] == 0 and data[i + 1] == 0 and data[i + 2] == 1) {
            sc = 3;
        } else if (i + 3 < data.len and data[i] == 0 and data[i + 1] == 0 and data[i + 2] == 0 and data[i + 3] == 1) {
            sc = 4;
        }
        if (sc == 0) {
            i += 1;
            continue;
        }
        const nal_header = i + sc;
        if (nal_header >= data.len) break;
        const nal_type = (data[nal_header] >> 1) & 0x3F;
        if (nal_type == 19 or nal_type == 20 or nal_type == 32 or nal_type == 33 or nal_type == 34) return true;
        i = nal_header + 1;
    }
    return false;
}

// ------------------------------------------------------------------- init

fn setGuidAttr(mt: ?*anyopaque, key: *const w.Guid, val: *const w.Guid) void {
    const F = *const fn (?*anyopaque, *const w.Guid, *const w.Guid) i32;
    const f: F = @ptrCast(w.vtbl(mt)[SLOT_ATTR_SET_GUID].?);
    _ = f(mt, key, val);
}

fn setU32Attr(mt: ?*anyopaque, key: *const w.Guid, val: u32) void {
    const F = *const fn (?*anyopaque, *const w.Guid, u32) i32;
    const f: F = @ptrCast(w.vtbl(mt)[SLOT_ATTR_SET_UINT32].?);
    _ = f(mt, key, val);
}

fn setU64Attr(mt: ?*anyopaque, key: *const w.Guid, val: u64) void {
    const F = *const fn (?*anyopaque, *const w.Guid, u64) i32;
    const f: F = @ptrCast(w.vtbl(mt)[SLOT_ATTR_SET_UINT64].?);
    _ = f(mt, key, val);
}

pub fn encoderInit(width: u32, height: u32, fps: u32, bitrate: u32, cb: SendVideoFn) bool {
    send_video = cb;
    // Main thread already runs CoInitializeEx; this is a no-op-ish second init for safety.
    _ = w.CoInitializeEx(null, w.COINIT_MULTITHREADED);
    if (!loadFlat()) {
        w.logz("Failed to load mfplat exports\n", .{});
        return false;
    }

    // MFStartup validates the version: try the modern one, fall back to Vista's.
    var hr = p_MFStartup.?(MF_VERSION, MFSTARTUP_NOSOCKET);
    if (!w.hrOk(hr)) hr = p_MFStartup.?(0x00010070, MFSTARTUP_NOSOCKET);
    if (!w.hrOk(hr)) {
        w.logz("MFStartup failed (hr=0x{X:0>8})\n", .{@as(u32, @bitCast(hr))});
        return false;
    }

    frames_encoded = 0;
    bytes_encoded = 0;
    enc_need_input = true;

    const out_info = RegisterTypeInfo{ .major = MFMediaType_Video, .subtype = MFVideoFormat_HEVC };

    var activates: ?[*]?*anyopaque = null;
    var count: u32 = 0;
    hr = p_MFTEnumEx.?(&MFT_CATEGORY_VIDEO_ENCODER, MFT_ENUM_FLAG_HARDWARE | MFT_ENUM_FLAG_SORTANDFILTER, null, &out_info, &activates, &count);
    if (count == 0 or activates == null) {
        w.logz("Hardware HEVC MFT not found, trying software/all...\n", .{});
        activates = null;
        count = 0;
        hr = p_MFTEnumEx.?(&MFT_CATEGORY_VIDEO_ENCODER, MFT_ENUM_FLAG_ALL, null, &out_info, &activates, &count);
    }
    if (count == 0 or activates == null) {
        w.logz("Error: No HEVC encoder MFT found on system\n", .{});
        return false;
    }
    w.logz("Found {d} HEVC encoder MFT(s)\n", .{count});

    // IMFActivate is not the transform itself: activate it (same as HolyC/C#).
    const ActivateF = *const fn (?*anyopaque, *const w.Guid, *?*anyopaque) i32;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const act = activates.?[i];
        if (p_transform == null and act != null) {
            const activate: ActivateF = @ptrCast(w.vtbl(act)[SLOT_ACTIVATE_OBJECT].?);
            const ahr = activate(act, &IID_IMFTRANSFORM, &p_transform);
            if (!w.hrOk(ahr)) p_transform = null;
        }
        rel(act);
    }
    w.CoTaskMemFree(@ptrCast(activates.?));

    if (p_transform == null) {
        w.logz("Error: Failed to activate IMFTransform\n", .{});
        return false;
    }

    // Unlock async + configure low latency (best effort: attrs may be absent).
    enc_is_async = false;
    var attrs: ?*anyopaque = null;
    // GetAttributes(IMFAttributes **pp) - two params only, no flags arg.
    const GetAttrsF = *const fn (?*anyopaque, *?*anyopaque) i32;
    const get_attrs: GetAttrsF = @ptrCast(w.vtbl(p_transform)[SLOT_GET_ATTRIBUTES].?);
    if (get_attrs(p_transform, &attrs) >= 0 and attrs != null) {
        const SetU32F = *const fn (?*anyopaque, *const w.Guid, u32) i32;
        const set_u32: SetU32F = @ptrCast(w.vtbl(attrs)[SLOT_ATTR_SET_UINT32].?);
        const hr_unlock = set_u32(attrs, &MF_TRANSFORM_ASYNC_UNLOCK, 1);
        _ = set_u32(attrs, &MF_LOW_LATENCY, 1);
        enc_is_async = w.hrOk(hr_unlock);
        rel(attrs);
    } else {
        w.logz("GetAttributes failed, async MFT stays locked\n", .{});
    }

    // Output type: HEVC
    var p_out: ?*anyopaque = null;
    if (p_MFCreateMediaType.?(&p_out) < 0 or p_out == null) {
        w.logz("MFCreateMediaType(out) failed\n", .{});
        return false;
    }
    setGuidAttr(p_out, &MF_MT_MAJOR_TYPE, &MFMediaType_Video);
    setGuidAttr(p_out, &MF_MT_SUBTYPE, &MFVideoFormat_HEVC);
    setU32Attr(p_out, &MF_MT_AVG_BITRATE, bitrate);
    setU32Attr(p_out, &MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
    setU64Attr(p_out, &MF_MT_FRAME_SIZE, packU64(width, height));
    setU64Attr(p_out, &MF_MT_FRAME_RATE, packU64(fps, 1));
    setU64Attr(p_out, &MF_MT_PIXEL_ASPECT_RATIO, packU64(1, 1));
    const SetTypeF = *const fn (?*anyopaque, u32, ?*anyopaque, u32) i32;
    const set_out: SetTypeF = @ptrCast(w.vtbl(p_transform)[SLOT_SET_OUTPUT_TYPE].?);
    hr = set_out(p_transform, 0, p_out, 0);
    rel(p_out);
    if (!w.hrOk(hr)) {
        w.logz("Error: SetOutputType failed (hr=0x{X:0>8})\n", .{@as(u32, @bitCast(hr))});
        rel(p_transform);
        p_transform = null;
        return false;
    }

    // Input type: NV12
    var p_in: ?*anyopaque = null;
    if (p_MFCreateMediaType.?(&p_in) < 0 or p_in == null) {
        w.logz("MFCreateMediaType(in) failed\n", .{});
        return false;
    }
    setGuidAttr(p_in, &MF_MT_MAJOR_TYPE, &MFMediaType_Video);
    setGuidAttr(p_in, &MF_MT_SUBTYPE, &MFVideoFormat_NV12);
    setU32Attr(p_in, &MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
    setU64Attr(p_in, &MF_MT_FRAME_SIZE, packU64(width, height));
    setU64Attr(p_in, &MF_MT_FRAME_RATE, packU64(fps, 1));
    setU64Attr(p_in, &MF_MT_PIXEL_ASPECT_RATIO, packU64(1, 1));
    const set_in: SetTypeF = @ptrCast(w.vtbl(p_transform)[SLOT_SET_INPUT_TYPE].?);
    hr = set_in(p_transform, 0, p_in, 0);
    rel(p_in);
    if (!w.hrOk(hr)) {
        w.logz("Error: SetInputType failed (hr=0x{X:0>8})\n", .{@as(u32, @bitCast(hr))});
        rel(p_transform);
        p_transform = null;
        return false;
    }

    const ProcMsgF = *const fn (?*anyopaque, u32, usize) i32;
    const proc_msg: ProcMsgF = @ptrCast(w.vtbl(p_transform)[SLOT_PROCESS_MESSAGE].?);
    _ = proc_msg(p_transform, MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0);
    _ = proc_msg(p_transform, MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0);

    if (enc_is_async) {
        if (!qi(p_transform, &IID_IMFMEDIAEVENTGENERATOR, &p_event_gen)) {
            enc_is_async = false;
            p_event_gen = null;
        }
    }

    w.logz("Media Foundation HEVC encoder ready: {d}x{d} @{d}fps ({d} bps)\n", .{ width, height, fps, bitrate });
    return true;
}

pub fn encoderCleanup() void {
    if (p_transform != null) {
        const ProcMsgF = *const fn (?*anyopaque, u32, usize) i32;
        const proc_msg: ProcMsgF = @ptrCast(w.vtbl(p_transform)[SLOT_PROCESS_MESSAGE].?);
        _ = proc_msg(p_transform, MFT_MESSAGE_NOTIFY_END_OF_STREAM, 0);
        if (p_event_gen != null) {
            rel(p_event_gen);
            p_event_gen = null;
        }
        rel(p_transform);
        p_transform = null;
    }
    if (p_MFShutdown) |f| _ = f();
    w.CoUninitialize();
}

// -------------------------------------------------------------------- feed

pub fn encoderFeedNv12(data: []const u8, pts_us: i64, duration_hns: i64) bool {
    if (p_transform == null) return false;

    var p_buf: ?*anyopaque = null;
    var hr = p_MFCreateMemoryBuffer.?(@intCast(data.len), &p_buf);
    if (!w.hrOk(hr) or p_buf == null) {
        w.logz("MFCreateMemoryBuffer failed: 0x{X:0>8}\n", .{@as(u32, @bitCast(hr))});
        return false;
    }

    const LockF = *const fn (?*anyopaque, *?*anyopaque, ?*u32, ?*u32) i32;
    const lock: LockF = @ptrCast(w.vtbl(p_buf)[SLOT_BUFFER_LOCK].?);
    var p_data: ?*anyopaque = null;
    hr = lock(p_buf, &p_data, null, null);
    if (!w.hrOk(hr) or p_data == null) {
        rel(p_buf);
        return false;
    }
    const dst: [*]u8 = @ptrCast(p_data.?);
    @memcpy(dst[0..data.len], data);
    const UnlockF = *const fn (?*anyopaque) i32;
    const unlock: UnlockF = @ptrCast(w.vtbl(p_buf)[SLOT_BUFFER_UNLOCK].?);
    _ = unlock(p_buf);
    const SetLenF = *const fn (?*anyopaque, u32) i32;
    const set_len: SetLenF = @ptrCast(w.vtbl(p_buf)[SLOT_BUFFER_SET_LEN].?);
    _ = set_len(p_buf, @intCast(data.len));

    var p_sample: ?*anyopaque = null;
    hr = p_MFCreateSample.?(&p_sample);
    if (!w.hrOk(hr) or p_sample == null) {
        rel(p_buf);
        return false;
    }

    const AddBufF = *const fn (?*anyopaque, ?*anyopaque) i32;
    const add_buf: AddBufF = @ptrCast(w.vtbl(p_sample)[SLOT_SAMPLE_ADD_BUFFER].?);
    _ = add_buf(p_sample, p_buf);
    const SetTimeF = *const fn (?*anyopaque, i64) i32;
    const set_time: SetTimeF = @ptrCast(w.vtbl(p_sample)[SLOT_SAMPLE_SET_TIME].?);
    _ = set_time(p_sample, pts_us * 10);
    const SetDurF = *const fn (?*anyopaque, i64) i32;
    const set_dur: SetDurF = @ptrCast(w.vtbl(p_sample)[SLOT_SAMPLE_SET_DURATION].?);
    _ = set_dur(p_sample, duration_hns);

    const ProcInF = *const fn (?*anyopaque, u32, ?*anyopaque, u32) i32;
    const proc_in: ProcInF = @ptrCast(w.vtbl(p_transform)[SLOT_PROCESS_INPUT].?);
    hr = proc_in(p_transform, 0, p_sample, 0);

    rel(p_sample);
    rel(p_buf);

    if (w.hrOk(hr)) {
        enc_need_input = false;
        return true;
    }
    return false;
}

// ------------------------------------------------------------------- drain

pub fn encoderDrainOutput(sock: w.Socket) void {
    if (p_transform == null) return;

    var odb: OutputDataBuffer = std.mem.zeroes(OutputDataBuffer);
    odb.stream_id = 0;
    var status: u32 = 0;

    const ProcOutF = *const fn (?*anyopaque, u32, u32, *OutputDataBuffer, *u32) i32;
    const proc_out: ProcOutF = @ptrCast(w.vtbl(p_transform)[SLOT_PROCESS_OUTPUT].?);
    const hr = proc_out(p_transform, 0, 1, &odb, &status);
    if (!w.hrOk(hr)) {
        rel(odb.sample);
        if (odb.events) |e| rel(e);
        return;
    }

    if (odb.sample) |sample| {
        const GetTimeF = *const fn (?*anyopaque, *i64) i32;
        const get_time: GetTimeF = @ptrCast(w.vtbl(sample)[SLOT_SAMPLE_GET_TIME].?);
        var time_hns: i64 = 0;
        _ = get_time(sample, &time_hns);
        const pts_us = @divTrunc(time_hns, 10);

        var p_contig: ?*anyopaque = null;
        const ToContigF = *const fn (?*anyopaque, *?*anyopaque) i32;
        const to_contig: ToContigF = @ptrCast(w.vtbl(sample)[SLOT_SAMPLE_TO_CONTIGUOUS].?);
        if (to_contig(sample, &p_contig) >= 0 and p_contig != null) {
            const LockC = *const fn (?*anyopaque, *?*anyopaque, ?*u32, *u32) i32;
            const lock_c: LockC = @ptrCast(w.vtbl(p_contig)[SLOT_BUFFER_LOCK].?);
            var p_enc: ?*anyopaque = null;
            var enc_len: u32 = 0;
            if (lock_c(p_contig, &p_enc, null, &enc_len) >= 0 and p_enc != null and enc_len > 0) {
                const bytes: [*]const u8 = @ptrCast(p_enc.?);
                const slice = bytes[0..enc_len];
                const key: u8 = if (isHevcKeyframe(slice)) 1 else 0;
                frames_encoded += 1;
                bytes_encoded += enc_len;
                if (frames_encoded <= 5 or @mod(frames_encoded, 60) == 0) {
                    w.logz("HEVC Frame #{d}: {d} bytes, key={}, pts={d} us\n", .{ frames_encoded, enc_len, key != 0, pts_us });
                }
                if (send_video) |f| f(sock, pts_us, key, slice);
                const UnlockC = *const fn (?*anyopaque) i32;
                const unlock_c: UnlockC = @ptrCast(w.vtbl(p_contig)[SLOT_BUFFER_UNLOCK].?);
                _ = unlock_c(p_contig);
            }
            rel(p_contig);
        }
        rel(sample);
    }
    if (odb.events) |e| rel(e);
}

// -------------------------------------------------------------------- poll

/// One non-blocking event pass: NeedInput arms feeding, HaveOutput drains.
pub fn encoderPollEvents(sock: w.Socket) void {
    if (p_event_gen == null) {
        enc_need_input = true;
        return;
    }

    const GetEventF = *const fn (?*anyopaque, u32, *?*anyopaque) i32;
    const get_event: GetEventF = @ptrCast(w.vtbl(p_event_gen)[SLOT_EVENT_GET].?);
    var p_event: ?*anyopaque = null;
    const hr = get_event(p_event_gen, MF_EVENT_FLAG_NO_WAIT, &p_event);
    if (!w.hrOk(hr) or p_event == null) {
        if (!w.hrIs(hr, MF_E_NO_EVENTS_AVAILABLE)) return;
        return;
    }

    const GetTypeF = *const fn (?*anyopaque, *u32) i32;
    const get_type: GetTypeF = @ptrCast(w.vtbl(p_event)[SLOT_EVENT_GET_TYPE].?);
    var met: u32 = 0;
    _ = get_type(p_event, &met);
    rel(p_event);

    if (met == METransformNeedInput) {
        enc_need_input = true;
    } else if (met == METransformHaveOutput) {
        encoderDrainOutput(sock);
    } else if (met == MEError) {
        // Encoder-side error; keep the session alive - watchdog handles stalls.
        w.logz("MF encoder error event\n", .{});
    }
}
