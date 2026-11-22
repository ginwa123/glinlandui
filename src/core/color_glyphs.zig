//! Colour glyphs: a codepoint the text face cannot draw as an outline, drawn as the colour image its font carries.
const std = @import("std");
const builtin = @import("builtin");
const glyphs = @import("glyphs.zig");
// `build.zig`'s `stbFlags` compiles stb's C TUs for wasm with `-DSTBI_NO_STDIO=1 -DSTBIR_NO_SIMD=1`, because `wasm32-freestanding` has no `<stdio.h>`.

// `@cImport` runs its own translate-c and inherits none of a C TU's flags, so the same two macros are declared here too, or the browser build cannot translate the header at all.
const stbi = @cImport({
    if (builtin.cpu.arch.isWasm()) {
        @cDefine("STBI_NO_STDIO", "1");
        @cDefine("STBIR_NO_SIMD", "1");
    }
    @cInclude("stb/stb_image.h");
});

/// A rasterised colour glyph: RGBA8 with straight alpha, and where its top-left sits from the pen (x) and baseline (y).
pub const Rgba = struct {
    pixels: []const u8,
    w: usize,
    h: usize,
    xoff: i32,
    yoff: i32,
    /// How far the pen moves after drawing it: the colour face's own advance, not the text face's `.notdef` width.
    advance: f32,
};

// ---- big-endian readers: every sfnt table is big-endian, and every one of these returns null rather than panicking ----

fn u8At(b: []const u8, at: usize) ?u8 {
    return if (at < b.len) b[at] else null;
}

fn u16At(b: []const u8, at: usize) ?u16 {
    if (at + 2 > b.len) return null;
    return (@as(u16, b[at]) << 8) | b[at + 1];
}

fn i16At(b: []const u8, at: usize) ?i16 {
    const v = u16At(b, at) orelse return null;
    return @bitCast(v);
}

fn u32At(b: []const u8, at: usize) ?u32 {
    if (at + 4 > b.len) return null;
    return (@as(u32, b[at]) << 24) | (@as(u32, b[at + 1]) << 16) | (@as(u32, b[at + 2]) << 8) | b[at + 3];
}

/// The bytes of one table, found through the sfnt directory at the front of the file.
pub fn table(bytes: []const u8, tag: *const [4]u8) ?[]const u8 {
    if (bytes.len < 12) return null;
    // A collection ("ttcf") holds several fonts; this reads the FIRST one, which is what a single installed face means.
    var base: usize = 0;
    if (std.mem.eql(u8, bytes[0..4], "ttcf")) {
        base = u32At(bytes, 12) orelse return null;
    }
    if (base + 12 > bytes.len) return null;
    const num = u16At(bytes, base + 4) orelse return null;
    var i: usize = 0;
    while (i < num) : (i += 1) {
        const rec = base + 12 + i * 16;
        if (rec + 16 > bytes.len) return null;
        if (!std.mem.eql(u8, bytes[rec..][0..4], tag)) continue;
        const off = u32At(bytes, rec + 8) orelse return null;
        const len = u32At(bytes, rec + 12) orelse return null;
        if (@as(u64, off) + len > bytes.len) return null;
        return bytes[off..][0..len];
    }
    return null;
}

/// True when a face carries any colour table at all, which is the cheap test before asking it for an image.
pub fn hasColourTable(bytes: []const u8) bool {
    return table(bytes, "COLR") != null or table(bytes, "CBDT") != null or table(bytes, "sbix") != null;
}

// ---- CPAL: the colours a COLR layer can name ----

/// A colour from the first palette of a CPAL table, as RGBA. An index past the palette is the text colour, per spec.
pub fn paletteColor(cpal: []const u8, index: u16) ?[4]u8 {
    const entries = u16At(cpal, 2) orelse return null;
    const num_palettes = u16At(cpal, 4) orelse return null;
    if (entries == 0 or num_palettes == 0) return null;
    const records = u32At(cpal, 8) orelse return null;
    const first = u16At(cpal, 12) orelse return null;
    if (index >= entries) return null;
    const at = @as(usize, records) + (@as(usize, first) + index) * 4;
    // CPAL stores BGRA.
    const b = u8At(cpal, at) orelse return null;
    const g = u8At(cpal, at + 1) orelse return null;
    const r = u8At(cpal, at + 2) orelse return null;
    const a = u8At(cpal, at + 3) orelse return null;
    return .{ r, g, b, a };
}

// ---- COLR v0: a base glyph is a list of (layer glyph, palette colour) ----

