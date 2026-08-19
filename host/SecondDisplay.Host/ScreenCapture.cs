using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

namespace SecondDisplay.Host;

public sealed class ScreenCapture : IDisposable
{
    private readonly Bitmap _bitmap;
    private readonly Graphics _graphics;
    private readonly int _originX;
    private readonly int _originY;

    public int Width { get; }
    public int Height { get; }

    /// <summary>Capture a specific virtual-screen rectangle (e.g. one monitor's bounds).</summary>
    public ScreenCapture(int originX, int originY, int width, int height)
    {
        Width = width;
        Height = height;
        _originX = originX;
        _originY = originY;

        _bitmap = new Bitmap(Width, Height, PixelFormat.Format32bppArgb);
        _graphics = Graphics.FromImage(_bitmap);

        Console.WriteLine($"Screen capture initialized: {Width}x{Height} at ({_originX},{_originY})");
    }

    public readonly record struct MonitorInfo(int Index, string Device, int X, int Y, int Width, int Height, bool Primary);

    /// <summary>Enumerate monitors in virtual-screen (physical, DPI-aware) coordinates.</summary>
    public static List<MonitorInfo> GetMonitors()
    {
        var list = new List<MonitorInfo>();
        int i = 0;
        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, (IntPtr hMon, IntPtr hdc, ref RECT r, IntPtr d) =>
        {
            var mi = new MONITORINFOEX { cbSize = Marshal.SizeOf<MONITORINFOEX>() };
            if (GetMonitorInfo(hMon, ref mi))
            {
                list.Add(new MonitorInfo(i++, mi.szDevice,
                    mi.rcMonitor.left, mi.rcMonitor.top,
                    mi.rcMonitor.right - mi.rcMonitor.left,
                    mi.rcMonitor.bottom - mi.rcMonitor.top,
                    (mi.dwFlags & MONITORINFOF_PRIMARY) != 0));
            }
            return true;
        }, IntPtr.Zero);
        return list;
    }

    public byte[] CaptureJpeg(int quality = 60)
    {
        _graphics.CopyFromScreen(_originX, _originY, 0, 0, new Size(Width, Height), CopyPixelOperation.SourceCopy);

        using var ms = new MemoryStream();
        var encoder = ImageCodecInfo.GetImageEncoders().First(c => c.FormatID == ImageFormat.Jpeg.Guid);
        var encoderParams = new EncoderParameters(1);
        encoderParams.Param[0] = new EncoderParameter(Encoder.Quality, (long)quality);
        _bitmap.Save(ms, encoder, encoderParams);
        return ms.ToArray();
    }

    /// <summary>Grab the screen and lock its pixels (BGRA). Call UnlockBgra when done.</summary>
    public BitmapData LockBgra()
    {
        _graphics.CopyFromScreen(_originX, _originY, 0, 0, new Size(Width, Height), CopyPixelOperation.SourceCopy);
        DrawCursor(_graphics);
        return _bitmap.LockBits(
            new Rectangle(0, 0, Width, Height),
            ImageLockMode.ReadOnly,
            PixelFormat.Format32bppArgb);
    }

    public void UnlockBgra(BitmapData data) => _bitmap.UnlockBits(data);

    /// <summary>BitBlt doesn't include the cursor, so draw it onto the frame ourselves.</summary>
    void DrawCursor(Graphics g)
    {
        var ci = new CURSORINFO { cbSize = Marshal.SizeOf<CURSORINFO>() };
        if (!GetCursorInfo(ref ci) || ci.flags != CURSOR_SHOWING || ci.hCursor == IntPtr.Zero)
            return;

        int hotX = 0, hotY = 0;
        if (GetIconInfo(ci.hCursor, out var ii))
        {
            hotX = ii.xHotspot;
            hotY = ii.yHotspot;
            if (ii.hbmMask != IntPtr.Zero) DeleteObject(ii.hbmMask);
            if (ii.hbmColor != IntPtr.Zero) DeleteObject(ii.hbmColor);
        }

        IntPtr hdc = g.GetHdc();
        try
        {
            DrawIconEx(hdc, ci.ptScreenPos.x - _originX - hotX, ci.ptScreenPos.y - _originY - hotY,
                       ci.hCursor, 0, 0, 0, IntPtr.Zero, DI_NORMAL);
        }
        finally
        {
            g.ReleaseHdc(hdc);
        }
    }

    const int CURSOR_SHOWING = 0x00000001;
    const int DI_NORMAL = 0x0003;

    [StructLayout(LayoutKind.Sequential)]
    struct POINT { public int x, y; }

    [StructLayout(LayoutKind.Sequential)]
    struct CURSORINFO { public int cbSize; public int flags; public IntPtr hCursor; public POINT ptScreenPos; }

    [StructLayout(LayoutKind.Sequential)]
    struct ICONINFO { public bool fIcon; public int xHotspot; public int yHotspot; public IntPtr hbmMask; public IntPtr hbmColor; }

    [DllImport("user32.dll")] static extern bool GetCursorInfo(ref CURSORINFO pci);
    [DllImport("user32.dll")] static extern bool GetIconInfo(IntPtr hIcon, out ICONINFO piconinfo);
    [DllImport("user32.dll")] static extern bool DrawIconEx(IntPtr hdc, int xLeft, int yTop, IntPtr hIcon, int cxWidth, int cyHeight, int istepIfAniCur, IntPtr hbrFlickerFreeDraw, int diFlags);
    [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr hObject);

    public void Dispose()
    {
        _graphics.Dispose();
        _bitmap.Dispose();
    }

    const int MONITORINFOF_PRIMARY = 0x1;

    [StructLayout(LayoutKind.Sequential)]
    struct RECT { public int left, top, right, bottom; }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct MONITORINFOEX
    {
        public int cbSize;
        public RECT rcMonitor;
        public RECT rcWork;
        public uint dwFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string szDevice;
    }

    delegate bool MonitorEnumProc(IntPtr hMonitor, IntPtr hdcMonitor, ref RECT lprcMonitor, IntPtr dwData);

    [DllImport("user32.dll")]
    static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr lprcClip, MonitorEnumProc lpfnEnum, IntPtr dwData);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern bool GetMonitorInfo(IntPtr hMonitor, ref MONITORINFOEX lpmi);
}
