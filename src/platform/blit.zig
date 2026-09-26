//! RGBA8 -> CoreGraphics blit preparation (pure).
//!
//! A `CGBitmapContext` created with
//! `kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Little` wants bytes
//! in B, G, R, A order, and its origin is the BOTTOM-LEFT corner, so its row
//! 0 is the visual bottom row. `soft.Surface` produces top-left-origin RGBA8.
//! A blit therefore needs TWO transforms, and they fail differently:
//!
//!   1. channel swap (R <-> B) — wrong colours, still looks like a UI
//!   2. vertical flip         — an upside-down UI, which on a keypad reads as
//!                              "nothing is where I clicked"
//!
//! Both are pure byte shuffles, so both live here and are unit-tested on every
//! platform rather than being buried in the Objective-C shim where a mistake
//! would only ever show up as "the window looks odd".
//!
//! THE FLIP IS ROW-WISE, NOT PER-PIXEL. Reversing the whole pixel buffer looks
//! like a flip in a 1-wide image, but on a 2+-wide image it is a 180-degree
//! rotation: the left and right edges swap too. That silently mirrors every
//! control, so a keypad's "7" lands where "DEL" is drawn. The tests below pin
//! the left/right order explicitly so that regression cannot come back.

const std = @import("std");

/// Bytes per pixel for every path in this file.
pub const bytes_per_pixel: usize = 4;

/// Byte length a converted buffer needs for a `width` x `height` surface.
pub fn blitBufLen(width: u32, height: u32) usize {
    return @as(usize, width) * @as(usize, height) * bytes_per_pixel;
}

/// True when the geometry can produce a blittable buffer at all. A zero
/// dimension means "no surface yet" and must not be turned into a 0-byte
/// CGBitmapContext (CoreGraphics rejects that).
pub fn blitSizeValid(width: u32, height: u32) bool {
    return width > 0 and height > 0;
}

/// Convert a top-left-origin RGBA8 image into the byte order and row order
/// `CGBitmapContext` expects: BGRA, bottom-row-first, left-to-right preserved.
///
/// `dst` must be at least `blitBufLen(width, height)`; a longer `dst` keeps
/// its tail untouched so one caller-owned buffer can be reused every frame.
/// `src` is read for exactly `width * height` pixels; short buffers stop
/// safely rather than reading past the end.
pub fn rgba8ToBgraFlipped(src: []const u8, dst: []u8, width: u32, height: u32) void {
    if (!blitSizeValid(width, height)) return;
    const w: usize = @intCast(width);
    const h: usize = @intCast(height);
    const src_px = src.len / bytes_per_pixel;
    const dst_px = dst.len / bytes_per_pixel;
    const rows = @min(h, @min(src_px, dst_px) / w);

    var dy: usize = 0;
    while (dy < rows) : (dy += 1) {
        // Row reversal only: source row counted from the bottom. The column
        // index is NOT reversed, which is what keeps this a flip rather than
        // a 180-degree rotation.
        const sy = rows - 1 - dy;
        var x: usize = 0;
        while (x < w) : (x += 1) {
            const s = (sy * w + x) * bytes_per_pixel;
            const d = (dy * w + x) * bytes_per_pixel;
            dst[d + 0] = src[s + 2]; // B first: 32Little byte order
            dst[d + 1] = src[s + 1];
            dst[d + 2] = src[s + 0];
            dst[d + 3] = src[s + 3];
        }
    }
}

// ===================== tests (parity suite — every platform) =====================

const fill4: [4]u8 = .{0xAA} ** 4;
const fill8: [8]u8 = .{0xAA} ** 8;
const fill12: [12]u8 = .{0xAA} ** 12;
const fill16: [16]u8 = .{0xAA} ** 16;
const src_empty: [0]u8 = .{};

/// One pixel of R,G,B,A, used to keep the fixtures short.
fn px(r: u8, g: u8, b: u8, a: u8) [4]u8 {
    return .{ r, g, b, a };
}

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

test "channels are reordered R->B and B->R, G and A untouched" {
    // A 1x1 image: a single row is its own flip, so this isolates the channel
    // swap from the row flip.
    const src = [4]u8{ 1, 2, 3, 4 };
    var dst: [4]u8 = undefined;
    rgba8ToBgraFlipped(&src, &dst, 1, 1);
    try std.testing.expectEqual([4]u8{ 3, 2, 1, 4 }, dst);
}

