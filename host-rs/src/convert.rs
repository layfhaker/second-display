//! BGRA → NV12 conversion (CPU path), mirroring the C# `ColorConvert`.

/// Convert a tight BGRA buffer (`stride` bytes/row) into NV12 (Y plane + interleaved UV).
/// Uses the same BT.601 limited-range coefficients as the C# host.
pub fn bgra_to_nv12(src: &[u8], src_stride: usize, out: &mut [u8], w: usize, h: usize) {
    let y_size = w * h;
    // Y plane
    for y in 0..h {
        let row = y * src_stride;
        let drow = y * w;
        for x in 0..w {
            let si = row + x * 4;
            let b = src[si] as i32;
            let g = src[si + 1] as i32;
            let r = src[si + 2] as i32;
            let yy = ((66 * r + 129 * g + 25 * b + 128) >> 8) + 16;
            out[drow + x] = yy.clamp(0, 255) as u8;
        }
    }
    // UV plane (2x2 box averaged)
    for y in (0..h).step_by(2) {
        let row0 = y * src_stride;
        let row1 = ((y + 1).min(h - 1)) * src_stride;
        let drow = y_size + (y / 2) * w;
        for x in (0..w).step_by(2) {
            let x1 = (x + 1).min(w - 1);
            let mut rs = 0i32;
            let mut gs = 0i32;
            let mut bs = 0i32;
            for (rx, ry) in [(x, row0), (x1, row0), (x, row1), (x1, row1)] {
                let si = ry + rx * 4;
                bs += src[si] as i32;
                gs += src[si + 1] as i32;
                rs += src[si + 2] as i32;
            }
            let r = rs / 4;
            let g = gs / 4;
            let b = bs / 4;
            let u = ((-38 * r - 74 * g + 112 * b + 128) >> 8) + 128;
            let v = ((112 * r - 94 * g - 18 * b + 128) >> 8) + 128;
            out[drow + x] = u.clamp(0, 255) as u8;
            if x + 1 < w {
                out[drow + x + 1] = v.clamp(0, 255) as u8;
            }
        }
    }
}
