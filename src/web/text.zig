//! Browser text engine — the `text.zig` half of the platform mirror.
const std = @import("std");
const estimator = @import("../core/text_estimator.zig");

pub const TextExtent = estimator.TextExtent;
pub const ResolveFontError = estimator.ResolveFontError;
pub const estimatorExtent = estimator.estimatorExtent;
pub const hashMeasureKey = estimator.hashMeasureKey;
pub const extentCacheReset = estimator.extentCacheReset;
pub const measureText = estimator.measureText;

/// Pointers, not values — see the note in `core/text_portable.zig`.
pub const extent_hits = &estimator.extent_hits;
pub const extent_misses = &estimator.extent_misses;

/// No candidate paths, by construction: a browser has none to offer.
pub const font_candidates: []const [:0]const u8 = &.{};

pub fn fontCandidates() []const [:0]const u8 {
    return font_candidates;
}

/// Always fails.
pub fn resolveFont() ResolveFontError![]const u8 {
    return error.FontNotFound;
}

/// Never called: `readFontBytes` below is the only reader the glyph path uses, and it always fails.
pub fn readFontBytes(path: [:0]const u8, alloc: std.mem.Allocator) ![]u8 {
    _ = path;
    _ = alloc;
    return error.FontNotFound;
}

/// `pangoFamily` is a pangocairo concept.
pub fn pangoFamily() [:0]const u8 {
    return "monospace";
}

// ===================== tests (parity suite — every platform) ===================== The estimator's own tests live in core/text_estimator.zig (moved.

test "a browser offers no font paths" {
    try std.testing.expectEqual(@as(usize, 0), fontCandidates().len);
}

test "resolveFont fails rather than inventing a path" {
    try std.testing.expectError(error.FontNotFound, resolveFont());
}

test "readFontBytes fails rather than pretending a browser has a filesystem" {
    try std.testing.expectError(error.FontNotFound, readFontBytes("/System/Library/Fonts/Menlo.ttc", std.testing.allocator));
}

test "the estimator is still reachable through the browser text module" {
    // Proves the re-export genuinely resolves to the shared implementation, so a browser lays text out with the SAME arithmetic macOS does.
    const m = measureText("Settings", 18);
    try std.testing.expect(m.w > 0);
    try std.testing.expect(m.h > 0);
    try std.testing.expectEqual(estimator.estimatorExtent("Settings", 18).w, m.w);
}
