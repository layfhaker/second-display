// SecondDisplay host, HolyC port - capture and colour conversion.
//
// Milestone 2. There is no D3D11 VideoProcessor here and no DXGI, so both halves are written out by
// hand: read the screen into a BGRA buffer, then convert to the NV12 the encoder stage expects.
//
// The conversion is plain integer BT.601 with limited (video) range, the same coefficients the
// hardware path uses, so the two hosts produce frames the client can compare:
//     Y  = ( 66*R + 129*G +  25*B + 128) >> 8) + 16
//     Cb = ((-38*R -  74*G + 112*B + 128) >> 8) + 128
//     Cr = ((112*R -  94*G -  18*B + 128) >> 8) + 128
// NV12 layout, exactly as the encoder is told: width*height luma bytes, then height/2 rows of
// interleaved Cb/Cr at width bytes per row.
//
// TempleOS specifics to verify against the installed headers before compiling (same rule the asm host
// uses for COM vtables - never guess, read it):
//   - how the framebuffer is reached (gr.dc / VGA memory) and its row pitch,
//   - GrWidth/GrHeight style globals for the screen size,
//   - whether the screen even has the 1920x1280 mode we announce; if not, scale or announce what we
//     have, because the client checks READY against the decoder's surface.

#define STREAM_W        1920
#define STREAM_H        1280
#define FRAME_NV12      3686400         // STREAM_W * STREAM_H * 3 / 2

U8 *frame_nv12;

U0 CaptureInit()
{
    frame_nv12 = MAlloc(FRAME_NV12);
}

U8 ClipU8(I64 v)
{
    if (v < 0)   return 0;
    if (v > 255) return 255;
    return v;
}

// One BGRA source row -> one NV12 luma row.
U0 BgraRowToY(U8 *src, U8 *dst, I64 pixels)
{
    I64 i;
    for (i = 0; i < pixels; i++) {
        I64 b = src[i * 4 + 0];
        I64 g = src[i * 4 + 1];
        I64 r = src[i * 4 + 2];
        dst[i] = ClipU8(((66 * r + 129 * g + 25 * b + 128) >> 8) + 16);
    }
}

// Two BGRA source rows -> one interleaved Cb/Cr chroma row (NV12 keeps chroma at half resolution in
// both directions, so the second row only contributes to the average).
U0 BgraRowsToUv(U8 *row0, U8 *row1, U8 *dst, I64 pixels)
{
    I64 x;
    for (x = 0; x < pixels; x += 2) {
        I64 b = row0[x * 4 + 0] + row0[(x + 1) * 4 + 0] + row1[x * 4 + 0] + row1[(x + 1) * 4 + 0];
        I64 g = row0[x * 4 + 1] + row0[(x + 1) * 4 + 1] + row1[x * 4 + 1] + row1[(x + 1) * 4 + 1];
        I64 r = row0[x * 4 + 2] + row0[(x + 1) * 4 + 2] + row1[x * 4 + 2] + row1[(x + 1) * 4 + 2];
        b >>= 2; g >>= 2; r >>= 2;
        dst[x]     = ClipU8((((-38 * r - 74 * g + 112 * b + 128) >> 8) + 128));
        dst[x + 1] = ClipU8(((112 * r - 94 * g - 18 * b + 128) >> 8) + 128);
    }
}

// Fill frame_nv12 from a BGRA buffer of width x height with the given source row pitch.
U0 ConvertBgraToNv12(U8 *bgra, I64 pitch, I64 width, I64 height)
{
    U8 *luma  = frame_nv12;
    U8 *chroma = frame_nv12 + width * height;
    I64 y;
    for (y = 0; y < height; y++)
        BgraRowToY(bgra + y * pitch, luma + y * width, width);
    for (y = 0; y < height; y += 2)
        BgraRowsToUv(bgra + y * pitch, bgra + (y + 1) * pitch, chroma + (y / 2) * width, width);
}

// Grab the screen into frame_nv12. The framebuffer access itself has to be verified against the
// TempleOS graphics headers; everything above this line is pure arithmetic and portable.
U0 CaptureFrame()
{
    U8 *fb = GrScreenBase;              // <- verify: framebuffer base
    I64 pitch = GrScreenPitch;          // <- verify: bytes per row
    ConvertBgraToNv12(fb, pitch, STREAM_W, STREAM_H);
}
