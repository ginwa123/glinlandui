//! `Color` — one color value, four ways to write it.
//!
//! A color is whatever you were handed: a design tool gives you `#BBADA0`, a
//! legacy file gives you `rgb(98, 0, 238)`, a spec gives you `0.38f, 0f,
//! 0.93f`, and a copied constant is `0xFF6200EE`. `Color` accepts all four,
//! and it is the type every color-bearing value in this library now uses —
//! widget props included.
//!
//!     const COLOR_BG = Color.hexC("#101014");   // hex string   (palette)
//!     const accent  = Color.rgb(98, 0, 238);    // 0-255 ints
//!     const ghost   = Color.rgbF(.38, 0, .93);  // 0-1 floats   (specs, theming)
//!     const ink     = Color.argb(0xFF6200EE);   // ARGB hex     (copied constant)
//!
//!     text.label(.{ .str = "hi", .color = accent });
//!
//! Use `hexC` for a constant and `hex` when the string is only known at
//! runtime: `hex` returns `error.InvalidColor`, `hexC` turns a typo into a
//! compile error.
//!
//! Three deliberate decisions:
//!
//! 1. **A one-`u32` struct, not a newtype.** Props stay copyable and
//!    `==`-comparable, so a `Color` drops into every place the old `u32`
//!    did and a test can `expectEqual` it directly.
//! 2. **Alpha is stored, and both outputs are honest about it.** `toClay()`
//!    carries it to Clay's 4-channel color; `toU32()` drops it because
//!    0xRRGGBB has nowhere to put it. Prefer handing the `Color` straight to
//!    a prop and reaching for `toU32()` only at an interop boundary.
//! 3. **No allocation, no globals, no platform.** This file imports only
//!    `std` (for `testing` and `fmt`) and is platform-agnostic like the rest
//!    of `core/`. `hexString` writes into a caller-owned buffer, so a color
//!    costs exactly what the `u32` it replaced cost.
const std = @import("std");

/// A color, stored as 0xAARRGGBB.
///
/// A plain struct wrapping one `u32` so it stays trivially copyable and
/// comparable with `==` — props can hold it and tests can `expectEqual` it.
pub const Color = struct {
    /// Packed 0xAARRGGBB. Named `value` rather than `argb` so the field and
    /// the `argb()` constructor can both be called `argb` at the call site
    /// (`Color.argb(0xFF6200EE)`), which is how callers spell it.
    value: u32,

    // ---- construction -----------------------------------------------------

    /// From a packed 0xAARRGGBB literal. Alpha 0x00 is fully transparent,
    /// 0xFF fully opaque.
    pub fn argb(v: u32) Color {
        return .{ .value = v };
    }

    /// From three 0-255 channel ints. Opaque.
    pub fn rgb(red: u8, green: u8, blue: u8) Color {
        return rgba(red, green, blue, 255);
    }

    /// From four 0-255 channel ints. `alpha` is 0 (transparent) .. 255
    /// (opaque). The parameters are spelled out rather than `r`/`g`/`b`/`a`
    /// because those are the accessor methods below, and a struct's
    /// parameters and declarations share one namespace.
    pub fn rgba(red: u8, green: u8, blue: u8, alpha: u8) Color {
        return .{ .value = pack(alpha, red, green, blue) };
    }

    /// From three 0.0-1.0 channel floats. Opaque.
    ///
    /// Values outside 0-1 are clamped rather than rejected: a theme file with
    /// a sloppy 1.02 should render as white, not take down the frame.
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

    /// From a CSS-style hex string. Accepts `#RGB`, `#RGBA`, `#RRGGBB` and
    /// `#RRGGBBAA`, with or without the leading `#`, upper or lower case.
    ///
    ///     const myColor = try Color.hex("#BBADA0");
    ///     // "bbada0" is the same color; "#6200EE80" carries a half alpha
    ///
    /// Returns `error.InvalidColor` for anything else (bad digit, bad length,
    /// empty) rather than defaulting to a color the caller did not ask for.
    pub fn hex(s: []const u8) ParseError!Color {
        return parseHex(s);
    }

    /// `hex` for compile-time-known strings — the shape a palette wants.
    ///
    ///     const COLOR_BG = Color.hexC("#101014");
    ///     const COLOR_FG = Color.hexC("#f0f0f5");
    ///
    /// This is a thin wrapper, NOT a second parser: it evaluates the same
    /// `parseHex` at comptime, so there is one set of accepted forms and one
    /// set of error cases. The difference is that a malformed literal becomes
    /// a COMPILE error instead of a runtime one, which is what you want for
    /// a constant — a top-level `const COLOR_BG = Color.hex("#nope");` would
    /// otherwise be an error union sitting in a declaration that claims to
    /// hold a color.
    ///
    /// The `comptime` goes on the INITIALIZER, not on the `return`. The
    /// latter looks equivalent and is not: `comptime return …` makes the
    /// whole return statement a comptime context, and a plain function call
    /// inside one fails with "function called at runtime cannot return value
    /// at comptime". Evaluating the call into a local under `comptime`, then
    /// returning the local, is the form that actually compiles.
    pub fn hexC(comptime s: []const u8) Color {
        const parsed = comptime parseHex(s) catch
            @compileError("invalid Color hex literal \"" ++ s ++ "\"");
        return parsed;
    }

    /// Errors `Color.hex` can produce. A named set so callers can
    /// `catch |err| switch (err) { error.InvalidColor => ... }`.
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

    /// True when the color is fully opaque — i.e. when `toU32()` loses
    /// nothing.
    pub fn isOpaque(c: Color) bool {
        return c.a() == 255;
    }

    // ---- derivation -------------------------------------------------------

    /// Same RGB, new alpha (0-255). This is how you fade a theme color:
    /// `Color.hex("#6200EE").withAlpha(128)`.
    pub fn withAlpha(c: Color, alpha: u8) Color {
        return rgba(c.r(), c.g(), c.b(), alpha);
    }

    /// Same color at a 0-1 opacity. `withAlphaF(c, 0.5)` is a 50% fade.
    pub fn withAlphaF(c: Color, alpha: f32) Color {
        return c.withAlpha(floatToByte(alpha));
    }

    /// Component-wise linear blend. `t = 0` is `from`, `t = 1` is `to`, and
    /// `t` is clamped, so a hover tween cannot overshoot into out-of-gamut
    /// channels. Alpha is blended too, so a fade is one expression.
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

    /// The 0xRRGGBB form every widget prop takes. Alpha is dropped — that is
    /// the prop contract, not an oversight; use `toClay()` when the alpha
    /// matters.
    pub fn toU32(c: Color) u32 {
        return c.value & 0x00ff_ffff;
    }

    /// The packed 0xAARRGGBB form, alpha included.
    pub fn toArgb(c: Color) u32 {
        return c.value;
    }

    /// A Clay color: `[4]f32` in the 0-255 range, alpha carried through.
    /// This is what `cl.*` config fields want, and it is the same shape
    /// `render.u32ToClayColor` produces for a 0xRRGGBB value.
    pub fn toClay(c: Color) [4]f32 {
        return .{
            @floatFromInt(c.r()),
            @floatFromInt(c.g()),
            @floatFromInt(c.b()),
            @floatFromInt(c.a()),
        };
    }

    /// Write `c` as a hex string into `buf` and return the written slice.
    /// Opaque colors get `#RRGGBB`; translucent ones get `#RRGGBBAA` — both
    /// of which `Color.hex` reads back, so a round trip is lossless.
    ///
    /// Returns `error.NoSpaceLeft` if `buf` is too small; 9 bytes always
    /// suffice.
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

    /// Formatted with `{}` as `#RRGGBB` (or `#RRGGBBAA` when translucent),
    /// so `Color.hex("#BBADA0")` prints the way it was written.
    pub fn format(c: Color, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        var buf: [9]u8 = undefined;
        const s = c.hexString(&buf) catch return;
        try writer.writeAll(s);
    }
};

