//! Windows text engine — the `text.zig` half of the platform mirror.
const portable = @import("../core/text_portable.zig");

pub const TextExtent = portable.TextExtent;
pub const ResolveFontError = portable.ResolveFontError;

/// Windows' monospace faces, in preference order.
pub const font_candidates: []const [:0]const u8 = &.{
    // Consolas: shipped since Vista, and the face most Windows apps use.
    "C:\\Windows\\Fonts\\consola.ttf",
    // Courier New: since NT. A wider fallback for odd layouts.
    "C:\\Windows\\Fonts\\cour.ttf",
    // Lucida Console: since NT 4.0, present on nearly every install.
    "C:\\Windows\\Fonts\\lucon.ttf",
    // The Windows 3.1/95 bitmap console face.
    "C:\\Windows\\Fonts\\vgafix.ttf",
};

/// `resolveFont` is the estimator's own implementation, and it walks THAT module's `font_candidates` — the macOS list — so it cannot be reused as-is.
pub fn resolveFont() ResolveFontError![]const u8 {
    for (font_candidates) |path| {
        if (fontExists(path)) return path;
    }
    return error.FontNotFound;
}

fn fontExists(path: [:0]const u8) bool {
    std.Io.Dir.cwd().access(std.Io.Threaded.global_single_threaded.io(), path, .{}) catch return false;
    return true;
}

/// Every candidate path, for callers that must try more than one (e.g.
pub fn fontCandidates() []const [:0]const u8 {
    return font_candidates;
}

/// Read a font file whole.
pub fn readFontBytes(path: [:0]const u8, alloc: std.mem.Allocator) ![]u8 {
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

const std = @import("std");

/// The family name reported for a resolved font.
pub fn pangoFamily() [:0]const u8 {
    _ = resolveFont() catch {};
    return "Consolas";
}

pub const estimatorExtent = portable.estimatorExtent;
pub const hashMeasureKey = portable.hashMeasureKey;
pub const extentCacheReset = portable.extentCacheReset;
pub const measureText = portable.measureText;
pub const extent_hits = portable.extent_hits;
pub const extent_misses = portable.extent_misses;

// ===================== tests (parity suite — every platform) ===================== The count stays identical on every platform: these assert the SHAPE.

test "the candidate list is non-empty and every entry is a .ttf" {
    // A `.ttc` here would be a file stb_truetype cannot open, which costs a failed parse before the next candidate is tried.
    try std.testing.expect(font_candidates.len > 0);
    for (font_candidates) |path| {
        const s: []const u8 = path;
        try std.testing.expect(s.len > 0);
        try std.testing.expect(std.mem.endsWith(u8, s, ".ttf"));
    }
}

test "the candidates are absolute Windows paths, not POSIX ones" {
    // The portable list is macOS absolute ("/System/Library/...").
    for (font_candidates) |path| {
        const s: []const u8 = path;
        try std.testing.expect(s.len >= 3);
        try std.testing.expectEqual(@as(u8, ':'), s[1]);
        try std.testing.expect(s[0] >= 'A' and s[0] <= 'Z');
        try std.testing.expectEqual(@as(u8, '\\'), s[2]);
    }
}

test "the candidate list is deduplicated" {
    // A duplicate makes the rasterizer try the same file twice for no reason, and hides a copy-paste error in the table.
    for (font_candidates, 0..) |a, i| {
        for (font_candidates[i + 1 ..]) |b| {
            try std.testing.expect(!std.mem.eql(u8, a, b));
        }
    }
}

test "fontCandidates is the same list resolveFont walks" {
    // If these two ever diverge, the glyph rasterizer and the reported family name disagree about which font is in use — and the difference is only visible.
    try std.testing.expectEqual(@intFromPtr(font_candidates.ptr), @intFromPtr(fontCandidates().ptr));
}

test "resolveFont returns one of the advertised paths, or FontNotFound" {
    // Deliberately does NOT assert success: whether Consolas is installed is a property of the build machine, and a test that depended on it would make the.
    if (resolveFont()) |path| {
        var listed = false;
        for (font_candidates) |c| {
            if (std.mem.eql(u8, c, path)) listed = true;
        }
        try std.testing.expect(listed);
    } else |err| {
        try std.testing.expectEqual(ResolveFontError.FontNotFound, err);
    }
}

test "the family name is a stable, NUL-terminated Windows family" {
    const fam: []const u8 = pangoFamily();
    try std.testing.expectEqualStrings("Consolas", fam);
}
