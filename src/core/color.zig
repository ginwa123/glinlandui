//! `Color` — one color value, four ways to write it.
const std = @import("std");

/// A color, stored as 0xAARRGGBB.
pub const Color = struct {
    /// Packed 0xAARRGGBB.
    value: u32,

    // ---- construction -----------------------------------------------------

    /// From a packed 0xAARRGGBB literal.
    pub fn argb(v: u32) Color {
        return .{ .value = v };
    }

    /// From three 0-255 channel ints. Opaque.
    pub fn rgb(red: u8, green: u8, blue: u8) Color {
        return rgba(red, green, blue, 255);
    }

    /// From four 0-255 channel ints.
    pub fn rgba(red: u8, green: u8, blue: u8, alpha: u8) Color {
        return .{ .value = pack(alpha, red, green, blue) };
    }

    /// From three 0.0-1.0 channel floats.
    pub fn rgbF(red: f32, green: f32, blue: f32) Color {
        return rgbaF(red, green, blue, 1.0);
    }

    /// From four 0.0-1.0 channel floats. Clamped to 0-1 like `rgbF`.
    pub fn rgbaF(red: f32, green: f32, blue: f32, alpha: f32) Color {
        return rgba(
            floatToByte(red),
            floatToByte(green),
            floatToByte(blue),
            floatToByte(alpha),
        );
    }

    /// From a CSS-style hex string.
    pub fn hex(s: []const u8) ParseError!Color {
        return parseHex(s);
    }

    /// `hex` for compile-time-known strings — the shape a palette wants.
    pub fn hexC(comptime s: []const u8) Color {
        const parsed = comptime parseHex(s) catch
            @compileError("invalid Color hex literal \"" ++ s ++ "\"");
        return parsed;
    }

    /// Errors `Color.hex` can produce.
    pub const ParseError = error{InvalidColor};

    // ---- accessors --------------------------------------------------------

    /// Red channel, 0-255.
    pub fn r(c: Color) u8 {
        return @truncate(c.value >> 16);
    }

    /// Green channel, 0-255.
    pub fn g(c: Color) u8 {
        return @truncate(c.value >> 8);
    }

    /// Blue channel, 0-255.
    pub fn b(c: Color) u8 {
        return @truncate(c.value);
    }

    /// Alpha channel, 0-255 (0 transparent .. 255 opaque).
    pub fn a(c: Color) u8 {
        return @truncate(c.value >> 24);
    }

    /// True when the color is fully opaque — i.e.
    pub fn isOpaque(c: Color) bool {
        return c.a() == 255;
    }

    // ---- derivation -------------------------------------------------------

    /// Same RGB, new alpha (0-255).
    pub fn withAlpha(c: Color, alpha: u8) Color {
        return rgba(c.r(), c.g(), c.b(), alpha);
    }

    /// Same color at a 0-1 opacity. `withAlphaF(c, 0.5)` is a 50% fade.
    pub fn withAlphaF(c: Color, alpha: f32) Color {
        return c.withAlpha(floatToByte(alpha));
    }

    /// Component-wise linear blend.
    pub fn lerp(from: Color, to: Color, t: f32) Color {
        const k = std.math.clamp(t, 0.0, 1.0);
        return rgba(
            blendChannel(from.r(), to.r(), k),
            blendChannel(from.g(), to.g(), k),
            blendChannel(from.b(), to.b(), k),
            blendChannel(from.a(), to.a(), k),
        );
    }

    // ---- output -----------------------------------------------------------

    /// The 0xRRGGBB form every widget prop takes.
    pub fn toU32(c: Color) u32 {
        return c.value & 0x00ff_ffff;
    }

    /// The packed 0xAARRGGBB form, alpha included.
    pub fn toArgb(c: Color) u32 {
        return c.value;
    }

    /// A Clay color: `[4]f32` in the 0-255 range, alpha carried through.
    pub fn toClay(c: Color) [4]f32 {
        return .{
            @floatFromInt(c.r()),
            @floatFromInt(c.g()),
            @floatFromInt(c.b()),
            @floatFromInt(c.a()),
        };
    }

    /// Write `c` as a hex string into `buf` and return the written slice.
    pub fn hexString(c: Color, buf: []u8) std.fmt.BufPrintError![]u8 {
        const digits = "0123456789abcdef";
        if (buf.len < 9) return error.NoSpaceLeft;
        buf[0] = '#';
        var i: usize = 1;
        inline for (.{ c.r(), c.g(), c.b() }) |channel| {
            buf[i] = digits[channel >> 4];
            buf[i + 1] = digits[channel & 0xf];
            i += 2;
        }
        if (c.a() == 255) {
            return buf[0..i];
        }
        buf[i] = digits[c.a() >> 4];
        buf[i + 1] = digits[c.a() & 0xf];
        return buf[0 .. i + 2];
    }

    /// Formatted with `{}` as `#RRGGBB` (or `#RRGGBBAA` when translucent), so `Color.hex("#BBADA0")` prints the way it was written.
    pub fn format(c: Color, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        var buf: [9]u8 = undefined;
        const s = c.hexString(&buf) catch return;
        try writer.writeAll(s);
    }
};

