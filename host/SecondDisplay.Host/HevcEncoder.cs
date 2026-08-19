using System.Collections.Concurrent;
using System.Runtime.InteropServices;
using SharpGen.Runtime;
using Vortice.Direct3D11;
using Vortice.MediaFoundation;

namespace SecondDisplay.Host;

/// <summary>
/// Hardware HEVC encoder using the built-in Windows Media Foundation encoder MFT
/// (maps to Intel QuickSync on this machine). Drives the async MFT on a background thread.
/// Input: NV12. Output: raw HEVC bitstream (Annex-B) access units via OnEncodedFrame.
/// </summary>
public sealed class HevcEncoder : IDisposable
{
    // --- MF attribute GUIDs (not all exposed by Vortice as typed keys) ---
    static readonly Guid MF_MT_MAJOR_TYPE = new("48eba18e-f8c9-4687-bf11-0a74c9f96a8f");
    static readonly Guid MF_MT_SUBTYPE = new("f7e34c9a-42e8-4714-b74b-cb29d72c35e5");
    static readonly Guid MF_MT_FRAME_SIZE = new("1652c33d-d6b2-4012-b834-72030849a37d");
    static readonly Guid MF_MT_FRAME_RATE = new("c459a2e8-3d2c-4e44-b132-fee5156c7bb0");
    static readonly Guid MF_MT_AVG_BITRATE = new("20332624-fb0d-4d9e-bd0d-cbf6786c102e");
    static readonly Guid MF_MT_INTERLACE_MODE = new("e2724bb8-e676-4806-b4b2-a8d6efb44ccd");
    static readonly Guid MF_MT_PIXEL_ASPECT_RATIO = new("c6376a1e-8d0a-4027-be45-6d9a0ad39bb6");
    static readonly Guid MF_LOW_LATENCY = new("9c27891a-ed7a-40e1-88e8-b22727a024ee");
    static readonly Guid MF_TRANSFORM_ASYNC_UNLOCK = new("e5666d6b-3422-4eb6-a421-da7db1f8e207");
    static readonly Guid IID_ID3D11Texture2D = new("6f15aaf2-d208-4e89-9ab4-489535d34f9c");

    const int MFVideoInterlace_Progressive = 2;
    const int MFT_OUTPUT_STREAM_PROVIDES_SAMPLES = 0x100;
    const int MFT_OUTPUT_STREAM_CAN_PROVIDE_SAMPLES = 0x200;
    const int MF_E_TRANSFORM_NEED_MORE_INPUT = unchecked((int)0xC00D6D72);

    readonly int _width, _height, _fps;
    readonly long _frameDurationHns;

    IMFTransform _transform = null!;
    IMFMediaEventGenerator _eventGen = null!;
    bool _providesSamples;

    // Small (low-latency) queue. SubmitFrame drops the STALE queued frame and keeps the newest,
    // so the encoder always works on the freshest capture → minimal "catch-up" lag.
    readonly BlockingCollection<(byte[] nv12, long ptsMicros)> _inputQueue = new(2);
    // Zero-copy texture input queue (used when the encoder runs in D3D11 mode). Carries the NV12
    // D3D11 texture produced by the GPU converter; the texture is owned by the converter's ring,
    // the encoder only references it.
    readonly BlockingCollection<(ID3D11Texture2D tex, long ptsMicros)> _texQueue = new(2);
    readonly bool _d3dMode;
    ID3D11Device? _d3dDevice;
    IMFDXGIDeviceManager? _devManager;
    // Pool of reusable NV12 buffers so we don't allocate (and GC) a ~12 MB array per frame,
    // which at 50 fps is ~600 MB/s of garbage → GC pauses → jerky feed → the async MFT stalls.
    readonly System.Collections.Concurrent.ConcurrentQueue<byte[]> _pool = new();
    Thread _eventThread = null!;
    volatile bool _running;

    /// <summary>Fires for each encoded access unit (Annex-B). Called on the encoder thread.</summary>
    public Action<byte[], long, bool>? OnEncodedFrame;