pub const Layer = struct { glyph: u16, palette: u16 };

/// The version-0 part of a COLR table: base glyph records and the layer records they index.
pub const Colr = struct {
    data: []const u8,
    base_at: usize,
    layer_at: usize,
    num_base: usize,

    /// The layer records of `glyph`, four bytes each, or null when it is not a colour base glyph.
    pub fn layersOf(self: Colr, glyph: u16) ?[]const u8 {
        // Base records are sorted by glyph id, so a binary search finds one; the record itself is (first, count).
        var lo: usize = 0;
        var hi: usize = self.num_base;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const at = self.base_at + mid * 6;
            const id = u16At(self.data, at) orelse return null;
            if (id == glyph) {
                const first = u16At(self.data, at + 2) orelse return null;
                const count = u16At(self.data, at + 4) orelse return null;
                const start = self.layer_at + @as(usize, first) * 4;
                const end = start + @as(usize, count) * 4;
                if (end > self.data.len) return null;
                return self.data[start..end];
            }
            if (id < glyph) lo = mid + 1 else hi = mid;
        }
        return null;
    }
};

/// One layer record: the glyph to draw and the palette colour to fill it with.
pub fn layerAt(layers: []const u8, index: usize) ?Layer {
    if (index * 4 + 4 > layers.len) return null;
    const glyph = u16At(layers, index * 4) orelse return null;
    const palette = u16At(layers, index * 4 + 2) orelse return null;
    return .{ .glyph = glyph, .palette = palette };
}

/// The COLR table of a face, when it has a version-0 part (a version-1 table keeps it for renderers like this one).
pub fn colrOf(face_bytes: []const u8) ?Colr {
    const data = table(face_bytes, "COLR") orelse return null;
    const base_at = u32At(data, 4) orelse return null;
    const layer_at = u32At(data, 8) orelse return null;
    const num_base = u16At(data, 2) orelse return null;
    if (num_base == 0) return null;
    return .{ .data = data, .base_at = base_at, .layer_at = layer_at, .num_base = num_base };
}

// ---- CBDT / CBLC and sbix: PNGs, one per glyph, in a strike per size ----

/// One bitmap a font carries for a glyph: the PNG bytes plus where it goes and how wide it is.
pub const Bitmap = struct {
    png: []const u8,
    w: usize,
    h: usize,
    bearing_x: i32,
    bearing_y: i32,
    advance: f32,
    /// The strike's pixels per em, so the caller can scale the image to the size it actually asked for.
    ppem: u16,
};

fn diff(a: u16, b: u16) u16 {
    return if (a > b) a - b else b - a;
}

/// The PNG a CBDT/CBLC font carries for `glyph`, from the strike nearest `size`.
pub fn cbdtBitmap(face_bytes: []const u8, glyph: u16, size: u16) ?Bitmap {
    const cblc = table(face_bytes, "CBLC") orelse return null;
    const cbdt = table(face_bytes, "CBDT") orelse return null;
    const num_sizes = u32At(cblc, 4) orelse return null;
    var best: ?struct { rec: usize, ppem: u16 } = null;
    var i: usize = 0;
    while (i < num_sizes) : (i += 1) {
        const rec = 8 + i * 48;
        if (rec + 48 > cblc.len) return null;
        const start = u16At(cblc, rec + 40) orelse return null;
        const end = u16At(cblc, rec + 42) orelse return null;
        if (glyph < start or glyph > end) continue;
        const ppem = u8At(cblc, rec + 45) orelse return null;
        if (best) |b| {
            if (diff(ppem, size) >= diff(b.ppem, size)) continue;
        }
        best = .{ .rec = rec, .ppem = ppem };
    }
    const strike = best orelse return null;
    const array_off = u32At(cblc, strike.rec) orelse return null;
    const num_sub = u32At(cblc, strike.rec + 8) orelse return null;

    var s: usize = 0;
    while (s < num_sub) : (s += 1) {
        const entry = @as(usize, array_off) + s * 8;
        const first = u16At(cblc, entry) orelse return null;
        const last = u16At(cblc, entry + 2) orelse return null;
        if (glyph < first or glyph > last) continue;
        const sub = @as(usize, array_off) + (u32At(cblc, entry + 4) orelse return null);
        return cbdtFromSubtable(cbdt, cblc, sub, first, glyph, strike.ppem);
    }
    return null;
}

