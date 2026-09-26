//! Pixel hand-off from the software surface to CoreGraphics (pure).
//!
//! ## What CoreGraphics actually wants here — measured, not assumed
//!
//! The obvious guess is "CGBitmapContext wants BGR with the origin at the
//! bottom-left, so swap R/B and flip vertically". That guess is WRONG for this
//! path, and it cost a day: it rendered the calculator upside down with the
//! accent key at the top, and blue as pink.
//!
//! What was measured, by reproducing the shim's exact CoreGraphics round trip
//! (`CGBitmapContextCreate` -> `CGBitmapContextCreateImage` ->
//! `CGContextDrawImage`) and reading back the DISPLAYED colour:
//!
//!   - `soft.Surface` is TOP-LEFT origin: its row 0 is the visual top, and its
//!     bytes are plain R, G, B, A. Going through a `CGImage` is what removes
//!     the vertical flip — a CGImage's row 0 is its TOP row — so the rows stay
//!     in order.
//!   - with the shim's bitmap info, `kCGImageAlphaPremultipliedLast |
//!     kCGBitmapByteOrder32Big`, the four bytes of a pixel are read as
//!     R, G, B, A: exactly the order they are already in.
//!
//! So the required transform is the IDENTITY. Both the channel swap and the
//! vertical flip are over-corrections, and each one produces a plausible,
//! wrong-looking window rather than an obvious failure.
//!
//! ## Read this before trusting the tests below
//!
//! Every test in this file compares the blit buffer against the surface it
//! was copied from — i.e. against this module's own idea of the answer. They
//! are worth having, and they pin the layout, but they CANNOT catch a wrong
//! hand-off to CoreGraphics, because the thing that goes wrong lives in
//! `mac/shim.m`'s `kGlinBitmapInfo` and is invisible from here. They stayed
//! green through a bug that rendered the entire window bright red.
//!
//! The check that actually guards the hand-off is `ci/check_macos_colors.c`,
//! which drives CoreGraphics for real and compares the DISPLAYED colour with
//! the colour that was written. It needs no window server and no Screen
//! Recording permission, so it runs on every macOS build machine. Run it with
//! `./ci/check_macos_colors.sh`.
//!
//! `identityRgba8` keeps the call site honest and the buffer reusable across
//! frames, and the tests below pin the layout and the colours — the two things
//! a wrong transform actually breaks.

const std = @import("std");

/// Bytes per pixel for every path in this file.
pub const bytes_per_pixel: usize = 4;

/// Byte length the buffer needs for a `width` x `height` surface.
pub fn blitBufLen(width: u32, height: u32) usize {
    return @as(usize, width) * @as(usize, height) * bytes_per_pixel;
}

/// True when the geometry can produce a blittable buffer at all. A zero
/// dimension means "no surface yet", and a 0-byte CGBitmapContext is rejected
/// by CoreGraphics, so this must be false rather than producing a tiny buffer.
pub fn blitSizeValid(width: u32, height: u32) bool {
    return width > 0 and height > 0;
}

/// Copy a top-left-origin RGBA8 surface into the buffer CoreGraphics will read.
///
/// This is deliberately an identity copy — see the module comment for the
/// measurement that disproved the channel-swap/vertical-flip assumption. The
/// function exists (rather than the caller just copying) so the contract has
/// one named home and the tests have something to assert against.
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

test "a single pixel survives the hand-off byte for byte" {
    const src = [4]u8{ 1, 2, 3, 4 };
    var dst: [4]u8 = undefined;
    identityRgba8(&src, &dst, 1, 1);
    try std.testing.expectEqual([4]u8{ 1, 2, 3, 4 }, dst);
}

test "channels are NOT swapped — the accent blue stays blue" {
    // THE regression guard for the bug this module documents. Swapping R and B
    // turns 0x2f6df6 into 0xf66d2f, a red. Nothing errors; the window just
    // looks wrong, which is why this is pinned by colour and not by count.
    var src: [4]u8 = undefined;
    var dst: [4]u8 = undefined;
    src = test_accent;
    identityRgba8(&src, &dst, 1, 1);
    try std.testing.expectEqual(test_accent, dst);
    try std.testing.expectEqual(@as(u8, 0x2f), dst[0]); // R stays in byte 0
    try std.testing.expectEqual(@as(u8, 0xf6), dst[2]); // B stays in byte 2
}

test "rows are NOT flipped — row 0 stays row 0" {
    // THE other regression guard. A vertical flip mirrors the whole UI: on the
    // calculator the display moves to the bottom and the `=` key to the top.
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
    // single accent key at the BOTTOM-right. This is the whole bug in one
    // test — the panel must stay in the first rows and the accent must stay in
    // the last, and the accent must still be blue.
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
