using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;

namespace SecondDisplay.Host;

/// <summary>
/// Thin wrapper over adb.exe for controlling Android devices.
/// </summary>
public sealed class AdbController
{
    private readonly string _package;
    private readonly int _port;

    public string AdbPath { get; }

    // Consecutive adb timeout counter + restart debounce: if adb devices keeps timing out,
    // the adb server has degraded (observed after a reconnect storm). Restart it once to
    // recover, with a min interval so we don't spam kill/start on every 1.5s poll.
    private int _consecutiveTimeouts;
    private DateTime _lastTimeoutRestart = DateTime.MinValue;
    private static readonly TimeSpan TimeoutRestartMinInterval = TimeSpan.FromSeconds(20);

    public AdbController(string? adbPathOverride = null, string package = "com.seconddisplay.client", int port = 27315)
    {
        _package = package;
        _port = port;
        AdbPath = ResolveAdbPath(adbPathOverride);
    }

    private string ResolveAdbPath(string? adbPathOverride)
    {
        // Try override first
        if (!string.IsNullOrEmpty(adbPathOverride) && File.Exists(adbPathOverride))
            return adbPathOverride;

        // Try adb on PATH
        try
        {
            var (exitCode, _, _) = RunAdb("version");
            if (exitCode == 0)
                return "adb";
        }
        catch { }

        // Try default path
        string defaultPath = @"C:\Users\admin\android-build\sdk\platform-tools\adb.exe";
        if (File.Exists(defaultPath))
            return defaultPath;

        // Fallback to "adb" and hope it's on PATH
        return "adb";
    }

    // "adb devices" is polled constantly and must fail fast (a 10s hang here blinds the whole
    // orchestrator loop). Shell probes get a bit more room; everything else keeps the default.
    private const int DefaultAdbTimeoutMs = 10000;
    private const int DevicesTimeoutMs = 3000;
    private const int ShellTimeoutMs = 6000;
    private const int ReverseRemoveTimeoutMs = 3000;

    private (int exitCode, string stdout, string stderr) RunAdb(params string[] args)
        => RunAdb(DefaultAdbTimeoutMs, args);

    private (int exitCode, string stdout, string stderr) RunAdb(int timeoutMs, params string[] args)
        => RunProcess(AdbPath, timeoutMs, args);

    private (int exitCode, string stdout, string stderr) RunProcess(string fileName, int timeoutMs, params string[] args)
    {
        var psi = new ProcessStartInfo
        {
            FileName = fileName,
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true
        };

        foreach (var arg in args)
            psi.ArgumentList.Add(arg);

        // "adb devices" is polled every ~1.5s by the orchestrator watchdog — logging every
        // call drowns the host log and adds noise without diagnostic value. Log other adb
        // commands (reverse, shell, install) which are infrequent and meaningful.
        string commandLine = $"{fileName} {string.Join(" ", args)}";
        bool quiet = args.Length == 1 && args[0] == "devices";
        if (!quiet)
            Console.WriteLine($"[adb] {commandLine}");

        var process = Process.Start(psi);
        if (process == null)
            return (1, "", "Failed to start process");

        if (!process.WaitForExit(timeoutMs))
        {
            process.Kill();
            Console.WriteLine($"[adb] Process timeout ({timeoutMs}ms): {commandLine}");
            Interlocked.Increment(ref _consecutiveTimeouts);
            return (1, "", "Process timeout");
        }

        Interlocked.Exchange(ref _consecutiveTimeouts, 0); // command completed fine

        string stdout = process.StandardOutput.ReadToEnd();
        string stderr = process.StandardError.ReadToEnd();
        int exitCode = process.ExitCode;

        if (exitCode != 0)
            Console.WriteLine($"[adb] Exit code {exitCode}: {commandLine}");

        return (exitCode, stdout, stderr);
    }

    public void StartServer()
    {
        try
        {
            RunAdb("start-server");
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[adb] StartServer failed: {ex.Message}");
        }
    }

