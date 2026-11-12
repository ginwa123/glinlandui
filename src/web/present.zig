//! Pixel hand-off from the software surface to the browser's `<canvas>` (pure).
const std = @import("std");

/// Bytes per pixel for every path in this file. `ImageData` agrees.
pub const bytes_per_pixel: usize = 4;

/// Byte length the canvas needs for a `width` x `height` surface.
pub fn blitBufLen(width: u32, height: u32) usize {
    return @as(usize, width) * @as(usize, height) * bytes_per_pixel;
}

/// True when the geometry can describe a presentable frame at all.
pub fn blitSizeValid(width: u32, height: u32) bool {
    return width > 0 and height > 0;
}

/// Copy a top-left-origin RGBA8 surface into the buffer the DOM will read.
pub fn identityRgba8(src: []const u8, dst: []u8, width: u32, height: u32) void {
    if (!blitSizeValid(width, height)) return;
    const want = blitBufLen(width, height);
    const n = @min(want, @min(src.len, dst.len));
    @memcpy(dst[0..n], src[0..n]);
}

/// The largest `devicePixelRatio` this presenter will honour.
pub const max_device_scale: f32 = 4.0;

/// The largest canvas dimension this presenter will produce.
pub const max_canvas_dim: u32 = 16384;

/// Backing-store size for a CSS size at a device scale.
pub fn canvasSize(css_w: u32, css_h: u32, device_scale: f32) struct { w: u32, h: u32 } {
    const scale = if (device_scale > 0 and device_scale <= max_device_scale)
        device_scale
    else
        1.0;
    const limit: f32 = @floatFromInt(max_canvas_dim);
    const w = @ceil(@as(f32, @floatFromInt(css_w)) * scale);
    const h = @ceil(@as(f32, @floatFromInt(css_h)) * scale);
    // `!(x >= 1)` rather than `x < 1` so a NaN takes this branch instead of falling through to `@intFromFloat`, which would be illegal behaviour.
    if (!(w >= 1) or !(h >= 1)) return .{ .w = 1, .h = 1 };
    return .{
        .w = @intFromFloat(@min(w, limit)),
        .h = @intFromFloat(@min(h, limit)),
    };
}

/// Map a DOM (CSS pixel) coordinate to the canvas backing store.
pub fn toBackingPoint(css_x: f32, css_y: f32, device_scale: f32) struct { x: f32, y: f32 } {
    const scale = if (device_scale > 0 and device_scale <= max_device_scale)
        device_scale
    else
        1.0;
    return .{ .x = css_x * scale, .y = css_y * scale };
}

/// Pixels that differ from the surface's own clear colour.
pub fn countPainted(pixels: []const u8, clear_rgb: [4]f32) usize {
    var painted: usize = 0;
    var i: usize = 0;
    while (i + 3 < pixels.len) : (i += 4) {
        const r: f32 = @floatFromInt(pixels[i]);
        const g: f32 = @floatFromInt(pixels[i + 1]);
        const b: f32 = @floatFromInt(pixels[i + 2]);
        if (r != clear_rgb[0] or g != clear_rgb[1] or b != clear_rgb[2]) painted += 1;
    }
    return painted;
}

/// FNV-1a over a frame's bytes.
pub fn frameHash(pixels: []const u8) u64 {
    var h: u64 = 0xcbf29ce484222325;
    for (pixels) |byte| {
        h ^= byte;
        h *%= 0x100000001b3;
    }
    return h;
}

/// The accent blue the calculator's `=` key uses, used by the tests below to prove channel order survives the hand-off: a swapped R/B turns this into a.
pub const test_accent: [4]u8 = .{ 0x2f, 0x6d, 0xf6, 0xff };

// ===================== tests (parity suite — every platform) =====================

const fill8: [8]u8 = .{0xAA} ** 8;
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

test "channels are NOT swapped — the accent blue stays blue" {
    // THE regression guard for the assumption this module disproves.
    var src: [4]u8 = test_accent;
    var dst: [4]u8 = undefined;
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
    try std.testing.expectEqualSlices(u8, &.{ 27, 27, 33, 255 }, dst[0..4]);
    const accent_i = ((h - 1) * w + (w - 1)) * 4;
    try std.testing.expectEqualSlices(u8, &test_accent, dst[accent_i..][0..4]);
}

test "a longer destination keeps its tail untouched for frame reuse" {
    const src = [4]u8{ 1, 2, 3, 4 };
    var dst: [12]u8 = undefined;
    @memset(&dst, 0xAA);
    identityRgba8(&src, &dst, 1, 1);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, dst[0..4]);
    try std.testing.expectEqualSlices(u8, &fill8, dst[4..12]);
}

