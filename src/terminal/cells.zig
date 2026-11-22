//! The CPU tier: the same render commands, painted into a character grid a terminal can print.
const std = @import("std");
const cl = @import("zclay");
const term = @import("term.zig");

/// One colour, 8 bits a channel, in the order a terminal escape wants it.
pub const Color = struct {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
    a: u8 = 255,

    pub const default_fg = Color{ .r = 216, .g = 216, .b = 216 };
    pub const default_bg = Color{ .r = 17, .g = 17, .b = 17 };

    /// Mix this colour over `under`, honouring alpha: a translucent panel keeps the text behind it readable.
    pub fn over(self: Color, under: Color) Color {
        if (self.a >= 255) return self;
        if (self.a == 0) return under;
        const a: u32 = self.a;
        const inv: u32 = 255 - a;
        return .{
            .r = @intCast((@as(u32, self.r) * a + @as(u32, under.r) * inv) / 255),
            .g = @intCast((@as(u32, self.g) * a + @as(u32, under.g) * inv) / 255),
            .b = @intCast((@as(u32, self.b) * a + @as(u32, under.b) * inv) / 255),
            .a = 255,
        };
    }

    pub fn eql(a: Color, b: Color) bool {
        return a.r == b.r and a.g == b.g and a.b == b.b;
    }
};

/// One cell: what to print, in what colour, on what background. `cont` marks the right half of a double-width glyph.
pub const Cell = struct {
    ch: u21 = ' ',
    fg: Color = Color.default_fg,
    bg: Color = Color.default_bg,
    cont: bool = false,

    pub fn eql(a: Cell, b: Cell) bool {
        return a.ch == b.ch and a.cont == b.cont and a.fg.eql(b.fg) and a.bg.eql(b.bg);
    }
};

/// A half-open cell rectangle.
pub const Rect = struct {
    x0: i32,
    y0: i32,
    x1: i32,
    y1: i32,

    fn empty(self: Rect) bool {
        return self.x1 <= self.x0 or self.y1 <= self.y0;
    }

    fn intersect(a: Rect, b: Rect) Rect {
        return .{ .x0 = @max(a.x0, b.x0), .y0 = @max(a.y0, b.y0), .x1 = @min(a.x1, b.x1), .y1 = @min(a.y1, b.y1) };
    }
};

/// A Clay colour (0-1 or 0-255, both appear in the tree) to a byte channel.
pub fn fromClay(c: [4]f32) Color {
    const mx = @max(@max(c[0], c[1]), @max(c[2], c[3]));
    if (mx <= 1.0 and mx > 0) {
        return .{
            .r = chan(c[0] * 255.0),
            .g = chan(c[1] * 255.0),
            .b = chan(c[2] * 255.0),
            .a = chan(c[3] * 255.0),
        };
    }
    return .{ .r = chan(c[0]), .g = chan(c[1]), .b = chan(c[2]), .a = chan(c[3]) };
}

fn chan(v: f32) u8 {
    const s = @round(v);
    if (s <= 0) return 0;
    if (s >= 255) return 255;
    return @intFromFloat(s);
}

/// A double-width codepoint: CJK, Hangul, kana and emoji each take two cells on a terminal.
pub fn isWide(cp: u21) bool {
    return (cp >= 0x1100 and cp <= 0x115F) or
        (cp >= 0x2E80 and cp <= 0xA4CF) or
        (cp >= 0xAC00 and cp <= 0xD7A3) or
        (cp >= 0xF900 and cp <= 0xFAFF) or
        (cp >= 0xFE30 and cp <= 0xFE6F) or
        (cp >= 0xFF00 and cp <= 0xFF60) or
        (cp >= 0xFFE0 and cp <= 0xFFE6) or
        (cp >= 0x1F300 and cp <= 0x1FAFF) or
        (cp >= 0x20000 and cp <= 0x3FFFD);
}

/// The box-drawing character for a corner, chosen from which edges meet there.
fn corner(left: bool, right: bool, top: bool, bottom: bool) u21 {
    if (top and left) return 0x250C;
    if (top and right) return 0x2510;
    if (bottom and left) return 0x2514;
    if (bottom and right) return 0x2518;
    if (top or bottom) return 0x2500;
    return 0x2502;
}

