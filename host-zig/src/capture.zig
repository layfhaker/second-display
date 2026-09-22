const std = @import("std");
const w = @import("win.zig");

pub const STREAM_W: u32 = 1920;
pub const STREAM_H: u32 = 1280;
pub const STREAM_REFRESH: u32 = 60;
pub const FRAME_NV12: u32 = STREAM_W * STREAM_H * 3 / 2; // 3686400

// ------------------------------------------------------------------ GUIDs

const IID_IDXGIFACTORY1 = w.Guid{ .data1 = 0x770aae78, .data2 = 0xf26f, .data3 = 0x4dba, .data4 = .{ 0xa8, 0x29, 0x25, 0x3c, 0x83, 0xd1, 0xb3, 0x87 } };
const IID_IDXGIADAPTER1 = w.Guid{ .data1 = 0x29038f61, .data2 = 0x3839, .data3 = 0x4626, .data4 = .{ 0x91, 0xfd, 0x08, 0x68, 0x79, 0x01, 0x1a, 0x05 } };
const IID_ID3D11DEVICE = w.Guid{ .data1 = 0xdb6f6ddb, .data2 = 0xac77, .data3 = 0x4e88, .data4 = .{ 0x82, 0x53, 0x81, 0x9d, 0xf9, 0xbb, 0xf1, 0x40 } };

const IID_IDXGIOUTPUT1 = w.Guid{ .data1 = 0x00cddea8, .data2 = 0x939b, .data3 = 0x4b83, .data4 = .{ 0xa3, 0x40, 0xa6, 0x85, 0x22, 0x66, 0x66, 0xcc } };
const IID_ID3D11TEXTURE2D = w.Guid{ .data1 = 0x6f15aaf2, .data2 = 0xd208, .data3 = 0x4e89, .data4 = .{ 0x9a, 0xb4, 0x48, 0x95, 0x35, 0xd3, 0x4f, 0x9c } };

// ------------------------------------------------------------ vtable slots
// Element indices in the vtable array (byte_offset = index * 8).
// Verified against live objects by src/probe.c (the slot dumper); byte offsets
// from the Windows SDK headers kept in comments for reference:
//   IDXGIFactory:  EnumAdapters=56/7, EnumAdapters1=96/12
//   IDXGIAdapter:  EnumOutputs=56/7
//   IDXGIOutput:   GetDesc=56/7
//   IDXGIOutput1:  DuplicateOutput=176/22
//   Duplication:   AcquireNextFrame=64/8, ReleaseFrame=112/14
//   ID3D11Device:  CreateTexture2D=40/5
//   ID3D11DeviceContext: Map=112/14, Unmap=120/15, CopyResource=376/47
const SLOT_QUERYINTERFACE: usize = 0;
const SLOT_RELEASE: usize = 2;
const SLOT_ENUMADAPTERS: usize = 7;
const SLOT_ENUMADAPTERS1: usize = 12;
const SLOT_ENUMOUTPUTS: usize = 7;
const SLOT_OUTPUT_GETDESC: usize = 7;
const SLOT_DUPLICATE_OUTPUT: usize = 22;
const SLOT_ACQUIRE_FRAME: usize = 8;
const SLOT_RELEASE_FRAME: usize = 14;
const SLOT_CREATE_TEXTURE2D: usize = 5;
const SLOT_COPY_RESOURCE: usize = 47;
const SLOT_MAP: usize = 14;
const SLOT_UNMAP: usize = 15;

const DXGI_ERROR_WAIT_TIMEOUT: u32 = 0x887A0027;
const DXGI_ERROR_ACCESS_LOST: u32 = 0x887A0026;

const D3D11_USAGE_STAGING: u32 = 3;
const D3D11_CPU_ACCESS_READ: u32 = 0x20000;
const D3D11_MAP_READ: u32 = 1;
const D3D11_CREATE_DEVICE_BGRA_SUPPORT: u32 = 0x20;
const D3D_DRIVER_TYPE_UNKNOWN: u32 = 0;
const D3D11_SDK_VERSION: u32 = 7;
const DXGI_FORMAT_B8G8R8A8_UNORM: u32 = 87;

// ----------------------------------------------------------------- structs

const Rect = extern struct { left: i32, top: i32, right: i32, bottom: i32 };

