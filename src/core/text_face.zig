// The one face: text is MEASURED with the font that DRAWS it. This file exists because the two used to disagree. Clay lays a run out with the measure

// callback, and the software rasteriser draws it with real glyphs; while the callback answered from an estimate (`len * size * 0.6`) every text box was

// the wrong width, a caret placed from a measurement drifted off the glyphs, and a run could overflow the box that was supposed to hold it. Nothing

// caught it, because the estimate was also what the tests measured against. So: one face, one measurement, used by the layout and by the rasteriser.

// When the host has no font file (a bare CI runner, wasm), the estimator is the fallback — and `fontAvailable()` says which one you got, so a test can

// skip or assert accordingly instead of silently measuring against a fiction.

const std = @import("std");
const glyphs = @import("glyphs.zig");
const color_glyphs = @import("color_glyphs.zig");
const font_io = @import("font_io.zig");
const estimator = @import("text_estimator.zig");

pub const TextExtent = estimator.TextExtent;

// The process-wide face. Loaded once, from the installed font or the platform's candidate list.
var face: ?glyphs.Font = null;
// True when `face` was loaded HERE, so its bytes are this module's to free; a backend-installed font owns its own.
var face_owned: bool = false;
var load_tried: bool = false;
// The allocator the application's `main` supplied. `Host.init` sets it before the first frame.
var face_alloc: ?std.mem.Allocator = null;
// The bytes of a face the APPLICATION handed over: copied so the caller's buffer may go, and given back by `deinitFace`.
var app_face: ?[]u8 = null;
var app_face_alloc: ?std.mem.Allocator = null;

/// Point the face at the allocator the application's `main` gave the toolkit.
pub fn setAllocator(alloc: std.mem.Allocator) void {
    face_alloc = alloc;
}

/// Adopt a face the APPLICATION supplies — an embedded `.ttf`, say — as the one this process measures and paints with.
pub fn installFaceBytes(alloc: std.mem.Allocator, bytes: []const u8) !void {
    // The face points into these bytes for the rest of the process, so the copy is not politeness: the caller's buffer may be a literal.
    const owned = try alloc.dupe(u8, bytes);
    errdefer alloc.free(owned);
    const f = try glyphs.Font.fromBytes(alloc, owned);
    // Drops the face and the widths this module held: those widths were measured with the pen that is being replaced.
    reset();
    // Installed after the reset, so nothing above can clear the new face out of the slot `font()` consults first.
    glyphs.installFont(f);
    app_face = owned;
    app_face_alloc = alloc;
}

// The face this process measures and draws with, or null when no font file could be parsed.
pub fn font() ?*glyphs.Font {
    // A backend that installed a face owns its bytes; copy the struct, not the data. Checked every call, because a host can install its face after the first

    // measurement.
    if (glyphs.installedFont()) |f| {
        // The installed struct replaces the one in use: a face loaded here is given back rather than dropped.
        releaseFace();
        face = f.*;
        load_tried = true;
        return &face.?;
    }
    if (!load_tried) {
        // Only a real allocator may latch the attempt: a measurement taken before `main` ran must not leave the process fontless for good.
        if (face_alloc) |a| {
            load_tried = true;
            face = glyphs.Font.loadDefault(a);
            face_owned = face != null;
        }
    }
    if (face) |*f| return f;
    return null;
}

// True when text is measured with real metrics rather than the estimator.
pub fn fontAvailable() bool {
    return font() != null;
}

// The line height a text box reserves at `font_size`. Deliberately the estimator's 1.2 * size and NOT the font's own ascent-descent: every layout in

// every consumer is tuned to that number, and the rasteriser centres the real line box inside it anyway.
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

// Drop the cached widths (and re-probe the font on the next call). For tests and for a font hot-swap.
pub fn reset() void {
    for (&cache) |*e| e.valid = false;
    cache_next = 0;
    deinitFace();
}

// Free the face this module loaded, if the bytes are its own; an installed face is left alone.
fn releaseFace() void {
    if (!face_owned) return;
    if (face) |*f| f.deinit();
    face_owned = false;
}

// Release the face for good: a host shutting down hands its allocator's memory back, so a debug allocator reports no leak.
pub fn deinitFace() void {
    releaseFace();
    face = null;
    load_tried = false;
    // An application's face is this module's to give back, and the slot that points into its bytes has to go with them.
    if (app_face) |bytes| if (app_face_alloc) |a| a.free(bytes);
    app_face = null;
    app_face_alloc = null;
    glyphs.clearInstalledFont();
    releaseColorFace();
}

// ---- the colour face: where an emoji comes from when the text face has no glyph for it ----

var colour_face: ?glyphs.Font = null;
var colour_tried: bool = false;

// The emoji face this platform ships, loaded once: Segoe UI Emoji, Noto Color Emoji, Apple Color Emoji.
pub fn colorFace() ?*glyphs.Font {
    if (!colour_tried) {
        colour_tried = true;
        if (face_alloc) |a| {
            for (font_io.colorCandidates()) |path| {
                const loaded = glyphs.Font.load(a, path) catch continue;
                if (!color_glyphs.hasColourTable(loaded.bytes)) {
                    var skip = loaded;
                    skip.deinit();
                    continue;
                }
                colour_face = loaded;
                break;
            }
            // The colour cache is pointed at the same allocator as the text cache, once.
            if (colour_face != null) color_glyphs.initCache(a);
        }
    }
    if (colour_face) |*f| return f;
    return null;
}

fn releaseColorFace() void {
    if (colour_face) |*f| f.deinit();
    colour_face = null;
    colour_tried = false;
}

