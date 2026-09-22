using Vortice;
using Vortice.Direct3D11;
using Vortice.DXGI;

namespace SecondDisplay.Host;

/// <summary>
/// GPU BGRA→NV12 colour conversion via ID3D11VideoProcessor (fixed-function VPP block on the
/// Intel iGPU), composing the mouse cursor as an alpha-blended substream in the same blit.
///
/// This replaces the CPU hot path (staging readback + ColorConvert.BgraToNv12 + CPU cursor
/// composite, ~25 ms/frame) so the whole tract stays in video memory: DXGI desktop texture →
/// VPP → NV12 texture → encoder, no GPU↔CPU round-trips.
/// </summary>
public sealed class GpuColorConverter : IDisposable
{
    readonly ID3D11Device _device;
    readonly ID3D11VideoDevice _videoDevice;
    readonly ID3D11VideoContext _videoContext;
    readonly ID3D11VideoProcessor _processor;
    readonly ID3D11VideoProcessorEnumerator _enumerator;

    readonly int _inputWidth, _inputHeight;
    readonly int _width, _height;
    bool _cursorSupported;

    // Ring of NV12 output textures + their output views. Must be larger than the encoder's in-flight
    // depth: if we overwrite a texture the MFT still holds, the GPU serializes → encode fps collapses.
    const int RingSize = 8;
    readonly ID3D11Texture2D[] _nv12 = new ID3D11Texture2D[RingSize];
    readonly ID3D11VideoProcessorOutputView[] _outViews = new ID3D11VideoProcessorOutputView[RingSize];
    int _ring;

    // Desktop input view (stable texture → created once).
    ID3D11VideoProcessorInputView? _desktopView;
    ID3D11Texture2D? _desktopForView;

    // Cursor substream state.
    ID3D11Texture2D? _cursorTex;
    ID3D11VideoProcessorInputView? _cursorView;
    int _cursorTexW, _cursorTexH;

    public int Width => _width;
    public int Height => _height;

    public GpuColorConverter(ID3D11Device device, ID3D11DeviceContext context, int width, int height, int fps)
        : this(device, context, width, height, width, height, fps)
    {
    }

    public GpuColorConverter(ID3D11Device device, ID3D11DeviceContext context, int inputWidth, int inputHeight, int outputWidth, int outputHeight, int fps)
    {
        _device = device;
        _inputWidth = inputWidth & ~1;
        _inputHeight = inputHeight & ~1;
        _width = outputWidth & ~1;
        _height = outputHeight & ~1;

        _videoDevice = device.QueryInterface<ID3D11VideoDevice>();
        _videoContext = context.QueryInterface<ID3D11VideoContext>();

        var content = new VideoProcessorContentDescription
        {
            InputFrameFormat = VideoFrameFormat.Progressive,
            InputWidth = _inputWidth,
            InputHeight = _inputHeight,
            OutputWidth = _width,
            OutputHeight = _height,
            InputFrameRate = new Rational(fps, 1),
            OutputFrameRate = new Rational(fps, 1),
            Usage = VideoUsage.OptimalSpeed
        };
        _enumerator = _videoDevice.CreateVideoProcessorEnumerator(content);

        // Cursor needs a second input stream. Most Intel VPP supports many; guard anyway.
        int maxStreams = 1;
        try { maxStreams = _enumerator.VideoProcessorCaps.MaxInputStreams; } catch { }
        _cursorSupported = maxStreams >= 2;

        _processor = _videoDevice.CreateVideoProcessor(_enumerator, 0);

        // Input is full-range RGB (desktop); output is BT.601 studio-range YCbCr to match the
        // previous CPU coefficients (so the tablet decoder sees the same colours it did before).
        _videoContext.VideoProcessorSetStreamColorSpace(_processor, 0, new VideoProcessorColorSpace
        {
            Usage = 0, RGB_Range = 0 /*full*/, YCbCr_Matrix = 0, Nominal_Range = 2 /*0-255*/
        });
        _videoContext.VideoProcessorSetOutputColorSpace(_processor, new VideoProcessorColorSpace
        {
            Usage = 0, YCbCr_Matrix = 0 /*BT.601*/, Nominal_Range = 1 /*16-235*/
        });
        // Disable frame-rate conversion / interpolation — we feed each captured frame straight through.
        _videoContext.VideoProcessorSetStreamFrameFormat(_processor, 0, VideoFrameFormat.Progressive);

        for (int i = 0; i < RingSize; i++)
        {
            _nv12[i] = device.CreateTexture2D(new Texture2DDescription
            {
                Width = _width, Height = _height, MipLevels = 1, ArraySize = 1,
                Format = Format.NV12,
                SampleDescription = new SampleDescription(1, 0),
                Usage = ResourceUsage.Default,
                BindFlags = BindFlags.RenderTarget,
                CPUAccessFlags = CpuAccessFlags.None,
                MiscFlags = ResourceOptionFlags.None
            });
            _outViews[i] = _videoDevice.CreateVideoProcessorOutputView(_nv12[i], _enumerator,
                new VideoProcessorOutputViewDescription
                {
                    ViewDimension = VideoProcessorOutputViewDimension.Texture2D,
                    Texture2D = new Texture2DVideoProcessorOutputView { MipSlice = 0 }
                });
        }

        Console.WriteLine($"GPU VPP: BGRA {_inputWidth}x{_inputHeight}->NV12 {_width}x{_height}, cursor substream {(_cursorSupported ? "ON" : "unsupported")} (maxStreams={maxStreams})");
    }