// DXGI_OUTPUT_DESC field order verified against um\dxgi.h: DeviceName first.
const DxgiOutputDesc = extern struct {
    device_name: [32]u16, // WCHAR[32] at 0..63
    desktop_coordinates: Rect, // RECT at 64..79
    attached_to_desktop: w.BOOL, // 80..83
    rotation: u32, // 84..87
    monitor: ?*anyopaque, // HMONITOR at 88..95
};

const DxgiAdapterDesc1 = extern struct {
    description: [128]u16,
    vendor_id: u32,
    device_id: u32,
    sub_sys_id: u32,
    revision: u32,
    dedicated_video_memory: usize,
    dedicated_system_memory: usize,
    shared_system_memory: usize,
    adapter_luid: i64,
    flags: u32,
};

// MS SDK D3D11_TEXTURE2D_DESC: {Width, Height, MipLevels, ArraySize, Format,
// DXGI_SAMPLE_DESC, Usage, BindFlags, CPUAccessFlags, MiscFlags} = 44 bytes.
// (There is NO StructureByteStride here - that field belongs to BUFFER_DESC.
// Verified against um\d3d11.h; the BindFlags slot misread caused the
// historic E_INVALIDARG: staging textures require BindFlags == 0.)
const Texture2dDesc = extern struct {
    width: u32,
    height: u32,
    mip_levels: u32,
    array_size: u32,
    format: u32,
    sample_count: u32,
    sample_quality: u32,
    usage: u32,
    bind_flags: u32,
    cpu_access_flags: u32,
    misc_flags: u32,
};

const MappedSubresource = extern struct {
    data: ?*anyopaque,
    row_pitch: u32,
    depth_pitch: u32,
};

// DXGIP is fixed by protocol: staging texture and convert always 1920x1280.
const staging_desc = Texture2dDesc{
    .width = STREAM_W,
    .height = STREAM_H,
    .mip_levels = 1,
    .array_size = 1,
    .format = DXGI_FORMAT_B8G8R8A8_UNORM,
    .sample_count = 1,
    .sample_quality = 0,
    .usage = D3D11_USAGE_STAGING,
    .bind_flags = 0,
    .cpu_access_flags = D3D11_CPU_ACCESS_READ,
    .misc_flags = 0,
};

// -------------------------------------------------------------- flat types

const CreateDxgiFactory1Fn = *const fn (riid: *const w.Guid, pp: *?*anyopaque) w.HRESULT;
const D3D11CreateDeviceFn = *const fn (
    adapter: ?*anyopaque,
    driver_type: u32,
    software: ?*anyopaque,
    flags: u32,
    feature_levels: [*]const u32,
    levels: u32,
    sdk: u32,
    device: *?*anyopaque,
    feature_level: *u32,
    context: *?*anyopaque,
) w.HRESULT;

var create_dxgi_factory1: ?CreateDxgiFactory1Fn = null;
var d3d11_create_device: ?D3D11CreateDeviceFn = null;

// ------------------------------------------------------------------ state

pub var frame_nv12: [FRAME_NV12]u8 = undefined;
pub var has_valid_frame = false;

var p_device: ?*anyopaque = null;
var p_context: ?*anyopaque = null;
var p_duplication: ?*anyopaque = null;
var p_staging: ?*anyopaque = null;
var p_output1: ?*anyopaque = null;

pub var origin_x: i32 = 1920;
pub var origin_y: i32 = 0;
pub var cap_w: i32 = 1920;
pub var cap_h: i32 = 1280;

fn rel(obj: ?*anyopaque) void {
    if (obj == null) return;
    const F = *const fn (?*anyopaque) u32;
    const f: F = @ptrCast(w.vtbl(obj)[SLOT_RELEASE].?);
    _ = f(obj);
}

fn qi(obj: ?*anyopaque, iid: *const w.Guid, out: *?*anyopaque) bool {
    const F = *const fn (?*anyopaque, *const w.Guid, *?*anyopaque) i32;
    const f: F = @ptrCast(w.vtbl(obj)[SLOT_QUERYINTERFACE].?);
    return f(obj, iid, out) >= 0;
}

// ---------------------------------------------------------------- convert

