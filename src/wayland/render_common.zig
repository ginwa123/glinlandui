//! Renderer-independent helpers shared by the GLES3 backend and every
//! platform that runs the CPU-only Clay test surface.
//!
//! Nothing in this file talks to EGL, GLES, Pango, or the filesystem, so it
//! is the portion of the render contract that the reusable components and
//! test harness can safely import on every supported platform.
const std = @import("std");

/// Convert 0xRRGGBB to a Clay color ([4]f32 in 0-255 range, alpha 255).
pub fn u32ToClayColor(hex: u32) [4]f32 {
    return .{
        @floatFromInt((hex >> 16) & 0xff),
        @floatFromInt((hex >> 8) & 0xff),
        @floatFromInt(hex & 0xff),
        255,
    };
}

/// How an image fills its box (mirrors wallpaper fit modes + stretch).
pub const ImageFit = enum { cover, contain, stretch };

/// Opaque payload a widget passes through Clay's image_data pointer.
/// The widget owns the slot (static per-declare scratch, synchronous
/// lifetime like all props); the renderer only reads it during the same
/// frame's drawCommands. `path` points at the owner's stable bytes
/// (e.g. AppState file paths) — never retained past the frame.
pub const ImageRef = struct {
    path_ptr: [*]const u8,
    path_len: usize,
    fit: ImageFit = .cover,
    /// Decode ceiling: the longest side is downscaled to this (no
    /// upscale). Thumbnails pass small values, the preview a larger one.
    max_dim: u16 = 256,
};

/// Pure: downscaled dims preserving aspect so the longest side is at
/// most max_dim. Never upscales. Returns [w, h] (min 1).
pub fn scaledDims(iw: u32, ih: u32, max_dim: u16) [2]u32 {
    if (iw == 0 or ih == 0) return .{ 1, 1 };
    const m: u32 = @max(iw, ih);
    if (m <= max_dim) return .{ iw, ih };
    if (iw >= ih) {
        const w: u32 = max_dim;
        const h: u32 = @max((ih * max_dim) / iw, 1);
        return .{ w, h };
    }
    const h: u32 = max_dim;
    const w: u32 = @max((iw * max_dim) / ih, 1);
    return .{ w, h };
}

/// Pure: cover-fit UV crop (u0, v0, u1, v1 fractions of the source) so
/// the image fills a bw×bh box with no distortion. v=0 is the top row
/// (matches the unflipped upload + unit-quad VBO convention).
pub fn coverUv(iw: f32, ih: f32, bw: f32, bh: f32) [4]f32 {
    if (iw <= 0 or ih <= 0 or bw <= 0 or bh <= 0) return .{ 0, 0, 1, 1 };
    const img_aspect = iw / ih;
    const box_aspect = bw / bh;
    if (img_aspect > box_aspect) {
        // Wide source: crop the sides.
        const f = box_aspect / img_aspect;
        const cu0 = (1 - f) * 0.5;
        return .{ cu0, 0, 1 - cu0, 1 };
    }
    if (img_aspect < box_aspect) {
        // Tall source: crop top/bottom.
        const f = img_aspect / box_aspect;
        const cv0 = (1 - f) * 0.5;
        return .{ 0, cv0, 1, 1 - cv0 };
    }
    return .{ 0, 0, 1, 1 };
}

/// Pure + headless-testable key for the image cache. FNV-1a over the path
/// bytes and the decode ceiling.
pub fn hashImageKey(path: []const u8, max_dim: u16) u64 {
    var h: u64 = 0xcbf29ce484222325;
    for (path) |b| {
        h ^= b;
        h *%= 0x100000001b3;
    }
    h ^= @as(u64, max_dim);
    h *%= 0x100000001b3;
    h ^= @as(u64, path.len);
    h *%= 0x100000001b3;
    return h;
}

/// Convert 0xRRGGBB to normalized GL RGBA floats (alpha 1.0).
pub fn u32ToGLColor(hex: u32) [4]f32 {
    const n = normChannel(hex >> 16);
    return .{ n, n, n, 1.0 };
}

