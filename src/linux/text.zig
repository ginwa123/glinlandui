//! The Linux text backend: which font file this host has, and the coverage rasteriser the GLES renderer blits.
const std = @import("std");
const glyphs = @import("../core/glyphs.zig");
const text_face = @import("../core/text_face.zig");
const estimator = @import("../core/text_estimator.zig");

/// Clay-shaped text extent.
pub const TextExtent = text_face.TextExtent;

pub const ResolveFontError = error{
    FontNotFound,
};

// Preferred fonts first (Fira Code Regular, confirmed via fc-list on this machine), then any monospace TTF/OTF fallback.
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

/// Every candidate path.
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

/// Pure-Zig fallback: deterministic, no C deps.
pub const estimatorExtent = estimator.estimatorExtent;
pub const hashMeasureKey = estimator.hashMeasureKey;
pub const extentCacheReset = estimator.extentCacheReset;

/// The extent Clay lays a box out with: measured by the face that draws the run, exactly as every other backend does it.
pub const measureText = text_face.measureText;

/// Family name of the resolved face, for a host that would rather ask a system text engine than carry the glyphs itself.
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

// ---- the rasteriser ----

/// One run as 8-bit coverage, one byte per pixel: the red channel the GLES text shader samples.
pub const RunBitmap = struct {
    pixels: []u8,
    width: u32,
    height: u32,

    /// Release the coverage buffer. The bitmap owns nothing else.
    pub fn deinit(self: RunBitmap, alloc: std.mem.Allocator) void {
        alloc.free(self.pixels);
    }
};

/// Rasterise `run` at (`origin_x`, `origin_y`) into coverage of `box_h`, pen advances and glyph snapping exactly as the CPU reference does.
pub fn rasterizeRun(
    alloc: std.mem.Allocator,
    run: []const u8,
    font_size: u16,
    origin_x: f32,
    origin_y: f32,
    box_h: f32,
) ?RunBitmap {
    if (run.len == 0) return null;
    const face = text_face.font() orelse return null;
    const fs: u16 = if (font_size == 0) 16 else font_size;
    const m = glyphs.measure(face, run, fs);
    if (m.width <= 0) return null;

    const line_h = text_face.lineHeight(fs);
    const box = if (box_h > 0) box_h else line_h;
    // One spare column each way: the pen may round up on the first glyph and down on the last.
    const w: u32 = @intFromFloat(@ceil(m.width) + 2);
    const h: u32 = @intFromFloat(@ceil(@max(box, line_h)) + 1);
    if (w == 0 or h == 0) return null;

    const pixels = alloc.alloc(u8, @as(usize, w) * @as(usize, h)) catch return null;
    @memset(pixels, 0);

    const baseline = origin_y + (if (glyphs.capBox(face, fs)) |cap|
        (if (box_h > 0) (box_h - cap.height) * 0.5 else 0) - cap.top
    else
        (if (box_h > 0) box_h - line_h else 0) * 0.5 + m.ascent);
    // The bitmap is blitted on this whole pixel, so glyph rows and columns are measured from it.
    const grid_x: f32 = @floor(origin_x);
    const grid_y: f32 = @floor(origin_y);

    var pen = origin_x;
    var i: usize = 0;
    while (i < run.len) {
        const cp = glyphs.nextCodepoint(run, &i);
        const gm = face.glyphMetrics(cp, fs);
        if (glyphs.cachedGlyph(face, cp, fs)) |mask| {
            const gx: f32 = @floor(pen + mask.xoff) - grid_x;
            const gy: f32 = @floor(baseline + mask.yoff) - grid_y;
            blitCoverage(pixels, w, h, gx, gy, mask.data[0 .. mask.w * mask.h], mask.w, mask.h);
        }
        pen += gm.advance;
    }
    return .{ .pixels = pixels, .width = w, .height = h };
}

