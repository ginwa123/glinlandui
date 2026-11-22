//! The kitty graphics protocol: the framebuffer as one RGBA image, base64 in 4096-byte chunks, drawn into cells.
const std = @import("std");

/// The largest base64 payload the protocol allows in one escape.
pub const chunk_size: usize = 4096;

/// How the pixel payload is carried: raw RGB, or zlib (`o=z`) when the terminal says it can inflate one.
pub const Format = enum { raw, zlib };

/// A rectangle of an image, in pixels, plus where it goes in cells: what an incremental repaint sends.
pub const Placement = struct {
    x: u32,
    y: u32,
    w: u32,
    h: u32,
    /// The cell the image's left edge is placed at, relative to the cursor.
    cell_x: u16 = 0,
    /// The cell the image's top edge is placed at, relative to the cursor.
    cell_y: u16 = 0,
};

/// The size, in bytes, of the RGB payload an image of this size needs.
pub fn rgbSize(w: u32, h: u32) usize {
    return @as(usize, w) * h * 3;
}

/// Encode an RGBA surface as a kitty `a=T` escape: transmit and display in one pass, no palette, no alpha beyond `f=24`.
pub fn encoded(alloc: std.mem.Allocator, rgba: []const u8, w: u32, h: u32, cols: u16, rows: u16, image_id: u32) ![]u8 {
    return encodedRegion(alloc, rgba, w, h, .{ .x = 0, .y = 0, .w = w, .h = h }, cols, rows, image_id, .raw);
}

/// Encode one rectangle of an RGBA surface, placed at `cell_x`/`cell_y`: how a dirty region is repainted without re-sending the frame.
pub fn encodedRegion(
    alloc: std.mem.Allocator,
    rgba: []const u8,
    w: u32,
    h: u32,
    region: Placement,
    cols: u16,
    rows: u16,
    image_id: u32,
    format: Format,
) ![]u8 {
    if (w == 0 or h == 0 or region.w == 0 or region.h == 0) return error.EmptyImage;
    if (rgba.len < @as(usize, w) * h * 4) return error.ShortBuffer;
    if (region.x + region.w > w or region.y + region.h > h) return error.ShortBuffer;
    const rw: usize = region.w;
    const rh: usize = region.h;
    const rgb = try alloc.alloc(u8, rw * rh * 3);
    defer alloc.free(rgb);
    var y: usize = 0;
    while (y < rh) : (y += 1) {
        const src = (@as(usize, region.y) + y) * w + region.x;
        var x: usize = 0;
        while (x < rw) : (x += 1) {
            const px = rgba[(src + x) * 4 ..][0..4];
            rgb[(y * rw + x) * 3] = px[0];
            rgb[(y * rw + x) * 3 + 1] = px[1];
            rgb[(y * rw + x) * 3 + 2] = px[2];
        }
    }
    // A UI frame compresses ~95x, so a full-screen image costs tens of KB instead of megabytes on the wire.
    const compressed = if (format == .zlib) try deflate(alloc, rgb) else null;
    defer if (compressed) |c| alloc.free(c);
    const payload = compressed orelse rgb;
    const b64 = try alloc.alloc(u8, std.base64.standard.Encoder.calcSize(payload.len));
    defer alloc.free(b64);
    _ = std.base64.standard.Encoder.encode(b64, payload);
    const o = if (format == .zlib) ",o=z" else "";

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);
    var first = true;
    var off: usize = 0;
    while (true) {
        const n = @min(chunk_size, b64.len - off);
        const last = off + n >= b64.len;
        var header: [160]u8 = undefined;
        const hdr = if (first)
            try std.fmt.bufPrint(&header, "\x1b_Ga=T,f=24,s={d},v={d},c={d},r={d},i={d},x={d},y={d}{s},q=2,m={d};", .{
                region.w,
                region.h,
                cols,
                rows,
                image_id,
                region.cell_x,
                region.cell_y,
                o,
                @intFromBool(!last),
            })
        else
            try std.fmt.bufPrint(&header, "\x1b_Gm={d};", .{@intFromBool(!last)});
        try out.appendSlice(alloc, hdr);
        try out.appendSlice(alloc, b64[off .. off + n]);
        try out.appendSlice(alloc, "\x1b\\");
        first = false;
        off += n;
        if (last) break;
    }
    return out.toOwnedSlice(alloc);
}

/// zlib-compress a payload, so the escape carries a fraction of the pixels. The terminal inflates it (`o=z`).
pub fn deflate(alloc: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var out = try std.Io.Writer.Allocating.initCapacity(alloc, @max(bytes.len / 8, 4096));
    errdefer out.deinit();
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    // Fast settings: a UI frame is flat colour, so the ratio stays ~95x and the cost stays a few milliseconds.
    var c = try std.compress.flate.Compress.init(&out.writer, &window, .zlib, .{ .good = 4, .nice = 16, .lazy = 0, .chain = 16 });
    try c.writer.writeAll(bytes);
    try c.finish();
    return out.toOwnedSlice();
}

/// The escape that deletes one placement, by the id its image was sent with.
pub fn deleteOne(alloc: std.mem.Allocator, id: u32) ![]u8 {
    return std.fmt.allocPrint(alloc, "\x1b_Ga=d,d=i,i={d},q=2\x1b\\", .{id});
}