    /// <param name="d3dDevice">
    /// When non-null, the encoder runs in zero-copy D3D11 mode: it accepts NV12 D3D11 textures via
    /// <see cref="SubmitTexture"/> instead of CPU byte[] frames. The device must be the same one the
    /// GPU converter renders the NV12 textures on (shared via an IMFDXGIDeviceManager).
    /// </param>
    public HevcEncoder(int width, int height, int fps, int bitrate, ID3D11Device? d3dDevice = null)
    {
        _width = width;
        _height = height;
        _fps = fps;
        _frameDurationHns = 10_000_000L / fps;
        _d3dDevice = d3dDevice;
        _d3dMode = d3dDevice != null;

        MediaFactory.MFStartup(false).CheckError();
        CreateEncoder(bitrate);
    }

    void CreateEncoder(int bitrate)
    {
        var outputInfo = new RegisterTypeInfo
        {
            GuidMajorType = MediaTypeGuids.Video,
            GuidSubtype = VideoFormatGuids.Hevc
        };

        MediaFactory.MFTEnumEx(
            TransformCategoryGuids.VideoEncoder,
            (uint)(EnumFlag.EnumFlagHardware | EnumFlag.EnumFlagSortandfilter),
            null,
            outputInfo,
            out IntPtr activatesPtr,
            out uint count);

        if (count == 0)
        {
            // Fall back to any (software) HEVC encoder if no hardware MFT is present.
            MediaFactory.MFTEnumEx(
                TransformCategoryGuids.VideoEncoder,
                (uint)(EnumFlag.EnumFlagSyncmft | EnumFlag.EnumFlagAsyncmft | EnumFlag.EnumFlagSortandfilter),
                null, outputInfo, out activatesPtr, out count);
        }
        if (count == 0)
            throw new NotSupportedException("No HEVC encoder MFT found on this system.");

        IntPtr firstActivate = Marshal.ReadIntPtr(activatesPtr);
        using var activate = new IMFActivate(firstActivate);
        // FriendlyName property often throws MF_E_ATTRIBUTENOTFOUND on hardware MFTs;
        // read MFT_FRIENDLY_NAME via GetString instead.
        string name = "?";
        try { name = activate.GetString(new Guid("314ffbae-5b41-4c95-9c19-4e7d586face3")); }
        catch { try { name = activate.FriendlyName ?? "?"; } catch { name = "(no name)"; } }
        Console.WriteLine($"HEVC encoder: {name} ({count} found)");
        Marshal.FreeCoTaskMem(activatesPtr);

        _transform = activate.ActivateObject<IMFTransform>();

        var attrs = _transform.Attributes;
        if (attrs != null)
        {
            attrs.SetUInt32(MF_TRANSFORM_ASYNC_UNLOCK, 1);
            attrs.SetUInt32(MF_LOW_LATENCY, 1);
        }

        // Zero-copy mode: hand the shared D3D11 device to the MFT so it can consume our NV12
        // textures directly from video memory (verified viable by the --probe-d3d11 probe).
        if (_d3dMode)
        {
            _devManager = MediaFactory.MFCreateDXGIDeviceManager();
            _devManager.ResetDevice(_d3dDevice!);
            _transform.ProcessMessage(TMessageType.MessageSetD3DManager, (UIntPtr)(ulong)_devManager.NativePointer);
        }

        // Output type first (required ordering for encoders).
        var outType = MediaFactory.MFCreateMediaType();
        outType.Set(MF_MT_MAJOR_TYPE, MediaTypeGuids.Video);
        outType.Set(MF_MT_SUBTYPE, VideoFormatGuids.Hevc);
        outType.SetUInt32(MF_MT_AVG_BITRATE, (uint)bitrate);
        outType.SetUInt32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
        outType.SetUInt64(MF_MT_FRAME_SIZE, Pack(_width, _height));
        outType.SetUInt64(MF_MT_FRAME_RATE, Pack(_fps, 1));
        outType.SetUInt64(MF_MT_PIXEL_ASPECT_RATIO, Pack(1, 1));
        _transform.SetOutputType(0, outType, 0);

        // Input type NV12.
        var inType = MediaFactory.MFCreateMediaType();
        inType.Set(MF_MT_MAJOR_TYPE, MediaTypeGuids.Video);
        inType.Set(MF_MT_SUBTYPE, VideoFormatGuids.NV12);
        inType.SetUInt32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
        inType.SetUInt64(MF_MT_FRAME_SIZE, Pack(_width, _height));
        inType.SetUInt64(MF_MT_FRAME_RATE, Pack(_fps, 1));
        inType.SetUInt64(MF_MT_PIXEL_ASPECT_RATIO, Pack(1, 1));
        _transform.SetInputType(0, inType, 0);

        var osi = _transform.GetOutputStreamInfo(0);
        _providesSamples = (osi.Flags & (MFT_OUTPUT_STREAM_PROVIDES_SAMPLES | MFT_OUTPUT_STREAM_CAN_PROVIDE_SAMPLES)) != 0;

        _eventGen = _transform.QueryInterface<IMFMediaEventGenerator>();

        _transform.ProcessMessage(TMessageType.MessageNotifyBeginStreaming, UIntPtr.Zero);
        _transform.ProcessMessage(TMessageType.MessageNotifyStartOfStream, UIntPtr.Zero);

        _running = true;
        _eventThread = new Thread(EventLoop) { IsBackground = true, Name = "HevcEncoderEvents" };
        _eventThread.Start();
    }