/// The character grid: cols x rows cells, plus the clip stack a frame's scissors need.
pub const Grid = struct {
    alloc: std.mem.Allocator,
    cols: u16 = 0,
    rows: u16 = 0,
    cells: []Cell = &.{},
    clip: Rect = .{ .x0 = 0, .y0 = 0, .x1 = 0, .y1 = 0 },
    clip_stack: [32]Rect = undefined,
    clip_depth: usize = 0,

    pub fn init(alloc: std.mem.Allocator, cols: u16, rows: u16) !Grid {
        var g = Grid{ .alloc = alloc };
        try g.resize(cols, rows);
        return g;
    }

    pub fn deinit(self: *Grid) void {
        if (self.cells.len != 0) self.alloc.free(self.cells);
        self.cells = &.{};
        self.cols = 0;
        self.rows = 0;
    }

    /// Point the grid at a terminal size, clearing it; a same-size resize keeps nothing, because a repaint always follows.
    pub fn resize(self: *Grid, cols: u16, rows: u16) !void {
        const c: u16 = if (cols == 0) 80 else cols;
        const r: u16 = if (rows == 0) 24 else rows;
        if (c == self.cols and r == self.rows and self.cells.len != 0) return;
        if (self.cells.len != 0) self.alloc.free(self.cells);
        self.cells = try self.alloc.alloc(Cell, @as(usize, c) * r);
        self.cols = c;
        self.rows = r;
        self.clear(Color.default_bg);
    }

    /// Every cell back to a blank, with the terminal's own background.
    pub fn clear(self: *Grid, bg: Color) void {
        for (self.cells) |*cell| cell.* = .{ .bg = bg };
        self.clip = .{ .x0 = 0, .y0 = 0, .x1 = self.cols, .y1 = self.rows };
        self.clip_depth = 0;
    }

    pub fn at(self: *Grid, col: i32, row: i32) ?*Cell {
        if (col < 0 or row < 0 or col >= self.cols or row >= self.rows) return null;
        return &self.cells[@as(usize, @intCast(row)) * self.cols + @as(usize, @intCast(col))];
    }

    fn cellRect(self: *const Grid, bb: cl.BoundingBox) Rect {
        _ = self;
        const x0 = term.colOf(bb.x);
        const y0 = term.rowOf(bb.y);
        const x1 = term.colOf(bb.x + @max(bb.width, 0));
        const y1 = term.rowOf(bb.y + @max(bb.height, 0));
        // A rect that ends exactly on a cell boundary does not touch the next cell.
        const ex1 = if (x1 > x0) x1 else x0 + 1;
        const ey1 = if (y1 > y0) y1 else y0 + 1;
        return .{ .x0 = x0, .y0 = y0, .x1 = ex1, .y1 = ey1 };
    }

    /// Paint a frame's commands, in order: the last command to touch a cell wins, exactly as on the GPU path.
    pub fn render(self: *Grid, commands: []const cl.RenderCommand, w: i32, h: i32) void {
        _ = w;
        _ = h;
        self.clip = .{ .x0 = 0, .y0 = 0, .x1 = self.cols, .y1 = self.rows };
        self.clip_depth = 0;
        for (commands) |cmd| {
            switch (cmd.command_type) {
                .rectangle => self.fill(cmd.bounding_box, fromClay(cmd.render_data.rectangle.background_color)),
                .border => self.stroke(cmd.bounding_box, fromClay(cmd.render_data.border.color)),
                .text => {
                    const t = cmd.render_data.text;
                    const bytes = t.string_contents.chars[0..@intCast(t.string_contents.length)];
                    self.text(cmd.bounding_box, bytes, fromClay(t.text_color));
                },
                .image => self.image(cmd.bounding_box),
                .scissor_start => self.pushClip(cmd.bounding_box),
                .scissor_end => self.popClip(),
                else => {},
            }
        }
        self.clip_depth = 0;
        self.clip = .{ .x0 = 0, .y0 = 0, .x1 = self.cols, .y1 = self.rows };
    }

    fn pushClip(self: *Grid, bb: cl.BoundingBox) void {
        if (self.clip_depth < self.clip_stack.len) {
            self.clip_stack[self.clip_depth] = self.clip;
            self.clip_depth += 1;
        }
        self.clip = self.clip.intersect(self.cellRect(bb));
    }

    fn popClip(self: *Grid) void {
        if (self.clip_depth == 0) return;
        self.clip_depth -= 1;
        self.clip = self.clip_stack[self.clip_depth];
    }

    fn fill(self: *Grid, bb: cl.BoundingBox, color: Color) void {
        if (color.a == 0) return;
        const r = self.cellRect(bb).intersect(self.clip);
        if (r.empty()) return;
        var row = r.y0;
        while (row < r.y1) : (row += 1) {
            var col = r.x0;
            while (col < r.x1) : (col += 1) {
                const cell = self.at(col, row) orelse continue;
                cell.bg = color.over(cell.bg);
            }
        }
    }

    fn stroke(self: *Grid, bb: cl.BoundingBox, color: Color) void {
        if (color.a == 0) return;
        const r = self.cellRect(bb).intersect(self.clip);
        if (r.empty()) return;
        const top = r.y0;
        const bottom = r.y1 - 1;
        const left = r.x0;
        const right = r.x1 - 1;
        var col = left;
        while (col <= right) : (col += 1) {
            self.glyph(col, top, corner(col == left, col == right, true, top == bottom), color);
            self.glyph(col, bottom, corner(col == left, col == right, false, true), color);
        }
        var row = top + 1;
        while (row < bottom) : (row += 1) {
            self.glyph(left, row, 0x2502, color);
            self.glyph(right, row, 0x2502, color);
        }
    }

    fn glyph(self: *Grid, col: i32, row: i32, cp: u21, color: Color) void {
        const cell = self.at(col, row) orelse return;
        cell.ch = cp;
        cell.fg = color;
        cell.cont = false;
    }

    fn text(self: *Grid, bb: cl.BoundingBox, bytes: []const u8, color: Color) void {
        if (bytes.len == 0) return;
        const row = term.rowOf(bb.y + bb.height * 0.5);
        if (row < self.clip.y0 or row >= self.clip.y1) return;
        var col = term.colOf(bb.x);
        var i: usize = 0;
        while (i < bytes.len) {
            const cp = nextCodepoint(bytes, &i);
            if (cp == '\n' or cp == '\r') continue;
            const wide = isWide(cp);
            if (col >= self.clip.x1) break;
            if (col >= self.clip.x0) {
                if (self.at(col, row)) |cell| {
                    cell.ch = cp;
                    cell.fg = color;
                    cell.cont = false;
                }
                if (wide) {
                    if (self.at(col + 1, row)) |next| {
                        next.ch = ' ';
                        next.cont = true;
                    }
                }
            }
            col += if (wide) 2 else 1;
        }
    }

    fn image(self: *Grid, bb: cl.BoundingBox) void {
        // A raster has no cell form, so an image becomes a shaded block: the layout it occupies stays visible.
        const r = self.cellRect(bb).intersect(self.clip);
        if (r.empty()) return;
        var row = r.y0;
        while (row < r.y1) : (row += 1) {
            var col = r.x0;
            while (col < r.x1) : (col += 1) {
                const cell = self.at(col, row) orelse continue;
                cell.ch = 0x2592;
                cell.fg = Color{ .r = 120, .g = 120, .b = 120 };
                cell.cont = false;
            }
        }
    }

    /// One row as text, trailing blanks trimmed: what a golden frame is compared against.
    pub fn rowText(self: *const Grid, row: u16, alloc: std.mem.Allocator) ![]u8 {
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(alloc);
        var col: u16 = 0;
        while (col < self.cols) : (col += 1) {
            const cell = &self.cells[@as(usize, row) * self.cols + col];
            if (cell.cont) continue;
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(cell.ch, &buf) catch {
                try out.append(alloc, '?');
                continue;
            };
            try out.appendSlice(alloc, buf[0..n]);
        }
        while (out.items.len != 0 and out.items[out.items.len - 1] == ' ') _ = out.pop();
        return out.toOwnedSlice(alloc);
    }

    /// The whole grid as text, one line per row: a frame a test can assert on.
    pub fn toText(self: *const Grid, alloc: std.mem.Allocator) ![]u8 {
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(alloc);
        var row: u16 = 0;
        while (row < self.rows) : (row += 1) {
            const line = try self.rowText(row, alloc);
            defer alloc.free(line);
            try out.appendSlice(alloc, line);
            try out.append(alloc, '\n');
        }
        return out.toOwnedSlice(alloc);
    }

    /// Adopt another grid's contents wholesale: the emitter compares against this, so the copy must be exact.
    pub fn copyFrom(self: *Grid, src: *const Grid) void {
        if (self.cols != src.cols or self.rows != src.rows) {
            self.resize(src.cols, src.rows) catch return;
        }
        @memcpy(self.cells, src.cells);
        self.clip = src.clip;
        self.clip_depth = src.clip_depth;
        @memcpy(self.clip_stack[0..src.clip_depth], src.clip_stack[0..src.clip_depth]);
    }

    /// How many cells differ: a frame that changed nothing costs nothing to emit.
    pub fn changedCells(self: *const Grid, prev: *const Grid) usize {
        if (prev.cols != self.cols or prev.rows != self.rows) return self.cells.len;
        var n: usize = 0;
        for (self.cells, prev.cells) |a, b| {
            if (!a.eql(b)) n += 1;
        }
        return n;
    }
};

