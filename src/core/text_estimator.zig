//! The deterministic text estimator — the pure half of the text backend.
//!
//! ## Why this is its own module (and not just "the top of text_portable")
//!
//! `core/text_portable.zig` used to hold two things that have nothing to do
//! with each other:
//!
//!   1. this estimator — a pure function of (bytes, font_size), plus a small
//!      extent cache and its hit/miss counters. No I/O, no allocator, no
//!      platform.
//!   2. macOS system-font *discovery* — a list of `/System/Library/Fonts/...`
//!      paths and an `exists` check that goes through `std.Io`.
//!
//! Every build reaches (2) through `platform.zig`'s `is_test` branch, so
//! `text_portable.zig` is the macOS production text backend AND the test
//! backend on every OS (README invariant I2). That made (1) — the part a new
//! platform actually needs — unreachable for any host that cannot run
//! `std.Io`: the wasm/browser backend included, since `std.Io.Threaded` is an
//! OS-threaded reactor with no meaning in a wasm module.
//!
//! Splitting (1) out is what lets a backend take the estimator without taking
//! a filesystem. `text_portable.zig` and `src/mac/text.zig` keep their exact
//! public surface (they re-export from here), and `src/web/text.zig` re-exports
//! from here too while supplying its own no-fs font resolution.
//!
//! The three `test` blocks below moved here from `text_portable.zig`. That is a
//! MOVE, not an addition: the count in `tests.lock` is unchanged, because
//! `text_portable.zig` still reaches this file and the parity suite still
//! collects the same three tests exactly once.
//!
//! `ResolveFontError` also lives here, which looks like a layering slip until
//! you see the alternative: both `text_portable.zig` (via fs) and
//! `src/web/text.zig` (via embedded/fetched bytes) must return it, and the web
//! module must not import `text_portable.zig` at all. One definition, shared.
const std = @import("std");

/// Clay-shaped text extent.
pub const TextExtent = struct {
    w: f32,
    h: f32,
};

/// Returned by a font resolver that cannot find a usable face. Shared by every
/// text backend — see the module comment for why it lives in the pure module
/// rather than in the fs-backed one.
pub const ResolveFontError = error{
    FontNotFound,
};

/// Pure-Zig fallback: deterministic, no C deps.
pub fn estimatorExtent(text: []const u8, font_size: u16) TextExtent {
    const size: f32 = @floatFromInt(font_size);
    const h = size * 1.2;
    if (text.len == 0) return .{ .w = 0, .h = h };
    const len: f32 = @floatFromInt(text.len);
    return .{ .w = len * size * 0.6, .h = h };
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

/// Test seam: clear the cache + stats.
pub fn extentCacheReset() void {
    for (&extent_cache) |*e| e.valid = false;
    extent_cache_next = 0;
    extent_hits = 0;
    extent_misses = 0;
}

/// The estimator behind the cache. Backends with a real text engine (Linux's
/// pangocairo) call their own measure first and fall back to
/// `estimatorExtent`; backends without one (macOS, the browser) call this.
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

// ===================== tests (parity suite — every platform) =====================

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