    /// <summary>
    /// Submit a raw NV12 frame. Copies <paramref name="nv12"/> into a pooled buffer (so the caller
    /// may reuse its buffer immediately) and enqueues NON-BLOCKING: if the encoder is behind we drop
    /// the frame rather than block the capture thread (blocking would slow capture → starve the
    /// encoder → permanent stall).
    /// </summary>
    public void SubmitFrame(byte[] nv12, long ptsMicros)
    {
        if (!_running) return;
        if (!_pool.TryDequeue(out var buf) || buf.Length != nv12.Length)
            buf = new byte[nv12.Length];
        Buffer.BlockCopy(nv12, 0, buf, 0, nv12.Length);
        if (!_inputQueue.TryAdd((buf, ptsMicros), 0))
        {
            // Full → throw away the STALE queued frame, keep the newest (low latency).
            if (_inputQueue.TryTake(out var stale, 0)) _pool.Enqueue(stale.nv12);
            if (!_inputQueue.TryAdd((buf, ptsMicros), 0)) _pool.Enqueue(buf);
        }
    }

    /// <summary>
    /// Zero-copy submit: enqueue an NV12 D3D11 texture (owned by the GPU converter ring). Same
    /// drop-stale, non-blocking policy as <see cref="SubmitFrame"/> to keep latency minimal.
    /// </summary>
    public void SubmitTexture(ID3D11Texture2D nv12Texture, long ptsMicros)
    {
        if (!_running) return;
        if (!_texQueue.TryAdd((nv12Texture, ptsMicros), 0))
        {
            _texQueue.TryTake(out _, 0);
            _texQueue.TryAdd((nv12Texture, ptsMicros), 0);
        }
    }

    void EventLoop()
    {
        while (_running)
        {
            try
            {
                IMFMediaEvent ev = _eventGen.GetEvent(0);
                var type = ev.Type;
                ev.Dispose();

                if (type == MediaEventTypes.TransformNeedInput)
                {
                    // Must fulfill the request — MFT won't ask again until we ProcessInput.
                    // Block up to 500ms; if still nothing, retry in a tight loop.
                    while (_running)
                    {
                        if (_d3dMode)
                        {
                            if (_texQueue.TryTake(out var tf, 500)) { FeedTexture(tf.tex, tf.ptsMicros); break; }
                        }
                        else if (_inputQueue.TryTake(out var frame, 500))
                        {
                            FeedInput(frame.nv12, frame.ptsMicros);
                            break;
                        }
                    }
                }
                else if (type == MediaEventTypes.TransformHaveOutput)
                {
                    DrainOutput();
                }
            }
            catch (Exception ex)
            {
                // Hardware MFT can fault (mode change, GPU TDR, etc.). Don't die silently —
                // flag it so the main loop recreates the encoder, then exit this thread.
                Console.WriteLine($"Encoder event loop fault: {ex.Message} — flagging for restart");
                Faulted = true;
                return;
            }
        }
    }

