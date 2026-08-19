using System.Diagnostics;
using System.Linq;
using System.Linq;
using System.Threading;

namespace SecondDisplay.Host;

/// <summary>
/// Passive background state machine: waits for the Android tablet to show up over ADB,
/// then enables the virtual display, sets up the adb reverse tunnel, streams to it, and
/// launches the client app. Tears everything down again on disconnect. Ties together
/// AdbController, VddController and StreamingSession without modifying any of them.
/// </summary>
public sealed class Orchestrator
{
    private const int PollIntervalMs = 1500;
    private const int MissingPollsBeforeTeardown = 2; // debounce adb list blips
    private const int SessionShutdownTimeoutMs = 5000;
    // The tablet responds to ADB even in "charge only" USB mode. Picking "file transfer" re-enumerates
    // USB and drops the ADB session — so require the device to be continuously present+responsive for a
    // few polls before firing, letting the user settle the USB mode first. Each re-enumeration resets it.
    private const int StableConnectPolls = 4; // ~4.5s of uninterrupted presence at PollIntervalMs

    private readonly FpsOptions _opts;
    private readonly AdbController _adb;
    private readonly VddController _vdd;

    public Orchestrator(FpsOptions opts, AdbController adb, VddController vdd)
    {
        _opts = opts;
        _adb = adb;
        _vdd = vdd;
    }

    public void Run(CancellationToken ct)
    {
        try
        {
            // Passive start: make sure there's no phantom monitor left over from a previous run.
            try { _vdd.Disable(); DisplayConfig.RestoreExtend(); }
            catch (Exception ex) { Console.WriteLine($"[orchestrator] Startup VDD.Disable failed (not admin?): {ex.Message}"); }

            _adb.StartServer();
            Console.WriteLine("[orchestrator] Passive — waiting for tablet...");

            while (!ct.IsCancellationRequested)
            {
                string? serial = PollForQualifyingDevice(ct);
                if (serial == null)
                {
                    if (ct.IsCancellationRequested) break;
                    continue;
                }

                RunConnectingAndStreaming(serial, ct);
            }
        }
        finally
        {
            // Final cleanup: never leave a phantom monitor behind.
            try { _vdd.Disable(); }
            catch (Exception ex) { Console.WriteLine($"[orchestrator] Final VDD.Disable failed: {ex.Message}"); }
            DisplayConfig.RestoreExtend();
        }
    }

    /// <summary>
    /// Polls adb until a device carrying our app has been continuously present+responsive for
    /// StableConnectPolls polls (so the USB mode has settled), or ct is cancelled. Any interruption
    /// (device drops, goes unauthorized, or a different serial appears) resets the stability counter —
    /// this rides out the USB re-enumeration that happens when the user picks "file transfer".
    /// </summary>
    private string? PollForQualifyingDevice(CancellationToken ct)
    {
        string? candidate = null;
        int stableCount = 0;

        while (!ct.IsCancellationRequested)
        {
            string? found = FindFirstQualifying(ct);

            if (found != null && found == candidate)
            {
                stableCount++;
                if (stableCount >= StableConnectPolls)
                    return candidate;
            }
            else
            {
                candidate = found;
                stableCount = found != null ? 1 : 0;
                if (found != null)
                    Console.WriteLine($"[orchestrator] Device {found} detected — waiting for USB mode to settle...");
            }

            SleepRespectingCt(PollIntervalMs, ct);
        }
        return null;
    }

    /// <summary>First device (sorted) that is on ADB and has our app installed, or null.</summary>
    private string? FindFirstQualifying(CancellationToken ct)
    {
        IReadOnlyList<string> devices;
        try { devices = _adb.ListDevices(); }
        catch (Exception ex)
        {
            Console.WriteLine($"[orchestrator] ListDevices failed: {ex.Message}");
            return null;
        }

        foreach (var serial in devices)
        {
            if (ct.IsCancellationRequested) return null;
            bool hasApp;
            try { hasApp = _adb.HasApp(serial); }
            catch (Exception ex)
            {
                Console.WriteLine($"[orchestrator] HasApp({serial}) failed: {ex.Message}");
                continue;
            }
            if (hasApp) return serial;
        }
        return null;
    }

