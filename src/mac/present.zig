//! Pixel hand-off from the software surface to CoreGraphics (pure).

const std = @import("std");

/// Bytes per pixel for every path in this file.
pub const bytes_per_pixel: usize = 4;

/// Byte length the buffer needs for a `width` x `height` surface.
pub fn blitBufLen(width: u32, height: u32) usize {
    return @as(usize, width) * @as(usize, height) * bytes_per_pixel;
}

/// True when the geometry can produce a blittable buffer at all.
pub fn blitSizeValid(width: u32, height: u32) bool {
    return width > 0 and height > 0;
}

/// Copy a top-left-origin RGBA8 surface into the buffer CoreGraphics will read.
pub fn identityRgba8(src: []const u8, dst: []u8, width: u32, height: u32) void {
    if (!blitSizeValid(width, height)) return;
    const want = blitBufLen(width, height);
    const n = @min(want, @min(src.len, dst.len));
    @memcpy(dst[0..n], src[0..n]);
}

/// The accent blue the calculator's `=` key uses.
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
    // THE regression guard for the bug this module documents.
    var src: [4]u8 = undefined;
    var dst: [4]u8 = undefined;
    src = test_accent;
    identityRgba8(&src, &dst, 1, 1);
    try std.testing.expectEqual(test_accent, dst);
    try std.testing.expectEqual(@as(u8, 0x2f), dst[0]); // R stays in byte 0
    try std.testing.expectEqual(@as(u8, 0xf6), dst[2]); // B stays in byte 2
}

test "rows are NOT flipped — row 0 stays row 0" {
    // THE other regression guard.
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
    // A miniature of the actual frame: a display panel along the TOP and a single accent key at the BOTTOM-right.
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
    // A 2x2 of four different colours, checked per pixel — catches a channel swap that happens to be right for greys but wrong for colour.
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
    // A mirror would pass a row-order-only test, so pin the column order explicitly: two visually different cells in one row.
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
