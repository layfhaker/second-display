using System.Runtime.InteropServices;

namespace SecondDisplay.Host;

/// <summary>
/// Helpers for nudging the Windows display topology. Removing the virtual display
/// (Disable-PnpDevice) makes Windows reflow all monitors, and in some multi-monitor
/// setups (laptop panel + ScreenPad + VDD) it can leave the internal panel powered off.
/// Re-applying the "extend" topology is the programmatic equivalent of Win+P → Extend and
/// reliably brings every physically attached display back on.
/// </summary>
public static class DisplayConfig
{
    // SetDisplayConfig flags (wingdi.h).
    private const uint SDC_APPLY = 0x00000080;
    private const uint SDC_TOPOLOGY_EXTEND = 0x00000004;
    private const int ERROR_SUCCESS = 0;

    private const int CDS_UPDATEREGISTRY = 0x01;
    private const int DISP_CHANGE_SUCCESSFUL = 0;
    private const int ENUM_CURRENT_SETTINGS = -1;
    private const int DM_BITSPERPEL = 0x40000;
    private const int DM_PELSWIDTH = 0x80000;
    private const int DM_PELSHEIGHT = 0x100000;
    private const int DM_DISPLAYFREQUENCY = 0x400000;

    [DllImport("user32.dll")]
    private static extern int SetDisplayConfig(
        uint numPathArrayElements, IntPtr pathArray,
        uint numModeInfoArrayElements, IntPtr modeInfoArray,
        uint flags);

    [DllImport("user32.dll", CharSet = CharSet.Ansi)]
    private static extern bool EnumDisplaySettings(string? deviceName, int modeNum, ref DEVMODE devMode);

    [DllImport("user32.dll", CharSet = CharSet.Ansi)]
    private static extern int ChangeDisplaySettingsEx(
        string? lpszDeviceName, ref DEVMODE lpDevMode, IntPtr hwnd, int dwflags, IntPtr lParam);