fn normChannel(v: u32) f32 {
    return @as(f32, @floatFromInt(v & 0xff)) / 255.0;
}

/// Legacy fixed advance per glyph (0.6 * font_size).
pub fn estimatorAdvance(font_size: u16) f32 {
    return @as(f32, @floatFromInt(font_size)) * 0.6;
}

/// Map Clay corner radius (0-255/f32) to (TL, TR, BL, BR), clamping negatives.
pub fn cornerRadiusVec4(r: anytype) [4]f32 {
    return .{
        @max(r.top_left, 0),
        @max(r.top_right, 0),
        @max(r.bottom_left, 0),
        @max(r.bottom_right, 0),
    };
}

/// Normalize a Clay 0-255 (or 0-1) color to cairo 0-1 RGBA.
pub fn clayToCairo(clay_color: [4]f32) [4]f64 {
    const mx = @max(@max(clay_color[0], clay_color[1]), @max(clay_color[2], clay_color[3]));
    if (mx <= 1.0) {
        return .{
            @floatCast(clay_color[0]),
            @floatCast(clay_color[1]),
            @floatCast(clay_color[2]),
            @floatCast(clay_color[3]),
        };
    }
    return .{
        @floatCast(clay_color[0] / 255.0),
        @floatCast(clay_color[1] / 255.0),
        @floatCast(clay_color[2] / 255.0),
        @floatCast(clay_color[3] / 255.0),
    };
}

/// FNV-1a over text bytes, size, and color bits.
pub fn hashTextKey(text_bytes: []const u8, font_size: u16, clay_color: [4]f32) u64 {
    var h: u64 = 0xcbf29ce484222325;
    for (text_bytes) |b| {
        h ^= b;
        h *%= 0x100000001b3;
    }
    h ^= @as(u64, font_size);
    h *%= 0x100000001b3;
    h ^= @as(u64, text_bytes.len);
    h *%= 0x100000001b3;
    for (clay_color) |c| {
        h ^= @as(u64, @as(u32, @bitCast(c)));
        h *%= 0x100000001b3;
    }
    return h;
}

/// LRU victim pick: first invalid slot, else the smallest last_used.
pub fn lruVictim(entries: anytype) ?usize {
    if (entries.len == 0) return null;
    for (entries, 0..) |e, i| {
        if (!e.valid) return i;
    }
    var best: usize = 0;
    var best_used = entries[0].last_used;
    for (entries, 0..) |e, i| {
        if (e.last_used < best_used) {
            best_used = e.last_used;
            best = i;
        }
    }
    return best;
}

/// Pure: contain-fit inner box (x, y, w, h relative to the bw×bh box)
/// so the whole image shows letterboxed. Never upscales beyond the box.
pub fn containBox(iw: f32, ih: f32, bw: f32, bh: f32) [4]f32 {
    if (iw <= 0 or ih <= 0 or bw <= 0 or bh <= 0) return .{ 0, 0, bw, bh };
    const s = @min(bw / iw, bh / ih);
    const w = iw * s;
    const h = ih * s;
    return .{ (bw - w) * 0.5, (bh - h) * 0.5, w, h };
}

test "u32ToClayColor expands RGB and forces opaque alpha" {
    try std.testing.expectEqual([4]f32{ 18, 52, 86, 255 }, u32ToClayColor(0x123456));
    try std.testing.expectEqual([4]f32{ 0, 0, 0, 255 }, u32ToClayColor(0));
    try std.testing.expectEqual([4]f32{ 255, 255, 255, 255 }, u32ToClayColor(0xffffff));
}

test "scaledDims preserves aspect and never upscales" {
    try std.testing.expectEqual([2]u32{ 512, 384 }, scaledDims(640, 480, 512));
    try std.testing.expectEqual([2]u32{ 100, 50 }, scaledDims(200, 100, 100));
    try std.testing.expectEqual([2]u32{ 1, 1 }, scaledDims(0, 0, 100));
}

