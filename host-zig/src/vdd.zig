const std = @import("std");
const w = @import("win.zig");

var vdd_active = false;

fn containsIgnoreCase(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or hay.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        var ok = true;
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            if (std.ascii.toLower(hay[i + j]) != std.ascii.toLower(needle[j])) {
                ok = false;
                break;
            }
        }
        if (ok) return true;
    }
    return false;
}

/// Remove MTT phantom monitors so disabling the driver drops them from the topology.
fn detachPhantoms() void {
    var dd: w.DisplayDeviceA = undefined;
    var i: u32 = 0;
    while (i < 16) : (i += 1) {
        dd = std.mem.zeroes(w.DisplayDeviceA);
        dd.cb = @sizeOf(w.DisplayDeviceA);
        if (w.EnumDisplayDevicesA(null, i, &dd, 0) == 0) break;
        var mon: w.DisplayDeviceA = undefined;
        mon = std.mem.zeroes(w.DisplayDeviceA);
        mon.cb = @sizeOf(w.DisplayDeviceA);
        const name_z = nameToZ(&dd) orelse continue;
        if (w.EnumDisplayDevicesA(name_z, 0, &mon, 0) == 0) continue;
        const id = sliceZ(&mon.device_id);
        if (containsIgnoreCase(id, "MTT")) {
            w.logz("Removing phantom monitor: {s}\n", .{sliceZ(&dd.device_name)});
            _ = w.ChangeDisplaySettingsExA(name_z, null, null, 0x00000008, null);
        }
    }
    w.Sleep(100);
}

fn sliceZ(buf: []const u8) []const u8 {
    const n = std.mem.indexOfScalar(u8, buf, 0) orelse buf.len;
    return buf[0..n];
}

/// device_name as a NUL-terminated stack buffer (EnumDisplayDevices needs LPCSTR).
threadlocal var name_storage: [33]u8 = undefined;
fn nameToZ(dd: *w.DisplayDeviceA) ?[*:0]const u8 {
    const s = sliceZ(&dd.device_name);
    if (s.len == 0 or s.len >= name_storage.len) return null;
    @memcpy(name_storage[0..s.len], s);
    name_storage[s.len] = 0;
    return name_storage[0..s.len :0];
}

pub fn enable() void {
    if (vdd_active) return;
    w.logz("Enabling Virtual Display Driver (ROOT\\DISPLAY\\0000)...\n", .{});
    w.runHidden("pnputil.exe /enable-device \"ROOT\\DISPLAY\\0000\"");
    w.runHidden("powershell.exe -NoProfile -NonInteractive -Command \"$d = Get-PnpDevice -FriendlyName 'Virtual Display Driver' -ErrorAction SilentlyContinue; if ($d -and $d.Status -ne 'OK') { Enable-PnpDevice -InstanceId $d.InstanceId -Confirm:$false }\"");
    w.Sleep(500);
    // SDC_TOPOLOGY_SUPPLIED (0x80) | SDC_ALLOW_CHANGES (0x4): let the display
    // manager settle with the freshly enabled device, no path garbage.
    _ = w.SetDisplayConfig(0, null, 0, null, 0x00000080 | 0x00000004);
    _ = w.ChangeDisplaySettingsExA(null, null, null, 0, null);
    vdd_active = true;
    w.logz("Virtual Display Driver enabled successfully.\n", .{});
}

pub fn disable() void {
    w.logz("Disabling Virtual Display Driver (ROOT\\DISPLAY\\0000)...\n", .{});
    detachPhantoms();
    w.runHidden("pnputil.exe /disable-device \"ROOT\\DISPLAY\\0000\"");
    w.runHidden("powershell.exe -NoProfile -NonInteractive -Command \"$d = Get-PnpDevice -FriendlyName 'Virtual Display Driver' -ErrorAction SilentlyContinue; if ($d -and $d.Status -eq 'OK') { Disable-PnpDevice -InstanceId $d.InstanceId -Confirm:$false }\"");
    w.Sleep(300);
    _ = w.ChangeDisplaySettingsExA(null, null, null, 0, null);
    vdd_active = false;
    w.logz("Virtual Display Driver disabled successfully.\n", .{});
}
