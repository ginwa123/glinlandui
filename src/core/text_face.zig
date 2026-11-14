//! The one face: text is MEASURED with the font that DRAWS it.
//!
//! This file exists because the two used to disagree. Clay lays a run out with the measure callback, and the
//! software rasteriser draws it with real glyphs; while the callback answered from an estimate (`len * size * 0.6`)
//! every text box was the wrong width, a caret placed from a measurement drifted off the glyphs, and a run could
//! overflow the box that was supposed to hold it. Nothing caught it, because the estimate was also what the tests
//! measured against.
//!
//! So: one face, one measurement, used by the layout and by the rasteriser. When the host has no font file (a bare
//! CI runner, wasm), the estimator is the fallback — and `fontAvailable()` says which one you got, so a test can
//! skip or assert accordingly instead of silently measuring against a fiction.

const std = @import("std");
const glyphs = @import("glyphs.zig");
const estimator = @import("text_estimator.zig");

pub const TextExtent = estimator.TextExtent;

/// The process-wide face. Loaded once, from the installed font or the platform's candidate list.
var face: ?glyphs.Font = null;
var load_tried: bool = false;

/// The face this process measures and draws with, or null when no font file could be parsed.
pub fn font() ?*glyphs.Font {
    // A backend that installed a face owns its bytes; copy the struct, not the data. Checked every call, because a
    // host can install its face after the first measurement.
    if (glyphs.installedFont()) |f| {
        face = f.*;
        load_tried = true;
        return &face.?;
    }
    if (!load_tried) {
        load_tried = true;
        face = glyphs.Font.loadDefault();
    }
    if (face) |*f| return f;
    return null;
}

/// True when text is measured with real metrics rather than the estimator.
pub fn fontAvailable() bool {
    return font() != null;
}

/// The line height a text box reserves at `font_size`.
///
/// Deliberately the estimator's 1.2 * size and NOT the font's own ascent-descent: every layout in every consumer is
/// tuned to that number, and the rasteriser centres the real line box inside it anyway.
pub fn lineHeight(font_size: u16) f32 {
    return estimator.estimatorExtent("", font_size).h;
}

const cache_size: usize = 512;

const CacheEntry = struct {
    hash: u64 = 0,
    w: f32 = 0,
    valid: bool = false,
};

var cache: [cache_size]CacheEntry = [_]CacheEntry{.{}} ** cache_size;
var cache_next: usize = 0;

fn cacheGet(hash: u64) ?f32 {
    for (cache) |e| {
        if (e.valid and e.hash == hash) return e.w;
    }
    return null;
}

fn cachePut(hash: u64, w: f32) void {
    cache[cache_next] = .{ .hash = hash, .w = w, .valid = true };
    cache_next = (cache_next + 1) % cache_size;
}

/// Drop the cached widths (and re-probe the font on the next call). For tests and for a font hot-swap.
pub fn reset() void {
    for (&cache) |*e| e.valid = false;
    cache_next = 0;
    load_tried = false;
    face = null;
}

/// Width and line height of `text` at `font_size`, measured with the face that draws it.
///
/// The width is the sum of the glyph advances — exactly what the rasteriser advances its pen by, so a run can never
/// be wider than the box the layout gave it, and a caret placed at a measured offset lands on the glyph boundary.
pub fn measureText(text: []const u8, font_size: u16) TextExtent {
    const h = lineHeight(font_size);
    if (text.len == 0) return .{ .w = 0, .h = h };
    const f = font() orelse return estimator.measureText(text, font_size);

    const hash = estimator.hashMeasureKey(text, font_size);
    if (cacheGet(hash)) |w| return .{ .w = w, .h = h };
    const m = glyphs.measure(f, text, font_size);
    cachePut(hash, m.width);
    return .{ .w = m.width, .h = h };
}

// ===================== tests =====================

test "measureText agrees with the glyph advances it will be drawn with" {
    const f = font() orelse return error.SkipZigTest;
    const m = measureText("Invoice", 14);
    try std.testing.expectApproxEqAbs(glyphs.measure(f, "Invoice", 14).width, m.w, 0.001);
}

test "measureText is additive for a monospace run and empty text is zero wide" {
    try std.testing.expectEqual(@as(f32, 0), measureText("", 14).w);
    // No kerning is applied by either the measurer or the rasteriser, so the parts sum to the whole.
    const whole = measureText("abcdef", 14).w;
    const parts = measureText("abc", 14).w + measureText("def", 14).w;
    try std.testing.expectApproxEqAbs(whole, parts, 0.01);
}

test "the line height is stable whatever the font is" {
    // 1.2 * size, the number every layout in every consumer is tuned to.
    try std.testing.expectApproxEqAbs(@as(f32, 16.8), lineHeight(14), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 26.4), lineHeight(22), 0.001);
}
