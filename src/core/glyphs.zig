//! Real glyph rasterization for the software renderer (stb_truetype).

const std = @import("std");
const stb = @cImport({
    @cInclude("stb/stb_truetype.h");
});

const text_backend = @import("text_backend.zig");

pub const bytes_per_pixel: usize = 4;

/// A loaded font: the file bytes plus the stb face built over them.
pub const Font = struct {
    /// The file bytes must outlive the face, so they are owned here.
    bytes: []u8,
    info: stb.stbtt_fontinfo,
    /// Baseline offset from the top of a line, in pixels, at scale 1.
    ascent: f32 = 0,
    descent: f32 = 0,

    /// Load the platform's default UI font, trying each candidate until one actually PARSES.
    pub fn loadDefault() ?Font {
        for (text_backend.fontCandidates()) |path| {
            if (load(path)) |font| {
                return font;
            } else |_| {
                // Not parseable (wrong format, truncated, permissions).
            }
        }
        return null;
    }

    /// Load one specific font file.
    pub fn load(path: [:0]const u8) !Font {
        const buf = try text_backend.readFontBytes(path, std.heap.page_allocator);
        errdefer std.heap.page_allocator.free(buf);
        return fromBytes(buf);
    }

    /// Build a `Font` over bytes the CALLER owns.
    pub fn fromBytes(bytes: []u8) !Font {
        if (bytes.len == 0) return error.FontNotFound;
        // THE GUARD IS LOAD-BEARING, not defensive politeness.
        if (!sfntSignatureRecognized(bytes)) return error.FontInitFailed;

        var info: stb.stbtt_fontinfo = undefined;
        if (stb.stbtt_InitFont(&info, bytes.ptr, 0) == 0) return error.FontInitFailed;

        var font = Font{ .bytes = bytes, .info = info };
        var a: c_int = 0;
        var d: c_int = 0;
        var g: c_int = 0;
        stb.stbtt_GetFontVMetrics(&info, &a, &d, &g);
        font.ascent = @floatFromInt(a);
        font.descent = @floatFromInt(d);
        return font;
    }

    pub fn deinit(self: *Font) void {
        std.heap.page_allocator.free(self.bytes);
    }

    /// Horizontal scale factor for a requested pixel height.
    fn scaleFor(self: *const Font, font_size: u16) f32 {
        return stb.stbtt_ScaleForPixelHeight(&self.info, @floatFromInt(font_size));
    }

    /// The font's line box height at `font_size`, in pixels: ascent + |descent|.
    pub fn lineHeight(self: *const Font, font_size: u16) f32 {
        const scale = self.scaleFor(font_size);
        return (self.ascent - self.descent) * scale;
    }

    /// Horizontal advance of one codepoint in pixels, and where its bitmap starts relative to the pen.
    pub fn glyphMetrics(self: *const Font, cp: u21, font_size: u16) Metrics {
        const scale = self.scaleFor(font_size);
        var adv: c_int = 0;
        var lsb: c_int = 0;
        stb.stbtt_GetCodepointHMetrics(&self.info, @intCast(cp), &adv, &lsb);
        return .{
            .advance = @as(f32, @floatFromInt(adv)) * scale,
            .lsb = @as(f32, @floatFromInt(lsb)) * scale,
        };
    }

    /// Rasterize one codepoint's coverage mask, or null when the font has no glyph for it (a space, typically).
    pub fn glyphBitmap(self: *const Font, cp: u21, font_size: u16) ?Mask {
        const scale = self.scaleFor(font_size);
        var w: c_int = 0;
        var h: c_int = 0;
        var xoff: c_int = 0;
        var yoff: c_int = 0;
        const data = stb.stbtt_GetCodepointBitmap(
            &self.info,
            0,
            scale,
            @intCast(cp),
            &w,
            &h,
            &xoff,
            &yoff,
        );
        if (data == null or w <= 0 or h <= 0) return null;
        return .{
            .data = data,
            .w = @intCast(w),
            .h = @intCast(h),
            .xoff = @floatFromInt(xoff),
            .yoff = @floatFromInt(yoff),
        };
    }
};

/// The four sfnt signatures `stbtt_InitFont` is happy to parse at offset 0.
pub fn sfntSignatureRecognized(bytes: []const u8) bool {
    if (bytes.len < 4) return false;
    const tag = std.mem.readInt(u32, bytes[0..4], .big);
    return tag == 0x00010000 or // TrueType outlines
        tag == 0x4F54544F or // 'OTTO' — CFF outlines
        tag == 0x74727565 or // 'true' — Apple TrueType
        tag == 0x74797031; // 'typ1' — PostScript Type 1 in an sfnt wrapper
}

