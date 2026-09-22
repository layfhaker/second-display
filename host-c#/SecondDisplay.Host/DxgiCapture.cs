using System.Runtime.InteropServices;
using Vortice.Direct3D;
using Vortice.Direct3D11;
using Vortice.DXGI;

namespace SecondDisplay.Host;

/// <summary>
/// GPU screen capture via DXGI Desktop Duplication for a single monitor.
/// Much faster than GDI CopyFromScreen (handles 4K at full rate), which keeps
/// the HEVC encoder fed steadily (a slow/irregular feed stalls the async MFT).
///
/// Desktop Duplication does NOT bake the mouse cursor into the frame, so we keep
/// a "clean" desktop copy and composite the cursor (fetched separately) onto an
/// output buffer every Update — that way the cursor moves even on a static screen.
/// </summary>
public sealed class DxgiCapture : IDisposable
{
    private readonly ID3D11Device _device;
    private readonly ID3D11DeviceContext _context;
    private readonly IDXGIOutput1 _output1;   // kept so we can re-duplicate on access loss
    private IDXGIOutputDuplication? _dup;
    private readonly ID3D11Texture2D _staging;
    private long _dupLostTicks;

    private readonly byte[] _clean;   // desktop without cursor (tight BGRA)
    private readonly byte[] _out;     // desktop + cursor (tight BGRA)
    private readonly GCHandle _outHandle;

    // cursor state (persists across frames; shape only sent on change)
    private byte[]? _curBgra;         // decoded cursor as straight BGRA + alpha
    private int _curW, _curH;
    private int _curX, _curY;
    private bool _curVisible;

    public int Width { get; }
    public int Height { get; }
    public int Stride => Width * 4;
    public IntPtr FramePtr { get; private set; }
    public bool Ready { get; private set; }
    public string DeviceName { get; }

    // --- GPU pipeline exposure (Phase 4): share the device and the on-GPU desktop texture so the
    // converter/encoder never touch CPU memory. Only used by the GPU path (UpdateGpu). ---
    public ID3D11Device Device => _device;
    public ID3D11DeviceContext Context => _context;
    private ID3D11Texture2D? _desktopTex;     // BGRA desktop kept in VRAM (cursor composited later)
    public bool CurVisible => _curVisible;
    public int CurX => _curX;
    public int CurY => _curY;
    public byte[]? CursorBgra => _curBgra;
    public int CursorW => _curW;
    public int CursorH => _curH;
    public bool CursorShapeDirty;             // set when a new cursor shape is decoded; consumer clears

    public DxgiCapture(string targetDeviceName)
    {
        using var factory = DXGI.CreateDXGIFactory1<IDXGIFactory1>();

        IDXGIAdapter1? chosenAdapter = null;
        IDXGIOutput1? chosenOutput = null;
        int width = 0, height = 0;

        for (int ai = 0; factory.EnumAdapters1(ai, out var adapter).Success; ai++)
        {
            bool found = false;
            for (int oi = 0; adapter.EnumOutputs(oi, out var output).Success; oi++)
            {
                var desc = output.Description;
                if (desc.DeviceName == targetDeviceName)
                {
                    chosenAdapter = adapter;
                    chosenOutput = output.QueryInterface<IDXGIOutput1>();
                    var c = desc.DesktopCoordinates;
                    width = c.Right - c.Left;
                    height = c.Bottom - c.Top;
                    output.Dispose();
                    found = true;
                    break;
                }
                output.Dispose();
            }
            if (found) break;
            adapter.Dispose();
        }

        if (chosenAdapter == null || chosenOutput == null)
            throw new InvalidOperationException($"DXGI output '{targetDeviceName}' not found.");

        DeviceName = targetDeviceName;
        Width = width;
        Height = height;

        D3D11.D3D11CreateDevice(
            chosenAdapter, DriverType.Unknown,
            DeviceCreationFlags.BgraSupport | DeviceCreationFlags.VideoSupport,
            new[] { FeatureLevel.Level_11_1, FeatureLevel.Level_11_0, FeatureLevel.Level_10_1 },
            out _device!, out _context!).CheckError();

        // Required when the device is shared with Media Foundation / the GPU converter.
        using (var mt = _device.QueryInterface<ID3D11Multithread>())
            mt.SetMultithreadProtected(true);

        _output1 = chosenOutput; // keep for re-duplication
        _dup = _output1.DuplicateOutput(_device);
        chosenAdapter.Dispose();

        _staging = _device.CreateTexture2D(new Texture2DDescription
        {
            Width = Width,
            Height = Height,
            MipLevels = 1,
            ArraySize = 1,
            Format = Format.B8G8R8A8_UNorm,
            SampleDescription = new SampleDescription(1, 0),
            Usage = ResourceUsage.Staging,
            BindFlags = BindFlags.None,
            CPUAccessFlags = CpuAccessFlags.Read,
            MiscFlags = ResourceOptionFlags.None
        });

        _clean = new byte[Width * Height * 4];
        _out = new byte[Width * Height * 4];
        _outHandle = GCHandle.Alloc(_out, GCHandleType.Pinned);
        FramePtr = _outHandle.AddrOfPinnedObject();

        Console.WriteLine($"DXGI capture: {DeviceName} {Width}x{Height} (GPU Desktop Duplication, cursor overlay)");
    }