fn cbdtFromSubtable(cbdt: []const u8, cblc: []const u8, sub: usize, first: u16, glyph: u16, ppem: u16) ?Bitmap {
    const index_format = u16At(cblc, sub) orelse return null;
    const image_format = u16At(cblc, sub + 2) orelse return null;
    const base = u32At(cblc, sub + 4) orelse return null;
    const at = sub + 8;
    const index: usize = glyph - first;
    const offset: u32 = switch (index_format) {
        // 1: one u32 offset per glyph.
        1 => u32At(cblc, at + index * 4) orelse return null,
        // 2: every glyph in this subtable has the same image size.
        2 => blk: {
            const size_of_image = u32At(cblc, at) orelse return null;
            break :blk @intCast(index * size_of_image);
        },
        // 3: u16 offsets, so a strike stays inside 64 KB.
        3 => u16At(cblc, at + index * 2) orelse return null,
        else => return null,
    };
    const png_at = @as(usize, base) + offset;
    if (png_at >= cbdt.len) return null;
    const metrics: usize = switch (image_format) {
        17 => 5, // smallGlyphMetrics in front of the PNG
        18 => 8, // bigGlyphMetrics
        19 => 0, // no metrics at all
        else => return null,
    };
    if (png_at + metrics >= cbdt.len) return null;
    var w: usize = 0;
    var h: usize = 0;
    var bx: i32 = 0;
    var by: i32 = 0;
    var advance: f32 = 0;
    if (metrics > 0) {
        h = u8At(cbdt, png_at) orelse return null;
        w = u8At(cbdt, png_at + 1) orelse return null;
        bx = @as(i8, @bitCast(u8At(cbdt, png_at + 2) orelse return null));
        by = @as(i8, @bitCast(u8At(cbdt, png_at + 3) orelse return null));
        advance = @floatFromInt(u8At(cbdt, png_at + 4) orelse return null);
    }
    return .{ .png = cbdt[png_at + metrics ..], .w = w, .h = h, .bearing_x = bx, .bearing_y = by, .advance = advance, .ppem = ppem };
}

/// The PNG an sbix font carries for `glyph`, from the strike nearest `size`.
pub fn sbixBitmap(face_bytes: []const u8, glyph: u16, size: u16) ?Bitmap {
    const sbix = table(face_bytes, "sbix") orelse return null;
    const num_strikes = u32At(sbix, 4) orelse return null;
    const num_glyphs: u32 = blk: {
        const maxp = table(face_bytes, "maxp") orelse break :blk @as(u32, glyph) + 1;
        break :blk u16At(maxp, 4) orelse 0;
    };
    if (glyph >= num_glyphs) return null;
    var best: ?struct { off: usize, ppem: u16 } = null;
    var i: usize = 0;
    while (i < num_strikes) : (i += 1) {
        const off = u32At(sbix, 8 + i * 4) orelse return null;
        const ppem = u16At(sbix, off) orelse return null;
        if (best) |b| {
            if (diff(ppem, size) >= diff(b.ppem, size)) continue;
        }
        best = .{ .off = off, .ppem = ppem };
    }
    const strike = best orelse return null;
    const glyph_at = strike.off + 4 + @as(usize, glyph) * 4;
    const start = u32At(sbix, glyph_at) orelse return null;
    const end = u32At(sbix, glyph_at + 4) orelse return null;
    // A record is 8 bytes of origin and tag before its payload, so an `end` inside that header is truncated, not a PNG.
    if (@as(u64, end) < @as(u64, start) + 8) return null;
    const blob = strike.off + start;
    if (blob + 8 > sbix.len) return null;
    const ox = i16At(sbix, blob) orelse return null;
    const oy = i16At(sbix, blob + 2) orelse return null;
    // A masked ("dupe") or outline ("flip") record has no image of its own.
    if (!std.mem.eql(u8, sbix[blob + 4 ..][0..4], "png ")) return null;
    return .{
        .png = sbix[blob + 8 .. @min(sbix.len, strike.off + end)],
        .w = 0,
        .h = 0,
        .bearing_x = ox,
        .bearing_y = oy,
        .advance = 0,
        .ppem = strike.ppem,
    };
}