    ID3D11VideoProcessorInputView DesktopView(ID3D11Texture2D desktop)
    {
        if (_desktopView != null && ReferenceEquals(_desktopForView, desktop)) return _desktopView;
        _desktopView?.Dispose();
        _desktopForView = desktop;
        _desktopView = _videoDevice.CreateVideoProcessorInputView(desktop, _enumerator,
            new VideoProcessorInputViewDescription
            {
                FourCC = 0,
                ViewDimension = VideoProcessorInputViewDimension.Texture2D,
                Texture2D = new Texture2DVideoProcessorInputView { MipSlice = 0, ArraySlice = 0 }
            });
        return _desktopView;
    }

    /// <summary>
    /// Upload a fresh cursor shape (straight BGRA) into the substream texture. Pass when the shape
    /// changes; size may differ each time so the texture is recreated as needed.
    /// </summary>
    public unsafe void UpdateCursorShape(byte[] bgra, int w, int h, ID3D11DeviceContext context)
    {
        if (!_cursorSupported || w <= 0 || h <= 0) return;
        if (_cursorTex == null || _cursorTexW != w || _cursorTexH != h)
        {
            _cursorView?.Dispose(); _cursorTex?.Dispose();
            _cursorTexW = w; _cursorTexH = h;
            // Default usage (not Dynamic): the VideoProcessor requires Default-usage input textures.
            _cursorTex = _device.CreateTexture2D(new Texture2DDescription
            {
                Width = w, Height = h, MipLevels = 1, ArraySize = 1,
                Format = Format.B8G8R8A8_UNorm,
                SampleDescription = new SampleDescription(1, 0),
                Usage = ResourceUsage.Default,
                BindFlags = BindFlags.ShaderResource | BindFlags.RenderTarget,
                CPUAccessFlags = CpuAccessFlags.None,
                MiscFlags = ResourceOptionFlags.None
            });
            try
            {
                _cursorView = _videoDevice.CreateVideoProcessorInputView(_cursorTex, _enumerator,
                    new VideoProcessorInputViewDescription
                    {
                        FourCC = 0,
                        ViewDimension = VideoProcessorInputViewDimension.Texture2D,
                        Texture2D = new Texture2DVideoProcessorInputView { MipSlice = 0, ArraySlice = 0 }
                    });
            }
            catch (Exception ex)
            {
                // This VPP rejects the cursor substream input view — degrade gracefully (no GPU
                // cursor) rather than crashing; the desktop still streams. Cursor can move to a
                // tablet-side overlay later (see roadmap Phase 4 notes).
                Console.WriteLine($"GPU cursor substream disabled ({ex.Message.Trim()}).");
                _cursorSupported = false;
                _cursorView?.Dispose(); _cursorTex?.Dispose(); _cursorTex = null;
                return;
            }
        }
        fixed (byte* src = bgra)
            context.UpdateSubresource(_cursorTex!, 0, null, (IntPtr)src, w * 4, w * h * 4);
    }