/// The colour image for `cp` at `size`: the text face's own when it has one, else the emoji face's.
pub fn colorGlyph(cp: u21, font_size: u16) ?*const color_glyphs.Rgba {
    if (font()) |f| {
        if (color_glyphs.cached(f, cp, font_size)) |image| return image;
        // A real glyph in the text face means the app meant to draw that codepoint monochrome.
        if (f.glyphIndex(cp) != 0) return null;
    }
    const emoji_face = colorFace() orelse return null;
    return color_glyphs.cached(emoji_face, cp, font_size);
}

/// The advance a colour glyph takes, so the layout leaves it the room it will actually paint into.
pub fn colorAdvance(cp: u21, font_size: u16) ?f32 {
    const text = font() orelse return null;
    if (text.glyphIndex(cp) != 0) return null;
    const emoji_face = colorFace() orelse return null;
    const glyph = emoji_face.glyphIndex(cp);
    if (glyph == 0) return null;
    return emoji_face.glyphAdvance(glyph, font_size);
}

// Device pixels per point, as the window reported it: the rasteriser draws a run at round(size * this), not at size.
var pixel_scale: f32 = 1;

/// The scale the renderer will draw at, so a measured width is the width that is actually painted.
pub fn setPixelScale(s: f32) void {
    pixel_scale = if (s > 0) s else 1;
}

/// The whole device size a run of `font_size` points is drawn at: the same rounding the rasteriser does.
pub fn deviceSize(font_size: u16) u16 {
    if (font_size == 0) return 16;
    const scaled = @as(f32, @floatFromInt(font_size)) * pixel_scale;
    return @intFromFloat(@max(1, @round(scaled)));
}

// Width and line height of `text` at `font_size`, measured at the device size the rasteriser draws it at: the same pen.
pub fn measureText(text: []const u8, font_size: u16) TextExtent {
    const h = lineHeight(font_size);
    if (text.len == 0) return .{ .w = 0, .h = h };
    const f = font() orelse return estimator.measureText(text, font_size);

    // Keyed and cached in DEVICE pixels, so a width measured for one scale is never handed to another.
    const device = deviceSize(font_size);
    const hash = estimator.hashMeasureKey(text, device);
    if (cacheGet(hash)) |dev_w| return .{ .w = dev_w / pixel_scale, .h = h };
    const m = glyphs.measure(f, text, device);
    // An emoji is drawn from the colour face, so its own advance replaces the `.notdef` the text face measured.
    const width = m.width + colorWidthDelta(f, text, device);
    cachePut(hash, width);
    return .{ .w = width / pixel_scale, .h = h };
}

// How much wider the run is once every colour glyph takes its own advance: zero for ASCII, a scan for anything else.
fn colorWidthDelta(f: *const glyphs.Font, text: []const u8, device: u16) f32 {
    var non_ascii = false;
    for (text) |b| {
        if (b >= 0x80) non_ascii = true;
    }
    if (!non_ascii) return 0;
    var delta: f32 = 0;
    var i: usize = 0;
    while (i < text.len) {
        const cp = glyphs.nextCodepoint(text, &i);
        const advance = colorAdvance(cp, device) orelse continue;
        delta += advance - f.glyphMetrics(cp, device).advance;
    }
    return delta;
}

// ===================== tests =====================

test "measureText agrees with the glyph advances it will be drawn with" {
    // page_allocator: the face is a process-lifetime singleton, so it is deliberately never freed (same rule as the Clay arena).
    setAllocator(std.heap.page_allocator);
    const f = font() orelse return error.SkipZigTest;
    const m = measureText("Invoice", 14);
    try std.testing.expectApproxEqAbs(glyphs.measure(f, "Invoice", 14).width, m.w, 0.001);
}

test "a width is measured at the device size the run is drawn at" {
    // page_allocator: the face is a process-lifetime singleton, so it is deliberately never freed (same rule as the Clay arena).
    setAllocator(std.heap.page_allocator);
    const f = font() orelse return error.SkipZigTest;
    setPixelScale(1.25);
    defer setPixelScale(1);
    // 14 pt at 125% is drawn at round(17.5) = 18 device px, so the layout must be told 18 / 1.25 = 14.4 points.
    try std.testing.expectEqual(@as(u16, 18), deviceSize(14));
    const m = measureText("Invoice", 14);
    const drawn = glyphs.measure(f, "Invoice", deviceSize(14)).width;
    try std.testing.expectApproxEqAbs(drawn / 1.25, m.w, 0.01);
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

test "deinitFace returns the face's bytes to the allocator that was handed in" {
    // A backend's installed face owns its own bytes, so only the face loaded HERE is this module's to free.
    if (glyphs.installedFont() != null) return error.SkipZigTest;
    reset();
    setAllocator(std.testing.allocator);
    defer setAllocator(std.heap.page_allocator);
    if (font() == null) return error.SkipZigTest;
    try std.testing.expect(face_owned);
    // testing.allocator fails this test if the font's bytes are still live when it ends.
    deinitFace();
    try std.testing.expect(face == null);
    try std.testing.expect(!face_owned);
}

test "an application's face is what measures, and deinitFace hands its bytes back" {
    // The bundled bytes stand in for an app's own: what is under test is that installing them takes over the face and copies them.
    reset();
    setAllocator(std.testing.allocator);
    defer setAllocator(std.heap.page_allocator);
    try installFaceBytes(std.testing.allocator, font_io.bundled_font);
    try std.testing.expect(font() != null);
    try std.testing.expect(glyphs.installedFont() != null);
    try std.testing.expect(measureText("Invoice", 14).w > 0);
    // testing.allocator fails this test if the bytes this module copied are still live when it ends.
    deinitFace();
    try std.testing.expect(app_face == null);
    // The slot that points into those bytes is cleared too, so a later measurement cannot read freed memory.
    try std.testing.expect(glyphs.installedFont() == null);
}