fn clipU8(v: i64) u8 {
    if (v < 0) return 0;
    if (v > 255) return 255;
    return @intCast(v);
}

fn bgraRowToY(src: []const u8, dst: []u8, pixels: usize) void {
    var i: usize = 0;
    while (i < pixels) : (i += 1) {
        const b: i64 = src[i * 4 + 0];
        const g: i64 = src[i * 4 + 1];
        const r: i64 = src[i * 4 + 2];
        dst[i] = clipU8(((66 * r + 129 * g + 25 * b + 128) >> 8) + 16);
    }
}

fn bgraRowsToUv(row0: []const u8, row1: []const u8, dst: []u8, pixels: usize) void {
    var x: usize = 0;
    while (x < pixels) : (x += 2) {
        var b: i64 = row0[x * 4 + 0] + row0[(x + 1) * 4 + 0] + row1[x * 4 + 0] + row1[(x + 1) * 4 + 0];
        var g: i64 = row0[x * 4 + 1] + row0[(x + 1) * 4 + 1] + row1[x * 4 + 1] + row1[(x + 1) * 4 + 1];
        var r: i64 = row0[x * 4 + 2] + row0[(x + 1) * 4 + 2] + row1[x * 4 + 2] + row1[(x + 1) * 4 + 2];
        b >>= 2;
        g >>= 2;
        r >>= 2;
        dst[x] = clipU8(((((-38 * r) - 74 * g + 112 * b + 128)) >> 8) + 128);
        dst[x + 1] = clipU8(((112 * r - 94 * g - 18 * b + 128) >> 8) + 128);
    }
}

fn convertBgraToNv12(bgra: []const u8, pitch: u32, width: u32, height: u32) void {
    const wdt: usize = width;
    const hgt: usize = height;
    const luma = frame_nv12[0 .. wdt * hgt];
    const chroma = frame_nv12[wdt * hgt .. wdt * hgt + wdt * hgt / 2];
    var y: usize = 0;
    while (y < hgt) : (y += 1) {
        bgraRowToY(bgra[y * pitch ..], luma[y * wdt ..][0..wdt], wdt);
    }
    var y2: usize = 0;
    while (y2 < hgt) : (y2 += 2) {
        bgraRowsToUv(
            bgra[y2 * pitch ..],
            bgra[(y2 + 1) * pitch ..],
            chroma[(y2 / 2) * wdt ..][0..wdt],
            wdt,
        );
    }
}

// ---------------------------------------------------------------- discovery

/// Find the MTT/Virtual PnP monitor's GDI device name (e.g. \\.\DISPLAY5).
fn findMttTargetName(out: *[64]u8) bool {
    var dd: w.DisplayDeviceA = undefined;
    var dev_idx: u32 = 0;
    while (dev_idx < 32) : (dev_idx += 1) {
        dd = std.mem.zeroes(w.DisplayDeviceA);
        dd.cb = @sizeOf(w.DisplayDeviceA);
        if (w.EnumDisplayDevicesA(null, dev_idx, &dd, 0) == 0) break;
        var mon: w.DisplayDeviceA = undefined;
        mon = std.mem.zeroes(w.DisplayDeviceA);
        mon.cb = @sizeOf(w.DisplayDeviceA);
        // EnumDisplayDevicesA needs the device name as a C string
        var name_z: [33]u8 = undefined;
        const raw = sliceZ(&dd.device_name);
        if (raw.len == 0 or raw.len >= name_z.len) continue;
        @memcpy(name_z[0..raw.len], raw);
        name_z[raw.len] = 0;
        if (w.EnumDisplayDevicesA(name_z[0..raw.len :0], 0, &mon, 0) == 0) continue;
        const id = sliceZ(&mon.device_id);
        const dev_str = sliceZ(&mon.device_string);
        if (contains(id, "MTT") or contains(id, "mtt") or contains(dev_str, "Virtual")) {
            @memcpy(out[0..raw.len], raw);
            out[raw.len] = 0;
            return true;
        }
    }
    return false;
}