/// OR one glyph's coverage into the run bitmap, clipping to the bitmap's edges.
fn blitCoverage(dst: []u8, w: u32, h: u32, gx: f32, gy: f32, src: []const u8, sw: usize, sh: usize) void {
    const wi: i64 = @intCast(w);
    const hi: i64 = @intCast(h);
    const ox: i64 = @intFromFloat(gx);
    const oy: i64 = @intFromFloat(gy);
    var row: usize = 0;
    while (row < sh) : (row += 1) {
        const y = oy + @as(i64, @intCast(row));
        if (y < 0 or y >= hi) continue;
        var col: usize = 0;
        while (col < sw) : (col += 1) {
            const x = ox + @as(i64, @intCast(col));
            if (x < 0 or x >= wi) continue;
            const coverage = src[row * sw + col];
            if (coverage == 0) continue;
            const o = @as(usize, @intCast(y)) * @as(usize, w) + @as(usize, @intCast(x));
            dst[o] = @max(dst[o], coverage);
        }
    }
}

// ===================== tests (Linux-only `native-test` leg) =====================

fn requireFace() ?*glyphs.Font {
    // Both caches are process-lifetime singletons that outlive a test, so they take the page allocator, the same rule `text_face.zig` follows.
    text_face.setAllocator(std.heap.page_allocator);
    glyphs.initCache(std.heap.page_allocator);
    return text_face.font();
}

/// The rightmost column that carries ink, plus one — how wide the run actually paints.
fn inkWidth(b: RunBitmap) u32 {
    var last: u32 = 0;
    var y: u32 = 0;
    while (y < b.height) : (y += 1) {
        var x: u32 = 0;
        while (x < b.width) : (x += 1) {
            if (b.pixels[@as(usize, y) * b.width + x] != 0) last = @max(last, x + 1);
        }
    }
    return last;
}

/// The topmost row that carries ink, or null for a run with none.
fn firstInkRow(b: RunBitmap) ?u32 {
    for (0..b.height) |y| {
        for (0..b.width) |x| {
            if (b.pixels[y * b.width + x] != 0) return @intCast(y);
        }
    }
    return null;
}

/// The row after the last one that carries ink, or null for a run with none.
fn inkBottom(b: RunBitmap) ?u32 {
    var y = b.height;
    while (y > 0) {
        y -= 1;
        for (0..b.width) |x| {
            if (b.pixels[y * b.width + x] != 0) return @intCast(y + 1);
        }
    }
    return null;
}

test "a run paints no wider than the box the layout measured for it" {
    // The Linux renderer used to lay text out with the bundled face and paint it with a 1.333x wider one: every label overflowed.
    if (requireFace() == null) return error.SkipZigTest;
    const runs = [_][]const u8{ "Run query", "Explain", "Include view", "background surface" };
    for (runs) |run| {
        for ([_]u16{ 12, 13, 14, 18 }) |size| {
            const measured = measureText(run, size).w;
            const bmp = rasterizeRun(std.testing.allocator, run, size, 0, 0, 0) orelse continue;
            defer bmp.deinit(std.testing.allocator);
            try std.testing.expect(@as(f32, @floatFromInt(inkWidth(bmp))) <= measured + 2);
        }
    }
}

test "a run fills most of the width it was measured at" {
    // The other half of the same contract: a run that paints a fraction of its box is the mirror bug (too-wide boxes, drifting carets).
    if (requireFace() == null) return error.SkipZigTest;
    for ([_][]const u8{ "Run query", "background surface" }) |run| {
        const measured = measureText(run, 14).w;
        const bmp = rasterizeRun(std.testing.allocator, run, 14, 0, 0, 0) orelse return error.SkipZigTest;
        defer bmp.deinit(std.testing.allocator);
        try std.testing.expect(@as(f32, @floatFromInt(inkWidth(bmp))) > measured * 0.8);
    }
}

test "a taller box centres the ink in it instead of clipping it" {
    // Clay hands the run a line box; a taller one (a button's content box) must move the glyphs with it, not clip them.
    if (requireFace() == null) return error.SkipZigTest;
    const line_h = text_face.lineHeight(14);
    const tight = rasterizeRun(std.testing.allocator, "Ag", 14, 0, 0, 0) orelse return error.SkipZigTest;
    defer tight.deinit(std.testing.allocator);
    const tall = rasterizeRun(std.testing.allocator, "Ag", 14, 0, 0, line_h * 3) orelse return error.SkipZigTest;
    defer tall.deinit(std.testing.allocator);
    const tight_top = firstInkRow(tight) orelse return error.SkipZigTest;
    const tall_top = firstInkRow(tall) orelse return error.SkipZigTest;
    try std.testing.expect(@as(f32, @floatFromInt(tall_top)) > @as(f32, @floatFromInt(tight_top)) + line_h * 0.5);
}