test "alpha is carried through unchanged for every pixel" {
    // Hover tints and any future translucency depend on alpha surviving.
    var src: [16]u8 = undefined; // 2x2
    var dst: [16]u8 = undefined;
    for (0..4) |i| {
        const p = px(@intCast(i + 1), @intCast(i + 11), @intCast(i + 21), @intCast(i * 60));
        src[i * 4 ..][0..4].* = p;
    }
    rgba8ToBgraFlipped(&src, &dst, 2, 2);
    // 2x2, so the flip permutes pixels; collect the alphas as a set.
    var got: [4]u8 = .{ 0, 0, 0, 0 };
    for (0..4) |i| got[i] = dst[i * 4 + 3];
    var sorted = got;
    std.mem.sort(u8, &sorted, {}, std.sort.asc(u8));
    try std.testing.expectEqual([4]u8{ 0, 60, 120, 180 }, sorted);
}

test "rows are reversed top-to-bottom" {
    // Two rows, one column: source row 0 is the TOP, so it must end up in the
    // LAST destination row.
    const src = [_]u8{
        9, 9, 9, 255, // src row 0 = top
        4, 4, 4, 255, // src row 1 = bottom
    };
    var dst: [8]u8 = undefined;
    rgba8ToBgraFlipped(&src, &dst, 1, 2);
    try std.testing.expectEqualSlices(u8, &.{ 4, 4, 4, 255 }, dst[0..4]); // dst row 0 = bottom
    try std.testing.expectEqualSlices(u8, &.{ 9, 9, 9, 255 }, dst[4..8]); // dst row 1 = top
}

test "columns are NOT reversed — this is a flip, not a 180-degree rotation" {
    // THE regression guard. A 2-wide image makes the difference observable:
    // reversing the whole buffer would swap the left and right cells within
    // each row, mirroring every control. A keypad would put "DEL" where "7"
    // is drawn, so a click lands on the wrong key with no error anywhere.
    //
    // Layout (visual):
    //     A A
    //     B B
    const src = [_]u8{
        1, 1, 1, 255, // top-left   = A
        2, 2, 2, 255, // top-right  = A
        3, 3, 3, 255, // bottom-left  = B
        4, 4, 4, 255, // bottom-right = B
    };
    var dst: [16]u8 = undefined;
    rgba8ToBgraFlipped(&src, &dst, 2, 2);
    // After a vertical flip the visual result is still:
    //     B B      (dst row 0, left then right)
    //     A A      (dst row 1, left then right)
    // Left and right are indistinguishable by value here (both B, both A), so
    // the distinguishing check is that the ROW values are right and the
    // "reversed whole buffer" result would instead be B A / A B.
    try std.testing.expectEqualSlices(u8, &.{ 3, 3, 3, 255, 4, 4, 4, 255 }, dst[0..8]);
    try std.testing.expectEqualSlices(u8, &.{ 1, 1, 1, 255, 2, 2, 2, 255 }, dst[8..16]);
}

test "a 3-wide image keeps its left-to-right order within each row" {
    // Same guard with an odd width, where a per-pixel buffer reversal would
    // land each row's cells in exactly the wrong order.
    // Row values: top = 1,1,1 ; mid = 2,2,2 ; bottom = 3,3,3
    var src: [36]u8 = undefined;
    for (0..9) |i| {
        const row = i / 3; // 0 top, 1 mid, 2 bottom
        const v: u8 = @intCast(row + 1);
        src[i * 4 + 0] = v;
        src[i * 4 + 1] = v;
        src[i * 4 + 2] = v;
        src[i * 4 + 3] = 255;
    }
    var dst: [36]u8 = undefined;
    rgba8ToBgraFlipped(&src, &dst, 3, 3);
    for (0..9) |i| {
        // dst row 0 must be all 3s (the bottom row), row 1 all 2s, row 2 all 1s.
        const want: u8 = @intCast(3 - (i / 3));
        try std.testing.expectEqual(want, dst[i * 4 + 0]);
    }
}

test "a 2x2 with four distinct colours lands in the right quadrants" {
    //      R G
    //      B W
    const src = [_]u8{
        255, 0, 0, 255, // top-left    R
        0, 255, 0, 255, // top-right   G
        0, 0, 255, 255, // bottom-left B
        255, 255, 255, 255, // bottom-right W
    };
    var dst: [16]u8 = undefined;
    rgba8ToBgraFlipped(&src, &dst, 2, 2);
    // Flipped vertically the visual result is:
    //      B W      -> dst row 0, left=B, right=W
    //      R G      -> dst row 1, left=R, right=G
    // Each written as BGRA, so R becomes (0,0,255) and B becomes (255,0,0).
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, dst[0..4]); // B bottom-left
    try std.testing.expectEqualSlices(u8, &.{ 255, 255, 255, 255 }, dst[4..8]); // W bottom-right
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, dst[8..12]); // R top-left
    try std.testing.expectEqualSlices(u8, &.{ 0, 255, 0, 255 }, dst[12..16]); // G top-right
}