    /// <summary>Connecting -> Streaming -> teardown for a single tablet session. Always returns to Passive.</summary>
    private void RunConnectingAndStreaming(string serial, CancellationToken ct)
    {
        StreamingSession? session = null;
        CancellationTokenSource? sessionCts = null;
        Task? sessionTask = null;
        bool vddEnabled = false;

        try
        {
            Console.WriteLine($"[orchestrator] Connecting — device {serial} has our app.");

            var before = ScreenCapture.GetMonitors();
            DisplayConfig.SaveCurrent(); // snapshot layout so we can restore it exactly after teardown
            _vdd.Enable();
            vddEnabled = true;

            var mon = _vdd.WaitForMonitor(before, 8000);
            if (mon == null)
            {
                Console.WriteLine("[orchestrator] WaitForMonitor timed out — no VDD monitor appeared.");
                return;
            }

            // VDD defaults to 800×600; force a useful tablet-ish mode from vdd_settings.xml
            // (1920×1280 @ 60). Re-query bounds after the mode change so capture matches.
            var monitor = mon.Value;

            // Sometimes the VDD steals the primary role when it appears, shoving the real
            // monitors to negative coordinates. Give primary back and park the VDD to the right.
            if (monitor.Primary)
            {
                var origPrimary = before.FirstOrDefault(m => m.Primary);
                if (origPrimary.Device != null)
                {
                    Console.WriteLine($"[orchestrator] VDD took primary — giving it back to {origPrimary.Device}");
                    DisplayConfig.SetPrimary(origPrimary.Device);
                    var others = ScreenCapture.GetMonitors().Where(m => m.Device != monitor.Device).ToList();
                    if (others.Count > 0)
                    {
                        int right = others.Max(m => m.X + m.Width);
                        DisplayConfig.MoveTo(monitor.Device, right, 0);
                    }
                    Thread.Sleep(500); // let the desktop settle after the topology shuffle
                }
            }

            if (DisplayConfig.TrySetMode(monitor.Device, 1920, 1280, 60))
            {
                Thread.Sleep(500); // let DXGI / desktop settle
                var refreshed = ScreenCapture.GetMonitors().FirstOrDefault(m => m.Device == monitor.Device);
                if (refreshed.Device != null)
                    monitor = refreshed;
            }

            try
            {
                _adb.SetupReverse(serial);
            }
            catch (Exception ex)
            {
                Console.WriteLine($"[orchestrator] SetupReverse failed: {ex.Message}");
                return;
            }

            session = new StreamingSession(monitor.X, monitor.Y, monitor.Width, monitor.Height, monitor.Device, _opts);
            sessionCts = CancellationTokenSource.CreateLinkedTokenSource(ct);

            var localSession = session;
            var localSerial = serial;
            sessionTask = Task.Run(() =>
                localSession.Run(sessionCts.Token, onServerReady: () => _adb.LaunchClient(localSerial)));

            // The tablet may not be in "data transfer" USB mode yet, and switching modes drops the
            // adb reverse tunnel — so don't treat this as connected until a client actually shows up.
            // Keep re-applying reverse + relaunching the client until it does (or the device vanishes).
            if (!WaitForClient(localSession, serial, sessionTask, ct))
            {
                Console.WriteLine("[orchestrator] No tablet client connected — tearing down.");
                return; // finally -> Teardown -> back to Passive
            }

            Console.WriteLine($"[orchestrator] Streaming to {serial} on {monitor.Device} {monitor.Width}x{monitor.Height}");

            RunStreamingLoop(serial, sessionTask, ct);
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[orchestrator] Connect/stream error: {ex.Message}");
        }
        finally
        {
            Teardown(serial, session, sessionCts, sessionTask, vddEnabled);
        }
    }