/// The next codepoint of a UTF-8 run, replacing a broken one with '?' rather than failing a frame.
pub fn nextCodepoint(bytes: []const u8, i: *usize) u21 {
    const b = bytes[i.*];
    if (b < 0x80) {
        i.* += 1;
        return b;
    }
    const n = std.unicode.utf8ByteSequenceLength(b) catch {
        i.* += 1;
        return '?';
    };
    if (i.* + n > bytes.len) {
        i.* = bytes.len;
        return '?';
    }
    const cp = std.unicode.utf8Decode(bytes[i.* .. i.* + n]) catch {
        i.* += n;
        return '?';
    };
    i.* += n;
    return cp;
}

// ===================== tests =====================

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

fn borderCmd(x: f32, y: f32, w: f32, h: f32, color: [4]f32) cl.RenderCommand {
    return .{
        .bounding_box = .{ .x = x, .y = y, .width = w, .height = h },
        .render_data = .{ .border = .{ .color = color, .corner_radius = .{}, .width = .outside(1) } },
        .user_data = null,
        .id = 0,
        .z_index = 0,
        .command_type = .border,
    };
}

fn textCmd(x: f32, y: f32, w: f32, h: f32, s: []const u8, color: [4]f32) cl.RenderCommand {
    return .{
        .bounding_box = .{ .x = x, .y = y, .width = w, .height = h },
        .render_data = .{ .text = .{
            .string_contents = .{ .chars = s.ptr, .base_chars = s.ptr, .length = @intCast(s.len) },
            .text_color = color,
            .font_id = 0,
            .font_size = 14,
            .letter_spacing = 0,
            .line_height = 16,
        } },
        .user_data = null,
        .id = 0,
        .z_index = 0,
        .command_type = .text,
    };
}

