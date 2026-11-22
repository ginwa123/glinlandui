//! Sixel: the CPU framebuffer as a palette image, for the terminals that draw pixels with `ESC P ... q`.
const std = @import("std");

/// A 6x6x6 colour cube plus a 24-step grey ramp: 240 entries, under the 256 a sixel palette allows.
pub const palette_len: u16 = 240;

/// A rectangle of an image, in pixels: what an incremental repaint paints.
pub const Region = struct {
    x: u32,
    y: u32,
    w: u32,
    h: u32,
};

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
    const v: u8 = @intCast(if (step > 255) 255 else step);
    return .{ v, v, v };
}

fn percent(v: u8) u32 {
    return (@as(u32, v) * 100 + 127) / 255;
}

/// A transparent pixel is not part of the image at all: P2=1 leaves the terminal's own background showing.
const transparent: u8 = 0xFF;

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

/// Encode the whole RGBA surface as one sixel image.
pub fn encoded(alloc: std.mem.Allocator, rgba: []const u8, w: u32, h: u32) ![]u8 {
    return encodedRegion(alloc, rgba, w, h, .{ .x = 0, .y = 0, .w = w, .h = h });
}

/// Encode one rectangle of an RGBA surface: an incremental repaint sends only the cells that changed.
pub fn encodedRegion(alloc: std.mem.Allocator, rgba: []const u8, w: u32, h: u32, region: Region) ![]u8 {
    if (w == 0 or h == 0 or region.w == 0 or region.h == 0) return error.EmptyImage;
    if (rgba.len < @as(usize, w) * h * 4) return error.ShortBuffer;
    if (region.x + region.w > w or region.y + region.h > h) return error.ShortBuffer;
    const rw: usize = region.w;
    const rh: usize = region.h;
    const stride: usize = w;
    // One palette lookup per pixel for the whole frame: the band loops then compare bytes instead of doing colour maths.
    const idx = try alloc.alloc(u8, rw * rh);
    defer alloc.free(idx);
    var used = [_]bool{false} ** palette_len;
    var y: usize = 0;
    while (y < rh) : (y += 1) {
        const row = (region.y + @as(u32, @intCast(y))) * stride + region.x;
        var x: usize = 0;
        while (x < rw) : (x += 1) {
            const px = rgba[(row + @as(u32, @intCast(x))) * 4 ..][0..4];
            if (px[3] < 128) {
                idx[y * rw + x] = transparent;
                continue;
            }
            const p = paletteIndex(px[0], px[1], px[2]);
            idx[y * rw + x] = p;
            used[p] = true;
        }
    }
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);
    // P1=0 (square pixels), P2=1 (the unpainted pixels stay transparent), P3=0 (no raster aspect baked in).
    try out.appendSlice(alloc, "\x1bP0;1;0q");
    var current: i16 = -1;
    var i: u16 = 0;
    while (i < palette_len) : (i += 1) {
        if (!used[i]) continue;
        const c = paletteColor(@intCast(i));
        var buf: [32]u8 = undefined;
        try out.appendSlice(alloc, try std.fmt.bufPrint(&buf, "#{d};2;{d};{d};{d}", .{ i, percent(c[0]), percent(c[1]), percent(c[2]) }));
        current = @intCast(i);
    }
    // One byte per column per colour, built by walking the band's six rows once: emitting then only scans bytes.
    const masks = try alloc.alloc(u8, @as(usize, palette_len) * rw);
    defer alloc.free(masks);
    var present = [_]bool{false} ** palette_len;
    var band: usize = 0;
    while (band * 6 < rh) : (band += 1) {
        var count: usize = 0;
        var list: [palette_len]u8 = undefined;
        var bit: usize = 0;
        while (bit < 6) : (bit += 1) {
            const yy = band * 6 + bit;
            if (yy >= rh) break;
            var x: usize = 0;
            while (x < rw) : (x += 1) {
                const p = idx[yy * rw + x];
                if (p == transparent) continue;
                if (!present[p]) {
                    present[p] = true;
                    list[count] = p;
                    count += 1;
                    @memset(masks[@as(usize, p) * rw ..][0..rw], 0);
                }
                masks[@as(usize, p) * rw + x] |= @as(u8, 1) << @intCast(bit);
            }
        }
        var any = false;
        var k: usize = 0;
        while (k < count) : (k += 1) {
            const p = list[k];
            present[p] = false;
            if (any) try out.append(alloc, '$');
            any = true;
            if (current != @as(i16, p)) {
                var buf: [16]u8 = undefined;
                try out.appendSlice(alloc, try std.fmt.bufPrint(&buf, "#{d}", .{p}));
                current = p;
            }
            const row = masks[@as(usize, p) * rw ..][0..rw];
            var run_ch: u8 = 0;
            var run_len: u32 = 0;
            for (row) |m| {
                const ch: u8 = 0x3F + m;
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
        rgba[i * 4 + 1] = 255;
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

test "a region encodes only its own pixels, at its own size" {
    // A 4x2 image, half red and half blue; ask for the right half only.
    var rgba = [_]u8{0} ** (4 * 2 * 4);
    for (0..4 * 2) |i| {
        const blue = i % 4 >= 2;
        rgba[i * 4 + 2] = if (blue) 255 else 0;
        rgba[i * 4] = if (blue) 0 else 255;
        rgba[i * 4 + 3] = 255;
    }
    const out = try encodedRegion(std.testing.allocator, &rgba, 4, 2, .{ .x = 2, .y = 0, .w = 2, .h = 2 });
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "#5;2;0;0;100") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "#180;2;100;0;0") == null);
    // Two columns, two rows set in the same band: one run of two copies of the two-bit character.
    try std.testing.expect(std.mem.indexOf(u8, out, "BB") != null);
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
    try std.testing.expectError(error.ShortBuffer, encodedRegion(std.testing.allocator, &rgba, 1, 1, .{ .x = 0, .y = 0, .w = 2, .h = 1 }));
}
