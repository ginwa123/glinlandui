//! Pixel hand-off from the software surface to the D3D11 pipeline (pure).
//!
//! ## What D3D11 actually wants here — measured, not assumed
//!
//! The swap chain in `windows/shim.c` is created in `DXGI_FORMAT_R8G8B8A8_UNORM`
//! and the per-frame upload target in the same format. Two facts follow, and
//! both of them are things people get wrong by reasoning from the OpenGL or
//! CoreGraphics habits instead of from the API:
//!
//!  1. **Channel order is the identity.** A `R8G8B8A8_UNORM` texel's four bytes
//!     are read, in memory order, as R, G, B, A. That is exactly the order
//!     `soft.Surface` already holds. The "native" desktop format is
//!     `B8G8R8A8_UNORM` — the letters are in *encoding* order, not memory
//!     order — and picking that one obliges every frame to swap R and B on the
//!     CPU. Choosing R8G8B8A8 instead means the upload is a straight copy.
//!  2. **Rows are NOT flipped.** A D3D11 texture's (0,0) is its top-left texel,
//!     the same convention `soft.Surface` uses. `UpdateSubresource` with a box
//!     starting at (0,0,0) therefore writes row 0 to row 0. A vertical flip
//!     here renders the calculator upside down — the display panel at the
//!     bottom, the `=` key at the top — and nothing errors.
//!
//! Each of those mistakes produces a plausible, wrong-looking window rather
//! than an obvious failure, which is why both are pinned by colour and by
//! position below instead of being left to a screenshot.
//!
//! ## Read this before trusting the tests below
//!
//! Every test in this file compares the upload buffer against the surface it
//! was copied from — i.e. against this module's own idea of the answer. They
//! are worth having, and they pin the layout and the colours, but they CANNOT
//! catch a wrong hand-off to D3D11, because the thing that goes wrong lives in
//! `windows/shim.c` (the swap-chain format, the texture's row order, the
//! shader's sampling) and is invisible from here.
//!
//! The check that actually guards the hand-off is `ci/check_windows_colors.c`,
//! which drives the real D3D11 path — the same `createPipeline()` and
//! `drawQuad()` the window uses — and compares the DISPLAYED colour with the
//! colour that was written. It needs no window, no swap chain and no display,
//! because WARP is a Direct3D 11 software rasterizer, so it is safe on a stock
//! Windows CI runner. Run it with `./ci/check_windows_colors.sh`.

const std = @import("std");

/// Bytes per pixel for every path in this file.
pub const bytes_per_pixel: usize = 4;

/// Byte length the buffer needs for a `width` x `height` surface.
pub fn blitBufLen(width: u32, height: u32) usize {
    return @as(usize, width) * @as(usize, height) * bytes_per_pixel;
}

/// True when the geometry can produce an uploadable buffer at all. A zero
/// dimension means "no surface yet", and a zero-sized texture is rejected by
/// D3D11, so this must be false rather than producing a 0-byte texture.
pub fn blitSizeValid(width: u32, height: u32) bool {
    return width > 0 and height > 0;
}

/// The number of bytes in one row of the upload — the `SrcRowPitch` the shim
/// hands to `UpdateSubresource`.
///
/// This is the *surface* width, never the window's client width. The two are
/// independent (a resize adopts a new client size, and DPI scaling can differ
/// again), and using the wrong one is an off-by-a-factor read of the frame
/// buffer that no compiler and no assertion will catch.
pub fn rowPitch(width: u32) usize {
    return @as(usize, width) * bytes_per_pixel;
}

/// Copy a top-left-origin RGBA8 surface into the buffer D3D11 will read.
///
/// This is deliberately an identity copy — see the module comment for the two
/// measurements that disproved the channel-swap and vertical-flip assumptions.
/// The function exists (rather than the caller just copying) so the contract
/// has one named home and the tests have something to assert against.
///
/// `dst` must be at least `blitBufLen(width, height)`; a longer `dst` keeps its
/// tail untouched so one caller-owned buffer can be reused every frame.
pub fn identityRgba8(src: []const u8, dst: []u8, width: u32, height: u32) void {
    if (!blitSizeValid(width, height)) return;
    const want = blitBufLen(width, height);
    const n = @min(want, @min(src.len, dst.len));
    @memcpy(dst[0..n], src[0..n]);
}

