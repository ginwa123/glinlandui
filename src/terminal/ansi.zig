//! The escape stream: a grid diff, written as the fewest cursor moves and SGR codes that paint it.
const std = @import("std");
const cells = @import("cells.zig");
const term = @import("term.zig");

/// The 16-colour palette a `VT100`-class terminal has: the fallback depth must still look like the app.
pub const ansi16 = [16]cells.Color{
    .{ .r = 0, .g = 0, .b = 0 },      .{ .r = 170, .g = 0, .b = 0 },
    .{ .r = 0, .g = 170, .b = 0 },    .{ .r = 170, .g = 85, .b = 0 },
    .{ .r = 0, .g = 0, .b = 170 },    .{ .r = 170, .g = 0, .b = 170 },
    .{ .r = 0, .g = 170, .b = 170 },  .{ .r = 170, .g = 170, .b = 170 },
    .{ .r = 85, .g = 85, .b = 85 },   .{ .r = 255, .g = 85, .b = 85 },
    .{ .r = 85, .g = 255, .b = 85 },  .{ .r = 255, .g = 255, .b = 85 },
    .{ .r = 85, .g = 85, .b = 255 },  .{ .r = 255, .g = 85, .b = 255 },
    .{ .r = 85, .g = 255, .b = 255 }, .{ .r = 255, .g = 255, .b = 255 },
};

/// The nearest of the 216-cube + 24-grey 256-colour palette.
pub fn rgbTo256(c: cells.Color) u8 {
    if (c.r == c.g and c.g == c.b) {
        if (c.r < 8) return 16;
        if (c.r > 238) return 231;
        return @intCast(232 + (@as(u32, c.r) - 8) / 10);
    }
    const ri = (@as(u32, c.r) * 5 + 127) / 255;
    const gi = (@as(u32, c.g) * 5 + 127) / 255;
    const bi = (@as(u32, c.b) * 5 + 127) / 255;
    return @intCast(16 + 36 * ri + 6 * gi + bi);
}

/// The nearest of the 16 base colours, by squared distance.
pub fn rgbTo16(c: cells.Color) u8 {
    var best: u8 = 0;
    var best_d: i64 = std.math.maxInt(i64);
    for (ansi16, 0..) |p, i| {
        const dr = @as(i64, c.r) - @as(i64, p.r);
        const dg = @as(i64, c.g) - @as(i64, p.g);
        const db = @as(i64, c.b) - @as(i64, p.b);
        const d = dr * dr + dg * dg + db * db;
        if (d < best_d) {
            best_d = d;
            best = @intCast(i);
        }
    }
    return best;
}

/// The SGR parameters for a foreground colour at a depth.
pub fn fgSgr(buf: []u8, c: cells.Color, depth: term.Depth) []const u8 {
    return switch (depth) {
        .truecolor => std.fmt.bufPrint(buf, "\x1b[38;2;{d};{d};{d}m", .{ c.r, c.g, c.b }) catch "",
        .ansi256 => std.fmt.bufPrint(buf, "\x1b[38;5;{d}m", .{rgbTo256(c)}) catch "",
        .ansi16 => blk: {
            const i = rgbTo16(c);
            break :blk if (i < 8)
                std.fmt.bufPrint(buf, "\x1b[{d}m", .{30 + i}) catch ""
            else
                std.fmt.bufPrint(buf, "\x1b[{d}m", .{90 + i - 8}) catch "";
        },
    };
}

/// The SGR parameters for a background colour at a depth.
pub fn bgSgr(buf: []u8, c: cells.Color, depth: term.Depth) []const u8 {
    return switch (depth) {
        .truecolor => std.fmt.bufPrint(buf, "\x1b[48;2;{d};{d};{d}m", .{ c.r, c.g, c.b }) catch "",
        .ansi256 => std.fmt.bufPrint(buf, "\x1b[48;5;{d}m", .{rgbTo256(c)}) catch "",
        .ansi16 => blk: {
            const i = rgbTo16(c);
            break :blk if (i < 8)
                std.fmt.bufPrint(buf, "\x1b[{d}m", .{40 + i}) catch ""
            else
                std.fmt.bufPrint(buf, "\x1b[{d}m", .{100 + i - 8}) catch "";
        },
    };
}

/// What the terminal's pen is currently set to, so an unchanged colour costs no bytes.
const Pen = struct {
    fg: ?cells.Color = null,
    bg: ?cells.Color = null,
    row: i32 = -1,
    col: i32 = -1,
};

