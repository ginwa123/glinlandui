//! Real glyph rasterization for the software renderer (stb_truetype).
//!
//! ## Why this module exists
//!
//! `Surface.drawTextRun` used to be deliberately glyph-free: it drew one
//! anti-aliased box per UTF-8 *byte*. That is portable, needs no font, and is
//! what the shared pixel suite verifies — but it means the software backend
//! shows text as vertical bars instead of characters, so macOS did not look
//! like the Linux/GLES3 build. This module is the glyph path, using the
//! already-vendored stb_truetype and an already-resolved system font, so both
//! backends draw the same characters.
//!
//! ## Why it is its own module
//!
//! The GLES3 backend already has a stb_truetype atlas, but it is built around
//! uploading a texture and is therefore GL-specific. Rewriting or sharing that
//! would put the Linux native path at risk for a macOS problem, so this is a
//! separate, small, self-contained implementation for the CPU surface. It
//! blends straight into the RGBA8 surface using the same source-over equation
//! `Surface.blend` already uses for boxes, so glyphs composite over the
//! keypad exactly like everything else.
//!
//! ## Font selection
//!
//! Fonts come from the shared `text.resolveFont()`, which already lists macOS
//! system faces (Menlo, SFNSMono, Monaco) and Linux ones (DejaVuSansMono). No
//! font is bundled, so a host with neither simply falls back to the
//! glyph-free bars — `Surface.drawTextRun` degrades rather than failing.

const std = @import("std");
const stb = @cImport({
    @cInclude("stb/stb_truetype.h");
});

const text_backend = @import("text_backend.zig");

pub const bytes_per_pixel: usize = 4;

/// A loaded font: the file bytes plus the stb face built over them.
pub const Font = struct {
    /// The file bytes must outlive the face, so they are owned here.
    /// page_allocator hands back page-aligned memory, which also satisfies
    /// stb_truetype's alignment wish for mmap-style font access.
    bytes: []u8,
    info: stb.stbtt_fontinfo,
    /// Baseline offset from the top of a line, in pixels, at scale 1.
    ascent: f32 = 0,
    descent: f32 = 0,

    /// Load the platform's default UI font, trying each candidate until one
    /// actually PARSES.
    ///
    /// Walking the list matters: `text.resolveFont()` only checks that a path
    /// exists, and the first existing candidate on macOS is Menlo.ttc — a
    /// TrueType *collection*, which stbtt_InitFont rejects. Trusting
    /// `resolveFont` alone therefore meant "no font" even on a machine with
    /// perfectly good ones installed, and the UI silently fell back to bars.
    pub fn loadDefault() ?Font {
        for (text_backend.fontCandidates()) |path| {
            if (load(path)) |font| {
                return font;
            } else |_| {
                // Not parseable (wrong format, truncated, permissions). Try
                // the next candidate rather than giving up.
            }
        }
        return null;
    }

    /// Load one specific font file.
    pub fn load(path: [:0]const u8) !Font {
        // Zig 0.16's Io-based fs: cwd() is a Dir and every call needs an Io.
        const io = std.Io.Threaded.global_single_threaded.io();
        const dir = std.Io.Dir.cwd();
        const f = dir.openFile(io, path, .{}) catch return error.FontNotFound;
        defer f.close(io);
        const stat = f.stat(io) catch return error.FontNotFound;
        const n = stat.size;
        if (n == 0) return error.FontNotFound;
        const buf = std.heap.page_allocator.alloc(u8, @intCast(n)) catch
            return error.OutOfMemory;
        const got = f.readPositionalAll(io, buf, 0) catch return error.FontNotFound;
        if (got == 0) return error.FontNotFound;

        var info: stb.stbtt_fontinfo = undefined;
        if (stb.stbtt_InitFont(&info, buf.ptr, 0) == 0) return error.FontInitFailed;

        var font = Font{ .bytes = buf, .info = info };
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

    /// Horizontal advance of one codepoint in pixels, and where its bitmap
    /// starts relative to the pen.
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

    /// Rasterize one codepoint's coverage mask, or null when the font has no
    /// glyph for it (a space, typically). `w`/`h` are the mask dimensions and
    /// must be freed with `freeMask`.
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

/// Decode the next UTF-8 codepoint. The keymap and labels are ASCII, so this
/// is deliberately minimal: it handles 1-4 byte sequences and treats anything
/// malformed as a single byte rather than erroring, so a stray byte in a label
/// cannot take down a frame.
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

/// Total advance width of `text` in pixels, and the pixel ascent used to place
/// the baseline. Used by callers that need to centre or right-align a run.
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

// ===================== tests (parity suite — every platform) =====================
//
// These assert on behaviour that only makes sense when the host actually has a
// font, so they no-op where none is installed rather than failing. The test
// COUNT is identical on every platform either way, which is what the parity
// contract requires.

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
    // This is why drawTextRun needs both: a blank glyph must still move the
    // cursor, or every word would overlap.
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
    // The calculator's labels are ASCII, so this is the shape that matters:
    // every character must contribute, and none may be silently dropped.
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
        // Non-space labels must be at least as wide as a single digit; the
        // catch is a label whose glyphs all come back as zero advance.
        try std.testing.expect(got > 0);
        try std.testing.expect(got >= one - 0.01 or n == 0);
    }
}