// Decode a PNG into RGBA8 with stb_image; the buffer belongs to `alloc`.
fn decodePng(png: []const u8, alloc: std.mem.Allocator) ?struct { pixels: []u8, w: usize, h: usize } {
    var w: c_int = 0;
    var h: c_int = 0;
    var channels: c_int = 0;
    const px = stbi.stbi_load_from_memory(png.ptr, @intCast(png.len), &w, &h, &channels, 4) orelse return null;
    defer stbi.stbi_image_free(px);
    if (w <= 0 or h <= 0) return null;
    const n = @as(usize, @intCast(w)) * @as(usize, @intCast(h)) * 4;
    const out = alloc.alloc(u8, n) catch return null;
    @memcpy(out, px[0..n]);
    return .{ .pixels = out, .w = @intCast(w), .h = @intCast(h) };
}

// ---- the cache: one RGBA image per (face, codepoint, size) ----

const Key = struct { face: usize, cp: u21, size: u16 };

/// What a miss is stored as: zero width, which `cached` answers null for, so a caller's null-means-mask path is unchanged.
const miss = Rgba{ .pixels = &.{}, .w = 0, .h = 0, .xoff = 0, .yoff = 0, .advance = 0 };

var cache: std.AutoHashMapUnmanaged(Key, Rgba) = .empty;
var cache_alloc: ?std.mem.Allocator = null;
var arena: ?std.heap.ArenaAllocator = null;

// "Does this face carry colour at all", memoised by its bytes pointer: `cached` runs per codepoint per frame.
const FaceMemo = struct { at: usize = 0, yes: bool = false };
var face_memo: [4]FaceMemo = [_]FaceMemo{.{}} ** 4;
var face_memo_next: usize = 0;

fn hasColour(face: *const glyphs.Font) bool {
    const at = @intFromPtr(face.bytes.ptr);
    // An empty slot holds 0, which no loaded face's bytes ever are, so a bare compare is the whole test.
    for (face_memo) |m| {
        if (m.at == at) return m.yes;
    }
    const yes = hasColourTable(face.bytes);
    face_memo[face_memo_next] = .{ .at = at, .yes = yes };
    face_memo_next = (face_memo_next + 1) % face_memo.len;
    return yes;
}

/// Point the cache at the app's allocator, the way the glyph cache is pointed at it.
pub fn initCache(alloc: std.mem.Allocator) void {
    clearCache();
    if (arena) |*a| a.deinit();
    cache_alloc = alloc;
    arena = .init(alloc);
}

pub fn deinitCache() void {
    if (arena) |*a| a.deinit();
    arena = null;
    if (cache_alloc) |a| cache.deinit(a);
    cache = .empty;
    cache_alloc = null;
    face_memo = [_]FaceMemo{.{}} ** 4;
    face_memo_next = 0;
}

pub fn clearCache() void {
    if (cache_alloc) |a| cache.deinit(a);
    cache = .empty;
    // Keep the arena's pages: a font switch rasterises the same emoji again immediately.
    if (arena) |*a| _ = a.reset(.retain_capacity);
    face_memo = [_]FaceMemo{.{}} ** 4;
    face_memo_next = 0;
}

/// The colour image for `cp` in `face`, or null when that face has none (a plain glyph, or no colour table at all).
pub fn cached(face: *const glyphs.Font, cp: u21, size: u16) ?*const Rgba {
    if (cache_alloc == null) initCache(face.alloc);
    const key = Key{ .face = @intFromPtr(face.bytes.ptr), .cp = cp, .size = size };
    if (cache.getPtr(key)) |g| return if (g.w == 0) null else g;
    if (!hasColour(face)) return null;
    // A miss is remembered too: an emoji this face cannot draw would otherwise be decoded again on every frame it appears in.
    const image = blk: {
        // A codepoint the face cannot name is not a colour glyph it can draw.
        const glyph = face.glyphIndex(cp);
        if (glyph == 0) break :blk miss;
        break :blk rasterize(face, glyph, size) orelse miss;
    };
    cache.put(cache_alloc.?, key, image) catch return null;
    const stored = cache.getPtr(key) orelse return null;
    return if (stored.w == 0) null else stored;
}

/// Turn one glyph of one face into RGBA: layers for a COLR font, a decoded PNG for CBDT or sbix.
pub fn rasterize(face: *const glyphs.Font, glyph: u16, size: u16) ?Rgba {
    if (colrOf(face.bytes)) |colr| {
        if (composeLayers(face, colr, glyph, size)) |image| return image;
    }
    if (cbdtBitmap(face.bytes, glyph, size)) |bitmap| return fromBitmap(face, glyph, bitmap, size);
    if (sbixBitmap(face.bytes, glyph, size)) |bitmap| return fromBitmap(face, glyph, bitmap, size);
    return null;
}

