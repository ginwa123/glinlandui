//! Browser text engine — the `text.zig` half of the platform mirror.
//!
//! Linux talks to pangocairo through `linux/text.zig` plus a C shim; macOS
//! re-exports the deterministic estimator from `core/text_portable.zig`. The
//! browser is closer to macOS — there is no native text engine here either — but
//! with one structural difference that matters:
//!
//!   **A browser has no font PATHS.** `/System/Library/Fonts/…` is meaningless
//!   in a tab, and `std.Io` — which is how macOS reaches the filesystem — is an
//!   OS-threaded reactor with no meaning in a wasm module. So this module takes
//!   the estimator from `core/text_estimator.zig` (the pure half) and answers
//!   every path-shaped question with "no", while the font itself arrives as
//!   BYTES over the network and is installed with `core/glyphs.zig`'s
//!   `installFont`.
//!
//! That split is why `core/text_estimator.zig` exists at all: it is the part a
//! host without a filesystem can still use.
//!
//! The re-export list is deliberately the exact set `core/text_backend.zig`
//! forwards, so `core/select.zig` can treat any platform's module the same.
const std = @import("std");
const estimator = @import("../core/text_estimator.zig");

pub const TextExtent = estimator.TextExtent;
pub const ResolveFontError = estimator.ResolveFontError;
pub const estimatorExtent = estimator.estimatorExtent;
pub const hashMeasureKey = estimator.hashMeasureKey;
pub const extentCacheReset = estimator.extentCacheReset;
pub const measureText = estimator.measureText;

/// Pointers, not values — see the note in `core/text_portable.zig`. The counters
/// live in the estimator, and this module cannot alias a `var` across modules.
pub const extent_hits = &estimator.extent_hits;
pub const extent_misses = &estimator.extent_misses;

/// No candidate paths, by construction: a browser has none to offer.
///
/// This is not a stub left empty out of laziness — it is the value that makes
/// `glyphs.Font.loadDefault()` correctly decline on this platform, so the
/// backend's `installFont` is the only way a browser gets glyphs. An empty list
/// also means the 15 font-dependent glyph tests skip in a wasm test run for the
/// honest reason (no font installed) rather than a misleading one.
pub const font_candidates: []const [:0]const u8 = &.{};

pub fn fontCandidates() []const [:0]const u8 {
    return font_candidates;
}

/// Always fails. A path cannot name a font here — see `installFont` in
/// `core/glyphs.zig` for what a browser does instead.
pub fn resolveFont() ResolveFontError![]const u8 {
    return error.FontNotFound;
}

/// Never called: `readFontBytes` below is the only reader the glyph path uses,
/// and it always fails. Present because `core/text_backend.zig` forwards it, and
/// the facade has to resolve on every platform.
pub fn readFontBytes(path: [:0]const u8, alloc: std.mem.Allocator) ![]u8 {
    _ = path;
    _ = alloc;
    return error.FontNotFound;
}

/// `pangoFamily` is a pangocairo concept. It is re-exported for surface parity
/// with `linux/text.zig` and `mac/text.zig`; the estimator ignores it.
pub fn pangoFamily() [:0]const u8 {
    return "monospace";
}

// ===================== tests (parity suite — every platform) =====================
//
// The estimator's own tests live in core/text_estimator.zig (moved there, so the
// count did not change). What is worth pinning HERE is the platform-specific
// contract: the refusals. They are the reason the web backend installs bytes
// instead of resolving paths, and getting one of them wrong would mean a silent
// fallback to glyph-free bars in a tab with no way to see why.

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
    // Proves the re-export genuinely resolves to the shared implementation, so
    // a browser lays text out with the SAME arithmetic macOS does.
    const m = measureText("Settings", 18);
    try std.testing.expect(m.w > 0);
    try std.testing.expect(m.h > 0);
    try std.testing.expectEqual(estimator.estimatorExtent("Settings", 18).w, m.w);
}
