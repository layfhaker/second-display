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

    private (int exitCode, string stdout, string stderr) RunAdb(params string[] args)
    {
        return RunProcess(AdbPath, args);
    }

    private (int exitCode, string stdout, string stderr) RunProcess(string fileName, params string[] args)
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

        if (!process.WaitForExit(10000))
        {
            process.Kill();
            Console.WriteLine($"[adb] Process timeout: {commandLine}");
            return (1, "", "Process timeout");
        }

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

    public IReadOnlyList<string> ListDevices()
    {
        try
        {
            var (exitCode, stdout, _) = RunAdb("devices");
            if (exitCode != 0)
                return new List<string>();

            var devices = new List<string>();
            var lines = stdout.Split('\n');
            bool inDeviceList = false;

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
                }
            }

            return devices.OrderBy(x => x).ToList();
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[adb] ListDevices failed: {ex.Message}");
            return new List<string>();
        }
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
            RunAdb("-s", serial, "reverse", "--remove", $"tcp:{_port}");
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
}