    /// <summary>
    /// Poll for the next frame/cursor update. On a new desktop frame refresh the
    /// clean buffer; on any update re-composite cursor into the output buffer.
    /// Returns true once a frame is available (use FramePtr/Stride afterwards).
    /// </summary>
    public bool Update(int timeoutMs)
    {
        if (_dup == null)
        {
            // Back off: only retry re-duplication every 2 seconds
            long now = Environment.TickCount64;
            if (now - _dupLostTicks < 2000) return Ready;
            _dupLostTicks = now;
            ReinitDuplication();
            if (_dup == null) return Ready;
        }
        var res = _dup.AcquireNextFrame(timeoutMs, out OutduplFrameInfo info, out IDXGIResource? resource);
        if (res.Code == unchecked((int)0x887A0027)) // DXGI_ERROR_WAIT_TIMEOUT — nothing changed
        {
            resource?.Dispose();
            return Ready;
        }
        if (res.Code == unchecked((int)0x887A0026) ||  // DXGI_ERROR_ACCESS_LOST (mode change/UAC/fullscreen)
            res.Code == unchecked((int)0x887A0022))    // DXGI_ERROR_ACCESS_DENIED
        {
            resource?.Dispose();
            ReinitDuplication();
            return Ready; // reuse last frame this tick; next tick resumes
        }
        res.CheckError();

        bool desktopChanged = info.LastPresentTime != 0;
        if (desktopChanged)
        {
            using (resource)
            using (var tex = resource!.QueryInterface<ID3D11Texture2D>())
                _context.CopyResource(_staging, tex);

            var box = _context.Map(_staging, 0, MapMode.Read, Vortice.Direct3D11.MapFlags.None);
            CopyTight(box.DataPointer, (int)box.RowPitch);
            _context.Unmap(_staging, 0);
        }
        else
        {
            resource?.Dispose();
        }

        if (info.LastMouseUpdateTime != 0)
        {
            _curVisible = info.PointerPosition.Visible;
            _curX = info.PointerPosition.Position.X;
            _curY = info.PointerPosition.Position.Y;
            if (info.PointerShapeBufferSize > 0)
                FetchCursorShape(info.PointerShapeBufferSize);
        }

        _dup.ReleaseFrame();

        Composite();
        Ready = true;
        return true;
    }