// ---- internals -----------------------------------------------------------

/// The one hex parser, shared by `Color.hex` (runtime) and `Color.hexC`
/// (comptime). It is a plain function so BOTH can reach it: a method can only
/// be evaluated at comptime if its own body is comptime-evaluable, and an
/// error union returning across that boundary is exactly what `hexC` needs to
/// intercept with `@compileError`.
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

/// Blend two 0-255 channels. NOT `floatToByte` — that helper clamps to the
/// 0-1 range first, so feeding it a 0-255 mid value would saturate the whole
/// channel to white and make every `lerp` a step function.
fn blendChannel(from: u8, to: u8, t: f32) u8 {
    const f: f32 = @floatFromInt(from);
    const x: f32 = @floatFromInt(to);
    const blended = f + (x - f) * t;
    return @intFromFloat(std.math.clamp(blended, 0.0, 255.0) + 0.5);
}

/// One hex digit -> the byte that digit abbreviates (`f` -> 0xFF). This is
/// what makes `#f0a` mean `#ff00aa`.
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
    // The exact 0-1 spellings of 98/0/238 — this is the round trip that has
    // to hold, and it does because floatToByte rounds.
    const exact = Color.rgbF(98.0 / 255.0, 0.0, 238.0 / 255.0);
    try std.testing.expectEqual(Color.rgb(98, 0, 238), exact);
    try std.testing.expectEqual(@as(u8, 255), exact.a());
    // Rounded spec values land within a byte — that is the documented promise
    // of a 0-1 float channel, not exact equality with 0.38 * 255.
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
    // A palette is the reason hexC exists: a top-level const cannot hold an
    // error union, so these must be plain values.
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
    // Same value the widget layer gets from render.u32ToClayColor, which is
    // what makes a Color usable anywhere a 0xRRGGBB prop was.
    const c = Color.rgb(18, 52, 86);
    try std.testing.expectEqual([4]f32{ 18, 52, 86, 255 }, c.toClay());
    try std.testing.expectEqual(Color.argb(0xFF6200EE).toU32(), Color.rgb(98, 0, 238).toU32());
}

test "hexString round-trips through hex" {
    var buf: [9]u8 = undefined;
    // Opaque stays 6 digits, so the printed form matches how it was written.
    // Output is canonical LOWERCASE regardless of the input casing: one
    // spelling out, so a test or a log line is stable.
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