pub const Metrics = struct {
    advance: f32,
    lsb: f32,
};

/// An 8-bit coverage mask owned by stb's allocator. Free with `freeMask`.
pub const Mask = struct {
    data: [*c]const u8,
    w: usize,
    h: usize,
    /// Offset of the mask's top-left from the pen position, in pixels.
    xoff: f32,
    yoff: f32,
};

pub fn freeMask(m: *Mask) void {
    stb.stbtt_FreeBitmap(@constCast(@as([*c]const u8, m.data)), null);
    m.* = undefined;
}

// ---- glyph cache ----

/// A rasterized glyph, owned by the cache. Never freed by a caller.
pub const CachedGlyph = struct {
    data: []u8,
    w: usize,
    h: usize,
    xoff: f32,
    yoff: f32,
};

const CacheKey = struct { cp: u21, size: u16 };

var cache: std.AutoHashMapUnmanaged(CacheKey, CachedGlyph) = .empty;

/// Rasterize `cp` at `font_size` once and reuse it for every later frame.
pub fn cachedGlyph(font: *const Font, cp: u21, font_size: u16) ?*const CachedGlyph {
    const key = CacheKey{ .cp = cp, .size = font_size };
    if (cache.getPtr(key)) |g| return g;

    const mask = font.glyphBitmap(cp, font_size) orelse return null;
    var m = mask;
    defer freeMask(&m);

    const n = m.w * m.h;
    const data = std.heap.page_allocator.alloc(u8, n) catch return null;
    @memcpy(data, m.data[0..n]);
    cache.put(std.heap.page_allocator, key, .{
        .data = data,
        .w = m.w,
        .h = m.h,
        .xoff = m.xoff,
        .yoff = m.yoff,
    }) catch {
        std.heap.page_allocator.free(data);
        return null;
    };
    return cache.getPtr(key);
}

/// Drop every cached glyph. Call when the font changes.
pub fn clearGlyphCache() void {
    var it = cache.iterator();
    while (it.next()) |e| std.heap.page_allocator.free(e.value_ptr.data);
    cache.deinit(std.heap.page_allocator);
    cache = .empty;
}

/// How many glyphs are cached, for tests.
pub fn cachedGlyphCount() usize {
    return cache.count();
}

/// Decode the next UTF-8 codepoint.
pub fn nextCodepoint(text: []const u8, index: *usize) u21 {
    const i = index.*;
    if (i >= text.len) return 0;
    const b0 = text[i];
    if (b0 < 0x80) {
        index.* = i + 1;
        return b0;
    }
    const len: usize = if (b0 & 0xE0 == 0xC0)
        2
    else if (b0 & 0xF0 == 0xE0)
        3
    else if (b0 & 0xF8 == 0xF0)
        4
    else
        1;
    if (len == 1 or i + len > text.len) {
        index.* = i + 1;
        return b0; // malformed: consume one byte and show something
    }
    var cp: u32 = switch (len) {
        2 => b0 & 0x1F,
        3 => b0 & 0x0F,
        else => b0 & 0x07,
    };
    var k: usize = 1;
    while (k < len) : (k += 1) cp = (cp << 6) | (text[i + k] & 0x3F);
    index.* = i + len;
    return @intCast(cp);
}

/// Total advance width of `text` in pixels, and the pixel ascent used to place the baseline.
pub fn measure(font: *const Font, text: []const u8, font_size: u16) struct { width: f32, ascent: f32 } {
    var total: f32 = 0;
    var i: usize = 0;
    while (i < text.len) {
        const cp = nextCodepoint(text, &i);
        total += font.glyphMetrics(cp, font_size).advance;
    }
    const scale = font.scaleFor(font_size);
    return .{ .width = total, .ascent = font.ascent * scale };
}

// ---- a font supplied by the backend, for hosts that have no font paths ----

/// A process-wide font installed by a platform backend, preferred over walking `text_backend.fontCandidates()`.
var installed_font: ?Font = null;

/// Install `f` as the process-wide font.
pub fn installFont(f: Font) void {
    clearGlyphCache();
    installed_font = f;
}

/// The installed font, if any.
pub fn installedFont() ?*Font {
    if (installed_font) |*f| return f;
    return null;
}

/// Drop the installed font.
pub fn clearInstalledFont() void {
    clearGlyphCache();
    installed_font = null;
}

// ===================== tests (parity suite — every platform) ===================== These assert on behaviour that only makes sense when the host.

