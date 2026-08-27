using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading;

namespace SecondDisplay.Host;

/// <summary>
/// Controls the MikeTheTech Virtual Display Driver (MttVDD) via PowerShell PnP cmdlets.
/// </summary>
public sealed class VddController
{
    private readonly string _friendlyName;
    private DateTime _lastLogTime = DateTime.MinValue;

    public VddController(string friendlyName = "Virtual Display Driver")
    {
        _friendlyName = friendlyName;
    }

    private (int exitCode, string stdout, string stderr) RunPowerShell(string command)
    {
        var psi = new ProcessStartInfo
        {
            FileName = "powershell.exe",
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true
        };

        psi.ArgumentList.Add("-NoProfile");
        psi.ArgumentList.Add("-NonInteractive");
        psi.ArgumentList.Add("-Command");
        psi.ArgumentList.Add(command);

        Console.WriteLine($"[vdd] {command}");

        var process = Process.Start(psi);
        if (process == null)
            return (1, "", "Failed to start process");

        if (!process.WaitForExit(15000))
        {
            process.Kill();
            Console.WriteLine($"[vdd] PowerShell timeout");
            return (1, "", "Process timeout");
        }

        string stdout = process.StandardOutput.ReadToEnd();
        string stderr = process.StandardError.ReadToEnd();
        int exitCode = process.ExitCode;

        return (exitCode, stdout, stderr);
    }

    public void Enable()
    {
        string command = $"$d = Get-PnpDevice -FriendlyName '{_friendlyName}' -ErrorAction SilentlyContinue; if ($d) {{ Enable-PnpDevice -InstanceId $d.InstanceId -Confirm:$false; 'OK' }} else {{ 'NOTFOUND' }}";

        try
        {
            var (exitCode, stdout, stderr) = RunPowerShell(command);

            if (exitCode != 0 && stderr.Contains("Access is denied", StringComparison.OrdinalIgnoreCase))
            {
                Console.WriteLine("[vdd] Enable failed — needs administrator (run host with highest privileges).");
                throw new InvalidOperationException("Access denied: administrator privileges required");
            }

            if (stdout.Contains("NOTFOUND"))
            {
                Console.WriteLine("[vdd] Enable: device not found");
            }
        }
        catch (InvalidOperationException)
        {
            throw;
        }
        catch (Exception ex)
        {
            throw new InvalidOperationException($"Enable failed: {ex.Message}", ex);
        }
    }

    public void Disable()
    {
        // Remove phantom monitors from display topology BEFORE disabling the driver,
        // otherwise Disable-PnpDevice leaves the phantom visible to EnumDisplayDevices.
        RemoveVddMonitors();

        string command = $"$d = Get-PnpDevice -FriendlyName '{_friendlyName}' -ErrorAction SilentlyContinue; if ($d) {{ Disable-PnpDevice -InstanceId $d.InstanceId -Confirm:$false; 'OK' }} else {{ 'NOTFOUND' }}";

        try
        {
            var (exitCode, stdout, stderr) = RunPowerShell(command);

            if (exitCode != 0 && stderr.Contains("Access is denied", StringComparison.OrdinalIgnoreCase))
            {
                Console.WriteLine("[vdd] Disable failed — needs administrator (run host with highest privileges).");
                throw new InvalidOperationException("Access denied: administrator privileges required");
            }

            if (stdout.Contains("NOTFOUND"))
            {
                Console.WriteLine("[vdd] Disable: device not found");
            }
        }
        catch (InvalidOperationException)
        {
            throw;
        }
        catch (Exception ex)
        {
            throw new InvalidOperationException($"Disable failed: {ex.Message}", ex);
        }
    }

    public bool IsEnabled()
    {
        string command = $"$d = Get-PnpDevice -FriendlyName '{_friendlyName}' -ErrorAction SilentlyContinue; if ($d) {{ $d.Status }} else {{ 'NONE' }}";

        try
        {
            var (exitCode, stdout, _) = RunPowerShell(command);
            if (exitCode != 0)
                return false;

            string status = stdout.Trim();
            return status.Contains("OK");
        }
        catch
        {
            return false;
        }
    }

