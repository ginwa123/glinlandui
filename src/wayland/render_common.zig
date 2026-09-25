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
