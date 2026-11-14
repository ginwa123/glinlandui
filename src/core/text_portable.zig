//! Portable text measurement fallback — macOS's `text.zig` peer.
const std = @import("std");
const estimator = @import("text_estimator.zig");
const font_io = @import("font_io.zig");

// ---- the shared, pure surface ----

pub const TextExtent = estimator.TextExtent;
pub const ResolveFontError = estimator.ResolveFontError;
pub const estimatorExtent = estimator.estimatorExtent;
pub const hashMeasureKey = estimator.hashMeasureKey;
pub const extentCacheReset = estimator.extentCacheReset;
pub const measureText = estimator.measureText;
/// NOTE: these are **pointers** to the estimator's live counters, not the counter values.
pub const extent_hits = &estimator.extent_hits;
pub const extent_misses = &estimator.extent_misses;

// ---- the fs half of font loading: one implementation, in `font_io.zig` ----

/// Every candidate path for this OS, best first.
pub const font_candidates: []const [:0]const u8 = font_io.fontCandidates();

/// Read a font file whole.
pub const readFontBytes = font_io.readFontBytes;

/// True when the path names a file this process can open.
pub const fontExists = font_io.fontExists;

/// Return the path of a usable monospace font file, or FontNotFound.
pub fn resolveFont() ResolveFontError![]const u8 {
    for (font_candidates) |path| {
        if (fontExists(path)) return path;
    }
    return error.FontNotFound;
}

/// Every candidate path, for callers that must try more than one (e.g.
pub fn fontCandidates() []const [:0]const u8 {
    return font_candidates;
}

var cached_family: ?[:0]const u8 = null;

pub fn pangoFamily() [:0]const u8 {
    if (cached_family) |f| return f;
    const path = resolveFont() catch {
        cached_family = "monospace";
        return "monospace";
    };
    const fam: [:0]const u8 = if (std.mem.indexOf(u8, path, "Menlo") != null)
        "Menlo"
    else if (std.mem.indexOf(u8, path, "SFNSMono") != null)
        "SF Mono"
    else if (std.mem.indexOf(u8, path, "Monaco") != null)
        "Monaco"
    else
        "monospace";
    cached_family = fam;
    return fam;
}

// NOTE: there is deliberately NO `resolveFont` test here.