// A PNG strike is drawn at its own ppem; the quad is scaled to the size asked for, so the offset and advance scale too.
fn fromBitmap(face: *const glyphs.Font, glyph: u16, bitmap: Bitmap, size: u16) ?Rgba {
    // The GLOBAL arena, never a copy of it: an arena owns its buffer list, so chunks a copy allocates are orphaned on free.
    const a = if (arena) |*ar| ar.allocator() else return null;
    const decoded = decodePng(bitmap.png, a) orelse return null;
    const k: f32 = if (bitmap.ppem == 0) 1.0 else @as(f32, @floatFromInt(size)) / @as(f32, @floatFromInt(bitmap.ppem));
    const advance = if (bitmap.advance > 0) bitmap.advance * k else face.glyphAdvance(glyph, size);
    return .{
        .pixels = decoded.pixels,
        .w = decoded.w,
        .h = decoded.h,
        .xoff = @intFromFloat(@round(@as(f32, @floatFromInt(bitmap.bearing_x)) * k)),
        .yoff = -@as(i32, @intFromFloat(@round(@as(f32, @floatFromInt(bitmap.bearing_y)) * k))),
        .advance = advance,
    };
}

/// Composite a COLR glyph's layers into one RGBA image, each layer filled with its palette colour.
fn composeLayers(face: *const glyphs.Font, colr: Colr, glyph: u16, size: u16) ?Rgba {
    const records = colr.layersOf(glyph) orelse return null;
    const cpal = table(face.bytes, "CPAL") orelse return null;
    // Same rule as `fromBitmap`: the global arena, or the chunk holding the pixels is orphaned when the cache is freed.
    const arena_alloc = if (arena) |*ar| ar.allocator() else return null;

    const max_layers = 64;
    var masks: [max_layers]struct { mask: glyphs.Mask, color: [4]u8 } = undefined;
    var n: usize = 0;
    defer for (masks[0..n]) |*m| glyphs.freeMask(&m.mask);

    var min_x: f32 = 0;
    var min_y: f32 = 0;
    var max_x: f32 = 0;
    var max_y: f32 = 0;
    var first = true;
    const count = records.len / 4;
    for (0..@min(count, max_layers)) |i| {
        const layer = layerAt(records, i) orelse continue;
        const mask = face.glyphBitmapById(layer.glyph, size) orelse continue;
        const color = paletteColor(cpal, layer.palette) orelse continue;
        if (first) {
            min_x = mask.xoff;
            min_y = mask.yoff;
            max_x = mask.xoff + @as(f32, @floatFromInt(mask.w));
            max_y = mask.yoff + @as(f32, @floatFromInt(mask.h));
            first = false;
        } else {
            min_x = @min(min_x, mask.xoff);
            min_y = @min(min_y, mask.yoff);
            max_x = @max(max_x, mask.xoff + @as(f32, @floatFromInt(mask.w)));
            max_y = @max(max_y, mask.yoff + @as(f32, @floatFromInt(mask.h)));
        }
        masks[n] = .{ .mask = mask, .color = color };
        n += 1;
    }
    if (first or n == 0) return null;

    const w: usize = @intFromFloat(@ceil(max_x - min_x));
    const h: usize = @intFromFloat(@ceil(max_y - min_y));
    if (w == 0 or h == 0) return null;

    // Scratch from the cache's allocator, not the arena: an arena's free is a no-op, so 16 bytes per pixel would stay for good.
    const scratch = cache_alloc orelse arena_alloc;
    const acc = scratch.alloc(f32, w * h * 4) catch return null;
    defer scratch.free(acc);
    @memset(acc, 0);
    for (masks[0..n]) |m| {
        const gx: i64 = @intFromFloat(@round(m.mask.xoff - min_x));
        const gy: i64 = @intFromFloat(@round(m.mask.yoff - min_y));
        const alpha = @as(f32, @floatFromInt(m.color[3])) / 255.0;
        for (0..m.mask.h) |row| {
            for (0..m.mask.w) |col| {
                const coverage = @as(f32, @floatFromInt(m.mask.data[row * m.mask.w + col])) / 255.0;
                const src_a = coverage * alpha;
                if (src_a <= 0) continue;
                const x = gx + @as(i64, @intCast(col));
                const y = gy + @as(i64, @intCast(row));
                if (x < 0 or y < 0 or x >= @as(i64, @intCast(w)) or y >= @as(i64, @intCast(h))) continue;
                const at = (@as(usize, @intCast(y)) * w + @as(usize, @intCast(x))) * 4;
                acc[at + 0] = @as(f32, @floatFromInt(m.color[0])) / 255.0 * src_a + acc[at + 0] * (1 - src_a);
                acc[at + 1] = @as(f32, @floatFromInt(m.color[1])) / 255.0 * src_a + acc[at + 1] * (1 - src_a);
                acc[at + 2] = @as(f32, @floatFromInt(m.color[2])) / 255.0 * src_a + acc[at + 2] * (1 - src_a);
                acc[at + 3] = src_a + acc[at + 3] * (1 - src_a);
            }
        }
    }

    const pixels = arena_alloc.alloc(u8, w * h * 4) catch return null;
    for (0..w * h) |i| {
        const alpha = acc[i * 4 + 3];
        // Straight alpha out: a blitter multiplies by alpha itself, and a premultiplied pixel would go dark.
        const scale: f32 = if (alpha > 0.0001) 1.0 / alpha else 0;
        pixels[i * 4 + 0] = @intFromFloat(@min(255, @round(acc[i * 4 + 0] * scale * 255)));
        pixels[i * 4 + 1] = @intFromFloat(@min(255, @round(acc[i * 4 + 1] * scale * 255)));
        pixels[i * 4 + 2] = @intFromFloat(@min(255, @round(acc[i * 4 + 2] * scale * 255)));
        pixels[i * 4 + 3] = @intFromFloat(@min(255, @round(alpha * 255)));
    }
    return .{ .pixels = pixels, .w = w, .h = h, .xoff = @intFromFloat(@round(min_x)), .yoff = @intFromFloat(@round(min_y)), .advance = face.glyphAdvance(glyph, size) };
}