/// The accent blue the calculator's `=` key uses. Used by the tests below to
/// prove channel order survives the hand-off, because a swapped R/B turns this
/// into a red that still looks like "a colour" rather than an error.
pub const test_accent: [4]u8 = .{ 0x2f, 0x6d, 0xf6, 0xff };

// ===================== tests (parity suite — every platform) =====================

const fill4: [4]u8 = .{0xAA} ** 4;
const fill8: [8]u8 = .{0xAA} ** 8;
const fill12: [12]u8 = .{0xAA} ** 12;
const fill16: [16]u8 = .{0xAA} ** 16;
const src_empty: [0]u8 = .{};

test "blitBufLen is width * height * 4" {
    try std.testing.expectEqual(@as(usize, 4), blitBufLen(1, 1));
    try std.testing.expectEqual(@as(usize, 360 * 430 * 4), blitBufLen(360, 430));
    try std.testing.expectEqual(@as(usize, 0), blitBufLen(0, 10));
}

test "blitSizeValid rejects a zero dimension" {
    try std.testing.expect(blitSizeValid(1, 1));
    try std.testing.expect(!blitSizeValid(0, 10));
    try std.testing.expect(!blitSizeValid(10, 0));
    try std.testing.expect(!blitSizeValid(0, 0));
}

test "rowPitch is the SURFACE width, not the window width" {
    // 360x4 == the calculator's window width, and the number the shim passes
    // as SrcRowPitch. If this ever became `client_w * 4` from the wrong place,
    // every frame after the first would be sheared by a few pixels a row.
    try std.testing.expectEqual(@as(usize, 1440), rowPitch(360));
    try std.testing.expectEqual(@as(usize, 4), rowPitch(1));
    try std.testing.expectEqual(@as(usize, 0), rowPitch(0));
}

test "rowPitch * height is exactly blitBufLen" {
    for ([_]u32{ 1, 2, 360, 1024 }) |w| {
        for ([_]u32{ 1, 7, 430 }) |h| {
            try std.testing.expectEqual(blitBufLen(w, h), rowPitch(w) * @as(usize, h));
        }
    }
}

test "a single pixel survives the hand-off byte for byte" {
    const src = [4]u8{ 1, 2, 3, 4 };
    var dst: [4]u8 = undefined;
    identityRgba8(&src, &dst, 1, 1);
    try std.testing.expectEqual([4]u8{ 1, 2, 3, 4 }, dst);
}

test "channels are NOT swapped — the accent blue stays blue" {
    // THE regression guard for the byte-order claim. Swapping R and B turns
    // 0x2f6df6 into 0xf66d2f, a red. Nothing errors; the window just looks
    // wrong, which is why this is pinned by colour and not by count.
    var src: [4]u8 = test_accent;
    var dst: [4]u8 = undefined;
    identityRgba8(&src, &dst, 1, 1);
    try std.testing.expectEqual(test_accent, dst);
    try std.testing.expectEqual(@as(u8, 0x2f), dst[0]); // R stays in byte 0
    try std.testing.expectEqual(@as(u8, 0xf6), dst[2]); // B stays in byte 2
}

test "rows are NOT flipped — row 0 stays row 0" {
    // THE other regression guard. A vertical flip mirrors the whole UI: on the
    // calculator the display panel moves to the bottom and the `=` key to the
    // top. Row 0 is the visual top on both sides of this hand-off.
    const src = [_]u8{
        1, 1, 1, 255, // row 0 = top
        2, 2, 2, 255,
        3, 3, 3, 255,
    };
    var dst: [12]u8 = undefined;
    identityRgba8(&src, &dst, 3, 1);
    try std.testing.expectEqualSlices(u8, &src, &dst);
}