    /// <summary>
    /// GPU-path update: keep the desktop frame entirely in video memory and return the BGRA
    /// desktop texture (cursor is composited downstream by the GPU converter). No CPU readback.
    /// Returns null until the first frame is available.
    /// </summary>
    public ID3D11Texture2D? UpdateGpu(int timeoutMs)
    {
        _desktopTex ??= _device.CreateTexture2D(new Texture2DDescription
        {
            Width = Width, Height = Height, MipLevels = 1, ArraySize = 1,
            Format = Format.B8G8R8A8_UNorm,
            SampleDescription = new SampleDescription(1, 0),
            Usage = ResourceUsage.Default,
            BindFlags = BindFlags.ShaderResource | BindFlags.RenderTarget,
            CPUAccessFlags = CpuAccessFlags.None,
            MiscFlags = ResourceOptionFlags.None
        });

        if (_dup == null)
        {
            long now = Environment.TickCount64;
            if (now - _dupLostTicks < 2000) return Ready ? _desktopTex : null;
            _dupLostTicks = now;
            ReinitDuplication();
            if (_dup == null) return Ready ? _desktopTex : null;
        }

        // First frame after VDD enable often needs a longer wait — the virtual display may not
        // Present until DWM finishes composing it.
        int waitMs = Ready ? timeoutMs : Math.Max(timeoutMs, 500);
        var res = _dup.AcquireNextFrame(waitMs, out OutduplFrameInfo info, out IDXGIResource? resource);
        if (res.Code == unchecked((int)0x887A0027)) // WAIT_TIMEOUT — nothing changed, reuse last
        {
            resource?.Dispose();
            // Brand-new output (esp. VDD right after Enable) can sit with no Present for seconds.
            // Still expose a (black) desktop texture so encode/input keep running; the first real
            // Present will overwrite _desktopTex.
            if (!Ready)
            {
                Ready = true;
                Console.WriteLine("DXGI: no first Present yet — starting with blank frame");
            }
            return _desktopTex;
        }
        if (res.Code == unchecked((int)0x887A0026) || res.Code == unchecked((int)0x887A0022)) // access lost/denied
        {
            resource?.Dispose();
            ReinitDuplication();
            return Ready ? _desktopTex : null;
        }
        res.CheckError();

        if (info.LastPresentTime != 0)
        {
            using (resource)
            using (var tex = resource!.QueryInterface<ID3D11Texture2D>())
                _context.CopyResource(_desktopTex, tex); // GPU→GPU, no CPU touch
        }
        else
        {
            resource?.Dispose();
        }

        if (info.LastMouseUpdateTime != 0)
        {
            _curVisible = info.PointerPosition.Visible;
            _curX = info.PointerPosition.Position.X;
            _curY = info.PointerPosition.Position.Y;
            if (info.PointerShapeBufferSize > 0)
                FetchCursorShape(info.PointerShapeBufferSize);
        }

        _dup.ReleaseFrame();
        Ready = true;
        return _desktopTex;
    }

    // Copy mapped (possibly padded) staging rows into the tight _clean buffer.
    private unsafe void CopyTight(IntPtr src, int srcPitch)
    {
        int rowBytes = Width * 4;
        byte* s = (byte*)src;
        fixed (byte* d = _clean)
            for (int y = 0; y < Height; y++)
                Buffer.MemoryCopy(s + (long)y * srcPitch, d + (long)y * rowBytes, rowBytes, rowBytes);
    }

    // _out = _clean, then blend the cursor on top at its current position.
    private unsafe void Composite()
    {
        Array.Copy(_clean, _out, _out.Length);
        if (!_curVisible || _curBgra == null) return;

        int rowBytes = Width * 4;
        fixed (byte* dst = _out)
        fixed (byte* cur = _curBgra)
        {
            for (int cy = 0; cy < _curH; cy++)
            {
                int dy = _curY + cy;
                if (dy < 0 || dy >= Height) continue;
                for (int cx = 0; cx < _curW; cx++)
                {
                    int dx = _curX + cx;
                    if (dx < 0 || dx >= Width) continue;
                    byte* sp = cur + ((long)cy * _curW + cx) * 4;
                    byte a = sp[3];
                    if (a == 0) continue;
                    byte* dp = dst + (long)dy * rowBytes + (long)dx * 4;
                    if (a == 255)
                    {
                        dp[0] = sp[0]; dp[1] = sp[1]; dp[2] = sp[2];
                    }
                    else
                    {
                        dp[0] = (byte)((sp[0] * a + dp[0] * (255 - a)) / 255);
                        dp[1] = (byte)((sp[1] * a + dp[1] * (255 - a)) / 255);
                        dp[2] = (byte)((sp[2] * a + dp[2] * (255 - a)) / 255);
                    }
                }
            }
        }
    }