pub fn cachedCount() usize {
    return cache.count();
}

const testing = std.testing;

// A hand-built sfnt directory over the given tables: enough to prove `table()` walks one, with no font file in the repo.
fn buildSfnt(comptime n: usize, tags: [n][4]u8, bodies: [n][]const u8, buf: []u8) []const u8 {
    var at: usize = 12 + 16 * n;
    @memcpy(buf[0..4], &[_]u8{ 0, 1, 0, 0 });
    buf[4] = 0;
    buf[5] = n;
    for (0..n) |i| {
        const rec = 12 + i * 16;
        @memcpy(buf[rec..][0..4], &tags[i]);
        buf[rec + 8] = @intCast((at >> 24) & 0xff);
        buf[rec + 9] = @intCast((at >> 16) & 0xff);
        buf[rec + 10] = @intCast((at >> 8) & 0xff);
        buf[rec + 11] = @intCast(at & 0xff);
        const len = bodies[i].len;
        buf[rec + 12] = @intCast((len >> 24) & 0xff);
        buf[rec + 13] = @intCast((len >> 16) & 0xff);
        buf[rec + 14] = @intCast((len >> 8) & 0xff);
        buf[rec + 15] = @intCast(len & 0xff);
        @memcpy(buf[at..][0..len], bodies[i]);
        at += len;
    }
    return buf[0..at];
}

test "a table is found through the sfnt directory, and a missing one is null" {
    var buf: [512]u8 = undefined;
    const cpal = [_]u8{ 0, 0, 0, 1, 0, 1, 0, 1, 0, 0, 0, 14, 0, 0, 0, 0, 0xff, 0xff };
    const sfnt = buildSfnt(1, [_][4]u8{"CPAL".*}, [_][]const u8{&cpal}, &buf);
    const found = table(sfnt, "CPAL") orelse return error.TableMissing;
    try testing.expectEqualSlices(u8, &cpal, found);
    try testing.expect(table(sfnt, "COLR") == null);
    try testing.expect(!hasColourTable(sfnt));
}

test "a CPAL palette answers its colours in RGBA, and an index past it answers nothing" {
    var cpal: [14 + 8]u8 = undefined;
    @memset(&cpal, 0);
    cpal[3] = 2; // numPaletteEntries (u16 at 2)
    cpal[5] = 1; // numPalettes (u16 at 4)
    cpal[7] = 2; // numColorRecords (u16 at 6)
    cpal[11] = 14; // colorRecordsArrayOffset (u32 at 8)
    // Two BGRA records: opaque blue then half-transparent red, the first palette's colours right after the header.
    cpal[14..][0..4].* = .{ 0xff, 0x00, 0x00, 0xff };
    cpal[18..][0..4].* = .{ 0x00, 0x00, 0xff, 0x80 };
    const first = paletteColor(&cpal, 0) orelse return error.NoColour;
    try testing.expectEqual([4]u8{ 0x00, 0x00, 0xff, 0xff }, first);
    const second = paletteColor(&cpal, 1) orelse return error.NoColour;
    try testing.expectEqual([4]u8{ 0xff, 0x00, 0x00, 0x80 }, second);
    try testing.expect(paletteColor(&cpal, 2) == null);
}