    /// <summary>
    /// Fully restarts the adb server so it re-reads the device keys from disk.
    /// A stale adb server started earlier (e.g. at boot with a different HOME / no
    /// ADB_VENDOR_KEYS) can keep presenting a key the tablet does not recognize, so
    /// devices stay "unauthorized" forever no matter how many times the cable is
    /// re-plugged. kill-server + start-server fixes that by forcing a fresh key load.
    /// </summary>
    public void RestartServer(string reason)
    {
        try
        {
            Console.WriteLine($"[adb] Restarting adb server ({reason})...");
            RunAdb("kill-server");
            RunAdb("start-server");
            Console.WriteLine("[adb] adb server restarted.");
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[adb] RestartServer failed: {ex.Message}");
        }
    }

    public IReadOnlyList<string> ListDevices()
    {
        try
        {
            var (exitCode, stdout, _) = RunAdb(DevicesTimeoutMs, "devices");
            if (exitCode != 0)
            {
                MaybeRestartForTimeouts();
                return new List<string>();
            }            var devices = new List<string>();
            var lines = stdout.Split('\n');
            bool inDeviceList = false;
            bool sawUnauthorized = false;

            foreach (var line in lines)
            {
                string trimmed = line.Trim();
                if (trimmed == "List of devices attached")
                {
                    inDeviceList = true;
                    continue;
                }

                if (!inDeviceList || string.IsNullOrEmpty(trimmed))
                    continue;

                var parts = trimmed.Split('\t');
                if (parts.Length < 2)
                    continue;

                string serial = parts[0].Trim();
                string status = parts[1].Trim();

                if (status == "device")
                {
                    devices.Add(serial);
                }
                else if (status == "unauthorized" || status == "offline" || status == "no permissions")
                {
                    Console.WriteLine($"[adb] device {serial} status={status}, skipping");
                    if (status == "unauthorized")
                        sawUnauthorized = true;
                }
            }

            // A tablet stuck in "unauthorized" usually means the adb server is using a stale
            // key (started at boot with a different HOME / no ADB_VENDOR_KEYS). Force a fresh
            // server restart so it re-reads the correct keys — the device should then come up
            // as "device" without any manual adb kill-server. Debounced so we don't restart
            // the server on every 1.5s poll (that would drop an active session).
            if (sawUnauthorized && !HasAuthorizedDevice(devices))
                MaybeRestartForUnauthorized();

            return devices.OrderBy(x => x).ToList();
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[adb] ListDevices failed: {ex.Message}");
            return new List<string>();
        }
    }

    private bool HasAuthorizedDevice(IReadOnlyList<string> devices)
    {
        // Devices list already contains only "device"-status serials.
        return devices.Count > 0;
    }

    private DateTime _lastUnauthorizedRestart = DateTime.MinValue;
    private static readonly TimeSpan UnauthorizedRestartMinInterval = TimeSpan.FromSeconds(30);

    private void MaybeRestartForUnauthorized()
    {
        DateTime now = DateTime.Now;
        if (now - _lastUnauthorizedRestart < UnauthorizedRestartMinInterval)
            return; // already tried recently — give the tablet time to show the dialog

        _lastUnauthorizedRestart = now;
        RestartServer("device unauthorized");
    }

    /// <summary>
    /// If adb devices timed out several times in a row, the adb server has degraded
    /// (observed after a reconnect storm). Restart it (debounced) so the host recovers
    /// instead of spinning on "Process timeout" forever.
    /// </summary>
    private void MaybeRestartForTimeouts()
    {
        if (_consecutiveTimeouts < 3)
            return;

        DateTime now = DateTime.Now;
        if (now - _lastTimeoutRestart < TimeoutRestartMinInterval)
            return;

        _lastTimeoutRestart = now;
        int n = _consecutiveTimeouts;
        _consecutiveTimeouts = 0;
        RestartServer($"{n} consecutive adb timeouts");
    }