    /// <summary>
    /// Waits for a tablet client to actually connect after the session started. The tablet often
    /// isn't ready the instant its USB serial appears (user hasn't picked "data transfer" yet, or
    /// switching USB mode re-enumerates and drops the adb reverse tunnel). Re-applies reverse +
    /// relaunches the client every few seconds until one connects. Returns false on timeout,
    /// cancellation, session end, or debounced device loss.
    /// </summary>
    private bool WaitForClient(StreamingSession session, string serial, Task sessionTask, CancellationToken ct)
    {
        const int totalWaitMs = 60000; // give the user time to tap "data transfer" on the tablet
        const int retryEveryMs = 4000; // re-apply reverse + am start on this cadence
        var sw = Stopwatch.StartNew();
        long lastRetryMs = 0;
        int consecutiveMissing = 0;

        while (!ct.IsCancellationRequested && sw.ElapsedMilliseconds < totalWaitMs)
        {
            if (session.HasClients) return true;
            if (sessionTask.IsCompleted)
            {
                Console.WriteLine("[orchestrator] Session ended before a client connected.");
                return false;
            }

            IReadOnlyList<string> devices;
            try { devices = _adb.ListDevices(); }
            catch { devices = Array.Empty<string>(); }

            if (!devices.Contains(serial))
            {
                consecutiveMissing++;
                if (consecutiveMissing >= MissingPollsBeforeTeardown)
                {
                    Console.WriteLine($"[orchestrator] Device {serial} gone while waiting for client.");
                    return false;
                }
            }
            else
            {
                consecutiveMissing = 0;
            }

            if (sw.ElapsedMilliseconds - lastRetryMs >= retryEveryMs)
            {
                lastRetryMs = sw.ElapsedMilliseconds;
                Console.WriteLine("[orchestrator] Waiting for tablet — re-applying reverse + relaunching client...");
                try { _adb.SetupReverse(serial); } catch (Exception ex) { Console.WriteLine($"[orchestrator] reverse retry failed: {ex.Message}"); }
                _adb.LaunchClient(serial);
            }

            SleepRespectingCt(1000, ct);
        }

        return session.HasClients;
    }

    /// <summary>Polls while streaming: exits on ct cancel, session completion, or debounced device loss.</summary>
    private void RunStreamingLoop(string serial, Task sessionTask, CancellationToken ct)
    {
        int consecutiveMissing = 0;

        while (true)
        {
            if (ct.IsCancellationRequested) return;

            if (sessionTask.IsCompleted)
            {
                if (sessionTask.IsFaulted)
                    Console.WriteLine($"[orchestrator] Streaming session faulted: {sessionTask.Exception?.GetBaseException().Message}");
                else
                    Console.WriteLine("[orchestrator] Streaming session ended.");
                return;
            }

            IReadOnlyList<string> devices;
            try { devices = _adb.ListDevices(); }
            catch (Exception ex)
            {
                Console.WriteLine($"[orchestrator] ListDevices failed: {ex.Message}");
                devices = Array.Empty<string>();
            }

            if (!devices.Contains(serial))
            {
                consecutiveMissing++;
                Console.WriteLine($"[orchestrator] Device {serial} missing from adb list ({consecutiveMissing}/{MissingPollsBeforeTeardown})");
                if (consecutiveMissing >= MissingPollsBeforeTeardown)
                {
                    Console.WriteLine($"[orchestrator] Device {serial} confirmed gone — tearing down.");
                    return;
                }
            }
            else
            {
                consecutiveMissing = 0;
            }

            SleepRespectingCt(PollIntervalMs, ct);
        }
    }

    private void Teardown(string serial, StreamingSession? session, CancellationTokenSource? sessionCts, Task? sessionTask, bool vddEnabled)
    {
        Console.WriteLine("[orchestrator] Tearing down...");

        if (sessionCts != null)
        {
            try { sessionCts.Cancel(); }
            catch (Exception ex) { Console.WriteLine($"[orchestrator] sessionCts.Cancel failed: {ex.Message}"); }
        }

        if (sessionTask != null)
        {
            try { sessionTask.Wait(SessionShutdownTimeoutMs); }
            catch (Exception ex) { Console.WriteLine($"[orchestrator] Session task wait error: {ex.GetBaseException().Message}"); }
        }

        session?.Dispose();
        sessionCts?.Dispose();

        try { _adb.RemoveReverse(serial); }
        catch (Exception ex) { Console.WriteLine($"[orchestrator] RemoveReverse failed: {ex.Message}"); }

        if (vddEnabled)
        {
            try { _vdd.Disable(); }
            catch (Exception ex) { Console.WriteLine($"[orchestrator] Teardown VDD.Disable failed: {ex.Message}"); }

            // Removing the VDD reflows the desktop and can scramble per-monitor modes/positions
            // (or leave the internal panel off). Put back exactly what we saved before enabling it;
            // fall back to a blanket extend-topology restore if that fails.
            if (!DisplayConfig.RestoreSaved())
                DisplayConfig.RestoreExtend();
        }

        Console.WriteLine("[orchestrator] Passive — waiting for tablet...");
    }

    private static void SleepRespectingCt(int ms, CancellationToken ct)
    {
        try { Task.Delay(ms, ct).Wait(ct); }
        catch (OperationCanceledException) { /* expected on cancel */ }
        catch (AggregateException ae) when (ae.InnerException is OperationCanceledException) { /* expected */ }
    }
}
