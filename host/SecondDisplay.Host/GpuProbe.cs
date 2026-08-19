using System.Runtime.InteropServices;
using SharpGen.Runtime;
using Vortice.Direct3D;
using Vortice.Direct3D11;
using Vortice.DXGI;
using Vortice.MediaFoundation;

namespace SecondDisplay.Host;

/// <summary>
/// Phase 4 de-risk probe: does the hardware HEVC encoder MFT (QuickSync on Iris Xe)
/// accept a Direct3D11 NV12 texture as input (zero-copy), rather than a CPU memory buffer?
///
/// The whole "GPU pipeline" of Phase 4 hinges on this. If the MFT rejects D3D11 input we
/// must keep the CPU NV12 path. This probe reports each gate so we know exactly where it
/// stands before rewriting the real pipeline.
/// </summary>
public static class GpuProbe
{
    // MF attribute GUIDs reused from HevcEncoder.
    static readonly Guid MF_MT_MAJOR_TYPE = new("48eba18e-f8c9-4687-bf11-0a74c9f96a8f");
    static readonly Guid MF_MT_SUBTYPE = new("f7e34c9a-42e8-4714-b74b-cb29d72c35e5");
    static readonly Guid MF_MT_FRAME_SIZE = new("1652c33d-d6b2-4012-b834-72030849a37d");
    static readonly Guid MF_MT_FRAME_RATE = new("c459a2e8-3d2c-4e44-b132-fee5156c7bb0");
    static readonly Guid MF_MT_AVG_BITRATE = new("20332624-fb0d-4d9e-bd0d-cbf6786c102e");
    static readonly Guid MF_MT_INTERLACE_MODE = new("e2724bb8-e676-4806-b4b2-a8d6efb44ccd");
    static readonly Guid MF_MT_PIXEL_ASPECT_RATIO = new("c6376a1e-8d0a-4027-be45-6d9a0ad39bb6");
    static readonly Guid MF_TRANSFORM_ASYNC_UNLOCK = new("e5666d6b-3422-4eb6-a421-da7db1f8e207");
    static readonly Guid MF_LOW_LATENCY = new("9c27891a-ed7a-40e1-88e8-b22727a024ee");
    static readonly Guid MF_SA_D3D11_AWARE = new("206b4fc8-fcf9-4c51-afe3-9764369e33a0");
    static readonly Guid MF_SA_D3D11_BINDFLAGS = new("eacf97ad-065c-4408-bee3-fdcbfd128be2");
    static readonly Guid IID_ID3D11Texture2D = new("6f15aaf2-d208-4e89-9ab4-489535d34f9c");

    const int MFVideoInterlace_Progressive = 2;
    const int MF_E_TRANSFORM_NEED_MORE_INPUT = unchecked((int)0xC00D6D72);

    static ulong Pack(int high, int low) => ((ulong)(uint)high << 32) | (uint)low;

    /// <summary>
    /// End-to-end GPU pipeline self-test on a real monitor: DXGI capture → VPP (BGRA→NV12 + cursor)
    /// → zero-copy HEVC encoder. Writes a raw .h265 and reports capture/encode fps. No tablet needed.
    /// </summary>
    public static void RunPipeline(int displayIndex, double seconds, string outPath, int fps = 60)
    {
        DpiHelperShim();
        var monitors = ScreenCapture.GetMonitors();
        var target = (displayIndex >= 0 && displayIndex < monitors.Count)
            ? monitors[displayIndex]
            : monitors.FirstOrDefault(m => m.Primary, monitors[0]);
        Console.WriteLine($"=== GPU pipeline self-test on [{target.Index}] {target.Device} {target.Width}x{target.Height} @ {fps} fps ===");

        using var dxgi = new DxgiCapture(target.Device);
        int encW = dxgi.Width & ~1, encH = dxgi.Height & ~1;
        using var converter = new GpuColorConverter(dxgi.Device, dxgi.Context, encW, encH, fps);
        long encoded = 0, encodedBytes = 0;
        using var fs = File.Create(outPath);
        var encoder = new HevcEncoder(encW, encH, fps, 12_000_000, dxgi.Device);
        encoder.OnEncodedFrame = (data, pts, key) =>
        {
            fs.Write(data, 0, data.Length);
            Interlocked.Increment(ref encoded);
            Interlocked.Add(ref encodedBytes, data.Length);
        };

        var sw = System.Diagnostics.Stopwatch.StartNew();
        long captured = 0;
        while (sw.Elapsed.TotalSeconds < seconds)
        {
            var tex = dxgi.UpdateGpu(12);
            if (tex == null || !dxgi.Ready) { Thread.Sleep(2); continue; }
            if (dxgi.CursorShapeDirty && dxgi.CursorBgra != null)
            {
                converter.UpdateCursorShape(dxgi.CursorBgra, dxgi.CursorW, dxgi.CursorH, dxgi.Context);
                dxgi.CursorShapeDirty = false;
            }
            long pts = sw.ElapsedTicks * 1_000_000 / System.Diagnostics.Stopwatch.Frequency;
            var nv12Tex = converter.Convert(tex, dxgi.CurVisible, dxgi.CurX, dxgi.CurY);
            encoder.SubmitTexture(nv12Tex, pts);
            captured++;
            Thread.Sleep(Math.Max(0, 1000 / fps));
        }
        Thread.Sleep(500); // drain
        double el = sw.Elapsed.TotalSeconds;
        encoder.Dispose();

        Console.WriteLine($"captured {captured} frames ({captured / el:F1} fps), encoded {encoded} ({encoded / el:F1} fps), {encodedBytes / 1024.0 / el:F0} KB/s");
        Console.WriteLine($"output: {outPath} ({encodedBytes} bytes)");
        Console.WriteLine(encoded > 0 ? "RESULT: GPU pipeline OK." : "RESULT: NO encoded output — investigate.");
    }