test "a background rect fills whole cells, and the last fill wins" {
    var g = try Grid.init(std.testing.allocator, 10, 4);
    defer g.deinit();
    var cmds = [_]cl.RenderCommand{
        rectCmd(0, 0, 80, 64, .{ 10, 10, 10, 255 }),
        rectCmd(0, 0, 8, 16, .{ 200, 30, 30, 255 }),
    };
    g.render(&cmds, 80, 64);
    try std.testing.expectEqual(@as(u8, 200), g.at(0, 0).?.bg.r);
    try std.testing.expectEqual(@as(u8, 10), g.at(1, 0).?.bg.r);
    try std.testing.expectEqual(@as(u8, 10), g.at(0, 3).?.bg.r);
}

test "a half-covered cell is painted, because a cell is the smallest thing a terminal has" {
    var g = try Grid.init(std.testing.allocator, 10, 4);
    defer g.deinit();
    var cmds = [_]cl.RenderCommand{rectCmd(4, 4, 4, 4, .{ 1, 2, 3, 255 })};
    g.render(&cmds, 80, 64);
    try std.testing.expectEqual(@as(u8, 1), g.at(0, 0).?.bg.r);
}

test "text lands on the row its box centres on, one cell per glyph" {
    var g = try Grid.init(std.testing.allocator, 20, 4);
    defer g.deinit();
    var cmds = [_]cl.RenderCommand{textCmd(16, 0, 40, 16, "Hello", .{ 255, 255, 255, 255 })};
    g.render(&cmds, 160, 64);
    const line = try g.rowText(0, std.testing.allocator);
    defer std.testing.allocator.free(line);
    try std.testing.expectEqualStrings("  Hello", line);
}

test "a double-width glyph claims two cells and marks the second as a continuation" {
    var g = try Grid.init(std.testing.allocator, 10, 2);
    defer g.deinit();
    var cmds = [_]cl.RenderCommand{textCmd(0, 0, 16, 16, "漢x", .{ 255, 255, 255, 255 })};
    g.render(&cmds, 80, 32);
    try std.testing.expectEqual(@as(u21, 0x6F22), g.at(0, 0).?.ch);
    try std.testing.expect(g.at(1, 0).?.cont);
    try std.testing.expectEqual(@as(u21, 'x'), g.at(2, 0).?.ch);
}

