using System.Diagnostics;

namespace SecondDisplay.Host;

/// <summary>
/// Owns the capture/encode/serve loop that used to live directly in Program.cs's top-level
/// statements. Behavior is unchanged — this is a mechanical extraction so a future orchestrator
/// can start/stop streaming sessions repeatedly instead of the process only ever running one.
/// </summary>
public sealed class StreamingSession : IDisposable
{
    private readonly int _originX;
    private readonly int _originY;
    private readonly int _capW;
    private readonly int _capH;
    private readonly string? _captureDevice;
    private readonly FpsOptions _opts;

    private DxgiCapture? _dxgi;
    private ScreenCapture? _gdi;
    private GpuColorConverter? _converter;
    private HevcEncoder? _encoder;
    private Server? _server;
    private bool _disposed;

    /// <summary>True once a tablet client has actually connected to the server (not just "device on USB").</summary>
    public bool HasClients => _server?.HasClients ?? false;

    public StreamingSession(int originX, int originY, int capW, int capH, string? captureDevice, FpsOptions opts)
    {
        _originX = originX;
        _originY = originY;
        _capW = capW;
        _capH = capH;
        _captureDevice = captureDevice;
        _opts = opts;
    }

    /// <summary>
    /// Sets up capture (DxgiCapture/GpuColorConverter or GDI ScreenCapture) + HevcEncoder-per-connection,
    /// starts the Server (listening on 27315), invokes onServerReady ONCE right after Server.Start() returns,
    /// then runs the capture/encode/broadcast loop until ct is cancelled. Blocks until ct fires.
    /// </summary>
    public void Run(CancellationToken ct, Action? onServerReady = null)
    {
        int originX = _originX, originY = _originY;
        bool AdaptiveFps = _opts.Adaptive;
        int MaxAdaptiveFps = _opts.MaxAdaptiveFps;
        int TargetFps = _opts.TargetFps;
        long FrameIntervalTicks = Math.Max(1, Stopwatch.Frequency / TargetFps);

        // Prefer GPU capture (DXGI Desktop Duplication): fast enough for 4K, which keeps
        // the encoder fed steadily. Fall back to GDI (slow) only if DXGI is unavailable.
        DxgiCapture? dxgi = null;
        ScreenCapture? gdi = null;
        bool forceGdi = _opts.ForceGdi;
        if (_captureDevice != null && !forceGdi)
        {
            try { dxgi = new DxgiCapture(_captureDevice); }
            catch (Exception ex) { Console.WriteLine($"DXGI unavailable ({ex.Message}); using GDI."); }
        }
        if (dxgi == null)
        {
            gdi = new ScreenCapture(originX, originY, _capW, _capH);
            Console.WriteLine($"GDI capture: {gdi.Width}x{gdi.Height} at ({originX},{originY})");
        }
        int capWidth = dxgi?.Width ?? gdi!.Width;
        int capHeight = dxgi?.Height ?? gdi!.Height;

        InputInjector.Verbose = _opts.VerboseInput;

        _dxgi = dxgi;
        _gdi = gdi;

        var server = new Server(port: 27315);
        _server = server;

        // HEVC hardware encoder (QuickSync via Media Foundation). Even dimensions required.
        // Default: encode at capture resolution. Override with --encode-width/--encode-height
        // to reduce iGPU load (e.g. --encode-width 960 on weak GPUs).
        int requestedEncW = _opts.RequestedEncW > 0 ? _opts.RequestedEncW : capWidth;
        int requestedEncH = _opts.RequestedEncH > 0
            ? _opts.RequestedEncH
            : (requestedEncW != capWidth ? (int)Math.Round(requestedEncW * (double)capHeight / capWidth) : capHeight);
        int encW = Math.Min(requestedEncW, capWidth) & ~1;
        int encH = Math.Min(requestedEncH, capHeight) & ~1;
        var nv12 = new byte[encW * encH * 3 / 2];
        bool haveFrame = false; // becomes true after first successful capture

        // Phase 4 GPU pipeline: keep the whole tract in video memory (DXGI texture → VPP BGRA→NV12 +
        // cursor → zero-copy into the encoder). Requires DXGI capture. Falls back to the CPU path.
        bool gpu = !_opts.ForceCpu && dxgi != null;
        if (_opts.ForceGpu && dxgi == null)
            Console.WriteLine("--gpu requested but DXGI unavailable; using CPU path.");
        GpuColorConverter? converter = null;
        if (gpu)
        {
            try { converter = new GpuColorConverter(dxgi!.Device, dxgi.Context, capWidth, capHeight, encW, encH, TargetFps); }
            catch (Exception ex) { Console.WriteLine($"GPU converter init failed ({ex.Message}); using CPU path."); gpu = false; }
        }
        _converter = converter;

        // Encoder is created lazily when a client connects and torn down when none remain,
        // so every new connection's first frame carries fresh VPS/SPS/PPS + an IDR.
        HevcEncoder? encoder = null;

        server.Start(encW, encH);
        onServerReady?.Invoke();

        // Input is injected on a dedicated thread so key/touch latency is independent of the
        // video pipeline (capture waits, encoder hiccups). Polls with a tiny idle sleep.
        var inputThread = new Thread(() =>
        {
            while (!ct.IsCancellationRequested)
            {
                bool didWork = false;
                TouchPacket? touch;
                while ((touch = server.PollTouch()) != null)
                {
                    InputInjector.InjectTouch(touch, originX, originY, capWidth, capHeight);
                    didWork = true;
                }
                KeyPacket? key;
                while ((key = server.PollKey()) != null)
                {
                    InputInjector.InjectKey(key);
                    didWork = true;
                }
                if (!didWork) Thread.Sleep(1);
            }
        })
        { IsBackground = true, Name = "InputPump" };
        inputThread.Start();

        Console.WriteLine($"Capturing: {capWidth}x{capHeight} @ {TargetFps} fps, HEVC {encW}x{encH} ({(gpu ? "GPU zero-copy" : dxgi != null ? "DXGI capture + CPU convert" : "GDI")})");
        if (AdaptiveFps)
            Console.WriteLine($"Adaptive fps: ON (client refresh, max {MaxAdaptiveFps}; use --fps <n> to pin)");
        Console.WriteLine("Waiting for client... (press Ctrl+C to stop)");

        var sw = Stopwatch.StartNew();
        long frameCount = 0;
        long sentCount = 0;
        long sentBytes = 0;
        long lastStatTime = 0;
        long encLatSumMs = 0, encLatMaxMs = 0; // capture->encoded latency stats
        long lastOutputMs = 0; // when the encoder last produced output (stall watchdog)
        long nextFrameTicks = sw.ElapsedTicks;
        bool lastCursorVisible = false;
        int lastCursorX = int.MinValue, lastCursorY = int.MinValue, lastCursorW = 0, lastCursorH = 0;
        byte[]? lastCursorShape = null;
        int lastClientCount = 0;

        try
        {
            while (!ct.IsCancellationRequested)
            {
                var frameStart = sw.ElapsedMilliseconds;

                if (!server.HasClients)
                {
                    InputInjector.ReleaseAllKeys(); // avoid stuck keys if the client vanished mid-press
                    if (encoder != null) { encoder.Dispose(); encoder = null; Console.WriteLine("No clients — encoder released"); }
                    Thread.Sleep(100);
                    continue;
                }

                if (AdaptiveFps)
                {
                    int preferredRefresh = server.PreferredRefreshRate;
                    int lo = Math.Min(15, MaxAdaptiveFps);
                    int desiredFps = Math.Clamp(preferredRefresh > 0 ? preferredRefresh : TargetFps, lo, MaxAdaptiveFps);
                    if (desiredFps != TargetFps)
                    {
                        TargetFps = desiredFps;
                        FrameIntervalTicks = Math.Max(1, Stopwatch.Frequency / TargetFps);
                        nextFrameTicks = sw.ElapsedTicks;

                        encoder?.Dispose();
                        encoder = null;
                        if (gpu)
                        {
                            converter?.Dispose();
                            try { converter = new GpuColorConverter(dxgi!.Device, dxgi.Context, capWidth, capHeight, encW, encH, TargetFps); _converter = converter; }
                            catch (Exception ex) { Console.WriteLine($"GPU converter reinit failed ({ex.Message}); using CPU path."); gpu = false; }
                        }

                        Console.WriteLine($"Adaptive fps -> {TargetFps}");
                    }
                }

                // Watchdog: recreate the encoder if its async MFT faulted or stopped emitting output
                // (>2.5s with no encoded frame while we keep feeding it). Keeps the stream self-healing.
                if (encoder != null && (encoder.Faulted || (lastOutputMs > 0 && frameStart - lastOutputMs > 5000)))
                {
                    Console.WriteLine($"Encoder unhealthy (faulted={encoder.Faulted}, idle={frameStart - lastOutputMs}ms) — recreating");
                    encoder.Dispose(); encoder = null;
                }

                // A joining client only ever gets SPS/PPS/IDR from a freshly-created encoder (that's
                // baked into the first frame it emits). Without this, a client that connects while the
                // encoder is already running from an earlier connection never receives a keyframe and
                // stays black forever, even though capture/encode/send keeps running fine for everyone
                // else. Recreating on any increase in client count guarantees every new joiner sees one.
                int currentClientCount = server.ClientCount;
                if (currentClientCount > lastClientCount && encoder != null)
                {
                    Console.WriteLine($"Client joined ({lastClientCount} -> {currentClientCount}) — recreating encoder for a fresh keyframe");
                    encoder.Dispose(); encoder = null;
                    if (dxgi != null) dxgi.CursorShapeDirty = true;
                }
                lastClientCount = currentClientCount;

                if (encoder == null)
                {
                    encoder = new HevcEncoder(encW, encH, TargetFps, bitrate: 12_000_000,
                                              d3dDevice: gpu ? dxgi!.Device : null);
                    _encoder = encoder;
                    lastOutputMs = sw.ElapsedMilliseconds;
                    encoder.OnEncodedFrame = (data, pts, key) =>
                    {
                        lastOutputMs = sw.ElapsedMilliseconds;
                        long latMs = lastOutputMs - pts / 1000;
                        Interlocked.Add(ref encLatSumMs, latMs);
                        long cur;
                        while (latMs > (cur = Interlocked.Read(ref encLatMaxMs)))
                            Interlocked.CompareExchange(ref encLatMaxMs, latMs, cur);
                        Interlocked.Increment(ref sentCount);
                        Interlocked.Add(ref sentBytes, data.Length);
                        server.BroadcastFrame(pts, data, key);
                    };
                }

                // Touch/keys are injected by the dedicated InputPump thread (see above).

                try
                {
                    long pts = sw.ElapsedTicks * 1_000_000 / Stopwatch.Frequency;

                    if (gpu)
                    {
                        // Zero-copy GPU path: desktop texture → VPP (BGRA→NV12 + cursor) → encoder, no CPU copy.
                        var desktopTex = dxgi!.UpdateGpu(12);
                        if (desktopTex != null && dxgi.Ready)
                        {
                            byte[]? cursorShape = null;
                            if (dxgi.CursorShapeDirty && dxgi.CursorBgra != null)
                            {
                                int cursorBytes = dxgi.CursorW * dxgi.CursorH * 4;
                                cursorShape = new byte[cursorBytes];
                                Buffer.BlockCopy(dxgi.CursorBgra, 0, cursorShape, 0, cursorBytes);
                                lastCursorShape = cursorShape;
                                dxgi.CursorShapeDirty = false;
                            }
                            else if (dxgi.CurVisible && lastCursorShape == null && dxgi.CursorBgra != null && dxgi.CursorW > 0 && dxgi.CursorH > 0)
                            {
                                int cursorBytes = dxgi.CursorW * dxgi.CursorH * 4;
                                cursorShape = new byte[cursorBytes];
                                Buffer.BlockCopy(dxgi.CursorBgra, 0, cursorShape, 0, cursorBytes);
                                lastCursorShape = cursorShape;
                                cursorShape = lastCursorShape;
                            }

                            bool cursorChanged =
                                cursorShape != null ||
                                dxgi.CurVisible != lastCursorVisible ||
                                dxgi.CurX != lastCursorX ||
                                dxgi.CurY != lastCursorY ||
                                dxgi.CursorW != lastCursorW ||
                                dxgi.CursorH != lastCursorH;
                            if (cursorChanged)
                            {
                                int outCursorX = ScaleCoord(dxgi.CurX, encW, capWidth);
                                int outCursorY = ScaleCoord(dxgi.CurY, encH, capHeight);
                                int outCursorW = Math.Max(1, ScaleCoord(dxgi.CursorW, encW, capWidth));
                                int outCursorH = Math.Max(1, ScaleCoord(dxgi.CursorH, encH, capHeight));
                                server.BroadcastCursor(dxgi.CurVisible, outCursorX, outCursorY, outCursorW, outCursorH, dxgi.CurVisible ? cursorShape : null);
                                lastCursorVisible = dxgi.CurVisible;
                                lastCursorX = dxgi.CurX;
                                lastCursorY = dxgi.CurY;
                                lastCursorW = dxgi.CursorW;
                                lastCursorH = dxgi.CursorH;
                            }

                            var nv12Tex = converter!.Convert(desktopTex, false, 0, 0);
                            encoder.SubmitTexture(nv12Tex, pts);
                            frameCount++;
                        }
                    }
                    else
                    {
                        // CPU path: capture → readback → ColorConvert.BgraToNv12 → encoder.
                        // DXGI only delivers on screen change → on timeout we reuse the last frame
                        // so the encoder keeps getting a steady feed (a slow feed stalls it).
                        if (dxgi != null)
                        {
                            if (dxgi.Update(12) && dxgi.Ready)
                            {
                                ColorConvert.BgraToNv12(dxgi.FramePtr, dxgi.Stride, encW, encH, nv12);
                                haveFrame = true;
                            }
                        }
                        else
                        {
                            var bd = gdi!.LockBgra();
                            try { ColorConvert.BgraToNv12(bd.Scan0, bd.Stride, encW, encH, nv12); }
                            finally { gdi.UnlockBgra(bd); }
                            haveFrame = true;
                        }

                        if (haveFrame)
                        {
                            encoder.SubmitFrame(nv12, pts);
                            frameCount++;
                        }
                    }
                }
                catch (Exception ex)
                {
                    Console.WriteLine($"Capture error: {ex.Message}");
                }

                long now = sw.ElapsedMilliseconds;
                if (now - lastStatTime > 5000)
                {
                    double elapsed = (now - lastStatTime) / 1000.0;
                    long sc = Interlocked.Exchange(ref sentCount, 0);
                    long sb = Interlocked.Exchange(ref sentBytes, 0);
                    long latSum = Interlocked.Exchange(ref encLatSumMs, 0);
                    long latMax = Interlocked.Exchange(ref encLatMaxMs, 0);
                    long inKeys = Interlocked.Exchange(ref InputInjector.InjectedKeys, 0);
                    long inTouch = Interlocked.Exchange(ref InputInjector.InjectedTouches, 0);
                    Console.WriteLine($"  capture {frameCount / elapsed:F1} fps (#{frameCount}) | encoded+sent {sc / elapsed:F1} fps, {sb / 1024 / Math.Max(elapsed, 0.001):F0} KB/s | enc-lat avg {(sc > 0 ? latSum / sc : 0)}ms max {latMax}ms | input {inKeys} keys {inTouch} touch");
                    frameCount = 0;
                    lastStatTime = now;
                }

                nextFrameTicks += FrameIntervalTicks;
                long delayTicks = nextFrameTicks - sw.ElapsedTicks;
                if (delayTicks < -FrameIntervalTicks)
                    nextFrameTicks = sw.ElapsedTicks;
                else
                    SleepUntil(sw, nextFrameTicks);
            }
        }
        finally
        {
            InputInjector.ReleaseAllKeys();
            encoder?.Dispose();
            converter?.Dispose();
            dxgi?.Dispose();
            gdi?.Dispose();
            server.Dispose();
            _encoder = null;
            _converter = null;
            _dxgi = null;
            _gdi = null;
            _server = null;
            Console.WriteLine("Shutting down...");
        }
    }

    private static void SleepUntil(Stopwatch sw, long targetTicks)
    {
        while (true)
        {
            long remainingTicks = targetTicks - sw.ElapsedTicks;
            if (remainingTicks <= 0) return;

            double remainingMs = remainingTicks * 1000.0 / Stopwatch.Frequency;
            if (remainingMs > 2.0)
                Thread.Sleep(Math.Max(1, (int)remainingMs - 1));
            else
                Thread.SpinWait(64);
        }
    }

    private static int ScaleCoord(int value, int output, int input)
    {
        if (input <= 0) return value;
        return (int)Math.Round(value * (double)output / input);
    }

    /// <summary>Disposes encoder/converter/dxgi/gdi/server if Run didn't already (idempotent).</summary>
    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _encoder?.Dispose();
        _converter?.Dispose();
        _dxgi?.Dispose();
        _gdi?.Dispose();
        _server?.Dispose();
        _encoder = null;
        _converter = null;
        _dxgi = null;
        _gdi = null;
        _server = null;
    }
}