fn contains(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

fn sliceZ(buf: []const u8) []const u8 {
    const n = std.mem.indexOfScalar(u8, buf, 0) orelse buf.len;
    return buf[0..n];
}

/// ASCII GDI name -> UTF-16 (target names are plain ASCII: \\.\DISPLAYn).
fn asciiToWide(src: []const u8, out: []u16) usize {
    var n: usize = 0;
    while (n < src.len and n < out.len) : (n += 1) out[n] = src[n];
    return n;
}

fn wideEql(a: []const u16, b: []const u16) bool {
    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        if (i < b.len) {
            if (a[i] != b[i]) return false;
        } else {
            if (a[i] != 0) return false;
        }
    }
    return b.len <= a.len;
}

// ------------------------------------------------------------------ init

const SearchOut = struct {
    adapter: ?*anyopaque = null,
    output: ?*anyopaque = null,
};

/// Find the DXGI output with this GDI device name; on success fills origin/cap globals.
fn searchOutput(p_factory: ?*anyopaque, name_wide: []const u16) SearchOut {
    const EnumAdapters1F = *const fn (?*anyopaque, u32, *?*anyopaque) i32;
    const EnumOutputsF = *const fn (?*anyopaque, u32, *?*anyopaque) i32;
    const GetDescOutF = *const fn (?*anyopaque, *DxgiOutputDesc) i32;

    var out: SearchOut = .{};
    var ai: u32 = 0;
    while (out.output == null) : (ai += 1) {
        const enum_adapters: EnumAdapters1F = @ptrCast(w.vtbl(p_factory)[SLOT_ENUMADAPTERS1].?);
        var p_adapter: ?*anyopaque = null;
        if (enum_adapters(p_factory, ai, &p_adapter) != 0 or p_adapter == null) break;

        var oi: u32 = 0;
        while (true) : (oi += 1) {
            const enum_outputs: EnumOutputsF = @ptrCast(w.vtbl(p_adapter)[SLOT_ENUMOUTPUTS].?);
            var p_output: ?*anyopaque = null;
            if (enum_outputs(p_adapter, oi, &p_output) != 0 or p_output == null) break;

            var desc: DxgiOutputDesc = std.mem.zeroes(DxgiOutputDesc);
            const get_desc: GetDescOutF = @ptrCast(w.vtbl(p_output)[SLOT_OUTPUT_GETDESC].?);
            _ = get_desc(p_output, &desc);

            if (wideEql(desc.device_name[0..32], name_wide)) {
                var p_out1: ?*anyopaque = null;
                if (qi(p_output, &IID_IDXGIOUTPUT1, &p_out1)) {
                    out.output = p_out1;
                    origin_x = desc.desktop_coordinates.left;
                    origin_y = desc.desktop_coordinates.top;
                    cap_w = desc.desktop_coordinates.right - desc.desktop_coordinates.left;
                    cap_h = desc.desktop_coordinates.bottom - desc.desktop_coordinates.top;
                }
                rel(p_output);
                if (out.output != null) break;
            }
            rel(p_output);
        }

        if (out.output != null) {
            out.adapter = p_adapter; // keep: device must be created on this adapter
        } else {
            rel(p_adapter);
        }
    }
    return out;
}

