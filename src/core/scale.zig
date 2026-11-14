//! One definition of how a logical window becomes device pixels, so no two backends disagree about what 1x and 2x mean.
const std = @import("std");

/// The largest backing scale a backend honours. A compositor reporting more is clamped rather than trusted, because the pixel buffer is `w * s * h * s * 4`.
pub const max_scale: f32 = 4.0;

/// A usable scale: non-finite, zero and negative all mean 1x.
pub fn clampScale(scale: f32) f32 {
    if (!std.math.isFinite(scale) or scale <= 0) return 1.0;
    return @min(scale, max_scale);
}

/// The pixel size a logical window rasterizes at. This is THE invariant every backend must satisfy: a 2x display gets 2x the pixels, never a 1x image the compositor upscales into a blur.
pub fn pixelSize(logical_w: u32, logical_h: u32, scale: f32) struct { w: u32, h: u32 } {
    const s = clampScale(scale);
    const fw = @as(f32, @floatFromInt(logical_w)) * s;
    const fh = @as(f32, @floatFromInt(logical_h)) * s;
    return .{
        .w = @max(@as(u32, @intFromFloat(@round(fw))), 1),
        .h = @max(@as(u32, @intFromFloat(@round(fh))), 1),
    };
}

test "a 2x display gets exactly twice the pixels on each axis" {
    const p = pixelSize(960, 760, 2.0);
    try std.testing.expectEqual(@as(u32, 1920), p.w);
    try std.testing.expectEqual(@as(u32, 1520), p.h);
}

test "a 1x display renders the logical size unchanged" {
    const p = pixelSize(960, 760, 1.0);
    try std.testing.expectEqual(@as(u32, 960), p.w);
    try std.testing.expectEqual(@as(u32, 760), p.h);
}

test "a fractional scale rounds instead of truncating away a pixel row" {
    const p = pixelSize(100, 100, 1.5);
    try std.testing.expectEqual(@as(u32, 150), p.w);
    const odd = pixelSize(3, 3, 1.5);
    try std.testing.expectEqual(@as(u32, 5), odd.w);
}

test "an unusable scale falls back to 1x rather than a zero-sized surface" {
    for ([_]f32{ 0, -1, std.math.nan(f32), std.math.inf(f32) }) |bad| {
        const p = pixelSize(64, 32, bad);
        try std.testing.expectEqual(@as(u32, 64), p.w);
        try std.testing.expectEqual(@as(u32, 32), p.h);
    }
}

test "an absurd scale is clamped so the buffer cannot explode" {
    const p = pixelSize(1000, 1000, 1000);
    try std.testing.expectEqual(@as(u32, 4000), p.w);
}

test "a window always has at least one pixel" {
    const p = pixelSize(0, 0, 2.0);
    try std.testing.expectEqual(@as(u32, 1), p.w);
    try std.testing.expectEqual(@as(u32, 1), p.h);
}
