namespace SecondDisplay.Host;

public static class ColorConvert
{
    /// <summary>
    /// Convert a BGRA (B,G,R,A byte order) frame to NV12 (Y plane + interleaved U,V).
    /// Width and height must be even. Output length = w*h*3/2.
    /// </summary>
    public static unsafe void BgraToNv12(IntPtr bgra, int stride, int width, int height, byte[] nv12)
    {
        byte* src = (byte*)bgra;
        int ySize = width * height;

        fixed (byte* dst = nv12)
        {
            byte* yPlane = dst;
            byte* uvPlane = dst + ySize;

            System.Threading.Tasks.Parallel.For(0, height, y =>
            {
                byte* row = src + (long)y * stride;
                byte* yOut = yPlane + (long)y * width;
                for (int x = 0; x < width; x++)
                {
                    byte b = row[x * 4 + 0];
                    byte g = row[x * 4 + 1];
                    byte r = row[x * 4 + 2];
                    yOut[x] = (byte)(((66 * r + 129 * g + 25 * b + 128) >> 8) + 16);
                }
            });

            // UV: 2x2 subsample, take top-left pixel of each block.
            System.Threading.Tasks.Parallel.For(0, height / 2, yy =>
            {
                int y = yy * 2;
                byte* row = src + (long)y * stride;
                byte* uvOut = uvPlane + (long)yy * width;
                for (int x = 0; x < width; x += 2)
                {
                    byte b = row[x * 4 + 0];
                    byte g = row[x * 4 + 1];
                    byte r = row[x * 4 + 2];
                    uvOut[x] = (byte)(((-38 * r - 74 * g + 112 * b + 128) >> 8) + 128);     // U
                    uvOut[x + 1] = (byte)(((112 * r - 94 * g - 18 * b + 128) >> 8) + 128);  // V
                }
            });
        }
    }
}