    /// <summary>
    /// Convert the current desktop texture to NV12 (compositing the cursor if visible) and return
    /// the NV12 texture from the ring. The texture is valid until RingSize subsequent calls.
    /// </summary>
    public ID3D11Texture2D Convert(ID3D11Texture2D desktop, bool cursorVisible, int curX, int curY)
    {
        int slot = _ring; _ring = (_ring + 1) % RingSize;

        var desktopView = DesktopView(desktop);
        bool drawCursor = _cursorSupported && cursorVisible && _cursorView != null;

        // Stream 0: desktop, full frame.
        _videoContext.VideoProcessorSetStreamSourceRect(_processor, 0, true, new RawRect(0, 0, _inputWidth, _inputHeight));
        _videoContext.VideoProcessorSetStreamDestRect(_processor, 0, true, new RawRect(0, 0, _width, _height));

        VideoProcessorStream[] streams;
        if (drawCursor)
        {
            // Stream 1: cursor at its position, per-pixel alpha blended over the desktop.
            int cx2 = Math.Min(curX + _cursorTexW, _width);
            int cy2 = Math.Min(curY + _cursorTexH, _height);
            _videoContext.VideoProcessorSetStreamSourceRect(_processor, 1, true, new RawRect(0, 0, _cursorTexW, _cursorTexH));
            _videoContext.VideoProcessorSetStreamDestRect(_processor, 1, true, new RawRect(Math.Max(curX, 0), Math.Max(curY, 0), cx2, cy2));
            _videoContext.VideoProcessorSetStreamAlpha(_processor, 1, true, 1.0f);
            streams = new[]
            {
                new VideoProcessorStream { Enable = true, InputSurface = desktopView },
                new VideoProcessorStream { Enable = true, InputSurface = _cursorView! }
            };
        }
        else
        {
            streams = new[] { new VideoProcessorStream { Enable = true, InputSurface = desktopView } };
        }

        _videoContext.VideoProcessorBlt(_processor, _outViews[slot], 0, streams.Length, streams);
        return _nv12[slot];
    }

    ID3D11Texture2D? _stagingNv12;

    /// <summary>
    /// Copy an NV12 GPU texture into a tightly-packed CPU buffer (Y plane then UV).
    /// Used when the encoder runs without D3D11 zero-copy (more reliable throughput on
    /// this Intel driver than DXGI-surface input).
    /// </summary>
    public unsafe void ReadbackNv12(ID3D11Texture2D nv12Tex, ID3D11DeviceContext context, byte[] dest)
    {
        _stagingNv12 ??= _device.CreateTexture2D(new Texture2DDescription
        {
            Width = _width, Height = _height, MipLevels = 1, ArraySize = 1,
            Format = Format.NV12,
            SampleDescription = new SampleDescription(1, 0),
            Usage = ResourceUsage.Staging,
            BindFlags = BindFlags.None,
            CPUAccessFlags = CpuAccessFlags.Read,
            MiscFlags = ResourceOptionFlags.None
        });
        context.CopyResource(_stagingNv12, nv12Tex);
        var mapped = context.Map(_stagingNv12, 0, MapMode.Read, Vortice.Direct3D11.MapFlags.None);
        try
        {
            int ySize = _width * _height;
            int pitch = mapped.RowPitch;
            byte* src = (byte*)mapped.DataPointer;
            // Y plane
            for (int y = 0; y < _height; y++)
                System.Runtime.InteropServices.Marshal.Copy((IntPtr)(src + y * pitch), dest, y * _width, _width);
            // UV plane (interleaved, height/2 rows)
            byte* uv = src + pitch * _height;
            for (int y = 0; y < _height / 2; y++)
                System.Runtime.InteropServices.Marshal.Copy((IntPtr)(uv + y * pitch), dest, ySize + y * _width, _width);
        }
        finally
        {
            context.Unmap(_stagingNv12, 0);
        }
    }

    public void Dispose()
    {
        _desktopView?.Dispose();
        _cursorView?.Dispose();
        _cursorTex?.Dispose();
        _stagingNv12?.Dispose();
        for (int i = 0; i < RingSize; i++) { _outViews[i]?.Dispose(); _nv12[i]?.Dispose(); }
        _processor?.Dispose();
        _enumerator?.Dispose();
        _videoContext?.Dispose();
        _videoDevice?.Dispose();
    }
}