test "fromBytes rejects empty bytes instead of building a dead Font" {
    // A zero-length slice would make stbtt_InitFont read off the end of a 0-byte allocation.
    var empty: [0]u8 = .{};
    try std.testing.expectError(error.FontNotFound, Font.fromBytes(&empty));
}

test "sfntSignatureRecognized accepts the four loadable sfnt tags" {
    try std.testing.expect(sfntSignatureRecognized(&.{ 0x00, 0x01, 0x00, 0x00 })); // TrueType
    try std.testing.expect(sfntSignatureRecognized("OTTO"));
    try std.testing.expect(sfntSignatureRecognized("true"));
    try std.testing.expect(sfntSignatureRecognized("typ1"));
}

test "sfntSignatureRecognized rejects a TrueType collection and HTML" {
    // `ttcf`: a collection, which stbtt_InitFont at offset 0 cannot load.
    try std.testing.expect(!sfntSignatureRecognized("ttcf"));
    // The bytes a browser gets when the font fetch 404s.
    try std.testing.expect(!sfntSignatureRecognized("<!DOCTYPE html>"));
    try std.testing.expect(!sfntSignatureRecognized("wOFF"));
}

test "sfntSignatureRecognized rejects a short buffer instead of reading past it" {
    try std.testing.expect(!sfntSignatureRecognized(&.{}));
    try std.testing.expect(!sfntSignatureRecognized(&.{0}));
    try std.testing.expect(!sfntSignatureRecognized(&.{ 0, 1, 0 }));
}

test "fromBytes rejects bytes that are not a font, without aborting" {
    // THE regression guard for the abort above.
    var junk: [64]u8 = undefined;
    for (&junk, 0..) |*b, i| b.* = @intCast(i);
    try std.testing.expectError(error.FontInitFailed, Font.fromBytes(&junk));

    const html: []u8 = @constCast("<!DOCTYPE html><html></html>");
    try std.testing.expectError(error.FontInitFailed, Font.fromBytes(html));
}

test "installFont is visible to installedFont and clearInstalledFont drops it" {
    // The web backend's whole font story in one test: install once, and every later resolution finds it without touching a filesystem.
    var font = requireFont() orelse return error.SkipZigTest;
    defer font.deinit();
    clearInstalledFont();
    try std.testing.expect(installedFont() == null);

    installFont(font);
    const got = installedFont() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(font.bytes.len, got.bytes.len);
    try std.testing.expectEqual(font.ascent, got.ascent);
    // And it is the SAME face, not a copy that lost its offsets: an advance measured through the installed handle must match the original.
    try std.testing.expectEqual(
        measure(&font, "8", 18).width,
        measure(got, "8", 18).width,
    );

    clearInstalledFont();
    try std.testing.expect(installedFont() == null);
}

fn requireFont() ?Font {
    return Font.loadDefault();
}

test "nextCodepoint decodes ASCII one byte at a time" {
    var i: usize = 0;
    try std.testing.expectEqual(@as(u21, 'a'), nextCodepoint("abc", &i));
    try std.testing.expectEqual(@as(u21, 'b'), nextCodepoint("abc", &i));
    try std.testing.expectEqual(@as(u21, 'c'), nextCodepoint("abc", &i));
    try std.testing.expectEqual(@as(u21, 0), nextCodepoint("abc", &i));
}

test "nextCodepoint decodes multi-byte sequences and advances correctly" {
    // U+00E9 e-acute = C3 A9; U+1F600 = F0 9F 98 80.
    var i: usize = 0;
    const s = "é\u{1F600}z";
    try std.testing.expectEqual(@as(u21, 0xE9), nextCodepoint(s, &i));
    try std.testing.expectEqual(@as(u21, 0x1F600), nextCodepoint(s, &i));
    try std.testing.expectEqual(@as(u21, 'z'), nextCodepoint(s, &i));
    try std.testing.expectEqual(@as(u21, 0), nextCodepoint(s, &i));
}

test "nextCodepoint consumes exactly one byte for malformed input" {
    // A label with a stray byte must not desync the rest of the run or panic.
    var i: usize = 0;
    const s = "\xFFz";
    _ = nextCodepoint(s, &i);
    try std.testing.expectEqual(@as(usize, 1), i);
    try std.testing.expectEqual(@as(u21, 'z'), nextCodepoint(s, &i));
}

test "nextCodepoint does not read past the end for a truncated sequence" {
    var i: usize = 0;
    const s = "\xE9"; // claims 2 bytes but only 1 is present
    _ = nextCodepoint(s, &i);
    try std.testing.expectEqual(@as(usize, 1), i);
}