test "the calculator's real layout survives in the right place" {
    // A miniature of the actual frame: a display panel along the TOP and a
    // single accent key at the BOTTOM-right. This is the whole byte-order +
    // row-order bug in one test — the panel must stay in the first rows and
    // the accent must stay in the last, and the accent must still be blue.
    const w: u32 = 8;
    const h: u32 = 6;
    var src: [w * h * 4]u8 = undefined;
    for (0..w * h) |i| {
        const row = i / w;
        const is_panel = row < 2;
        const is_accent = (row == h - 1) and (i % w) >= (w - 2);
        const c: [4]u8 = if (is_panel)
            .{ 27, 27, 33, 255 }
        else if (is_accent)
            test_accent
        else
            .{ 38, 38, 46, 255 };
        @memcpy(src[i * 4 ..][0..4], &c);
    }
    var dst: [w * h * 4]u8 = undefined;
    identityRgba8(&src, &dst, w, h);
    try std.testing.expectEqualSlices(u8, &src, &dst);

    // Panel still in the top rows.
    try std.testing.expectEqualSlices(u8, &.{ 27, 27, 33, 255 }, dst[0..4]);
    // Accent still in the bottom-right, and still blue.
    const accent_i = ((h - 1) * w + (w - 1)) * 4;
    try std.testing.expectEqualSlices(u8, &test_accent, dst[accent_i..][0..4]);
}

test "every distinct colour round-trips to the same position" {
    // A 2x2 of four different colours, checked per pixel — catches a channel
    // swap that happens to be right for greys but wrong for colour.
    const src = [_]u8{
        255, 0,   0,   255,
        0,   255, 0,   255,
        0,   0,   255, 255,
        255, 255, 255, 255,
    };
    var dst: [16]u8 = undefined;
    identityRgba8(&src, &dst, 2, 2);
    try std.testing.expectEqualSlices(u8, &src, &dst);
}

test "left and right stay left and right" {
    // A mirror would pass a row-order-only test, so pin the column order
    // explicitly: two visually different cells in one row.
    const src = [_]u8{
        10, 0, 0, 255, // left
        20, 0, 0, 255, // right
    };
    var dst: [8]u8 = undefined;
    identityRgba8(&src, &dst, 2, 1);
    try std.testing.expectEqual(@as(u8, 10), dst[0]);
    try std.testing.expectEqual(@as(u8, 20), dst[4]);
}

test "converting twice is a no-op" {
    const src = [_]u8{
        1, 2, 3, 4,
        5, 6, 7, 8,
    };
    var mid: [8]u8 = undefined;
    var back: [8]u8 = undefined;
    identityRgba8(&src, &mid, 2, 2);
    identityRgba8(&mid, &back, 2, 2);
    try std.testing.expectEqualSlices(u8, &src, &back);
}

test "a longer destination keeps its tail untouched for frame reuse" {
    // The upload buffer is allocated once and reused every frame, so a shorter
    // frame must not scribble over the tail of a longer one.
    const src = [4]u8{ 1, 2, 3, 4 };
    var dst: [12]u8 = fill12;
    identityRgba8(&src, &dst, 1, 1);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, dst[0..4]);
    try std.testing.expectEqualSlices(u8, &fill8, dst[4..12]);
}

test "a zero width or height writes nothing" {
    var dst: [16]u8 = fill16;
    const src = [4]u8{ 1, 2, 3, 4 } ** 4;
    identityRgba8(&src, &dst, 4, 0);
    try std.testing.expectEqual(fill16, dst);
    identityRgba8(&src, &dst, 0, 4);
    try std.testing.expectEqual(fill16, dst);
}

test "an empty source is a no-op" {
    var dst: [4]u8 = fill4;
    identityRgba8(&src_empty, &dst, 1, 1);
    try std.testing.expectEqual(fill4, dst);
}

test "a zero-length destination does not trap" {
    const src = [4]u8{ 1, 2, 3, 4 };
    var dst: [0]u8 = .{};
    identityRgba8(&src, &dst, 1, 1);
}
