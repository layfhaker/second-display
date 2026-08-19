using System.Runtime.InteropServices;

namespace SecondDisplay.Host;

public static class SelfTest
{
    /// <summary>
    /// Encode synthetic moving frames to a raw .h265 file so we can validate the
    /// MF/QuickSync encoder on this machine (probe with ffprobe) without the tablet.
    /// </summary>
    public static void RunHevc(string outPath, int w = 1920, int h = 1080, int feedFps = 30)
    {
        int fps = 30; const int frames = 60;
        Console.WriteLine($"HEVC self-test: {w}x{h} {frames} frames, feed {feedFps}fps -> {outPath}");

        using var fs = File.Create(outPath);
        var encoder = new HevcEncoder(w, h, fps, bitrate: 8_000_000);
        int got = 0;
        long totalBytes = 0;
        encoder.OnEncodedFrame = (data, pts, key) =>
        {
            fs.Write(data, 0, data.Length);
            got++;
            totalBytes += data.Length;
            if (got <= 5 || got % 20 == 0)
                Console.WriteLine($"  frame {got}: {data.Length} bytes (starts {data[0]:X2} {data[1]:X2} {data[2]:X2} {data[3]:X2} {data[4]:X2})");
        };

        // Synthetic BGRA buffer with a moving vertical band.
        var bgra = Marshal.AllocHGlobal(w * h * 4);
        try
        {
            var nv12 = new byte[w * h * 3 / 2];
            for (int f = 0; f < frames; f++)
            {
                FillFrame(bgra, w, h, f);
                ColorConvert.BgraToNv12(bgra, w * 4, w, h, nv12);
                encoder.SubmitFrame((byte[])nv12.Clone(), (long)f * 1_000_000 / fps);
                Thread.Sleep(1000 / feedFps);
            }
            Thread.Sleep(800); // let encoder drain
        }
        finally
        {
            Marshal.FreeHGlobal(bgra);
            encoder.Dispose();
        }

        Console.WriteLine($"Done. {got} encoded frames, {totalBytes} bytes total, file: {outPath}");
    }

    static unsafe void FillFrame(IntPtr bgra, int w, int h, int frame)
    {
        byte* p = (byte*)bgra;
        int band = (frame * 16) % w;
        for (int y = 0; y < h; y++)
        {
            for (int x = 0; x < w; x++)
            {
                int i = (y * w + x) * 4;
                bool inBand = (x >= band && x < band + 80);
                p[i + 0] = (byte)(inBand ? 255 : (x * 255 / w));   // B
                p[i + 1] = (byte)(y * 255 / h);                    // G
                p[i + 2] = (byte)(inBand ? 0 : 128);               // R
                p[i + 3] = 255;
            }
        }
    }
}