// ---- internals -----------------------------------------------------------

/// The one hex parser, shared by `Color.hex` (runtime) and `Color.hexC` (comptime).
fn parseHex(s: []const u8) Color.ParseError!Color {
    const digits = if (s.len > 0 and s[0] == '#') s[1..] else s;
    return switch (digits.len) {
        3 => Color.rgba(
            try expandNibble(digits[0]),
            try expandNibble(digits[1]),
            try expandNibble(digits[2]),
            255,
        ),
        4 => Color.rgba(
            try expandNibble(digits[0]),
            try expandNibble(digits[1]),
            try expandNibble(digits[2]),
            try expandNibble(digits[3]),
        ),
        6 => Color.rgba(
            try byteAt(digits, 0),
            try byteAt(digits, 2),
            try byteAt(digits, 4),
            255,
        ),
        8 => Color.rgba(
            try byteAt(digits, 0),
            try byteAt(digits, 2),
            try byteAt(digits, 4),
            try byteAt(digits, 6),
        ),
        else => error.InvalidColor,
    };
}

fn pack(a: u8, r: u8, g: u8, b: u8) u32 {
    return (@as(u32, a) << 24) | (@as(u32, r) << 16) | (@as(u32, g) << 8) | @as(u32, b);
}

fn floatToByte(v: f32) u8 {
    return @intFromFloat(std.math.clamp(v, 0.0, 1.0) * 255.0 + 0.5);
}

/// Blend two 0-255 channels.
fn blendChannel(from: u8, to: u8, t: f32) u8 {
    const f: f32 = @floatFromInt(from);
    const x: f32 = @floatFromInt(to);
    const blended = f + (x - f) * t;
    return @intFromFloat(std.math.clamp(blended, 0.0, 255.0) + 0.5);
}

/// One hex digit -> the byte that digit abbreviates (`f` -> 0xFF).
fn expandNibble(c: u8) Color.ParseError!u8 {
    const v = try nibble(c);
    return v *% 17; // 0x0 -> 0x00, 0xF -> 0xFF
}

fn byteAt(s: []const u8, i: usize) Color.ParseError!u8 {
    return (try nibble(s[i])) *% 16 +% (try nibble(s[i + 1]));
}

fn nibble(c: u8) Color.ParseError!u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => error.InvalidColor,
    };
}

// ---- tests ---------------------------------------------------------------

test "argb keeps every channel including alpha" {
    const c = Color.argb(0xFF6200EE);
    try std.testing.expectEqual(@as(u8, 0x62), c.r());
    try std.testing.expectEqual(@as(u8, 0x00), c.g());
    try std.testing.expectEqual(@as(u8, 0xEE), c.b());
    try std.testing.expectEqual(@as(u8, 0xFF), c.a());
    try std.testing.expect(c.isOpaque());
    // toU32 is the 0xRRGGBB prop contract, so the 0xFF is dropped even here.
    try std.testing.expectEqual(@as(u32, 0x6200EE), c.toU32());
    // toArgb is the whole value, alpha included.
    try std.testing.expectEqual(@as(u32, 0xFF6200EE), c.toArgb());
}