    // Desktop Duplication access can be lost (resolution change, UAC secure desktop, a fullscreen
    // exclusive app). Re-acquire the duplication; on failure we retry next tick.
    // Back off harder on repeated failures so we don't spin the iGPU/CPU when access is denied.
    private int _reinitFailStreak;
    private void ReinitDuplication()
    {
        try { _dup?.Dispose(); } catch { }
        _dup = null;
        try
        {
            _dup = _output1.DuplicateOutput(_device);
            _reinitFailStreak = 0;
            Console.WriteLine("DXGI duplication re-acquired");
        }
        catch (Exception ex)
        {
            _reinitFailStreak = Math.Min(_reinitFailStreak + 1, 10);
            // 2s, 4s, … up to 10s between retries; log only every few failures to avoid spam.
            _dupLostTicks = Environment.TickCount64 + (_reinitFailStreak * 1000);
            if (_reinitFailStreak <= 2 || _reinitFailStreak % 5 == 0)
                Console.WriteLine($"DXGI re-duplicate failed (backoff {_reinitFailStreak + 1}s): {ex.Message}");
        }
    }

    private byte[] _shapeBuf = Array.Empty<byte>();

    private void FetchCursorShape(int size)
    {
        if (_shapeBuf.Length < size) _shapeBuf = new byte[size];
        GCHandle h = GCHandle.Alloc(_shapeBuf, GCHandleType.Pinned);
        var info = default(Vortice.DXGI.OutduplPointerShapeInfo);
        try
        {
            _dup.GetFramePointerShape(size, h.AddrOfPinnedObject(), out _, out info).CheckError();
        }
        finally { h.Free(); }

        CursorShapeDirty = true; // GPU path: signal converter to re-upload the cursor substream

        // Type: 1=Monochrome, 2=Color, 4=MaskedColor
        if (info.Type == 2 || info.Type == 4)
        {
            _curW = info.Width; _curH = info.Height;
            EnsureCursor(_curW * _curH * 4);
            for (int y = 0; y < _curH; y++)
                for (int x = 0; x < _curW; x++)
                {
                    int si = y * info.Pitch + x * 4;
                    int di = (y * _curW + x) * 4;
                    byte b = _shapeBuf[si], g = _shapeBuf[si + 1], r = _shapeBuf[si + 2], a = _shapeBuf[si + 3];
                    if (info.Type == 4) a = a == 0 ? (byte)255 : (byte)0; // masked: alpha 0 = opaque
                    _curBgra![di] = b; _curBgra[di + 1] = g; _curBgra[di + 2] = r; _curBgra[di + 3] = a;
                }
        }
        else // monochrome: top half = AND mask, bottom half = XOR mask, 1bpp
        {
            _curW = info.Width; _curH = info.Height / 2;
            EnsureCursor(_curW * _curH * 4);
            for (int y = 0; y < _curH; y++)
                for (int x = 0; x < _curW; x++)
                {
                    int andBit = (_shapeBuf[y * info.Pitch + (x >> 3)] >> (7 - (x & 7))) & 1;
                    int xorBit = (_shapeBuf[(y + _curH) * info.Pitch + (x >> 3)] >> (7 - (x & 7))) & 1;
                    int di = (y * _curW + x) * 4;
                    byte v, a;
                    if (andBit == 0) { v = (byte)(xorBit == 1 ? 255 : 0); a = 255; }   // opaque black/white
                    else { a = (byte)(xorBit == 1 ? 255 : 0); v = 255; }               // xor=1 invert→white, else transparent
                    if (andBit == 1 && xorBit == 1)
                    {
                        // I-beam cursors often use invert pixels. The GPU cursor substream
                        // cannot invert the desktop, so draw those pixels black instead.
                        v = 0;
                        a = 255;
                    }
                    _curBgra![di] = v; _curBgra[di + 1] = v; _curBgra[di + 2] = v; _curBgra[di + 3] = a;
                }
        }
    }

    private void EnsureCursor(int bytes)
    {
        if (_curBgra == null || _curBgra.Length < bytes) _curBgra = new byte[bytes];
    }

    public void Dispose()
    {
        if (_outHandle.IsAllocated) _outHandle.Free();
        _desktopTex?.Dispose();
        _staging?.Dispose();
        _dup?.Dispose();
        _output1?.Dispose();
        _context?.Dispose();
        _device?.Dispose();
    }
}