test "a COLR base glyph answers its layers, and a plain glyph answers none" {
    var colr: [14 + 12 + 12]u8 = undefined;
    @memset(&colr, 0);
    colr[1] = 2; // numBaseGlyphRecords
    colr[3] = 14; // baseGlyphRecordsOffset
    colr[7] = 26; // layerRecordsOffset
    colr[9] = 3; // numLayerRecords
    // Base record 0: glyph 10, first layer 0, two layers. Base record 1: glyph 20, layer 2, one layer.
    colr[14..][0..6].* = .{ 0, 10, 0, 0, 0, 2 };
    colr[20..][0..6].* = .{ 0, 20, 0, 2, 0, 1 };
    colr[26..][0..4].* = .{ 0, 11, 0, 1 };
    colr[30..][0..4].* = .{ 0, 12, 0, 2 };
    colr[34..][0..4].* = .{ 0, 13, 0, 3 };

    const parsed = Colr{ .data = &colr, .base_at = 14, .layer_at = 26, .num_base = 2 };
    const layers = parsed.layersOf(10) orelse return error.NoLayers;
    try testing.expectEqual(@as(usize, 2), layers.len / 4);
    const first = layerAt(layers, 0) orelse return error.NoLayer;
    try testing.expectEqual(@as(u16, 11), first.glyph);
    try testing.expectEqual(@as(u16, 1), first.palette);
    const second = layerAt(layers, 1) orelse return error.NoLayer;
    try testing.expectEqual(@as(u16, 12), second.glyph);
    try testing.expectEqual(@as(u16, 2), second.palette);
    const one = parsed.layersOf(20) orelse return error.NoLayers;
    try testing.expectEqual(@as(usize, 1), one.len / 4);
    // A glyph that is not a colour base answers nothing, which is how a plain outline stays plain.
    try testing.expect(parsed.layersOf(30) == null);
}

test "a CBLC strike finds the bitmap of the glyph nearest the size, and a glyph outside it finds none" {
    // One strike (ppem 32) covering glyphs 7..9, one index sub-table of format 1, image format 17 (metrics + PNG).
    const rec_at = 8;
    const array_at = rec_at + 48;
    const sub_at = array_at + 8;
    const offsets_at = sub_at + 8;
    const cblc_len = offsets_at + 3 * 4;
    var cblc: [cblc_len]u8 = undefined;
    @memset(&cblc, 0);
    cblc[7] = 1; // numSizes
    putU32(&cblc, rec_at + 0, array_at); // indexSubTableArrayOffset
    putU32(&cblc, rec_at + 8, 1); // numberOfIndexSubTables
    cblc[rec_at + 40] = 0;
    cblc[rec_at + 41] = 7; // startGlyphIndex
    cblc[rec_at + 42] = 0;
    cblc[rec_at + 43] = 9; // endGlyphIndex
    cblc[rec_at + 45] = 32; // ppemY
    // The array entry: glyphs 7..9, sub-table 8 bytes after the entry.
    cblc[array_at + 1] = 7;
    cblc[array_at + 3] = 9;
    putU32(&cblc, array_at + 4, 8);
    cblc[sub_at + 1] = 1; // indexFormat 1
    cblc[sub_at + 3] = 17; // imageFormat 17
    putU32(&cblc, sub_at + 4, 0); // imageDataOffset
    // Glyph 7 starts at 0 and glyph 8 at 9, so glyph 9 would start at 18 and be out of this blob.
    putU32(&cblc, offsets_at + 0, 0);
    putU32(&cblc, offsets_at + 4, 9);

    var cbdt: [9]u8 = undefined;
    cbdt[0] = 20; // height
    cbdt[1] = 20; // width
    cbdt[2] = 0; // bearingX
    cbdt[3] = 18; // bearingY
    cbdt[4] = 24; // advance
    cbdt[5..][0..4].* = .{ 0x89, 'P', 'N', 'G' };

    var buf: [1024]u8 = undefined;
    const sfnt = buildSfnt(2, [_][4]u8{ "CBLC".*, "CBDT".* }, [_][]const u8{ &cblc, &cbdt }, &buf);
    const bitmap = cbdtBitmap(sfnt, 7, 32) orelse return error.NoBitmap;
    try testing.expectEqual(@as(u16, 32), bitmap.ppem);
    try testing.expectEqual(@as(usize, 20), bitmap.w);
    try testing.expectEqual(@as(usize, 20), bitmap.h);
    try testing.expectEqual(@as(i32, 18), bitmap.bearing_y);
    try testing.expectEqual(@as(f32, 24), bitmap.advance);
    try testing.expectEqualStrings(&[_]u8{ 0x89, 'P', 'N', 'G' }, bitmap.png);
    // A glyph the strike does not cover answers nothing at all.
    try testing.expect(cbdtBitmap(sfnt, 40, 32) == null);
}

