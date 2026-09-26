const std = @import("std");

// Text measurement shaped for Clay.
//
// Backend: pangocairo via src/linux/shim.h shim (PangoLayout) with
// pure-Zig estimator fallback.
//   primary: glinlandui_text_measure() — correct advances, shaping,
//     CJK/Arabic, fontconfig fallback.
//   fallback: width = text.len * font_size * 0.6, height = size * 1.2
//     (empty text measures w = 0 but keeps full line height, which is
//     what Clay expects from a measure callback.)
//
// Why a shim: Zig @cImport cannot parse glib headers directly
// (G_GNUC_BEGIN_IGNORE_DEPRECATIONS translation failure). The shim header
// exposes only plain C types; real pango/cairo includes stay in
// src/linux/shim.c (system compiler). Links from build.zig linkTextEngine().

const shim = @cImport({
    @cInclude("shim.h");
});

/// Clay-shaped text extent.
pub const TextExtent = struct {
    w: f32,
    h: f32,
};

pub const ResolveFontError = error{
    FontNotFound,
};

// Preferred fonts first (Fira Code Regular, confirmed via fc-list on this
// machine), then any monospace TTF/OTF fallback. All entries must stay
// NUL-terminated: fontExists() passes them straight to access(2).
// Still used for the stb fallback atlas + to derive the Pango family name.
const font_candidates: []const [:0]const u8 = &.{
    "/usr/share/fonts/TTF/FiraCodeNerdFontMono-Regular.ttf",
    "/usr/share/fonts/TTF/FiraCodeNerdFont-Regular.ttf",
    "/usr/share/fonts/TTF/FiraCodeNerdFontPropo-Regular.ttf",
    "/usr/share/fonts/TTF/CaskaydiaCoveNerdFontMono-Regular.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
    "/usr/share/fonts/TTF/DejaVuSansMono.ttf",
};

fn fontExists(path: [:0]const u8) bool {
    // Linux-only (like the rest of this Wayland app): raw access(2), no Io needed.
    return std.os.linux.access(path, std.os.linux.F_OK) == 0;
}

/// Return the path of a usable monospace font file, or FontNotFound.
pub fn resolveFont() ResolveFontError![]const u8 {
    for (font_candidates) |path| {
        if (fontExists(path)) return path;
    }
    return error.FontNotFound;
}

/// Every candidate path. The CPU renderer walks the whole list and keeps the
/// first file that actually PARSES, not merely the first that exists: a `.ttc`
/// is a TrueType collection and stb_truetype cannot load it directly.
pub fn fontCandidates() []const [:0]const u8 {
    return font_candidates;
}

/// Pure-Zig fallback: deterministic, no C deps. Used when Pango fails
/// (headless without fontconfig, oversized text, or C null returns).
pub fn estimatorExtent(text: []const u8, font_size: u16) TextExtent {
    const size: f32 = @floatFromInt(font_size);
    const h = size * 1.2;
    if (text.len == 0) return .{ .w = 0, .h = h };
    const len: f32 = @floatFromInt(text.len);
    return .{ .w = len * size * 0.6, .h = h };
}

/// Pango family for measurement + rendering. Maps the resolved TTF path
/// to a fontconfig family so Pango reuses the same face the old stb atlas
/// used. Unknown paths fall back to generic "monospace" (always resolvable).
/// Pub because renderer.zig must use the identical family for draw.
/// Resolved once and cached — the font files don't change at runtime, and
/// per-call access(2) probing (up to 6 stats per measure/render) showed up
/// in hover profiles at ~3.6k desc parses/sec for 20 labels @ 60fps.
var cached_family: ?[:0]const u8 = null;

pub fn pangoFamily() [:0]const u8 {
    if (cached_family) |f| return f;
    const path = resolveFont() catch {
        cached_family = "monospace";
        return "monospace";
    };
    const fam: [:0]const u8 = if (std.mem.indexOf(u8, path, "FiraCodeNerdFontMono") != null)
        "FiraCode Nerd Font Mono"
    else if (std.mem.indexOf(u8, path, "FiraCodeNerdFontPropo") != null)
        "FiraCode Nerd Font Propo"
    else if (std.mem.indexOf(u8, path, "FiraCodeNerdFont") != null)
        "FiraCode Nerd Font"
    else if (std.mem.indexOf(u8, path, "CaskaydiaCove") != null)
        "CaskaydiaCove Nerd Font Mono"
    else if (std.mem.indexOf(u8, path, "DejaVuSansMono") != null)
        "DejaVu Sans Mono"
    else
        "monospace";
    cached_family = fam;
    return fam;
}

/// Small extent cache: hover motion re-measures the same ~20 static labels
/// every frame (once in Clay layout via clayMeasure, once in drawTextPango).
/// Each miss costs a full Pango stack (fontmap→context→layout→desc→measure).
/// 128-entry round-robin cache keyed by FNV-1a(text, font_size) — hits skip
/// Pango entirely. Single-threaded UI only; no locking.
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