test "rgb matches the same color written as an argb literal" {
    try std.testing.expectEqual(Color.argb(0xFF6200EE), Color.rgb(98, 0, 238));
}

test "rgba carries alpha that toU32 drops and toClay keeps" {
    const c = Color.rgba(255, 0, 0, 128);
    try std.testing.expectEqual(@as(u8, 128), c.a());
    try std.testing.expect(!c.isOpaque());
    // The prop contract is 0xRRGGBB: alpha is not part of it.
    try std.testing.expectEqual(@as(u32, 0xFF0000), c.toU32());
    // A Clay color is 4 channels, so the alpha survives.
    try std.testing.expectEqual([4]f32{ 255, 0, 0, 128 }, c.toClay());
    try std.testing.expectEqual(@as(u32, 0x80FF0000), c.toArgb());
}

test "rgbF converts 0-1 floats to the same bytes as the 0-255 form" {
    // The exact 0-1 spellings of 98/0/238 — this is the round trip that has to hold, and it does because floatToByte rounds.
    const exact = Color.rgbF(98.0 / 255.0, 0.0, 238.0 / 255.0);
    try std.testing.expectEqual(Color.rgb(98, 0, 238), exact);
    try std.testing.expectEqual(@as(u8, 255), exact.a());
    // Rounded spec values land within a byte — that is the documented promise of a 0-1 float channel, not exact equality with 0.38 * 255.
    const approx = Color.rgbF(0.38, 0.0, 0.93);
    try std.testing.expectEqual(@as(u8, 97), approx.r());
    try std.testing.expectEqual(@as(u8, 0), approx.g());
    try std.testing.expectEqual(@as(u8, 237), approx.b());
}

test "float constructors clamp instead of producing garbage bytes" {
    const over = Color.rgbF(1.5, -0.5, 2.0);
    try std.testing.expectEqual(Color.rgb(255, 0, 255), over);
    try std.testing.expectEqual(@as(u8, 255), Color.rgbaF(0, 0, 0, 3.0).a());
    try std.testing.expectEqual(@as(u8, 0), Color.rgbaF(0, 0, 0, -1.0).a());
}

test "rgbaF matches the byte form and keeps a fractional alpha" {
    try std.testing.expectEqual(Color.rgba(98, 0, 238, 51), Color.rgbaF(0.384, 0, 0.933, 0.2));
    // 0.5 alpha rounds to 128, not 127.
    try std.testing.expectEqual(@as(u8, 128), Color.rgbaF(0, 0, 0, 0.5).a());
}

test "hex reads the CSS string forms" {
    try std.testing.expectEqual(Color.rgb(187, 173, 160), try Color.hex("#BBADA0"));
    try std.testing.expectEqual(Color.rgb(187, 173, 160), try Color.hex("bbada0"));
    try std.testing.expectEqual(Color.rgb(187, 173, 160), try Color.hex("#BbAdA0"));
    // 3- and 4-digit shorthand expands each nibble.
    try std.testing.expectEqual(Color.rgb(0xFF, 0x00, 0xAA), try Color.hex("#f0a"));
    try std.testing.expectEqual(Color.rgba(255, 0, 170, 0x88), try Color.hex("#f0a8"));
    // 8 digits carry alpha.
    try std.testing.expectEqual(Color.rgba(0x62, 0x00, 0xEE, 0x80), try Color.hex("#6200EE80"));
    // Black and white, the two that catch a sign or off-by-one.
    try std.testing.expectEqual(Color.rgb(0, 0, 0), try Color.hex("#000000"));
    try std.testing.expectEqual(Color.rgb(255, 255, 255), try Color.hex("#ffffff"));
}

test "hexC agrees with hex and is usable in a constant" {
    // A palette is the reason hexC exists: a top-level const cannot hold an error union, so these must be plain values.
    const COLOR_BG: Color = Color.hexC("#101014");
    const COLOR_FG: Color = Color.hexC("#f0f0f5");
    try std.testing.expectEqual(Color.rgb(0x10, 0x10, 0x14), COLOR_BG);
    try std.testing.expectEqual(Color.rgb(0xf0, 0xf0, 0xf5), COLOR_FG);
    // Same accepted forms as the runtime parser — hexC is not a second parser.
    try std.testing.expectEqual(Color.hexC("#f0a"), try Color.hex("#f0a"));
    try std.testing.expectEqual(Color.hexC("#6200EE80"), try Color.hex("#6200EE80"));
    try std.testing.expectEqual(Color.hexC("bbada0"), try Color.hex("#BBADA0"));
}