test "a zero width or height writes nothing, and an empty source is a no-op" {
    var dst: [16]u8 = undefined;
    @memset(&dst, 0xAA);
    const src = [4]u8{ 1, 2, 3, 4 } ** 4;
    identityRgba8(&src, &dst, 4, 0);
    try std.testing.expectEqual(fill16, dst);
    identityRgba8(&src, &dst, 0, 4);
    try std.testing.expectEqual(fill16, dst);
    var small: [4]u8 = undefined;
    @memset(&small, 0xAA);
    identityRgba8(&src_empty, &small, 1, 1);
    try std.testing.expectEqual([4]u8{ 0xAA, 0xAA, 0xAA, 0xAA }, small);
}

test "canvasSize scales up for HiDPI and rounds up for a fractional ratio" {
    try std.testing.expectEqual(@as(u32, 640), canvasSize(640, 480, 1.0).w);
    try std.testing.expectEqual(@as(u32, 1280), canvasSize(640, 480, 2.0).w);
    try std.testing.expectEqual(@as(u32, 960), canvasSize(640, 480, 1.5).w);
    // 640 * 1.25 = 800 exactly, but 480 * 1.25 = 600 — the interesting case is a size whose product is fractional, which must round UP or a stripe of page.
    try std.testing.expectEqual(@as(u32, 800), canvasSize(640, 480, 1.25).w);
    try std.testing.expectEqual(@as(u32, 600), canvasSize(640, 480, 1.25).h);
    // 100 * 1.1 = 110.000001 in f32; ceil makes it 111 rather than 110.
    try std.testing.expect(canvasSize(101, 101, 1.1).w >= 112);
}

test "canvasSize clamps an absurd or invalid device ratio instead of allocating it" {
    // An out-of-range ratio is REJECTED, not clamped: `scale` falls back to 1.0, so an 8x request yields the CSS size rather than a 4x backing store.
    try std.testing.expectEqual(@as(u32, 960), canvasSize(960, 720, 8.0).w);
    // The ceiling itself IS honoured, which is the boundary the guard admits.
    try std.testing.expectEqual(@as(u32, 960 * 4), canvasSize(960, 720, max_device_scale).w);
    // A zero or negative ratio cannot come from a browser, but must not produce a zero-sized canvas that silently clears the element.
    try std.testing.expectEqual(@as(u32, 960), canvasSize(960, 720, 0).w);
    try std.testing.expectEqual(@as(u32, 960), canvasSize(960, 720, -2).w);
    try std.testing.expectEqual(@as(u32, 1), canvasSize(0, 0, 1).w);
    // A CSS size large enough to overflow after scaling must be clamped rather than converted: `@intFromFloat` out of range is illegal behaviour in Zig, so.
    const huge = canvasSize(std.math.maxInt(u32), std.math.maxInt(u32), 4.0);
    try std.testing.expectEqual(max_canvas_dim, huge.w);
    try std.testing.expectEqual(max_canvas_dim, huge.h);
}

test "toBackingPoint scales the DOM coordinate onto the backing store" {
    // The browser's whole coordinate disagreement in one call.
    const p = toBackingPoint(10, 20, 2.0);
    try std.testing.expectEqual(@as(f32, 20), p.x);
    try std.testing.expectEqual(@as(f32, 40), p.y);
    // No flip: a DOM y of 0 is the visual TOP, same as the toolkit's.
    const top = toBackingPoint(0, 0, 1.0);
    try std.testing.expectEqual(@as(f32, 0), top.y);
    // An invalid ratio falls back to 1 rather than to zero, which would collapse every click onto the origin.
    try std.testing.expectEqual(@as(f32, 10), toBackingPoint(10, 20, 0).x);
    try std.testing.expectEqual(@as(f32, 10), toBackingPoint(10, 20, 99).x);
}

test "countPainted counts only pixels that differ from the clear colour" {
    const clear = [4]f32{ 0, 0, 0, 255 };
    const pixels = [_]u8{
        0, 0, 0, 255, // clear
        0, 0, 0, 255, // clear
        255, 0, 0, 255, // painted
        0, 0, 0, 255, // clear
    };
    try std.testing.expectEqual(@as(usize, 1), countPainted(&pixels, clear));
    // A flat frame paints every pixel and yet differs from nothing.
    const flat = [_]u8{0} ** 16;
    try std.testing.expectEqual(@as(usize, 0), countPainted(&flat, clear));
    try std.testing.expectEqual(@as(usize, 0), countPainted(&src_empty, clear));
}

test "frameHash changes when a single byte changes, and is stable otherwise" {
    const a = [_]u8{ 1, 2, 3, 4 };
    const b = [_]u8{ 1, 2, 3, 5 };
    // A one-line "did anything actually change" probe a flat frame cannot fake.
    try std.testing.expectEqual(frameHash(&a), frameHash(&a));
    try std.testing.expect(frameHash(&a) != frameHash(&b));
    try std.testing.expect(frameHash(&a) != 0);
}
