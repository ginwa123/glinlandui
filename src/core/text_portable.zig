//! Portable text measurement fallback — macOS's `text.zig` peer.
//!
//! macOS does not get a fabricated Pango/EGL runtime: it gets a deterministic,
//! pure-Zig version of the same public measurement contract. It is used by the
//! CPU frame pipeline and the reusable headless test driver, so those tests stay
//! meaningful on macOS without pulling in Linux-only system libraries.
//!
//! ## What lives here, and what moved out
//!
//! This module is now the **fs-backed font-discovery half** of the text
//! backend: the macOS system-font path list, the existence probe, and the
//! family name Pango would want. The estimator, its cache, its counters and
//! `ResolveFontError` moved to `core/text_estimator.zig` — see that file's
//! header for why (short version: the estimator is the part a new platform
//! needs, and this module's `std.Io` calls make it unusable for any host
//! without a filesystem, the wasm/browser backend included).
//!
//! The public surface is unchanged: everything is re-exported, so
//! `core/text_backend.zig`, `core/select.zig` and `src/mac/text.zig` need no
//! edit. That includes the three estimator tests, which are now collected from
//! `text_estimator.zig` — still exactly once, still through this module, so
//! `tests.lock` does not move.
const std = @import("std");
const estimator = @import("text_estimator.zig");

// ---- the shared, pure surface ----

pub const TextExtent = estimator.TextExtent;
pub const ResolveFontError = estimator.ResolveFontError;
pub const estimatorExtent = estimator.estimatorExtent;
pub const hashMeasureKey = estimator.hashMeasureKey;
pub const extentCacheReset = estimator.extentCacheReset;
pub const measureText = estimator.measureText;
/// NOTE: these are **pointers** to the estimator's live counters, not the
/// counter values. Splitting the estimator into `text_estimator.zig` means this
/// module can no longer alias a `var`, and copying the u64 would silently
/// desync the copy from the counter `measureText` actually increments. Nothing
/// in the repository consumes them (they exist as a test seam, exercised by
/// text_estimator's own tests), so the type change is inert — but read them as
/// `text_backend.extent_hits.*`, not `text_backend.extent_hits`.
pub const extent_hits = &estimator.extent_hits;
pub const extent_misses = &estimator.extent_misses;

// ---- the fs half of font loading ----

/// Read a font file whole. This is the filesystem half of `core/glyphs.zig`'s
/// font loading, living here for one reason: `glyphs.zig` is compiled by EVERY
/// build — the wasm one included — so it must contain no filesystem and no
/// `std.Io` reference at all. The platform text module owns that, and the wasm
/// module answers `error.FontNotFound` because a browser has no paths to read.
///
/// `alloc` is the caller's, so the native call site can keep passing
/// `std.heap.page_allocator` exactly as it did before the split, and the
/// ownership rule (`glyphs.Font.deinit` frees with the same allocator) is
/// unchanged.
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

// macOS ships these system fonts, so a no-dependency test can still prove the
// public font-resolution contract. Keep this list separate from the Linux
// pangocairo candidates in text.zig.
//
// `resolveFont` returns the first path that merely EXISTS, which is not the
// same as the first one a rasterizer can actually parse: a `.ttc` is a
// TrueType *collection* and stb_truetype's stbtt_InitFont rejects it. So
// `resolveFont` stays existence-based (its tests depend on that), and
// `glyphs.Font.loadDefault` walks this list and keeps the first one that
// genuinely loads. Entries are ordered best-looking-first: monospace UI faces
// before the monospaced-with-glyph-fallback option last.
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

/// Every candidate path, for callers that must try more than one (e.g. a
/// rasterizer that has to keep going until a file actually parses, since a
/// `.ttc` collection exists but cannot be loaded directly).
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

// NOTE: there is deliberately NO `resolveFont` test here. That check asserts
// a macOS system font exists, so it only passes on macOS and would break the
// identical cross-platform test count that the parity suite guarantees. Font
// resolution on the native Pango path is covered by text.zig in `native-test`.
//
// The estimator's three tests now live in core/text_estimator.zig. They are
// still reached from here, so the parity count is unchanged.