/// Append the diff between two grids, as escape bytes. An identical frame appends nothing at all.
pub fn emit(out: *std.ArrayList(u8), alloc: std.mem.Allocator, prev: ?*const cells.Grid, next: *const cells.Grid, depth: term.Depth) !void {
    // A frame at a new size has no previous cells to compare against: clear and repaint everything.
    const size_changed = if (prev) |p| p.cols != next.cols or p.rows != next.rows else true;
    if (size_changed) {
        try out.appendSlice(alloc, "\x1b[0m\x1b[2J");
    }
    var pen = Pen{};
    var row: i32 = 0;
    while (row < next.rows) : (row += 1) {
        var col: i32 = 0;
        while (col < next.cols) : (col += 1) {
            const cell = &next.cells[@as(usize, @intCast(row)) * next.cols + @as(usize, @intCast(col))];
            if (cell.cont) continue;
            if (!size_changed) {
                if (prev) |p| {
                    const old = &p.cells[@as(usize, @intCast(row)) * p.cols + @as(usize, @intCast(col))];
                    if (cell.eql(old.*)) {
                        // The pen follows the cursor even over cells this frame did not touch.
                        continue;
                    }
                }
            }
            if (pen.row != row or pen.col != col) {
                var buf: [32]u8 = undefined;
                const move = try std.fmt.bufPrint(&buf, "\x1b[{d};{d}H", .{ row + 1, col + 1 });
                try out.appendSlice(alloc, move);
                pen.row = row;
                pen.col = col;
            }
            if (pen.bg == null or !pen.bg.?.eql(cell.bg)) {
                var buf: [32]u8 = undefined;
                try out.appendSlice(alloc, bgSgr(&buf, cell.bg, depth));
                pen.bg = cell.bg;
            }
            if (pen.fg == null or !pen.fg.?.eql(cell.fg)) {
                var buf: [32]u8 = undefined;
                try out.appendSlice(alloc, fgSgr(&buf, cell.fg, depth));
                pen.fg = cell.fg;
            }
            var utf8: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(cell.ch, &utf8) catch 1;
            if (n == 1 and cell.ch > 0x7f) {
                try out.append(alloc, '?');
            } else {
                try out.appendSlice(alloc, utf8[0..n]);
            }
            pen.col = col + @as(i32, if (cells.isWide(cell.ch)) 2 else 1);
        }
    }
}

// ===================== tests =====================

const cl = @import("zclay");

fn rectCmd(x: f32, y: f32, w: f32, h: f32, color: [4]f32) cl.RenderCommand {
    return .{
        .bounding_box = .{ .x = x, .y = y, .width = w, .height = h },
        .render_data = .{ .rectangle = .{ .background_color = color, .corner_radius = .{} } },
        .user_data = null,
        .id = 0,
        .z_index = 0,
        .command_type = .rectangle,
    };
}

test "an unchanged frame emits nothing at all" {
    var a = try cells.Grid.init(std.testing.allocator, 4, 2);
    defer a.deinit();
    var b = try cells.Grid.init(std.testing.allocator, 4, 2);
    defer b.deinit();
    var cmds = [_]cl.RenderCommand{rectCmd(0, 0, 32, 32, .{ 1, 2, 3, 255 })};
    a.render(&cmds, 32, 32);
    b.render(&cmds, 32, 32);
    var out = std.ArrayList(u8).empty;
    defer out.deinit(std.testing.allocator);
    try emit(&out, std.testing.allocator, &a, &b, .truecolor);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

test "one changed cell is one cursor move, one background change and one glyph" {
    var a = try cells.Grid.init(std.testing.allocator, 4, 2);
    defer a.deinit();
    var b = try cells.Grid.init(std.testing.allocator, 4, 2);
    defer b.deinit();
    var cmds = [_]cl.RenderCommand{rectCmd(0, 0, 32, 32, .{ 0, 0, 0, 255 })};
    a.render(&cmds, 32, 32);
    b.render(&cmds, 32, 32);
    b.at(2, 1).?.bg = .{ .r = 10, .g = 20, .b = 30 };
    var out = std.ArrayList(u8).empty;
    defer out.deinit(std.testing.allocator);
    try emit(&out, std.testing.allocator, &a, &b, .truecolor);
    try std.testing.expectEqualStrings("\x1b[2;3H\x1b[48;2;10;20;30m\x1b[38;2;216;216;216m ", out.items);
}

test "a first frame clears the screen before painting" {
    var g = try cells.Grid.init(std.testing.allocator, 2, 1);
    defer g.deinit();
    var out = std.ArrayList(u8).empty;
    defer out.deinit(std.testing.allocator);
    try emit(&out, std.testing.allocator, null, &g, .ansi16);
    try std.testing.expect(std.mem.startsWith(u8, out.items, "\x1b[0m\x1b[2J"));
}

test "256-colour quantisation lands on the cube and on the grey ramp" {
    try std.testing.expectEqual(@as(u8, 196), rgbTo256(.{ .r = 255, .g = 0, .b = 0 }));
    try std.testing.expectEqual(@as(u8, 46), rgbTo256(.{ .r = 0, .g = 255, .b = 0 }));
    try std.testing.expectEqual(@as(u8, 21), rgbTo256(.{ .r = 0, .g = 0, .b = 255 }));
    // 128 grey sits in the 24-step grey ramp, not in the cube.
    const grey = rgbTo256(.{ .r = 128, .g = 128, .b = 128 });
    try std.testing.expect(grey >= 232 and grey <= 255);
}

test "16-colour quantisation picks the closest base colour" {
    try std.testing.expectEqual(@as(u8, 1), rgbTo16(.{ .r = 200, .g = 0, .b = 0 }));
    try std.testing.expectEqual(@as(u8, 15), rgbTo16(.{ .r = 250, .g = 250, .b = 250 }));
    try std.testing.expectEqual(@as(u8, 0), rgbTo16(.{ .r = 0, .g = 0, .b = 0 }));
}

test "the 16-colour escape uses the classic bright codes, not 38;5" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("\x1b[91m", fgSgr(&buf, .{ .r = 255, .g = 120, .b = 120 }, .ansi16));
    try std.testing.expectEqualStrings("\x1b[31m", fgSgr(&buf, .{ .r = 180, .g = 0, .b = 0 }, .ansi16));
    try std.testing.expectEqualStrings("\x1b[42m", bgSgr(&buf, .{ .r = 0, .g = 255, .b = 0 }, .ansi16));
    try std.testing.expectEqualStrings("\x1b[38;5;196m", fgSgr(&buf, .{ .r = 255, .g = 0, .b = 0 }, .ansi256));
}