    /// <summary>Set when the async MFT event loop faults; main loop should recreate the encoder.</summary>
    public volatile bool Faulted;

    void FeedInput(byte[] nv12, long ptsMicros)
    {
        var buffer = MediaFactory.MFCreateMemoryBuffer(nv12.Length);
        buffer.Lock(out IntPtr p, out _, out _);
        Marshal.Copy(nv12, 0, p, nv12.Length);
        buffer.Unlock();
        buffer.CurrentLength = nv12.Length;

        var sample = MediaFactory.MFCreateSample();
        sample.AddBuffer(buffer);
        sample.SampleTime = ptsMicros * 10; // microseconds -> 100ns
        sample.SampleDuration = _frameDurationHns;

        _transform.ProcessInput(0, sample, 0);

        sample.Dispose();
        buffer.Dispose();

        // The MF buffer holds its own copy now → recycle the NV12 buffer.
        _pool.Enqueue(nv12);
    }

    // Zero-copy: wrap the NV12 D3D11 texture as a surface-backed MF sample (no RAM copy) and feed
    // it to the MFT. The texture is owned by the converter ring, so we only dispose the sample/buffer.
    void FeedTexture(ID3D11Texture2D nv12Texture, long ptsMicros)
    {
        var buffer = MediaFactory.MFCreateDXGISurfaceBuffer(IID_ID3D11Texture2D, nv12Texture, 0, false);
        using (var b2d = buffer.QueryInterface<IMF2DBuffer>())
            buffer.CurrentLength = b2d.ContiguousLength;

        var sample = MediaFactory.MFCreateSample();
        sample.AddBuffer(buffer);
        sample.SampleTime = ptsMicros * 10; // microseconds -> 100ns
        sample.SampleDuration = _frameDurationHns;

        _transform.ProcessInput(0, sample, 0);

        sample.Dispose();
        buffer.Dispose();
    }

    void DrainOutput()
    {
        var odb = new OutputDataBuffer { StreamID = 0, Sample = _providesSamples ? null! : MediaFactory.MFCreateSample() };
        if (!_providesSamples)
            odb.Sample.AddBuffer(MediaFactory.MFCreateMemoryBuffer(_width * _height * 2));

        var res = _transform.ProcessOutput(ProcessOutputFlags.None, 1, ref odb, out _);
        if (res.Code == MF_E_TRANSFORM_NEED_MORE_INPUT)
            return;
        res.CheckError();

        var sample = odb.Sample;
        if (sample == null) return;

        long ptsMicros = sample.SampleTime / 10;
        using var contiguous = sample.ConvertToContiguousBuffer();
        contiguous.Lock(out IntPtr p, out _, out int len);
        var data = new byte[len];
        Marshal.Copy(p, data, 0, len);
        contiguous.Unlock();

        OnEncodedFrame?.Invoke(data, ptsMicros, IsHevcKeyframe(data));

        sample.Dispose();
        odb.Events?.Dispose();
    }

    static bool IsHevcKeyframe(ReadOnlySpan<byte> data)
    {
        for (int i = 0; i + 5 < data.Length; i++)
        {
            int startCodeBytes = 0;
            if (data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1)
                startCodeBytes = 3;
            else if (i + 6 < data.Length && data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 0 && data[i + 3] == 1)
                startCodeBytes = 4;

            if (startCodeBytes == 0) continue;

            int nalHeader = i + startCodeBytes;
            int nalType = (data[nalHeader] >> 1) & 0x3F;
            if (nalType is 19 or 20 or 32 or 33 or 34)
                return true;

            i = nalHeader + 1;
        }
        return false;
    }

    static ulong Pack(int high, int low) => ((ulong)(uint)high << 32) | (uint)low;

    public void Dispose()
    {
        _running = false;
        _inputQueue.CompleteAdding();
        _texQueue.CompleteAdding();
        try { _transform?.ProcessMessage(TMessageType.MessageNotifyEndOfStream, UIntPtr.Zero); } catch { }
        _eventThread?.Join(500);
        _eventGen?.Dispose();
        _transform?.Dispose();
        _devManager?.Dispose();
        try { MediaFactory.MFShutdown(); } catch { }
    }
}