    public bool HasApp(string serial)
    {
        try
        {
            var (exitCode, stdout, _) = RunAdb("-s", serial, "shell", "pm", "list", "packages", _package);
            if (exitCode != 0)
                return false;

            return stdout.Contains($"package:{_package}");
        }
        catch
        {
            return false;
        }
    }

    public void SetupReverse(string serial)
    {
        var (exitCode, _, stderr) = RunAdb("-s", serial, "reverse", $"tcp:{_port}", $"tcp:{_port}");
        if (exitCode != 0)
        {
            throw new InvalidOperationException($"SetupReverse failed for {serial}: {stderr}");
        }
    }

    public void RemoveReverse(string serial)
    {
        try
        {
            // Short timeout: this runs during teardown and used to hang ~15s when adb had degraded.
            RunAdb(ReverseRemoveTimeoutMs, "-s", serial, "reverse", "--remove", $"tcp:{_port}");
        }
        catch
        {
            // Swallow all exceptions
        }
    }

    public void LaunchClient(string serial)
    {
        string component = $"{_package}/.MainActivity";
        var (exitCode, stdout, stderr) = RunAdb("-s", serial, "shell", "am", "start", "-n", component);

        if (exitCode != 0)
        {
            Console.WriteLine($"[adb] LaunchClient warning: exit code {exitCode}");
            if (!string.IsNullOrEmpty(stdout))
                Console.WriteLine($"[adb] stdout: {stdout}");
            if (!string.IsNullOrEmpty(stderr))
                Console.WriteLine($"[adb] stderr: {stderr}");
        }
    }

    /// <summary>
    /// Checks whether the tablet is awake and unlocked. Runs a single lightweight shell command.
    /// </summary>
    public DeviceReadiness GetDeviceReadiness(string serial)
    {
        // Deliberately do NOT require MTP/PTP ("data transfer") USB mode: on ColorOS the tablet
        // often stays in "adb only" mode and gating on MTP made the host wait forever (observed:
        // 55 minutes of "USB mode is not data transfer"). adb reverse works in any USB mode; if a
        // mode switch drops the tunnel, WaitForClient re-applies it.
        string script =
            "w=$(dumpsys power 2>/dev/null | grep -m1 'mWakefulness=');" +
            "case \"$w\" in *Awake*) ;; *) echo \"SCREEN_OFF\"; exit 0;; esac;" +
            "l=$(cmd statusbar is-keyguard-locked 2>/dev/null);" +
            "if [ \"$l\" = \"true\" ]; then echo \"LOCKED\"; exit 0; fi;" +
            "echo \"READY\"";

        try
        {
            var (exitCode, stdout, _) = RunAdb(ShellTimeoutMs, "-s", serial, "shell", script);
            if (exitCode != 0)
                return new DeviceReadiness(false, "adb shell command failed");

            return DeviceReadiness.Parse(stdout);
        }
        catch (Exception ex)
        {
            return new DeviceReadiness(false, $"Readiness check failed: {ex.Message}");
        }
    }

    /// <summary>
    /// Fetches the last crash/error logs from the tablet's logcat into host console/log.
    /// </summary>
    public void DumpCrashLogs(string serial, int lines = 25)
    {
        try
        {
            var (exitCode, stdout, _) = RunAdb("-s", serial, "logcat", "-d", "-v", "time", "-t", lines.ToString(),
                "-s", "SecondDisplay:V", "AndroidRuntime:E", "CRASH:E", "DEBUG:E");

            if (exitCode == 0 && !string.IsNullOrWhiteSpace(stdout))
            {
                Console.WriteLine($"[adb-logcat] Recent Android logs from {serial}:");
                foreach (var line in stdout.Split('\n'))
                {
                    string t = line.Trim();
                    if (!string.IsNullOrEmpty(t))
                        Console.WriteLine($"  [tablet] {t}");
                }
            }
        }
        catch { }
    }
}