pub fn captureInit() bool {
    // Attach this thread to the interactive "Default" desktop so DXGI duplication is allowed.
    const desk = w.OpenDesktopA("Default", 0, 0, w.DESKTOP_READOBJECTS | w.DESKTOP_WRITEOBJECTS | w.DESKTOP_SWITCHDESKTOP);
    if (desk) |d| _ = w.SetThreadDesktop(d);

    @memset(frame_nv12[0 .. STREAM_W * STREAM_H], 16);
    @memset(frame_nv12[STREAM_W * STREAM_H ..][0 .. STREAM_W * STREAM_H / 2], 128);
    has_valid_frame = false;

    if (create_dxgi_factory1 == null) {
        create_dxgi_factory1 = w.loadSym(CreateDxgiFactory1Fn, "dxgi.dll", "CreateDXGIFactory1");
        d3d11_create_device = w.loadSym(D3D11CreateDeviceFn, "d3d11.dll", "D3D11CreateDevice");
    }
    if (create_dxgi_factory1 == null or d3d11_create_device == null) {
        w.logz("Failed to load dxgi/d3d11\n", .{});
        return false;
    }

    var p_factory: ?*anyopaque = null;
    var hr = create_dxgi_factory1.?(&IID_IDXGIFACTORY1, &p_factory);
    if (!w.hrOk(hr) or p_factory == null) {
        w.logz("Failed to create DXGI Factory 1 (hr=0x{X:0>8})\n", .{@as(u32, @bitCast(hr))});
        return false;
    }
    defer rel(p_factory);

    // Pick the target output: MTT monitor if present, else DISPLAY5, else DISPLAY6.
    var target_ascii: [64]u8 = undefined;
    var target_len: usize = 0;
    const found_mtt = findMttTargetName(&target_ascii);
    if (found_mtt) {
        target_len = sliceZ(target_ascii[0..]).len;
    } else {
        const fb = "\\\\.\\DISPLAY5";
        @memcpy(target_ascii[0..fb.len], fb);
        target_len = fb.len;
    }

    var target_wide: [64]u16 = undefined;
    var target_wlen = asciiToWide(target_ascii[0..target_len], &target_wide);

    var chosen: SearchOut = searchOutput(p_factory, target_wide[0..target_wlen]);

    if (chosen.adapter == null and !found_mtt) {
        const fb6 = "\\\\.\\DISPLAY6";
        target_len = fb6.len;
        @memcpy(target_ascii[0..fb6.len], fb6);
        target_wlen = asciiToWide(target_ascii[0..target_len], &target_wide);
        chosen = searchOutput(p_factory, target_wide[0..target_wlen]);
    }
    const chosen_adapter = chosen.adapter;
    const chosen_output = chosen.output;

    if (chosen_adapter == null or chosen_output == null) {
        w.logz("Target DXGI output '{s}' not found!\n", .{target_ascii[0..target_len]});
        return false;
    }
    defer rel(chosen_adapter);
    // Take ownership of the output now so captureCleanup covers every failure path.
    p_output1 = chosen_output;

    const levels = [_]u32{ 0xB100, 0xB000, 0xA100 }; // 11.1, 11.0, 10.1
    var feature_level: u32 = 0;
    hr = d3d11_create_device.?(
        chosen_adapter,
        D3D_DRIVER_TYPE_UNKNOWN,
        null,
        D3D11_CREATE_DEVICE_BGRA_SUPPORT,
        &levels,
        @intCast(levels.len),
        D3D11_SDK_VERSION,
        &p_device,
        &feature_level,
        &p_context,
    );
    if (!w.hrOk(hr) or p_device == null or p_context == null) {
        w.logz("D3D11CreateDevice failed (hr=0x{X:0>8})\n", .{@as(u32, @bitCast(hr))});
        return false;
    }
    const DupF = *const fn (?*anyopaque, ?*anyopaque, *?*anyopaque) i32;
    const dup: DupF = @ptrCast(w.vtbl(p_output1)[SLOT_DUPLICATE_OUTPUT].?);
    hr = dup(p_output1, p_device, &p_duplication);
    if (!w.hrOk(hr) or p_duplication == null) {
        w.logz("DXGI DuplicateOutput failed (hr=0x{X:0>8})\n", .{@as(u32, @bitCast(hr))});
        return false;
    }

    const CreateTexF = *const fn (?*anyopaque, *const Texture2dDesc, ?*anyopaque, *?*anyopaque) i32;
    const create_tex: CreateTexF = @ptrCast(w.vtbl(p_device)[SLOT_CREATE_TEXTURE2D].?);
    hr = create_tex(p_device, &staging_desc, null, &p_staging);
    if (!w.hrOk(hr) or p_staging == null) {
        w.logz("Failed to create D3D11 staging texture (hr=0x{X:0>8})\n", .{@as(u32, @bitCast(hr))});
        return false;
    }

    // Warm up: trigger initial frame acquisition.
    var warmup: i32 = 0;
    while (warmup < 10 and !has_valid_frame) : (warmup += 1) {
        _ = captureScreen();
        if (!has_valid_frame) w.Sleep(30);
    }

    w.logz("DXGI Desktop Duplication initialized: {s} ({d}x{d} at {d},{d}, ready={})\n", .{
        target_ascii[0..target_len],
        STREAM_W,
        STREAM_H,
        origin_x,
        origin_y,
        has_valid_frame,
    });
    return true;
}