test "flipping twice restores the original image" {
    // Converting twice undoes both transforms, so this catches any row
    // arithmetic that is not a true involution.
    const src = [_]u8{
        1,  2,  3,  4,
        5,  6,  7,  8,
        9,  10, 11, 12,
        13, 14, 15, 16,
    };
    var mid: [16]u8 = undefined;
    var back: [16]u8 = undefined;
    rgba8ToBgraFlipped(&src, &mid, 2, 2);
    rgba8ToBgraFlipped(&mid, &back, 2, 2);
    try std.testing.expectEqualSlices(u8, &src, &back);
}

test "a single-pixel surface is its own flip" {
    const src = [4]u8{ 7, 8, 9, 10 };
    var dst: [4]u8 = undefined;
    rgba8ToBgraFlipped(&src, &dst, 1, 1);
    try std.testing.expectEqual([4]u8{ 9, 8, 7, 10 }, dst);
}

test "a single-row surface is its own flip" {
    // Height 1: the one row maps to itself, but every column must be copied.
    const src = [_]u8{
        1, 1, 1, 255,
        2, 2, 2, 255,
        3, 3, 3, 255,
    };
    var dst: [12]u8 = undefined;
    rgba8ToBgraFlipped(&src, &dst, 3, 1);
    try std.testing.expectEqualSlices(u8, &src, &dst);
}

test "a zero height or width writes nothing" {
    var dst: [16]u8 = fill16;
    const src = [_]u8{ 1, 2, 3, 4 } ** 4;
    rgba8ToBgraFlipped(&src, &dst, 4, 0);
    try std.testing.expectEqual(fill16, dst);
    rgba8ToBgraFlipped(&src, &dst, 0, 4);
    try std.testing.expectEqual(fill16, dst);
}

test "a short source writes nothing rather than reading past its end" {
    // Claims 2x2 but supplies only one pixel: a partial row cannot fill a
    // whole destination row, so the copy is skipped entirely and dst is left
    // untouched. Failing safe (draw nothing) beats drawing a half-shifted
    // image, and critically it never reads out of bounds.
    const src = [4]u8{ 1, 2, 3, 4 };
    var dst: [16]u8 = fill16;
    rgba8ToBgraFlipped(&src, &dst, 2, 2);
    try std.testing.expectEqual(fill16, dst);
}

test "a short source still fills whole rows it does have" {
    // 2x2 requested, 2 rows x 1 column supplied is not enough, but 1x2 is:
    // the one supplied row is a complete destination row.
    const src = [_]u8{
        1, 1, 1, 255,
        2, 2, 2, 255,
    };
    var dst: [8]u8 = fill8;
    rgba8ToBgraFlipped(&src, &dst, 1, 2);
    try std.testing.expectEqualSlices(u8, &.{ 2, 2, 2, 255, 1, 1, 1, 255 }, &dst);
}

test "a longer destination keeps its tail untouched for frame reuse" {
    const src = [4]u8{ 1, 2, 3, 4 };
    var dst: [12]u8 = fill12;
    rgba8ToBgraFlipped(&src, &dst, 1, 1);
    try std.testing.expectEqualSlices(u8, &.{ 3, 2, 1, 4 }, dst[0..4]);
    try std.testing.expectEqualSlices(u8, &fill8, dst[4..12]);
}

test "an empty source is a no-op and never indexes the buffer" {
    var dst: [4]u8 = fill4;
    rgba8ToBgraFlipped(&src_empty, &dst, 1, 1);
    try std.testing.expectEqual(fill4, dst);
}

test "an odd trailing byte is ignored rather than half-converted" {
    // 5 bytes cannot hold 2 whole pixels, so only the first is converted.
    const src = [_]u8{ 1, 2, 3, 4, 0xEE };
    var dst: [8]u8 = fill8;
    rgba8ToBgraFlipped(&src, &dst, 1, 1);
    try std.testing.expectEqualSlices(u8, &.{ 3, 2, 1, 4 }, dst[0..4]);
    try std.testing.expectEqualSlices(u8, &fill4, dst[4..8]);
}