/// The escape that deletes every placement this process made, so a resize never leaves a ghost behind.
pub fn deleteAll(alloc: std.mem.Allocator) ![]u8 {
    return std.fmt.allocPrint(alloc, "\x1b_Ga=d,q=2\x1b\\", .{});
}

// ===================== tests =====================

test "a two-by-two image is one chunk: transmit-and-display, sized, quiet, and final" {
    const rgba = [_]u8{
        255, 0,   0,   255,
        0,   255, 0,   255,
        0,   0,   255, 255,
        9,   9,   9,   255,
    };
    const out = try encoded(std.testing.allocator, &rgba, 2, 2, 1, 1, 7);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.startsWith(u8, out, "\x1b_Ga=T,f=24,s=2,v=2,c=1,r=1,i=7,x=0,y=0,q=2,m=0;"));
    try std.testing.expect(std.mem.endsWith(u8, out, "\x1b\\"));
    // The payload decodes back to the RGB triples, alpha dropped.
    const payload_start = std.mem.indexOf(u8, out, ";").? + 1;
    const payload = out[payload_start .. out.len - 2];
    var decoded: [12]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 12), try std.base64.standard.Decoder.calcSizeForSlice(payload));
    try std.base64.standard.Decoder.decode(&decoded, payload);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 0, 255, 0, 0, 0, 255, 9, 9, 9 }, &decoded);
}

test "a payload larger than one escape is chunked with m=1 until the last" {
    // 64x64 RGB = 12288 bytes, base64 of that is 16384 bytes: four chunks of 4096.
    const w: u32 = 64;
    const h: u32 = 64;
    const rgba = try std.testing.allocator.alloc(u8, w * h * 4);
    defer std.testing.allocator.free(rgba);
    @memset(rgba, 0x40);
    const out = try encoded(std.testing.allocator, rgba, w, h, 32, 32, 1);
    defer std.testing.allocator.free(out);
    var chunks: usize = 0;
    var it = std.mem.splitSequence(u8, out, "\x1b\\");
    while (it.next()) |part| {
        if (part.len == 0) continue;
        chunks += 1;
        if (chunks < 4) {
            try std.testing.expect(std.mem.indexOf(u8, part, "m=1") != null);
        } else {
            try std.testing.expect(std.mem.indexOf(u8, part, "m=0") != null);
        }
    }
    try std.testing.expectEqual(@as(usize, 4), chunks);
}

test "a region carries its own size and its cell offset, and only its own pixels" {
    // 4x2 pixels, the right half blue; ask for the right half and place it two cells in.
    var rgba = [_]u8{0} ** (4 * 2 * 4);
    for (0..4 * 2) |i| {
        const blue = i % 4 >= 2;
        rgba[i * 4 + 2] = if (blue) 255 else 0;
        rgba[i * 4] = if (blue) 0 else 255;
        rgba[i * 4 + 3] = 255;
    }
    const out = try encodedRegion(std.testing.allocator, &rgba, 4, 2, .{ .x = 2, .y = 0, .w = 2, .h = 2, .cell_x = 2, .cell_y = 1 }, 2, 1, 3, .raw);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.startsWith(u8, out, "\x1b_Ga=T,f=24,s=2,v=2,c=2,r=1,i=3,x=2,y=1,q=2,m=0;"));
    const payload_start = std.mem.indexOf(u8, out, ";").? + 1;
    const payload = out[payload_start .. out.len - 2];
    var decoded: [12]u8 = undefined;
    try std.base64.standard.Decoder.decode(&decoded, payload);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 255, 0, 0, 255, 0, 0, 255, 0, 0, 255 }, &decoded);
}

test "a short buffer or an empty image is refused" {
    const rgba = [_]u8{0} ** 4;
    try std.testing.expectError(error.ShortBuffer, encoded(std.testing.allocator, &rgba, 4, 4, 1, 1, 1));
    try std.testing.expectError(error.EmptyImage, encoded(std.testing.allocator, &rgba, 0, 5, 1, 1, 1));
}

test "a zlib payload decompresses to the same pixels, and says so in the header" {
    const rgba = [_]u8{ 200, 20, 20, 255 } ** (8 * 4);
    const out = try encodedRegion(std.testing.allocator, &rgba, 8, 4, .{ .x = 0, .y = 0, .w = 8, .h = 4 }, 1, 1, 5, .zlib);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, ",o=z,") != null);
    const payload_start = std.mem.indexOf(u8, out, ";").? + 1;
    const payload = out[payload_start .. out.len - 2];
    const packed_len = try std.base64.standard.Decoder.calcSizeForSlice(payload);
    const packed_bytes = try std.testing.allocator.alloc(u8, packed_len);
    defer std.testing.allocator.free(packed_bytes);
    try std.base64.standard.Decoder.decode(packed_bytes, payload);
    try std.testing.expect(packed_len < 8 * 4 * 3);
    var plain: [8 * 4 * 3]u8 = undefined;
    var in: std.Io.Reader = .fixed(packed_bytes);
    var out_reader: std.Io.Writer = .fixed(&plain);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var d = std.compress.flate.Decompress.init(&in, .zlib, &window);
    _ = try d.reader.streamRemaining(&out_reader);
    try std.testing.expectEqualSlices(u8, &([_]u8{ 200, 20, 20 } ** 32), &plain);
}