/// Build "Family 18px" Pango font-desc string into buf (NUL-terminated).
/// Returns the C pointer, or null if formatting fails.
///
/// The `px` suffix is load-bearing, not decoration. Pango reads a bare number
/// as POINTS and scales it by the fontmap resolution (96 dpi -> x4/3) before
/// picking the face, so "Mono 18" rasterizes as a 24px em. Every other backend
/// in this project treats `font_size` as PIXELS — that is Clay's unit, what the
/// CPU/stb glyph path feeds to stbtt_ScaleForPixelHeight, and what the shared
/// estimator in core/text_portable.zig assumes — so without the suffix the same
/// app drew its labels a third larger here than on macOS. `px` is Pango's
/// "absolute size" marker (pango/fonts.c: parse_size, consumed by
/// pango/pangofc-fontmap.c: get_scaled_size, which skips the dpi multiply).
///
/// BOTH the measure and the render path go through this one function, so the
/// layout box and the blitted texture can never disagree about the size.
pub fn pangoDescInto(buf: *[128]u8, font_size: u16) ?[*:0]const u8 {
    if (font_size == 0) return null;
    const family = pangoFamily();
    _ = std.fmt.bufPrint(buf, "{s} {d}px\x00", .{ family, font_size }) catch return null;
    return @ptrCast(buf);
}

test "pangoDescInto marks the size absolute (px), never points" {
    // Points would be x4/3 larger at Pango's default 96 dpi, which is exactly
    // the Linux-vs-macOS size mismatch this pins shut.
    var buf: [128]u8 = undefined;
    const desc = pangoDescInto(&buf, 18) orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.endsWith(u8, std.mem.span(desc), " 18px"));
    try std.testing.expect(pangoDescInto(&buf, 0) == null);
}

/// Try Pango measurement via the C shim. Returns null on any failure so
/// the caller can fall back to estimatorExtent(). Never crashes.
fn measurePango(text: []const u8, font_size: u16) ?TextExtent {
    if (font_size == 0) return null;
    if (text.len == 0) {
        // Keep Clay contract (w=0, full height) but use Pango line height
        // when available: measure "M" once.
        if (measurePango("M", font_size)) |m| return .{ .w = 0, .h = m.h };
        return null;
    }
    if (text.len > 4095) return null;

    var desc_buf: [128]u8 = undefined;
    const desc_str = pangoDescInto(&desc_buf, font_size) orelse return null;

    var w: c_int = 0;
    var h: c_int = 0;
    const ok = shim.glinlandui_text_measure(
        @ptrCast(text.ptr),
        @intCast(text.len),
        desc_str,
        &w,
        &h,
    );
    if (!ok or w < 0 or h <= 0) return null;
    return .{ .w = @floatFromInt(w), .h = @floatFromInt(h) };
}

/// Pixel extent of `text` at `font_size` for Clay layout.
/// Primary: Pango. Fallback: estimator (never fails).
/// Cached: repeat measures of the same label skip Pango entirely.
pub fn measureText(text_bytes: []const u8, font_size: u16) TextExtent {
    const key = hashMeasureKey(text_bytes, font_size);
    if (extentLookup(key)) |hit| {
        extent_hits += 1;
        return hit;
    }
    extent_misses += 1;
    const ext: TextExtent = if (measurePango(text_bytes, font_size)) |m| m else estimatorExtent(text_bytes, font_size);
    extentStore(key, ext);
    return ext;
}

test "resolveFont returns an existing .ttf/.otf/.ttc path" {
    const path = try resolveFont();
    try std.testing.expect(path.len > 0);
    const ok = std.mem.endsWith(u8, path, ".ttf") or
        std.mem.endsWith(u8, path, ".otf") or
        std.mem.endsWith(u8, path, ".ttc");
    try std.testing.expect(ok);
}

test "measureText returns positive extent for non-empty, zero width for empty" {
    const m = measureText("Settings", 18);
    try std.testing.expect(m.w > 0);
    try std.testing.expect(m.h > 0);
    const e = measureText("", 18);
    try std.testing.expectEqual(@as(f32, 0), e.w);
}

test "measureText is deterministic and pango height sane" {
    const a = measureText("Settings", 18);
    const b = measureText("Settings", 18);
    try std.testing.expectApproxEqAbs(a.w, b.w, 1e-6);
    try std.testing.expectApproxEqAbs(a.h, b.h, 1e-6);
    // Line height should be in a sane range (0.8x..2.0x font size).
    try std.testing.expect(a.h >= 18 * 0.8 and a.h <= 18 * 2.0);
}

test "estimatorExtent matches legacy 0.6 advance contract" {
    const e = estimatorExtent("AB", 18);
    try std.testing.expectApproxEqAbs(@as(f32, 2 * 18 * 0.6), e.w, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 18 * 1.2), e.h, 1e-6);
}

test "hashMeasureKey differs by bytes/size/len" {
    const a = hashMeasureKey("Settings", 18);
    const b = hashMeasureKey("Settings", 18);
    try std.testing.expectEqual(a, b);
    try std.testing.expect(hashMeasureKey("Settings", 16) != a);
    try std.testing.expect(hashMeasureKey("Setting", 18) != a);
}

test "measureText caches repeats (hit after miss)" {
    extentCacheReset();
    const a = measureText("CacheMe", 18);
    try std.testing.expectEqual(@as(u64, 0), extent_hits);
    try std.testing.expectEqual(@as(u64, 1), extent_misses);
    const b = measureText("CacheMe", 18);
    try std.testing.expectEqual(@as(u64, 1), extent_hits);
    try std.testing.expectApproxEqAbs(a.w, b.w, 1e-6);
    try std.testing.expectApproxEqAbs(a.h, b.h, 1e-6);
    extentCacheReset();
}