pub fn captureCleanup() void {
    if (p_staging != null) {
        rel(p_staging);
        p_staging = null;
    }
    if (p_duplication != null) {
        rel(p_duplication);
        p_duplication = null;
    }
    if (p_output1 != null) {
        rel(p_output1);
        p_output1 = null;
    }
    if (p_context != null) {
        rel(p_context);
        p_context = null;
    }
    if (p_device != null) {
        rel(p_device);
        p_device = null;
    }
    has_valid_frame = false;
}

const FrameInfo = extern struct {
    last_present_time: i64,
    last_mouse_update_time: i64,
    accumulated_frames: u32,
    rest: [112]u8,
};

/// Grab one frame via DXGI Desktop Duplication and convert to NV12.
/// FALSE on timeout/static desktop/access loss (caller paces the loop).
pub fn captureScreen() bool {
    if (p_duplication == null or p_context == null or p_staging == null) return false;

    const AcqF = *const fn (?*anyopaque, u32, *FrameInfo, *?*anyopaque) i32;
    const acq: AcqF = @ptrCast(w.vtbl(p_duplication)[SLOT_ACQUIRE_FRAME].?);

    var frame_info: FrameInfo = std.mem.zeroes(FrameInfo);
    var p_res: ?*anyopaque = null;
    const hr = acq(p_duplication, 10, &frame_info, &p_res);

    if (w.hrIs(hr, DXGI_ERROR_WAIT_TIMEOUT)) return false;

    if (w.hrIs(hr, DXGI_ERROR_ACCESS_LOST)) {
        if (p_duplication != null) {
            rel(p_duplication);
            p_duplication = null;
        }
        if (p_output1 != null and p_device != null) {
            const DupF = *const fn (?*anyopaque, ?*anyopaque, *?*anyopaque) i32;
            const dup: DupF = @ptrCast(w.vtbl(p_output1)[SLOT_DUPLICATE_OUTPUT].?);
            _ = dup(p_output1, p_device, &p_duplication);
        }
        return false;
    }

    const RelF = *const fn (?*anyopaque) i32;
    const release_frame: RelF = @ptrCast(w.vtbl(p_duplication)[SLOT_RELEASE_FRAME].?);

    if (!w.hrOk(hr) or p_res == null) return false;

    var p_tex: ?*anyopaque = null;
    if (qi(p_res, &IID_ID3D11TEXTURE2D, &p_tex)) {
        // Skip duplicate presents: nothing new since the last frame.
        if (frame_info.last_present_time == 0) {
            rel(p_tex);
            rel(p_res);
            _ = release_frame(p_duplication);
            return false;
        }
        const CopyF = *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque) void;
        const copy: CopyF = @ptrCast(w.vtbl(p_context)[SLOT_COPY_RESOURCE].?);
        copy(p_context, p_staging, p_tex);
        rel(p_tex);
        rel(p_res);
        _ = release_frame(p_duplication);

        // Map(ID3D11Resource*, MapType, Subresource, MapFlags, MappedSubresource*):
        // the missing Subresource arg was silently shifting the out-ptr into MapFlags.
        const MapF = *const fn (?*anyopaque, ?*anyopaque, u32, u32, u32, *MappedSubresource) i32;
        const map: MapF = @ptrCast(w.vtbl(p_context)[SLOT_MAP].?);
        var mapped: MappedSubresource = std.mem.zeroes(MappedSubresource);
        const mhr = map(p_context, p_staging, 0, D3D11_MAP_READ, 0, &mapped);
        if (mhr >= 0 and mapped.data != null) {
            const bytes: [*]const u8 = @ptrCast(mapped.data.?);
            // Valid mapped region is RowPitch * Height bytes.
            const len: usize = @as(usize, mapped.row_pitch) * STREAM_H;
            convertBgraToNv12(bytes[0..len], mapped.row_pitch, STREAM_W, STREAM_H);
            const UnmapF = *const fn (?*anyopaque, ?*anyopaque, u32) void;
            const unmap: UnmapF = @ptrCast(w.vtbl(p_context)[SLOT_UNMAP].?);
            unmap(p_context, p_staging, 0);
            has_valid_frame = true;
            return true;
        }
        return true;
    }

    rel(p_res);
    _ = release_frame(p_duplication);
    return true;
}
