using System.Diagnostics;
using System.Runtime.InteropServices;
using SecondDisplay.Host;

// Make process per-monitor DPI aware so we capture the FULL screen resolution,
// not the DPI-virtualized one (otherwise only a corner of the screen is captured).
DpiHelper.EnablePerMonitorDpiAwareness();

if (args.Length > 0 && args[0] == "--probe-d3d11")
{
    GpuProbe.Run(
        args.Length > 1 ? int.Parse(args[1]) : 1920,
        args.Length > 2 ? int.Parse(args[2]) : 1080);
    return;
}

if (args.Length > 0 && args[0] == "--selftest-gpu")
{
    DpiHelper.EnablePerMonitorDpiAwareness();
    GpuProbe.RunPipeline(
        args.Length > 1 ? int.Parse(args[1]) : -1,   // display index (-1 = primary)
        args.Length > 2 ? double.Parse(args[2]) : 5, // seconds
        args.Length > 3 ? args[3] : "selftest-gpu.h265",
        args.Length > 4 ? int.Parse(args[4]) : 60);  // encoder fps config
    return;
}

if (args.Length > 0 && args[0] == "--selftest-hevc")
{
    SelfTest.RunHevc(
        args.Length > 1 ? args[1] : "selftest.h265",
        args.Length > 3 ? int.Parse(args[2]) : 1920,
        args.Length > 3 ? int.Parse(args[3]) : 1080,
        args.Length > 4 ? int.Parse(args[4]) : 30);
    return;
}

if (args.Length > 0 && args[0] == "--auto")
{
    // Acquire the single-instance guard BEFORE touching the log file, so a blocked second
    // instance never truncates the running instance's log.
    using var single = SingleInstance.TryAcquire();
    if (single == null) { Console.WriteLine("Another SecondDisplay host is already running."); return; }

    string logPath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "SecondDisplay", "host.log");
    TeeTextWriter.Setup(logPath);

    var autoCts = new CancellationTokenSource();
    Console.CancelKeyPress += (_, e) => { e.Cancel = true; autoCts.Cancel(); };
    // Explicit Flush: the log writer is async, and the process may terminate right after this
    // handler returns, before the background writer thread gets a chance to run.
    AppDomain.CurrentDomain.UnhandledException += (_, e) =>
    {
        Console.WriteLine($"FATAL UNHANDLED: {e.ExceptionObject}");
        Console.Out.Flush();
    };

    var autoOpts = FpsOptions.FromArgs(args);
    var adb = new AdbController(GetArg(args, "--adb"));
    var vdd = new VddController();
    Console.WriteLine($"SecondDisplay Host — AUTO mode. adb={adb.AdbPath}");
    new Orchestrator(autoOpts, adb, vdd).Run(autoCts.Token);
    return;
}

using var singleInstance = SingleInstance.TryAcquire();
if (singleInstance == null)
{
    Console.WriteLine("Another SecondDisplay host is already running.");
    return;
}

Console.WriteLine("SecondDisplay Host v0.1");
Console.WriteLine("=================================================");

var opts = FpsOptions.FromArgs(args);

// Enumerate monitors so we can target the virtual display (not the primary).
var monitors = ScreenCapture.GetMonitors();
Console.WriteLine("Available monitors:");
foreach (var m in monitors)
    Console.WriteLine($"  [{m.Index}] {m.Device}  {m.Width}x{m.Height} @ ({m.X},{m.Y}){(m.Primary ? "  PRIMARY" : "")}");

// Pick capture target:
//   --display <index>   capture monitor by index from the list above
//   --region x,y,w,h    capture an explicit rectangle
// Default: the primary monitor.
int originX, originY, capW, capH;
string? captureDevice = null; // DXGI needs the monitor device name
string? regionArg = GetArg(args, "--region");
if (regionArg != null)
{
    var p = regionArg.Split(',');
    originX = int.Parse(p[0]); originY = int.Parse(p[1]); capW = int.Parse(p[2]); capH = int.Parse(p[3]);
}
else
{
    string? dispArg = GetArg(args, "--display");
    ScreenCapture.MonitorInfo target =
        dispArg != null && int.TryParse(dispArg, out var di) && di >= 0 && di < monitors.Count
            ? monitors[di]
            : (monitors.FirstOrDefault(m => m.Primary, monitors[0]));
    originX = target.X; originY = target.Y; capW = target.Width; capH = target.Height;
    captureDevice = target.Device;
    Console.WriteLine($"Capturing monitor [{target.Index}] {target.Device}");
}

var cts = new CancellationTokenSource();
Console.CancelKeyPress += (_, e) => { e.Cancel = true; cts.Cancel(); };

// Log any crash cause to the same output (native MF/D3D faults can otherwise vanish).
// Explicit Flush: the log writer is async, and the process may terminate right after this
// handler returns, before the background writer thread gets a chance to run.
AppDomain.CurrentDomain.UnhandledException += (_, e) =>
{
    Console.WriteLine($"FATAL UNHANDLED: {e.ExceptionObject}");
    Console.Out.Flush();
};

using var session = new StreamingSession(originX, originY, capW, capH, captureDevice, opts);
session.Run(cts.Token);

// "--key value" lookup over argv.
static string? GetArg(string[] a, string key)
{
    for (int i = 0; i < a.Length - 1; i++)
        if (a[i] == key) return a[i + 1];
    return null;
}

static class DpiHelper
{
    public static void EnablePerMonitorDpiAwareness()
    {
        try { SetProcessDpiAwarenessContext(new IntPtr(-4)); } // PER_MONITOR_AWARE_V2
        catch { /* older Windows — ignore */ }
    }

    [DllImport("user32.dll")]
    private static extern bool SetProcessDpiAwarenessContext(IntPtr value);
}
