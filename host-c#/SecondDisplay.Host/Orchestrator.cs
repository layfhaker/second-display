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
    private const int PollIntervalMs = 1000;
    private const int MissingPollsBeforeTeardown = 2; // debounce adb list blips
    private const int SessionShutdownTimeoutMs = 1000; // fast shutdown
    private const int StableConnectPolls = 2; // ~2s of uninterrupted readiness
    private const int MaxNoClientPolls = 12; // ~12s of reverse+relaunch attempts before giving up

    private readonly FpsOptions _opts;
    private readonly AdbController _adb;
    private readonly VddController _vdd;

    private string? _lastLoggedReason;
    private DateTime _lastLoggedReasonTime = DateTime.MinValue;

    private void LogReadinessState(string serial, string reason)
    {
        DateTime now = DateTime.Now;
        if (reason != _lastLoggedReason || (now - _lastLoggedReasonTime).TotalSeconds >= 10)
        {
            _lastLoggedReason = reason;
            _lastLoggedReasonTime = now;
            Console.WriteLine($"[orchestrator] Device {serial} waiting: {reason}");
        }
    }

    /// <summary>
    /// A readiness probe can fail because adb itself timed out (server hiccup, USB re-enumeration),
    /// not because the tablet is actually locked/asleep. Such failures must not be treated as a
    /// real device-state problem (they would tear a perfectly healthy session down).
    /// </summary>
    private static bool IsAdbTransientFailure(DeviceReadiness readiness) =>
        readiness.Reason.Contains("adb shell command failed", StringComparison.OrdinalIgnoreCase) ||
        readiness.Reason.Contains("Readiness check failed", StringComparison.OrdinalIgnoreCase);

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
            // Force a clean adb server state at startup: a stale server started at boot with
            // a different HOME / without ADB_VENDOR_KEYS keeps the tablet "unauthorized" forever.
            // A fresh server re-reads the keys and the tablet comes up as "device" on its own.
            _adb.RestartServer("startup");
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

    /// <summary>First device (sorted) that is on ADB, has our app installed, and is ready (unlocked + MTP), or null.</summary>
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
            if (!hasApp) continue;

            var readiness = _adb.GetDeviceReadiness(serial);
            if (!readiness.IsReady)
            {
                LogReadinessState(serial, readiness.Reason);
                continue;
            }

            return serial;
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
                }
            }

            if (DisplayConfig.TrySetMode(monitor.Device, 1920, 1280, 60))
            {
                Thread.Sleep(500); // let DXGI / desktop settle
                var refreshed = ScreenCapture.GetMonitors().FirstOrDefault(m => m.Device == monitor.Device);
                if (refreshed.Device != null)
                    monitor = refreshed;
            }

            // Always park the VDD to the right of the primary display. Windows can place it
            // at negative coordinates (e.g. y=-116) or overlapping other monitors, which causes
            // DWM to skip compositing → DXGI captures black frames → black screen on tablet.
            // Unconditional positioning avoids relying on Windows' often-unpredictable auto-layout.
            {
                var primary = ScreenCapture.GetMonitors().FirstOrDefault(m => m.Primary);
                int targetX = primary.Device != null ? primary.X + primary.Width : 0;
                var current = ScreenCapture.GetMonitors().FirstOrDefault(m => m.Device == monitor.Device);
                if (current.Device != null && (current.X != targetX || current.Y != 0))
                {
                    Console.WriteLine($"[orchestrator] Moving VDD from ({current.X},{current.Y}) to ({targetX},0)");
                    DisplayConfig.MoveTo(monitor.Device, targetX, 0);
                    Thread.Sleep(500);
                    var repositioned = ScreenCapture.GetMonitors().FirstOrDefault(m => m.Device == monitor.Device);
                    if (repositioned.Device != null)
                        monitor = repositioned;
                }
            }

            try
            {
                // TCP transport runs through the adb reverse loopback tunnel (127.0.0.1:27315
                // on the tablet -> host). This is the stable path; RNDIS USB-Ethernet is an
                // optional future transport where adb reverse would be omitted.
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

            RunStreamingLoop(serial, localSession, sessionTask, ct);
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
    /// Waits for a tablet client to actually connect after the session started. Re-applies reverse +
    /// relaunches the client every few seconds until one connects. Returns false on timeout,
    /// cancellation, session end, unready device, or debounced device loss.
    /// </summary>
    private bool WaitForClient(StreamingSession session, string serial, Task sessionTask, CancellationToken ct)
    {
        const int totalWaitMs = 15000; // tablet is already unlocked + in MTP mode
        const int retryEveryMs = 2500;
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
                var readiness = _adb.GetDeviceReadiness(serial);
                if (!readiness.IsReady && !IsAdbTransientFailure(readiness))
                {
                    Console.WriteLine($"[orchestrator] Tablet {serial} is no longer ready ({readiness.Reason}) — aborting connection.");
                    return false;
                }
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

    /// <summary>Polls while streaming: exits on ct cancel, session completion, debounced device loss, or device unready.</summary>
    private void RunStreamingLoop(string serial, StreamingSession session, Task sessionTask, CancellationToken ct)
    {
        // Never let adb auto-restart while streaming: kill-server tears down the adb reverse tunnel
        // and kills the connected client (transient hiccup -> black screen).
        _adb.AutoRestartEnabled = false;

        int consecutiveMissing = 0;
        int consecutiveUnready = 0;
        int noClientCount = 0;

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
                // A brief adb hiccup (server timeout / USB re-enumeration) can remove the device
                // from the list while the TCP tunnel and the running client are still fine. Only
                // treat a missing device as fatal when nothing is connected either.
                if (session.HasClients)
                {
                    consecutiveMissing = 0;
                    Console.WriteLine($"[orchestrator] Device {serial} missing from adb list but the stream is alive — ignoring (transient adb blip)");
                }
                else
                {
                    consecutiveMissing++;
                    Console.WriteLine($"[orchestrator] Device {serial} missing from adb list ({consecutiveMissing}/{MissingPollsBeforeTeardown})");
                    if (consecutiveMissing >= MissingPollsBeforeTeardown)
                    {
                        Console.WriteLine($"[orchestrator] Device {serial} confirmed gone — tearing down.");
                        return;
                    }
                }
            }
            else
            {
                consecutiveMissing = 0;

                // Check device readiness: if the user locked the screen or switched USB away from MTP.
                // An adb-timeout failure is NOT a real unready state — don't count it, or a flaky adb
                // server would tear down a perfectly healthy session.
                var readiness = _adb.GetDeviceReadiness(serial);
                if (readiness.IsReady || IsAdbTransientFailure(readiness))
                {
                    consecutiveUnready = 0;
                }
                else
                {
                    consecutiveUnready++;
                    Console.WriteLine($"[orchestrator] Device {serial} not ready ({readiness.Reason}) ({consecutiveUnready}/{MissingPollsBeforeTeardown})");
                    if (consecutiveUnready >= MissingPollsBeforeTeardown)
                    {
                        Console.WriteLine($"[orchestrator] Tablet {serial} is no longer active ({readiness.Reason}) — tearing down.");
                        return;
                    }
                }

                // Client connection state. Keep re-applying the reverse tunnel + relaunching the
                // client for a while: the drop is often a transient adb/USB glitch, and a full
                // teardown (VDD off/on) costs several seconds of black.
                if (!session.HasClients)
                {
                    noClientCount++;
                    if (noClientCount == 1)
                    {
                        Console.WriteLine("[orchestrator] Client disconnected while tablet is connected. Checking Android crash logs...");
                        _adb.DumpCrashLogs(serial);
                    }

                    if (noClientCount <= MaxNoClientPolls)
                    {
                        if (readiness.IsReady || IsAdbTransientFailure(readiness))
                        {
                            Console.WriteLine($"[orchestrator] Relaunching client ({noClientCount}/{MaxNoClientPolls})...");
                            try { _adb.SetupReverse(serial); }
                            catch (Exception ex) { Console.WriteLine($"[orchestrator] reverse retry failed: {ex.Message}"); }
                            _adb.LaunchClient(serial);
                        }
                    }
                    else
                    {
                        Console.WriteLine("[orchestrator] Client did not reconnect — tearing down.");
                        return;
                    }
                }
                else
                {
                    noClientCount = 0;
                }
            }

            SleepRespectingCt(PollIntervalMs, ct);
        }
    }

    private void Teardown(string serial, StreamingSession? session, CancellationTokenSource? sessionCts, Task? sessionTask, bool vddEnabled)
    {
        Console.WriteLine("[orchestrator] Tearing down...");

        // Back to Passive: adb auto-restart is allowed again (no live tunnel to protect).
        _adb.AutoRestartEnabled = true;

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

        // Clean up the adb reverse tunnel (TCP transport over adb).
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