    public ScreenCapture.MonitorInfo? WaitForMonitor(
        IReadOnlyList<ScreenCapture.MonitorInfo> before, int timeoutMs = 8000)
    {
        var beforeDevices = new HashSet<string>(before.Select(m => m.Device));
        long startTicks = DateTime.Now.Ticks;
        long timeoutTicks = timeoutMs * 10000L;

        while (true)
        {
            try
            {
                var current = ScreenCapture.GetMonitors();

                // Log at most once per second
                DateTime now = DateTime.Now;
                if ((now - _lastLogTime).TotalSeconds >= 1.0)
                {
                    _lastLogTime = now;
                    var formatted = string.Join(", ", current.Select(m =>
                        $"[{m.Index}] {m.Device} {m.Width}x{m.Height} @({m.X},{m.Y}){(m.Primary ? " primary" : "")}"));
                    Console.WriteLine($"[vdd] monitors: {formatted}");
                }

                // Find new monitors. NOTE: on some layouts the VDD comes up as the PRIMARY
                // display — accept it anyway (orchestrator fixes primary afterwards).
                var newMonitors = current
                    .Where(m => !beforeDevices.Contains(m.Device))
                    .ToList();

                if (newMonitors.Count == 1)
                {
                    if (newMonitors[0].Primary)
                        Console.WriteLine($"[vdd] New monitor {newMonitors[0].Device} came up as PRIMARY (will be corrected)");
                    return newMonitors[0];
                }

                if (newMonitors.Count > 1)
                {
                    // Prefer one with aspect ratio close to 3:2 (1.3 to 1.55)
                    var preferred = newMonitors.FirstOrDefault(m =>
                    {
                        double aspectRatio = (double)m.Width / m.Height;
                        return aspectRatio >= 1.3 && aspectRatio <= 1.55;
                    });

                    if (preferred.Device != null)
                    {
                        Console.WriteLine($"[vdd] Multiple new monitors; selected {preferred.Device} (aspect ratio close to 3:2)");
                        return preferred;
                    }

                    // Fallback: return the first one
                    Console.WriteLine($"[vdd] Multiple new monitors; selected first: {newMonitors[0].Device}");
                    return newMonitors[0];
                }

                // Check timeout
                if ((DateTime.Now.Ticks - startTicks) > timeoutTicks)
                {
                    // VDD phantom from a previous session may already be present —
                    // the driver re-creates it after Disable on some systems.  Detect
                    // it by matching the PnP vendor ID (MTT1337) via EnumDisplayDevices.
                    var fallback = FindVddMonitor(current);
                    if (fallback != null)
                    {
                        Console.WriteLine($"[vdd] VDD phantom already present: {fallback.Value.Device} {fallback.Value.Width}x{fallback.Value.Height} — reusing");
                        return fallback;
                    }
                    Console.WriteLine("[vdd] WaitForMonitor timeout");
                    return null;
                }

                Thread.Sleep(250);
            }
            catch (Exception ex)
            {
                Console.WriteLine($"[vdd] WaitForMonitor error: {ex.Message}");
                return null;
            }
        }
    }

    /// <summary>
    /// Actively remove any VDD-originated monitors from the display topology.
    /// Disable-PnpDevice does NOT clean up the phantom — Windows keeps it in display
    /// settings until we explicitly detach it via ChangeDisplaySettingsEx(DETOACH).
    /// </summary>
    private void RemoveVddMonitors()
    {
        try
        {
            var vddNames = new List<string>();
            var dd = new NativeMethods.DISPLAY_DEVICE { cb = Marshal.SizeOf<NativeMethods.DISPLAY_DEVICE>() };
            for (int i = 0; NativeMethods.EnumDisplayDevices(null, i, ref dd, 0); i++)
            {
                var monDd = new NativeMethods.DISPLAY_DEVICE { cb = Marshal.SizeOf<NativeMethods.DISPLAY_DEVICE>() };
                if (NativeMethods.EnumDisplayDevices(dd.DeviceName, 0, ref monDd, 0))
                {
                    if (monDd.DeviceID.Contains("MTT", StringComparison.OrdinalIgnoreCase))
                        vddNames.Add(dd.DeviceName);
                }
                dd.cb = Marshal.SizeOf<NativeMethods.DISPLAY_DEVICE>();
            }
            if (vddNames.Count == 0) return;

            foreach (string devName in vddNames)
            {
                Console.WriteLine($"[vdd] Removing phantom monitor: {devName}");
                NativeMethods.ChangeDisplaySettingsEx(devName, IntPtr.Zero, IntPtr.Zero, 0x08 /*DETACH*/, IntPtr.Zero);
            }
            Thread.Sleep(500);
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[vdd] RemoveVddMonitors failed (non-fatal): {ex.Message}");
        }
    }

    /// <summary>
    /// Find the VDD monitor (MTT1337 PnP vendor) among the current monitors.
    /// Returns null if no VDD output is present.
    /// </summary>
    private static ScreenCapture.MonitorInfo? FindVddMonitor(IReadOnlyList<ScreenCapture.MonitorInfo> monitors)
    {
        try
        {
            var displayToPath = new Dictionary<string, string>();
            var dd = new NativeMethods.DISPLAY_DEVICE { cb = Marshal.SizeOf<NativeMethods.DISPLAY_DEVICE>() };
            for (int i = 0; NativeMethods.EnumDisplayDevices(null, i, ref dd, 0); i++)
            {
                var monDd = new NativeMethods.DISPLAY_DEVICE { cb = Marshal.SizeOf<NativeMethods.DISPLAY_DEVICE>() };
                if (NativeMethods.EnumDisplayDevices(dd.DeviceName, 0, ref monDd, 0))
                    displayToPath[dd.DeviceName] = monDd.DeviceID;
                dd.cb = Marshal.SizeOf<NativeMethods.DISPLAY_DEVICE>();
            }

            return monitors.FirstOrDefault(m =>
                displayToPath.TryGetValue(m.Device, out var path) &&
                path.Contains("MTT", StringComparison.OrdinalIgnoreCase));
        }
        catch { return null; }
    }

    private static class NativeMethods
    {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        public struct DISPLAY_DEVICE
        {
            public int cb;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
            public int StateFlags;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
        }

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern bool EnumDisplayDevices(string? lpDevice, int iDevNum, ref DISPLAY_DEVICE lpDisplayDevice, int dwFlags);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern int ChangeDisplaySettingsEx(string lpszDeviceName, IntPtr lpDevMode, IntPtr hWnd, uint dwFlags, IntPtr lParam);
    }
}