test "a border is drawn with box-drawing characters, corners included" {
    var g = try Grid.init(std.testing.allocator, 10, 4);
    defer g.deinit();
    var cmds = [_]cl.RenderCommand{borderCmd(8, 16, 32, 48, .{ 90, 90, 90, 255 })};
    g.render(&cmds, 80, 64);
    try std.testing.expectEqual(@as(u21, 0x250C), g.at(1, 1).?.ch);
    try std.testing.expectEqual(@as(u21, 0x2510), g.at(4, 1).?.ch);
    try std.testing.expectEqual(@as(u21, 0x2500), g.at(2, 1).?.ch);
    try std.testing.expectEqual(@as(u21, 0x2514), g.at(1, 3).?.ch);
    try std.testing.expectEqual(@as(u21, 0x2502), g.at(1, 2).?.ch);
}

test "a scissor hides every cell it excludes, and the pop restores the rest" {
    var g = try Grid.init(std.testing.allocator, 10, 4);
    defer g.deinit();
    var cmds = [_]cl.RenderCommand{
        rectCmd(0, 0, 80, 64, .{ 5, 5, 5, 255 }),
        .{
            .bounding_box = .{ .x = 0, .y = 0, .width = 16, .height = 16 },
            .render_data = .{ .scroll = .{ .horizontal = true, .vertical = true } },
            .user_data = null,
            .id = 0,
            .z_index = 0,
            .command_type = .scissor_start,
        },
        rectCmd(0, 0, 80, 64, .{ 250, 0, 0, 255 }),
        .{
            .bounding_box = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
            .render_data = .{ .scroll = .{ .horizontal = true, .vertical = true } },
            .user_data = null,
            .id = 0,
            .z_index = 0,
            .command_type = .scissor_end,
        },
        rectCmd(0, 32, 80, 16, .{ 0, 250, 0, 255 }),
    };
    g.render(&cmds, 80, 64);
    try std.testing.expectEqual(@as(u8, 250), g.at(1, 0).?.bg.r);
    try std.testing.expectEqual(@as(u8, 5), g.at(3, 0).?.bg.r);
    try std.testing.expectEqual(@as(u8, 250), g.at(3, 2).?.bg.g);
}

test "an identical frame reports no changed cell, a single recolour reports one" {
    var a = try Grid.init(std.testing.allocator, 10, 4);
    defer a.deinit();
    var b = try Grid.init(std.testing.allocator, 10, 4);
    defer b.deinit();
    var cmds = [_]cl.RenderCommand{rectCmd(0, 0, 80, 64, .{ 5, 5, 5, 255 })};
    a.render(&cmds, 80, 64);
    b.render(&cmds, 80, 64);
    try std.testing.expectEqual(@as(usize, 0), a.changedCells(&b));
    b.at(2, 1).?.bg = .{ .r = 9, .g = 9, .b = 9 };
    try std.testing.expectEqual(@as(usize, 1), a.changedCells(&b));
}

test "a translucent panel blends over what was behind it" {
    var g = try Grid.init(std.testing.allocator, 4, 2);
    defer g.deinit();
    var cmds = [_]cl.RenderCommand{
        rectCmd(0, 0, 32, 32, .{ 0, 0, 0, 255 }),
        rectCmd(0, 0, 32, 32, .{ 255, 255, 255, 128 }),
    };
    g.render(&cmds, 32, 32);
    try std.testing.expectApproxEqAbs(@as(f32, 128), @as(f32, @floatFromInt(g.at(0, 0).?.bg.r)), 2);
}

test "an image has no cell form, so it becomes a shaded block that still shows where it is" {
    var g = try Grid.init(std.testing.allocator, 6, 3);
    defer g.deinit();
    const ref = @import("../core/render_common.zig").ImageRef{
        .path_ptr = "x",
        .path_len = 1,
    };
    var cmds = [_]cl.RenderCommand{.{
        .bounding_box = .{ .x = 0, .y = 0, .width = 16, .height = 16 },
        .render_data = .{ .image = .{ .image_data = @ptrCast(@constCast(&ref)), .background_color = .{ 0, 0, 0, 255 }, .corner_radius = .{} } },
        .user_data = null,
        .id = 0,
        .z_index = 0,
        .command_type = .image,
    }};
    g.render(&cmds, 48, 48);
    try std.testing.expectEqual(@as(u21, 0x2592), g.at(0, 0).?.ch);
}

test "a broken UTF-8 byte becomes a question mark instead of failing the frame" {
    var i: usize = 0;
    const bytes = [_]u8{ 0x41, 0xFF, 0x42 };
    try std.testing.expectEqual(@as(u21, 'A'), nextCodepoint(&bytes, &i));
    try std.testing.expectEqual(@as(u21, '?'), nextCodepoint(&bytes, &i));
    try std.testing.expectEqual(@as(u21, 'B'), nextCodepoint(&bytes, &i));
}