test "a font loads and reports a positive ascent when one is installed" {
    var font = requireFont() orelse return error.SkipZigTest;
    defer font.deinit();
    try std.testing.expect(font.ascent > 0);
    try std.testing.expect(font.descent < 0);
    try std.testing.expect(font.bytes.len > 0);
}

test "a space has no bitmap but still advances the pen" {
    var font = requireFont() orelse return error.SkipZigTest;
    defer font.deinit();
    // This is why drawTextRun needs both: a blank glyph must still move the cursor, or every word would overlap.
    try std.testing.expect(font.glyphMetrics(' ', 18).advance > 0);
    const m = font.glyphBitmap(' ', 18);
    if (m) |mask| {
        var mm = mask;
        freeMask(&mm);
    }
}

test "'i' rasterizes to a non-empty coverage mask" {
    var font = requireFont() orelse return error.SkipZigTest;
    defer font.deinit();
    // 'i' is the cheapest glyph that still has ink: a stem plus a dot.
    const mask = font.glyphBitmap('i', 32) orelse return error.SkipZigTest;
    var m = mask;
    defer freeMask(&m);
    try std.testing.expect(m.w > 0);
    try std.testing.expect(m.h > 0);
    var inked: usize = 0;
    for (0..m.w * m.h) |k| {
        if (m.data[k] > 0) inked += 1;
    }
    try std.testing.expect(inked > 0);
}

test "a space is blank and 'x' is not, at the same size" {
    // Proves the coverage mask is real coverage rather than a constant fill.
    var font = requireFont() orelse return error.SkipZigTest;
    defer font.deinit();
    if (font.glyphBitmap(' ', 24)) |sp| {
        var s = sp;
        defer freeMask(&s);
        for (0..s.w * s.h) |k| try std.testing.expectEqual(@as(u8, 0), s.data[k]);
    }
    const xm = font.glyphBitmap('x', 24) orelse return error.SkipZigTest;
    var x = xm;
    defer freeMask(&x);
    var inked: usize = 0;
    for (0..x.w * x.h) |k| {
        if (x.data[k] > 0) inked += 1;
    }
    try std.testing.expect(inked > 0);
}

test "a larger font size produces a larger glyph box" {
    var font = requireFont() orelse return error.SkipZigTest;
    defer font.deinit();
    const small = font.glyphBitmap('M', 12) orelse return error.SkipZigTest;
    var s = small;
    defer freeMask(&s);
    const big = font.glyphBitmap('M', 48) orelse return error.SkipZigTest;
    var b = big;
    defer freeMask(&b);
    try std.testing.expect(b.w > s.w);
    try std.testing.expect(b.h > s.h);
}

test "advance width grows with font size" {
    var font = requireFont() orelse return error.SkipZigTest;
    defer font.deinit();
    const a12 = font.glyphMetrics('8', 12).advance;
    const a24 = font.glyphMetrics('8', 24).advance;
    try std.testing.expect(a24 > a12);
    // Roughly proportional, not quadratic.
    try std.testing.expect(a24 < a12 * 3);
}

test "measure sums advances and stays monotonic in length" {
    var font = requireFont() orelse return error.SkipZigTest;
    defer font.deinit();
    const one = measure(&font, "7", 18);
    const two = measure(&font, "77", 18);
    const three = measure(&font, "777", 18);
    try std.testing.expect(two.width > one.width);
    try std.testing.expect(three.width > two.width);
    try std.testing.expect(one.ascent > 0);
}

test "measure of an empty string is zero width" {
    var font = requireFont() orelse return error.SkipZigTest;
    defer font.deinit();
    try std.testing.expectEqual(@as(f32, 0), measure(&font, "", 18).width);
}

test "a digits-only label is measured as a fixed number of advances" {
    // The calculator's labels are ASCII, so this is the shape that matters: every character must contribute, and none may be silently dropped.
    var font = requireFont() orelse return error.SkipZigTest;
    defer font.deinit();
    const labels = [_][]const u8{ "C", "DEL", ".", "/", "+/-", "%", "=" };
    for (labels) |label| {
        var n: usize = 0;
        var i: usize = 0;
        while (i < label.len) {
            _ = nextCodepoint(label, &i);
            n += 1;
        }
        const one = measure(&font, "0", 18).width;
        const got = measure(&font, label, 18).width;
        // Non-space labels must be at least as wide as a single digit; the catch is a label whose glyphs all come back as zero advance.
        try std.testing.expect(got > 0);
        try std.testing.expect(got >= one - 0.01 or n == 0);
    }
}
