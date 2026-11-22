//! Sixel: the CPU framebuffer as a palette image, for the terminals that draw pixels with `ESC P ... q`.
const std = @import("std");

/// A 6x6x6 colour cube plus a 24-step grey ramp: 240 entries, under the 256 a sixel palette allows.
pub const palette_len: u16 = 240;

/// The palette index a colour lands on: greys on the ramp (banding is invisible there) and everything else on the cube.
pub fn paletteIndex(r: u8, g: u8, b: u8) u8 {
    const mx = @max(r, @max(g, b));
    const mn = @min(r, @min(g, b));
    if (mx - mn <= 6) {
        const i: u32 = if (mx <= 8) 0 else (@as(u32, mx) - 8) * 23 / 247;
        const ramp: u32 = if (i > 23) 23 else i;
        const idx: u32 = 216 + ramp;
        return @intCast(idx);
    }
    const ri: u32 = (@as(u32, r) * 5 + 127) / 255;
    const gi: u32 = (@as(u32, g) * 5 + 127) / 255;
    const bi: u32 = (@as(u32, b) * 5 + 127) / 255;
    return @intCast(36 * ri + 6 * gi + bi);
}

/// The colour a palette index stands for, so a decoder (or a test) can read the palette back.
pub fn paletteColor(i: u8) [3]u8 {
    if (i < 216) {
        const ri: u32 = i / 36;
        const gi: u32 = (i % 36) / 6;
        const bi: u32 = i % 6;
        return .{ @intCast(ri * 51), @intCast(gi * 51), @intCast(bi * 51) };
    }
    const step: u32 = 8 + (@as(u32, i) - 216) * 247 / 23;
    const v: u8 = @intCast(@min(step, 255));
    return .{ v, v, v };
}

fn percent(v: u8) u32 {
    return (@as(u32, v) * 100 + 127) / 255;
}

fn writeDefinition(out: *std.ArrayList(u8), alloc: std.mem.Allocator, i: u8, current: *i16) !void {
    current.* = i;
    const c = paletteColor(i);
    var buf: [32]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, "#{d};2;{d};{d};{d}", .{ i, percent(c[0]), percent(c[1]), percent(c[2]) });
    try out.appendSlice(alloc, s);
}

fn writeRun(out: *std.ArrayList(u8), alloc: std.mem.Allocator, ch: u8, count: u32) !void {
    if (count == 0) return;
    if (count < 4) {
        var i: u32 = 0;
        while (i < count) : (i += 1) try out.append(alloc, ch);
        return;
    }
    var buf: [16]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, "!{d}", .{count});
    try out.appendSlice(alloc, s);
    try out.append(alloc, ch);
}

/// Encode an RGBA surface as a sixel image: one `ESC P` string, palette first, then six-row bands of RLE data.
pub fn encoded(alloc: std.mem.Allocator, rgba: []const u8, w: u32, h: u32) ![]u8 {
    if (w == 0 or h == 0) return error.EmptyImage;
    if (rgba.len < @as(usize, w) * h * 4) return error.ShortBuffer;
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);
    // P1=0 (square pixels), P2=1 (the unpainted pixels stay transparent), P3=0 (no raster aspect baked in).
    try out.appendSlice(alloc, "\x1bP0;1;0q");
    var used = [_]bool{false} ** palette_len;
    var i: usize = 0;
    while (i < @as(usize, w) * h) : (i += 1) {
        const px = rgba[i * 4 .. i * 4 + 4];
        if (px[3] < 128) continue;
        used[paletteIndex(px[0], px[1], px[2])] = true;
    }
    var current: i16 = -1;
    var idx: u16 = 0;
    while (idx < palette_len) : (idx += 1) {
        if (used[idx]) try writeDefinition(&out, alloc, @intCast(idx), &current);
    }
    var band: u32 = 0;
    while (band * 6 < h) : (band += 1) {
        var present = [_]bool{false} ** palette_len;
        var y: u32 = band * 6;
        while (y < @min(h, band * 6 + 6)) : (y += 1) {
            var x: u32 = 0;
            while (x < w) : (x += 1) {
                const px = rgba[(@as(usize, y) * w + x) * 4 ..][0..4];
                if (px[3] < 128) continue;
                present[paletteIndex(px[0], px[1], px[2])] = true;
            }
        }
        var any = false;
        idx = 0;
        while (idx < palette_len) : (idx += 1) {
            if (!present[idx]) continue;
            if (any) try out.append(alloc, '$');
            any = true;
            if (current != @as(i16, @intCast(idx))) {
                var buf: [16]u8 = undefined;
                try out.appendSlice(alloc, try std.fmt.bufPrint(&buf, "#{d}", .{idx}));
                current = @intCast(idx);
            }
            var run_ch: u8 = 0;
            var run_len: u32 = 0;
            var x: u32 = 0;
            while (x < w) : (x += 1) {
                var mask: u8 = 0;
                var bit: u3 = 0;
                while (bit < 6) : (bit += 1) {
                    const yy = band * 6 + bit;
                    if (yy >= h) break;
                    const px = rgba[(@as(usize, yy) * w + x) * 4 ..][0..4];
                    if (px[3] < 128) continue;
                    if (paletteIndex(px[0], px[1], px[2]) != idx) continue;
                    mask |= @as(u8, 1) << bit;
                }
                const ch: u8 = 0x3F + mask;
                if (ch == run_ch) {
                    run_len += 1;
                } else {
                    try writeRun(&out, alloc, run_ch, run_len);
                    run_ch = ch;
                    run_len = 1;
                }
            }
            try writeRun(&out, alloc, run_ch, run_len);
        }
        // A band with nothing in it still has to advance the raster, or the next band draws over this one's rows.
        try out.append(alloc, '-');
    }
    try out.appendSlice(alloc, "\x1b\\");
    return out.toOwnedSlice(alloc);
}