test "the same run on the same sub-pixel phase paints identical coverage" {
    // The texture depends on the box and the sub-pixel phase alone, which is why the phase is in the cache key.
    if (requireFace() == null) return error.SkipZigTest;
    const here = rasterizeRun(std.testing.allocator, "Run query", 13, 40.25, 100.75, 16.8) orelse return error.SkipZigTest;
    defer here.deinit(std.testing.allocator);
    const far = rasterizeRun(std.testing.allocator, "Run query", 13, 743.25, 850.75, 16.8) orelse return error.SkipZigTest;
    defer far.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, here.pixels, far.pixels);
}

test "a label sits inside the pill the layout drew around it" {
    // A button's content box starts at y = 166.4 and is one line tall: the run's ink has to end inside its bottom edge.
    const face = requireFace() orelse return error.SkipZigTest;
    const box_h = text_face.lineHeight(13);
    const origin_y: f32 = 166.4;
    const bmp = rasterizeRun(std.testing.allocator, "Run query", 13, 36.4, origin_y, box_h) orelse return error.SkipZigTest;
    defer bmp.deinit(std.testing.allocator);
    // The bitmap hangs off `floor(origin_y)`, so its rows only mean something back on the pixel grid the blit draws them on.
    const grid = @floor(origin_y);
    const top = grid + @as(f32, @floatFromInt(firstInkRow(bmp) orelse return error.SkipZigTest));
    const bottom = grid + @as(f32, @floatFromInt(inkBottom(bmp) orelse return error.SkipZigTest));
    try std.testing.expect(bottom <= @ceil(origin_y + box_h));
    // Ink shorter than the cap box means the bitmap clipped a glyph instead of laying it out inside the box.
    const cap = glyphs.capBox(face, 13) orelse return error.SkipZigTest;
    try std.testing.expect(bottom - top >= cap.height);
}

test "a space advances the pen without inking it" {
    // A missing space advance is what runs words together; a spaced-out run is what proves the advance is real.
    if (requireFace() == null) return error.SkipZigTest;
    const spaced = rasterizeRun(std.testing.allocator, "a a", 14, 0, 0, 0) orelse return error.SkipZigTest;
    defer spaced.deinit(std.testing.allocator);
    const tight = rasterizeRun(std.testing.allocator, "aa", 14, 0, 0, 0) orelse return error.SkipZigTest;
    defer tight.deinit(std.testing.allocator);
    try std.testing.expect(spaced.width > tight.width);

    const blank = rasterizeRun(std.testing.allocator, "   ", 14, 0, 0, 0) orelse return error.SkipZigTest;
    defer blank.deinit(std.testing.allocator);
    var inked: usize = 0;
    for (blank.pixels) |p| {
        if (p != 0) inked += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), inked);
}

test "rasterising the same run twice paints the same coverage" {
    if (requireFace() == null) return error.SkipZigTest;
    const a = rasterizeRun(std.testing.allocator, "Invoice 42", 15, 12, 40, 0) orelse return error.SkipZigTest;
    defer a.deinit(std.testing.allocator);
    const b = rasterizeRun(std.testing.allocator, "Invoice 42", 15, 12, 40, 0) orelse return error.SkipZigTest;
    defer b.deinit(std.testing.allocator);
    try std.testing.expectEqual(a.width, b.width);
    try std.testing.expectEqual(a.height, b.height);
    try std.testing.expectEqualSlices(u8, a.pixels, b.pixels);
}

test "an empty run paints nothing rather than allocating a texture" {
    if (requireFace() == null) return error.SkipZigTest;
    try std.testing.expect(rasterizeRun(std.testing.allocator, "", 14, 0, 0, 0) == null);
}

test "resolveFont returns an existing .ttf/.otf/.ttc path" {
    const path = try resolveFont();
    try std.testing.expect(path.len > 0);
    const ok = std.mem.endsWith(u8, path, ".ttf") or
        std.mem.endsWith(u8, path, ".otf") or
        std.mem.endsWith(u8, path, ".ttc");
    try std.testing.expect(ok);
}