    static void DpiHelperShim()
    {
        try { SetProcessDpiAwarenessContext(new IntPtr(-4)); } catch { }
    }
    [DllImport("user32.dll")] static extern bool SetProcessDpiAwarenessContext(IntPtr value);

    public static void Run(int w = 1920, int h = 1080)
    {
        Console.WriteLine("=== Phase 4 D3D11-encoder probe ===");
        w &= ~1; h &= ~1;
        int fps = 30;

        MediaFactory.MFStartup(false).CheckError();

        // 1) D3D11 device with video support (BGRA for capture interop, VideoSupport for VideoProcessor).
        D3D11.D3D11CreateDevice(
            null, DriverType.Hardware,
            DeviceCreationFlags.BgraSupport | DeviceCreationFlags.VideoSupport,
            new[] { FeatureLevel.Level_11_1, FeatureLevel.Level_11_0 },
            out ID3D11Device device, out ID3D11DeviceContext context).CheckError();
        Console.WriteLine("[1] D3D11 device created (Hardware, VideoSupport).");

        // Multithread protection is required when a device is shared with MF.
        using (var mt = device.QueryInterface<ID3D11Multithread>())
            mt.SetMultithreadProtected(true);

        // 2) Enumerate the hardware HEVC encoder MFT.
        var outputInfo = new RegisterTypeInfo { GuidMajorType = MediaTypeGuids.Video, GuidSubtype = VideoFormatGuids.Hevc };
        MediaFactory.MFTEnumEx(TransformCategoryGuids.VideoEncoder,
            (uint)(EnumFlag.EnumFlagHardware | EnumFlag.EnumFlagSortandfilter),
            null, outputInfo, out IntPtr activatesPtr, out uint count);
        if (count == 0) { Console.WriteLine("[2] FAIL: no hardware HEVC MFT."); return; }
        IntPtr firstActivate = Marshal.ReadIntPtr(activatesPtr);
        using var activate = new IMFActivate(firstActivate);
        string name; try { name = activate.FriendlyName ?? "?"; } catch { name = "(no name)"; }
        Marshal.FreeCoTaskMem(activatesPtr);
        var transform = activate.ActivateObject<IMFTransform>();
        Console.WriteLine($"[2] HEVC MFT: {name}");

        // 3) Does it advertise D3D11 awareness?
        var attrs = transform.Attributes;
        uint d3d11Aware = 0, bindFlags = 0;
        try { d3d11Aware = attrs.GetUInt32(MF_SA_D3D11_AWARE); } catch { }
        try { bindFlags = attrs.GetUInt32(MF_SA_D3D11_BINDFLAGS); } catch { }
        Console.WriteLine($"[3] MF_SA_D3D11_AWARE = {d3d11Aware}  (1 = accepts D3D11 textures)");
        Console.WriteLine($"    MF_SA_D3D11_BINDFLAGS hint = 0x{bindFlags:X}");

        attrs.SetUInt32(MF_TRANSFORM_ASYNC_UNLOCK, 1);
        attrs.SetUInt32(MF_LOW_LATENCY, 1);

        // 4) Hand the shared D3D11 device to the MFT via a device manager.
        var devManager = MediaFactory.MFCreateDXGIDeviceManager();
        devManager.ResetDevice(device);
        bool setMgrOk = true;
        try { transform.ProcessMessage(TMessageType.MessageSetD3DManager, (UIntPtr)(ulong)devManager.NativePointer); }
        catch (Exception ex) { setMgrOk = false; Console.WriteLine($"[4] SET_D3D_MANAGER FAILED: {ex.Message}"); }
        if (setMgrOk) Console.WriteLine("[4] SET_D3D_MANAGER OK.");

        // 5) Configure output (HEVC) then input (NV12).
        var outType = MediaFactory.MFCreateMediaType();
        outType.Set(MF_MT_MAJOR_TYPE, MediaTypeGuids.Video);
        outType.Set(MF_MT_SUBTYPE, VideoFormatGuids.Hevc);
        outType.SetUInt32(MF_MT_AVG_BITRATE, 12_000_000);
        outType.SetUInt32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
        outType.SetUInt64(MF_MT_FRAME_SIZE, Pack(w, h));
        outType.SetUInt64(MF_MT_FRAME_RATE, Pack(fps, 1));
        outType.SetUInt64(MF_MT_PIXEL_ASPECT_RATIO, Pack(1, 1));
        transform.SetOutputType(0, outType, 0);

        var inType = MediaFactory.MFCreateMediaType();
        inType.Set(MF_MT_MAJOR_TYPE, MediaTypeGuids.Video);
        inType.Set(MF_MT_SUBTYPE, VideoFormatGuids.NV12);
        inType.SetUInt32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
        inType.SetUInt64(MF_MT_FRAME_SIZE, Pack(w, h));
        inType.SetUInt64(MF_MT_FRAME_RATE, Pack(fps, 1));
        inType.SetUInt64(MF_MT_PIXEL_ASPECT_RATIO, Pack(1, 1));
        transform.SetInputType(0, inType, 0);
        Console.WriteLine("[5] Input/output media types set (NV12 -> HEVC).");

        var eventGen = transform.QueryInterface<IMFMediaEventGenerator>();
        transform.ProcessMessage(TMessageType.MessageNotifyBeginStreaming, UIntPtr.Zero);
        transform.ProcessMessage(TMessageType.MessageNotifyStartOfStream, UIntPtr.Zero);

        // 6) Allocate an NV12 D3D11 texture and feed it as a surface-backed sample.
        var bind = BindFlags.RenderTarget; // common requirement for encoder input
        if (bindFlags != 0) bind = (BindFlags)bindFlags;
        var nvTex = device.CreateTexture2D(new Texture2DDescription
        {
            Width = w, Height = h, MipLevels = 1, ArraySize = 1,
            Format = Format.NV12,
            SampleDescription = new SampleDescription(1, 0),
            Usage = ResourceUsage.Default,
            BindFlags = bind,
            CPUAccessFlags = CpuAccessFlags.None,
            MiscFlags = ResourceOptionFlags.None
        });
        Console.WriteLine($"[6] NV12 texture created (bind={bind}).");

        int got = 0;
        bool inputAccepted = false;
        long t0 = Environment.TickCount64;
        const int wantFrames = 10;

        // Drive the async MFT loop synchronously (single thread) for a handful of frames.
        for (int frame = 0; frame < 200 && Environment.TickCount64 - t0 < 8000; frame++)
        {
            IMFMediaEvent ev;
            try { ev = eventGen.GetEvent(0); } catch { break; }
            var type = ev.Type; ev.Dispose();

            if (type == MediaEventTypes.TransformNeedInput && got < wantFrames)
            {
                var buffer = MediaFactory.MFCreateDXGISurfaceBuffer(IID_ID3D11Texture2D, nvTex, 0, false);
                using (var b2d = buffer.QueryInterface<IMF2DBuffer>())
                    buffer.CurrentLength = b2d.ContiguousLength;

                var sample = MediaFactory.MFCreateSample();
                sample.AddBuffer(buffer);
                sample.SampleTime = (long)got * 10_000_000 / fps;
                sample.SampleDuration = 10_000_000L / fps;
                try
                {
                    transform.ProcessInput(0, sample, 0);
                    inputAccepted = true;
                }
                catch (Exception ex)
                {
                    Console.WriteLine($"[7] ProcessInput(D3D11 texture) REJECTED: 0x{ex.HResult:X8} {ex.Message}");
                    sample.Dispose(); buffer.Dispose();
                    break;
                }
                sample.Dispose(); buffer.Dispose();
            }
            else if (type == MediaEventTypes.TransformHaveOutput)
            {
                var odb = new OutputDataBuffer { StreamID = 0, Sample = null! };
                var res = transform.ProcessOutput(ProcessOutputFlags.None, 1, ref odb, out _);
                if (res.Code == MF_E_TRANSFORM_NEED_MORE_INPUT) continue;
                res.CheckError();
                var s = odb.Sample;
                if (s != null)
                {
                    using var contig = s.ConvertToContiguousBuffer();
                    contig.Lock(out IntPtr p, out _, out int len); contig.Unlock();
                    got++;
                    if (got <= 3) Console.WriteLine($"    encoded frame {got}: {len} bytes");
                    s.Dispose();
                }
                odb.Events?.Dispose();
                if (got >= wantFrames) break;
            }
        }

        Console.WriteLine();
        Console.WriteLine($"[7] ProcessInput accepted D3D11 texture: {(inputAccepted ? "YES" : "NO")}");
        Console.WriteLine($"[8] Encoded {got} HEVC frames from D3D11 textures.");
        Console.WriteLine();
        if (inputAccepted && got > 0)
            Console.WriteLine("RESULT: ZERO-COPY VIABLE — QuickSync MFT accepts D3D11 NV12 input. Proceed with Phase 4 GPU pipeline.");
        else
            Console.WriteLine("RESULT: D3D11 input NOT viable on this MFT — keep CPU NV12 path (still do GPU color-convert + readback).");

        transform.ProcessMessage(TMessageType.MessageNotifyEndOfStream, UIntPtr.Zero);
        nvTex.Dispose();
        eventGen.Dispose();
        transform.Dispose();
        devManager.Dispose();
        context.Dispose();
        device.Dispose();
        try { MediaFactory.MFShutdown(); } catch { }
    }
}