test "hex rejects junk instead of guessing a color" {
    try std.testing.expectError(error.InvalidColor, Color.hex(""));
    try std.testing.expectError(error.InvalidColor, Color.hex("#"));
    try std.testing.expectError(error.InvalidColor, Color.hex("#12345"));
    try std.testing.expectError(error.InvalidColor, Color.hex("#1234567"));
    try std.testing.expectError(error.InvalidColor, Color.hex("#gg0011"));
    try std.testing.expectError(error.InvalidColor, Color.hex("rebeccapurple"));
}

test "withAlpha and withAlphaF fade a color without touching its RGB" {
    const purple = try Color.hex("#6200EE");
    const half = purple.withAlpha(128);
    try std.testing.expectEqual(purple.r(), half.r());
    try std.testing.expectEqual(purple.g(), half.g());
    try std.testing.expectEqual(purple.b(), half.b());
    try std.testing.expectEqual(@as(u8, 128), half.a());
    try std.testing.expectEqual(@as(u8, 128), purple.withAlphaF(0.5).a());
    try std.testing.expect(purple.isOpaque());
}

test "lerp interpolates and clamps out-of-range t" {
    const black = Color.rgb(0, 0, 0);
    const white = Color.rgb(255, 255, 255);
    try std.testing.expectEqual(black, Color.lerp(black, white, 0));
    try std.testing.expectEqual(white, Color.lerp(black, white, 1));
    try std.testing.expectEqual(Color.rgb(128, 128, 128), Color.lerp(black, white, 0.5));
    // An unclamped t would wrap or overflow the u8; both ends stay sane.
    try std.testing.expectEqual(black, Color.lerp(black, white, -1));
    try std.testing.expectEqual(white, Color.lerp(black, white, 2));
}

test "lerp carries alpha so a fade can animate in one expression" {
    const from = Color.rgba(0, 0, 0, 0);
    const to = Color.rgba(255, 255, 255, 255);
    try std.testing.expectEqual(Color.rgba(0, 0, 0, 0), Color.lerp(from, to, 0));
    try std.testing.expectEqual(Color.rgba(128, 128, 128, 128), Color.lerp(from, to, 0.5));
}

test "toClay matches the renderer helper for an opaque color" {
    // Same value the widget layer gets from render.u32ToClayColor, which is what makes a Color usable anywhere a 0xRRGGBB prop was.
    const c = Color.rgb(18, 52, 86);
    try std.testing.expectEqual([4]f32{ 18, 52, 86, 255 }, c.toClay());
    try std.testing.expectEqual(Color.argb(0xFF6200EE).toU32(), Color.rgb(98, 0, 238).toU32());
}

test "hexString round-trips through hex" {
    var buf: [9]u8 = undefined;
    // Opaque stays 6 digits, so the printed form matches how it was written.
    const opaque_s = try (try Color.hex("#BBADA0")).hexString(&buf);
    try std.testing.expectEqualStrings("#bbada0", opaque_s);
    // Translucent grows the alpha pair rather than silently dropping it.
    const faded_s = try (try Color.hex("#6200EE80")).hexString(&buf);
    try std.testing.expectEqualStrings("#6200ee80", faded_s);
    for ([_][]const u8{ "#000000", "#FFFFFF", "#f0a8", "#010203" }) |s| {
        const c = try Color.hex(s);
        // hex -> Color -> hexString -> hex must be a fixed point.
        const out = try c.hexString(&buf);
        try std.testing.expectEqual(c, try Color.hex(out));
    }
}

test "hexString reports a too-small buffer instead of overflowing" {
    var tiny: [4]u8 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, Color.rgb(1, 2, 3).hexString(&tiny));
}

test "format prints the hex string form" {
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try (try Color.hex("#6200EE")).format(&w);
    try std.testing.expectEqualStrings("#6200ee", w.buffered());
}
