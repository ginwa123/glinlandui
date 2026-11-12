//! Portable text measurement fallback — macOS's `text.zig` peer.
const std = @import("std");
const estimator = @import("text_estimator.zig");

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

// ---- the fs half of font loading ----

/// Read a font file whole.
pub fn readFontBytes(path: [:0]const u8, alloc: std.mem.Allocator) ![]u8 {
    // Zig 0.16's Io-based fs: cwd() is a Dir and every call needs an Io.
    const io = std.Io.Threaded.global_single_threaded.io();
    const dir = std.Io.Dir.cwd();
    const f = dir.openFile(io, path, .{}) catch return error.FontNotFound;
    defer f.close(io);
    const stat = f.stat(io) catch return error.FontNotFound;
    const n = stat.size;
    if (n == 0) return error.FontNotFound;
    const buf = alloc.alloc(u8, @intCast(n)) catch return error.OutOfMemory;
    errdefer alloc.free(buf);
    const got = f.readPositionalAll(io, buf, 0) catch return error.FontNotFound;
    if (got == 0) return error.FontNotFound;
    return buf;
}

// ---- macOS system-font discovery (fs-backed) ----

// macOS ships these system fonts, so a no-dependency test can still prove the public font-resolution contract.
pub const font_candidates: []const [:0]const u8 = &.{
    "/System/Library/Fonts/SFNSMono.ttf",
    "/System/Library/Fonts/Menlo.ttc",
    "/System/Library/Fonts/Monaco.ttf",
    "/System/Library/Fonts/Geneva.ttf",
    "/Library/Fonts/Arial Unicode.ttf",
};

fn fontExists(path: [:0]const u8) bool {
    std.Io.Dir.cwd().access(std.Io.Threaded.global_single_threaded.io(), path, .{}) catch return false;
    return true;
}

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