test "coverUv crops the overflowing image axis" {
    try std.testing.expectEqual([4]f32{ 0, 0, 1, 1 }, coverUv(100, 100, 100, 100));
    const wide = coverUv(200, 100, 100, 100);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), wide[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), wide[2], 1e-6);
    const tall = coverUv(100, 200, 100, 100);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), tall[1], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), tall[3], 1e-6);
}

test "containBox letterboxes the complete source" {
    const box = containBox(200, 100, 100, 100);
    try std.testing.expectApproxEqAbs(@as(f32, 0), box[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 25), box[1], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 100), box[2], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 50), box[3], 1e-6);
}

// ---- portable pure-math tests (mirrored from the GLES3 backend) ----

test "u32ToGLColor normalizes bg with alpha 1" {
    try std.testing.expectApproxEqAbs(@as(f32, 0x11) / 255.0, u32ToGLColor(0x111111)[0], 1e-6);
    try std.testing.expectEqual(@as(f32, 1.0), u32ToGLColor(0x111111)[3]);
}

test "estimatorAdvance keeps legacy 0.6 contract" {
    try std.testing.expectApproxEqAbs(@as(f32, 10.8), estimatorAdvance(18), 1e-4);
}

test "cornerRadiusVec4 maps TL,TR,BL,BR and clamps negatives" {
    const ok = cornerRadiusVec4(.{ .top_left = 8, .top_right = 4, .bottom_left = 2, .bottom_right = 0 });
    try std.testing.expectEqual([4]f32{ 8, 4, 2, 0 }, ok);
    const neg = cornerRadiusVec4(.{ .top_left = -3, .top_right = 5, .bottom_left = -1, .bottom_right = 6 });
    try std.testing.expectEqual([4]f32{ 0, 5, 0, 6 }, neg);
}

test "clayToCairo normalizes 0-255 and passes through 0-1" {
    const n = clayToCairo(.{ 255, 128, 0, 255 });
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), n[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 128.0 / 255.0), n[1], 1e-6);
    const one = clayToCairo(.{ 1, 1, 1, 1 });
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), one[0], 1e-6);
}

test "hashTextKey differs by bytes/size/color" {
    const a = hashTextKey("hello", 18, .{ 255, 255, 255, 255 });
    try std.testing.expectEqual(a, hashTextKey("hello", 18, .{ 255, 255, 255, 255 }));
    try std.testing.expect(a != hashTextKey("hello", 16, .{ 255, 255, 255, 255 }));
    try std.testing.expect(a != hashTextKey("hellp", 18, .{ 255, 255, 255, 255 }));
    try std.testing.expect(a != hashTextKey("hello", 18, .{ 0, 255, 255, 255 }));
}

test "lruVictim prefers invalid slot, else oldest" {
    const Entry = struct { valid: bool, last_used: u64 };
    var entries = [_]Entry{
        .{ .valid = true, .last_used = 9 },
        .{ .valid = false, .last_used = 0 },
        .{ .valid = true, .last_used = 5 },
    };
    try std.testing.expectEqual(@as(usize, 1), lruVictim(&entries));
    entries[1].valid = true;
    entries[1].last_used = 100;
    try std.testing.expectEqual(@as(usize, 2), lruVictim(&entries));
}

test "lruVictim works for image cache entries too" {
    const Entry = struct { valid: bool, last_used: u64 };
    var entries = [_]Entry{
        .{ .valid = true, .last_used = 1 },
        .{ .valid = false, .last_used = 0 },
    };
    try std.testing.expectEqual(@as(usize, 1), lruVictim(&entries));
}

test "hashImageKey differs by path and max_dim" {
    const a = hashImageKey("/a/b.png", 256);
    try std.testing.expectEqual(a, hashImageKey("/a/b.png", 256));
    try std.testing.expect(a != hashImageKey("/a/b.png", 512));
    try std.testing.expect(a != hashImageKey("/a/c.png", 256));
}