    [DllImport("user32.dll", EntryPoint = "ChangeDisplaySettingsExA")]
    private static extern int ChangeDisplaySettingsExNoMode(
        string? lpszDeviceName, IntPtr lpDevMode, IntPtr hwnd, int dwflags, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Ansi)]
    private struct DEVMODE
    {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
        public short dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra;
        public int dmFields, dmPositionX, dmPositionY, dmDisplayOrientation, dmDisplayFixedOutput;
        public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
        public short dmLogPixels;
        public int dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency;
    }

    /// <summary>
    /// Re-apply the last-known "extend" topology across all currently attached displays.
    /// Safe to call when nothing is wrong (no-op-ish). Never throws.
    /// </summary>
    public static void RestoreExtend()
    {
        try
        {
            int rc = SetDisplayConfig(0, IntPtr.Zero, 0, IntPtr.Zero, SDC_APPLY | SDC_TOPOLOGY_EXTEND);
            Console.WriteLine(rc == ERROR_SUCCESS
                ? "[display] Extend topology restored."
                : $"[display] SetDisplayConfig(EXTEND) => {rc}");
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[display] RestoreExtend failed: {ex.Message}");
        }
    }

    // --- Per-monitor snapshot/restore -------------------------------------------
    // A blanket SetDisplayConfig(EXTEND) re-applies the database topology and resets custom
    // per-monitor modes (e.g. the ASUS ScreenXpert panel that normally runs 1000x504 instead
    // of its native 2160x1080). So around VDD add/remove we snapshot every active monitor's
    // exact mode+position and put it back afterwards.

    private sealed record SavedMode(string Device, int W, int H, int Hz, int Bpp, int X, int Y, int Orientation);
    private static List<SavedMode>? _saved;

    private const int CDS_NORESET = 0x10000000;
    private const int CDS_SET_PRIMARY = 0x10;
    private const int DM_POSITION = 0x20;
    private const int DM_DISPLAYORIENTATION = 0x80;
    private const int DISPLAY_DEVICE_ATTACHED_TO_DESKTOP = 0x1;

    [DllImport("user32.dll", CharSet = CharSet.Ansi)]
    private static extern bool EnumDisplayDevices(string? lpDevice, uint iDevNum, ref DISPLAY_DEVICE lpDisplayDevice, uint dwFlags);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Ansi)]
    private struct DISPLAY_DEVICE
    {
        public int cb;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
        public int StateFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
    }

    /// <summary>Snapshots every active monitor's current mode + position. Call before adding the VDD.</summary>
    public static void SaveCurrent()
    {
        var list = new List<SavedMode>();
        try
        {
            var dd = new DISPLAY_DEVICE { cb = Marshal.SizeOf<DISPLAY_DEVICE>() };
            for (uint i = 0; EnumDisplayDevices(null, i, ref dd, 0); i++)
            {
                if ((dd.StateFlags & DISPLAY_DEVICE_ATTACHED_TO_DESKTOP) == 0) continue;
                var dm = new DEVMODE { dmSize = (short)Marshal.SizeOf<DEVMODE>() };
                if (!EnumDisplaySettings(dd.DeviceName, ENUM_CURRENT_SETTINGS, ref dm)) continue;
                list.Add(new SavedMode(dd.DeviceName, dm.dmPelsWidth, dm.dmPelsHeight,
                    dm.dmDisplayFrequency, dm.dmBitsPerPel, dm.dmPositionX, dm.dmPositionY, dm.dmDisplayOrientation));
            }
            _saved = list;
            Console.WriteLine($"[display] Saved layout: {string.Join(", ", list.ConvertAll(m => $"{m.Device} {m.W}x{m.H}@({m.X},{m.Y})"))}");
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[display] SaveCurrent failed: {ex.Message}");
        }
    }

    /// <summary>
    /// Restores modes/positions saved by <see cref="SaveCurrent"/> after the VDD is removed.
    /// Returns false (caller should fall back to <see cref="RestoreExtend"/>) if there is no
    /// snapshot or any monitor could not be restored.
    /// </summary>
    public static bool RestoreSaved()
    {
        if (_saved == null || _saved.Count == 0) return false;
        bool ok = true;
        try
        {
            foreach (var m in _saved)
            {
                var dm = new DEVMODE { dmSize = (short)Marshal.SizeOf<DEVMODE>() };
                if (!EnumDisplaySettings(m.Device, ENUM_CURRENT_SETTINGS, ref dm)) { ok = false; continue; }
                if (dm.dmPelsWidth == m.W && dm.dmPelsHeight == m.H && dm.dmPositionX == m.X && dm.dmPositionY == m.Y)
                    continue; // already correct
                dm.dmPelsWidth = m.W;
                dm.dmPelsHeight = m.H;
                dm.dmDisplayFrequency = m.Hz;
                dm.dmBitsPerPel = m.Bpp;
                dm.dmPositionX = m.X;
                dm.dmPositionY = m.Y;
                dm.dmDisplayOrientation = m.Orientation;
                dm.dmFields = DM_BITSPERPEL | DM_PELSWIDTH | DM_PELSHEIGHT | DM_DISPLAYFREQUENCY | DM_POSITION | DM_DISPLAYORIENTATION;
                int rc = ChangeDisplaySettingsEx(m.Device, ref dm, IntPtr.Zero, CDS_UPDATEREGISTRY | CDS_NORESET, IntPtr.Zero);
                if (rc != DISP_CHANGE_SUCCESSFUL)
                {
                    Console.WriteLine($"[display] restore {m.Device} -> {m.W}x{m.H} failed rc={rc}");
                    ok = false;
                }
            }
            // Commit all NORESET changes in one go.
            int finalRc = ChangeDisplaySettingsExNoMode(null, IntPtr.Zero, IntPtr.Zero, 0, IntPtr.Zero);
            if (finalRc != DISP_CHANGE_SUCCESSFUL) ok = false;
            Console.WriteLine(ok ? "[display] Saved layout restored." : $"[display] Layout restore incomplete (rc={finalRc}).");
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[display] RestoreSaved failed: {ex.Message}");
            ok = false;
        }
        return ok;
    }

    /// <summary>Makes the given display the primary one (moves it to origin (0,0)).</summary>
    public static bool SetPrimary(string device)
    {
        try
        {
            var dm = new DEVMODE { dmSize = (short)Marshal.SizeOf<DEVMODE>() };
            if (!EnumDisplaySettings(device, ENUM_CURRENT_SETTINGS, ref dm)) return false;
            dm.dmPositionX = 0;
            dm.dmPositionY = 0;
            dm.dmFields = DM_POSITION;
            int rc = ChangeDisplaySettingsEx(device, ref dm, IntPtr.Zero,
                CDS_UPDATEREGISTRY | CDS_SET_PRIMARY | CDS_NORESET, IntPtr.Zero);
            ChangeDisplaySettingsExNoMode(null, IntPtr.Zero, IntPtr.Zero, 0, IntPtr.Zero);
            Console.WriteLine($"[display] SetPrimary({device}) rc={rc}");
            return rc == DISP_CHANGE_SUCCESSFUL;
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[display] SetPrimary failed: {ex.Message}");
            return false;
        }
    }

    /// <summary>Moves a display's top-left corner to (x, y) in desktop coordinates.</summary>
    public static bool MoveTo(string device, int x, int y)
    {
        try
        {
            var dm = new DEVMODE { dmSize = (short)Marshal.SizeOf<DEVMODE>() };
            if (!EnumDisplaySettings(device, ENUM_CURRENT_SETTINGS, ref dm)) return false;
            dm.dmPositionX = x;
            dm.dmPositionY = y;
            dm.dmFields = DM_POSITION;
            int rc = ChangeDisplaySettingsEx(device, ref dm, IntPtr.Zero, CDS_UPDATEREGISTRY | CDS_NORESET, IntPtr.Zero);
            ChangeDisplaySettingsExNoMode(null, IntPtr.Zero, IntPtr.Zero, 0, IntPtr.Zero);
            Console.WriteLine($"[display] MoveTo({device}, {x},{y}) rc={rc}");
            return rc == DISP_CHANGE_SUCCESSFUL;
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[display] MoveTo failed: {ex.Message}");
            return false;
        }
    }

    /// <summary>
    /// Set a monitor to width×height@refreshHz if that mode is advertised.
    /// Falls back to any matching resolution (any refresh), then fails quietly.
    /// Used after VDD appears so we don't stream the driver's default 800×600.
    /// </summary>
    public static bool TrySetMode(string deviceName, int width, int height, int refreshHz = 60)
    {
        try
        {
            var dm = new DEVMODE { dmSize = (short)Marshal.SizeOf<DEVMODE>() };

            // Prefer exact refresh; otherwise any mode with the right size.
            int foundHz = -1;
            for (int i = 0; EnumDisplaySettings(deviceName, i, ref dm); i++)
            {
                if (dm.dmPelsWidth != width || dm.dmPelsHeight != height) continue;
                if (dm.dmDisplayFrequency == refreshHz) { foundHz = refreshHz; break; }
                if (foundHz < 0) foundHz = dm.dmDisplayFrequency;
            }
            if (foundHz < 0)
            {
                Console.WriteLine($"[display] {deviceName}: no {width}x{height} mode advertised");
                return false;
            }

            // Load current settings so we preserve position / orientation.
            dm = new DEVMODE { dmSize = (short)Marshal.SizeOf<DEVMODE>() };
            if (!EnumDisplaySettings(deviceName, ENUM_CURRENT_SETTINGS, ref dm))
            {
                Console.WriteLine($"[display] {deviceName}: EnumDisplaySettings(current) failed");
                return false;
            }

            if (dm.dmPelsWidth == width && dm.dmPelsHeight == height && dm.dmDisplayFrequency == foundHz)
            {
                Console.WriteLine($"[display] {deviceName} already {width}x{height}@{foundHz}");
                return true;
            }

            dm.dmPelsWidth = width;
            dm.dmPelsHeight = height;
            dm.dmDisplayFrequency = foundHz;
            dm.dmBitsPerPel = 32;
            dm.dmFields = DM_PELSWIDTH | DM_PELSHEIGHT | DM_DISPLAYFREQUENCY | DM_BITSPERPEL;

            int rc = ChangeDisplaySettingsEx(deviceName, ref dm, IntPtr.Zero, CDS_UPDATEREGISTRY, IntPtr.Zero);
            if (rc != DISP_CHANGE_SUCCESSFUL)
            {
                Console.WriteLine($"[display] ChangeDisplaySettingsEx({deviceName} {width}x{height}@{foundHz}) => {rc}");
                return false;
            }

            Console.WriteLine($"[display] {deviceName} -> {width}x{height}@{foundHz}");
            return true;
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[display] TrySetMode failed: {ex.Message}");
            return false;
        }
    }
}
