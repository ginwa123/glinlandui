//! Portable text measurement fallback.
//!
//! macOS does not get a fabricated Pango/EGL runtime: it gets a deterministic,
//! pure-Zig version of the same public measurement contract. It is used by the
//! CPU frame pipeline and the reusable headless test driver, so those tests stay
//! meaningful on macOS without pulling in Linux-only system libraries.
const std = @import("std");

/// Clay-shaped text extent.
pub const TextExtent = struct {
    w: f32,
    h: f32,
};

pub const ResolveFontError = error{
    FontNotFound,
};

// macOS ships these system fonts, so a no-dependency test can still prove the
// public font-resolution contract. Keep this list separate from the Linux
// pangocairo candidates in text.zig.
const font_candidates: []const [:0]const u8 = &.{
    "/System/Library/Fonts/Menlo.ttc",
    "/System/Library/Fonts/SFNSMono.ttf",
    "/System/Library/Fonts/Monaco.dfont",
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

/// Pure-Zig fallback: deterministic, no C deps.
pub fn estimatorExtent(text: []const u8, font_size: u16) TextExtent {
    const size: f32 = @floatFromInt(font_size);
    const h = size * 1.2;
    if (text.len == 0) return .{ .w = 0, .h = h };
    const len: f32 = @floatFromInt(text.len);
    return .{ .w = len * size * 0.6, .h = h };
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

const extent_cache_size: usize = 128;

const ExtentEntry = struct {
    hash: u64 = 0,
    w: f32 = 0,
    h: f32 = 0,
    valid: bool = false,
};

var extent_cache: [extent_cache_size]ExtentEntry = [_]ExtentEntry{.{}} ** extent_cache_size;
var extent_cache_next: usize = 0;
pub var extent_hits: u64 = 0;
pub var extent_misses: u64 = 0;

/// Pure + headless-testable hash for the extent cache.
pub fn hashMeasureKey(text_bytes: []const u8, font_size: u16) u64 {
    var h: u64 = 0xcbf29ce484222325;
    for (text_bytes) |b| {
        h ^= b;
        h *%= 0x100000001b3;
    }
    h ^= @as(u64, font_size);
    h *%= 0x100000001b3;
    h ^= @as(u64, text_bytes.len);
    h *%= 0x100000001b3;
    return h;
}

fn extentLookup(hash: u64) ?TextExtent {
    for (extent_cache) |e| {
        if (e.valid and e.hash == hash) return .{ .w = e.w, .h = e.h };
    }
    return null;
}

fn extentStore(hash: u64, ext: TextExtent) void {
    extent_cache[extent_cache_next] = .{ .hash = hash, .w = ext.w, .h = ext.h, .valid = true };
    extent_cache_next = (extent_cache_next + 1) % extent_cache_size;
}

pub fn extentCacheReset() void {
    for (&extent_cache) |*e| e.valid = false;
    extent_cache_next = 0;
    extent_hits = 0;
    extent_misses = 0;
}

pub fn measureText(text_bytes: []const u8, font_size: u16) TextExtent {
    const key = hashMeasureKey(text_bytes, font_size);
    if (extentLookup(key)) |hit| {
        extent_hits += 1;
        return hit;
    }
    extent_misses += 1;
    const ext = estimatorExtent(text_bytes, font_size);
    extentStore(key, ext);
    return ext;
}

// NOTE: there is deliberately NO `resolveFont` test here. That check asserts
// a macOS system font exists, so it only passes on macOS and would break the
// identical cross-platform test count that the parity suite guarantees. Font
// resolution on the native Pango path is covered by text.zig in `native-test`.

test "measureText returns positive extent for non-empty, zero width for empty" {
    const m = measureText("Settings", 18);
    try std.testing.expect(m.w > 0);
    try std.testing.expect(m.h > 0);
    const e = measureText("", 18);
    try std.testing.expectEqual(@as(f32, 0), e.w);
}

test "measureText is deterministic and cache resets cleanly" {
    extentCacheReset();
    const a = measureText("Settings", 18);
    const b = measureText("Settings", 18);
    try std.testing.expectApproxEqAbs(a.w, b.w, 1e-6);
    try std.testing.expectApproxEqAbs(a.h, b.h, 1e-6);
    try std.testing.expectEqual(@as(u64, 1), extent_misses);
    try std.testing.expectEqual(@as(u64, 1), extent_hits);
    extentCacheReset();
}

test "hashMeasureKey differs by bytes/size/len" {
    const a = hashMeasureKey("Settings", 18);
    try std.testing.expectEqual(a, hashMeasureKey("Settings", 18));
    try std.testing.expect(hashMeasureKey("Settings", 16) != a);
    try std.testing.expect(hashMeasureKey("Setting", 18) != a);
}