fn putU32(b: []u8, at: usize, v: u32) void {
    b[at] = @intCast((v >> 24) & 0xff);
    b[at + 1] = @intCast((v >> 16) & 0xff);
    b[at + 2] = @intCast((v >> 8) & 0xff);
    b[at + 3] = @intCast(v & 0xff);
}

test "an sbix strike reads a PNG record's origin, and refuses a record with no image" {
    // One strike at 12: ppem 32, resolution 72, then glyph data offsets for glyphs 0..1 and the end.
    const strike_at = 12;
    const offs_at = strike_at + 4;
    const glyph1_at = 16; // relative to the strike
    var sbix: [strike_at + 32]u8 = undefined;
    @memset(&sbix, 0);
    sbix[7] = 1; // numStrikes
    putU32(&sbix, 8, strike_at);
    sbix[strike_at + 1] = 32; // ppem
    sbix[strike_at + 3] = 72; // resolution
    putU32(&sbix, offs_at + 0, 0); // glyph 0 starts at 0 (no payload)
    putU32(&sbix, offs_at + 4, glyph1_at);
    putU32(&sbix, offs_at + 8, glyph1_at + 12); // end, past the four payload bytes
    const blob = strike_at + glyph1_at;
    sbix[blob + 0] = 0xff; // originX = -1
    sbix[blob + 1] = 0xff;
    sbix[blob + 2] = 0xff; // originY = -2
    sbix[blob + 3] = 0xfe;
    sbix[blob + 4 ..][0..4].* = "png ".*;
    sbix[blob + 8 ..][0..4].* = .{ 0x89, 'P', 'N', 'G' };
    var maxp: [6]u8 = .{ 0, 1, 0, 0, 0, 2 };

    var buf: [1024]u8 = undefined;
    const sfnt = buildSfnt(2, [_][4]u8{ "sbix".*, "maxp".* }, [_][]const u8{ &sbix, &maxp }, &buf);
    const bitmap = sbixBitmap(sfnt, 1, 32) orelse return error.NoBitmap;
    try testing.expectEqual(@as(i32, -1), bitmap.bearing_x);
    try testing.expectEqual(@as(i32, -2), bitmap.bearing_y);
    try testing.expectEqual(@as(u16, 32), bitmap.ppem);
    // A glyph with no PNG payload answers nothing, and a glyph past maxp answers nothing either.
    try testing.expect(sbixBitmap(sfnt, 0, 32) == null);
    try testing.expect(sbixBitmap(sfnt, 5, 32) == null);
}

test "an sbix record that ends inside its own header is refused instead of sliced backwards" {
    // Glyph 1's record says it ends 4 bytes past its start, but the origin and tag are 8: [blob + 8 .. blob + 4] is a panic.
    const strike_at = 12;
    const offs_at = strike_at + 4;
    const glyph1_at = 16;
    var sbix: [strike_at + 32]u8 = undefined;
    @memset(&sbix, 0);
    sbix[7] = 1; // numStrikes
    putU32(&sbix, 8, strike_at);
    sbix[strike_at + 1] = 32; // ppem
    sbix[strike_at + 3] = 72; // resolution
    putU32(&sbix, offs_at + 0, 0); // glyph 0 starts at 0 (no payload)
    putU32(&sbix, offs_at + 4, glyph1_at);
    putU32(&sbix, offs_at + 8, glyph1_at + 4); // end, INSIDE the header
    var maxp: [6]u8 = .{ 0, 1, 0, 0, 0, 2 };

    var buf: [1024]u8 = undefined;
    const sfnt = buildSfnt(2, [_][4]u8{ "sbix".*, "maxp".* }, [_][]const u8{ &sbix, &maxp }, &buf);
    try testing.expect(sbixBitmap(sfnt, 1, 32) == null);
}