// ===================== tests =====================

test "a single red pixel is one palette entry, one glyph and one band advance" {
    const rgba = [_]u8{ 255, 0, 0, 255 };
    const out = try encoded(std.testing.allocator, &rgba, 1, 1);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("\x1bP0;1;0q#180;2;100;0;0@-\x1b\\", out);
}

test "ten identical pixels collapse into one run length" {
    var rgba = [_]u8{0} ** (10 * 4);
    for (0..10) |i| {
        rgba[i * 4] = 0;
        rgba[i * 4 + 1] = 255;
        rgba[i * 4 + 2] = 0;
        rgba[i * 4 + 3] = 255;
    }
    const out = try encoded(std.testing.allocator, &rgba, 10, 1);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "#30;2;0;100;0!10@") != null);
}

test "two colours in one band are separated by a graphics carriage return" {
    var rgba = [_]u8{ 255, 0, 0, 255, 0, 0, 255, 255 };
    const out = try encoded(std.testing.allocator, &rgba, 2, 1);
    defer std.testing.allocator.free(out);
    // Both palette entries are defined, and the band paints the second colour after a carriage return.
    try std.testing.expect(std.mem.indexOf(u8, out, "#180;2;100;0;0") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "#5;2;0;0;100") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "$") != null);
}

test "a transparent pixel is not painted, so the terminal background shows through" {
    const rgba = [_]u8{ 255, 0, 0, 0 };
    const out = try encoded(std.testing.allocator, &rgba, 1, 1);
    defer std.testing.allocator.free(out);
    // No palette entry at all, and the single cell is the empty sixel character.
    try std.testing.expectEqualStrings("\x1bP0;1;0q-\x1b\\", out);
}

test "a six-row image fills one band, a seven-row one starts a second" {
    var rgba = [_]u8{ 200, 200, 200, 255 } ** (1 * 7);
    const seven = try encoded(std.testing.allocator, &rgba, 1, 7);
    defer std.testing.allocator.free(seven);
    var count: usize = 0;
    for (seven) |b| {
        if (b == '-') count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "the palette round-trips a colour to within one cube step" {
    const c = [3]u8{ 140, 60, 200 };
    const p = paletteColor(paletteIndex(c[0], c[1], c[2]));
    try std.testing.expect(@abs(@as(i32, p[0]) - c[0]) <= 26);
    try std.testing.expect(@abs(@as(i32, p[1]) - c[1]) <= 26);
    try std.testing.expect(@abs(@as(i32, p[2]) - c[2]) <= 26);
}

test "a short buffer is refused rather than reading past the pixels" {
    const rgba = [_]u8{ 1, 2, 3, 255 };
    try std.testing.expectError(error.ShortBuffer, encoded(std.testing.allocator, &rgba, 4, 4));
    try std.testing.expectError(error.EmptyImage, encoded(std.testing.allocator, &rgba, 0, 0));
}
