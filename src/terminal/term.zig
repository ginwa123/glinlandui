//! Terminal facts: how big the cell grid is, what the terminal can paint, and how many colours it has.
const std = @import("std");

/// One cell in layout points: 8x16, so a frame declared in points always lands on whole cells.
pub const cell_w: u16 = 8;
pub const cell_h: u16 = 16;

/// The terminal's geometry: character cells, plus the pixel size when the kernel reports one (often it does not).
pub const Size = struct {
    cols: u16 = 80,
    rows: u16 = 24,
    px_w: u16 = 0,
    px_h: u16 = 0,
};

/// What the backend can paint with: a pixel protocol, or the cell grid it falls back to.
pub const Mode = enum { kitty, sixel, cells };

/// How many colours the escape stream may use.
pub const Depth = enum { truecolor, ansi256, ansi16 };

/// Environment lookup, taken as a value so detection is a pure function a test can drive.
pub const Getter = struct {
    ctx: ?*const anyopaque = null,
    get: *const fn (?*const anyopaque, name: []const u8) ?[]const u8,
};

/// The process environment through libc, the one lookup every platform of this backend shares.
pub fn libcEnv() Getter {
    return .{ .get = struct {
        fn get(_: ?*const anyopaque, name: []const u8) ?[]const u8 {
            var buf: [64]u8 = undefined;
            if (name.len >= buf.len) return null;
            @memcpy(buf[0..name.len], name);
            buf[name.len] = 0;
            const v = std.c.getenv(buf[0..name.len :0]) orelse return null;
            const s = std.mem.span(v);
            return if (s.len == 0) null else s;
        }
    }.get };
}

/// The layout width in points for a terminal of `cols` cells.
pub fn layoutWidth(cols: u16) u32 {
    return @as(u32, if (cols == 0) 80 else cols) * cell_w;
}

/// The layout height in points for a terminal of `rows` cells.
pub fn layoutHeight(rows: u16) u32 {
    return @as(u32, if (rows == 0) 24 else rows) * cell_h;
}

/// The terminal size the kernel reports through TIOCGWINSZ, or null when it is unusable.
pub fn sizeFromWinsize(row: u16, col: u16, xpixel: u16, ypixel: u16) ?Size {
    if (row == 0 or col == 0) return null;
    return .{ .cols = col, .rows = row, .px_w = xpixel, .px_h = ypixel };
}

/// The size a headless run reports to the layer above: the caller's cells, never zero.
pub fn sanitise(src: Size) Size {
    var out = src;
    if (out.cols == 0) out.cols = 80;
    if (out.rows == 0) out.rows = 24;
    return out;
}

/// The cell column a point falls in.
pub fn colOf(x: f32) i32 {
    const c = @floor(x / @as(f32, @floatFromInt(cell_w)));
    return @intFromFloat(c);
}

/// The cell row a point falls in.
pub fn rowOf(y: f32) i32 {
    const r = @floor(y / @as(f32, @floatFromInt(cell_h)));
    return @intFromFloat(r);
}

/// The x of a cell's left edge, in points.
pub fn colX(col: i32) f32 {
    return @as(f32, @floatFromInt(col)) * @as(f32, @floatFromInt(cell_w));
}

/// The y of a cell's top edge, in points.
pub fn rowY(row: i32) f32 {
    return @as(f32, @floatFromInt(row)) * @as(f32, @floatFromInt(cell_h));
}

fn has(env: Getter, name: []const u8) bool {
    return env.get(env.ctx, name) != null;
}

fn contains(env: Getter, name: []const u8, needle: []const u8) bool {
    const v = env.get(env.ctx, name) orelse return false;
    return std.mem.indexOf(u8, v, needle) != null;
}

fn eql(env: Getter, name: []const u8, want: []const u8) bool {
    const v = env.get(env.ctx, name) orelse return false;
    return std.mem.eql(u8, v, want);
}

/// The renderer the user asked for by name (`GLIN_TUI_RENDERER`), or null for auto.
pub fn request(env: Getter) ?Mode {
    const v = env.get(env.ctx, "GLIN_TUI_RENDERER") orelse return null;
    if (std.mem.eql(u8, v, "cells") or std.mem.eql(u8, v, "cpu")) return .cells;
    if (std.mem.eql(u8, v, "kitty")) return .kitty;
    if (std.mem.eql(u8, v, "sixel")) return .sixel;
    return null;
}

/// Whether any pixel protocol is available. Detection is by environment because a DA1 round trip needs raw mode and a deadline.
pub fn detectMode(env: Getter) Mode {
    if (request(env)) |m| return m;
    // Kitkat first: a kitty-protocol terminal draws an opaque RGBA surface with no palette, so it is the least lossy tier.
    if (has(env, "KITTY_WINDOW_ID")) return .kitty;
    if (contains(env, "TERM", "kitty")) return .kitty;
    if (eql(env, "TERM_PROGRAM", "ghostty")) return .kitty;
    if (eql(env, "TERM_PROGRAM", "WezTerm")) return .kitty;
    if (eql(env, "TERM_PROGRAM", "wezterm")) return .kitty;
    if (contains(env, "TERM_PROGRAM", "Ghostty")) return .kitty;
    // Sixel second: a palette, no alpha, but real pixels and real anti-aliasing.
    if (contains(env, "TERM", "sixel")) return .sixel;
    if (contains(env, "TERM", "foot")) return .sixel;
    if (contains(env, "TERM", "mlterm")) return .sixel;
    if (contains(env, "TERM", "contour")) return .sixel;
    if (contains(env, "TERM", "yaft")) return .sixel;
    if (eql(env, "TERM_PROGRAM", "iTerm.app")) return .sixel;
    if (eql(env, "LC_TERMINAL", "iTerm2")) return .sixel;
    // Everything else, including a pipe and a dumb terminal: the CPU cell grid, which needs no capability at all.
    return .cells;
}

/// The colour depth the escape stream may use.
pub fn detectDepth(env: Getter) Depth {
    if (contains(env, "COLORTERM", "truecolor") or contains(env, "COLORTERM", "24bit")) return .truecolor;
    if (contains(env, "TERM", "direct") or contains(env, "TERM", "truecolor")) return .truecolor;
    if (contains(env, "TERM", "256") or contains(env, "TERM", "kitty")) return .ansi256;
    if (has(env, "NO_COLOR")) return .ansi16;
    if (contains(env, "TERM", "xterm")) return .ansi256;
    return .ansi16;
}

/// Everything the backend needs from the environment, resolved once at startup.
pub const Plan = struct {
    mode: Mode,
    depth: Depth,
};

/// Resolve the plan: the requested renderer, else the detected one, with the depth it may use.
pub fn plan(env: Getter) Plan {
    return .{ .mode = detectMode(env), .depth = detectDepth(env) };
}

// ===================== tests =====================

const Fake = struct {
    const Entry = struct { name: []const u8, value: []const u8 };
    const Map = struct { entries: []const Entry };
    fn get(ctx: ?*const anyopaque, name: []const u8) ?[]const u8 {
        const map: *const Map = @ptrCast(@alignCast(ctx.?));
        for (map.entries) |e| {
            if (std.mem.eql(u8, e.name, name)) return e.value;
            // A case-insensitive match for TERM_PROGRAM, which different terminals capitalise differently.
            if (std.ascii.eqlIgnoreCase(e.name, name)) return e.value;
        }
        return null;
    }
    fn env(map: *const Map) Getter {
        return .{ .ctx = map, .get = get };
    }
};

test "a terminal with no capability at all gets the CPU cell grid" {
    const m = Fake.Map{ .entries = &.{.{ .name = "TERM", .value = "dumb" }} };
    try std.testing.expectEqual(Mode.cells, detectMode(Fake.env(&m)));
    try std.testing.expectEqual(Depth.ansi16, detectDepth(Fake.env(&m)));
}

test "kitty is detected from its window id, its TERM and the terminal programs that speak it" {
    const by_id = Fake.Map{ .entries = &.{.{ .name = "KITTY_WINDOW_ID", .value = "3" }} };
    try std.testing.expectEqual(Mode.kitty, detectMode(Fake.env(&by_id)));
    const by_term = Fake.Map{ .entries = &.{.{ .name = "TERM", .value = "xterm-kitty" }} };
    try std.testing.expectEqual(Mode.kitty, detectMode(Fake.env(&by_term)));
    const ghostty = Fake.Map{ .entries = &.{.{ .name = "TERM_PROGRAM", .value = "ghostty" }} };
    try std.testing.expectEqual(Mode.kitty, detectMode(Fake.env(&ghostty)));
}

test "sixel is detected from foot, mlterm, xterm-sixel and iTerm2" {
    const foot = Fake.Map{ .entries = &.{.{ .name = "TERM", .value = "foot-extra" }} };
    try std.testing.expectEqual(Mode.sixel, detectMode(Fake.env(&foot)));
    const mlterm = Fake.Map{ .entries = &.{.{ .name = "TERM", .value = "mlterm" }} };
    try std.testing.expectEqual(Mode.sixel, detectMode(Fake.env(&mlterm)));
    const sixel = Fake.Map{ .entries = &.{.{ .name = "TERM", .value = "xterm-sixel" }} };
    try std.testing.expectEqual(Mode.sixel, detectMode(Fake.env(&sixel)));
    const iterm = Fake.Map{ .entries = &.{.{ .name = "TERM_PROGRAM", .value = "iTerm.app" }} };
    try std.testing.expectEqual(Mode.sixel, detectMode(Fake.env(&iterm)));
}

test "an explicit request beats detection, and an unknown one means auto" {
    const iterm = Fake.Map{ .entries = &.{
        .{ .name = "TERM_PROGRAM", .value = "iTerm.app" },
        .{ .name = "GLIN_TUI_RENDERER", .value = "cells" },
    } };
    try std.testing.expectEqual(Mode.cells, detectMode(Fake.env(&iterm)));
    const forced = Fake.Map{ .entries = &.{
        .{ .name = "TERM", .value = "dumb" },
        .{ .name = "GLIN_TUI_RENDERER", .value = "sixel" },
    } };
    try std.testing.expectEqual(Mode.sixel, detectMode(Fake.env(&forced)));
    const junk = Fake.Map{ .entries = &.{
        .{ .name = "GLIN_TUI_RENDERER", .value = "quantum" },
        .{ .name = "KITTY_WINDOW_ID", .value = "1" },
    } };
    try std.testing.expectEqual(Mode.kitty, detectMode(Fake.env(&junk)));
}

test "depth follows COLORTERM, then TERM, and the fallback is the 16-colour palette" {
    const tc = Fake.Map{ .entries = &.{.{ .name = "COLORTERM", .value = "truecolor" }} };
    try std.testing.expectEqual(Depth.truecolor, detectDepth(Fake.env(&tc)));
    const c256 = Fake.Map{ .entries = &.{.{ .name = "TERM", .value = "xterm-256color" }} };
    try std.testing.expectEqual(Depth.ansi256, detectDepth(Fake.env(&c256)));
    const direct = Fake.Map{ .entries = &.{.{ .name = "TERM", .value = "xterm-direct" }} };
    try std.testing.expectEqual(Depth.truecolor, detectDepth(Fake.env(&direct)));
    const plain = Fake.Map{ .entries = &.{.{ .name = "TERM", .value = "vt100" }} };
    try std.testing.expectEqual(Depth.ansi16, detectDepth(Fake.env(&plain)));
}

test "winsize parsing rejects an empty size and keeps the pixel box when present" {
    try std.testing.expectEqual(@as(?Size, null), sizeFromWinsize(0, 80, 0, 0));
    try std.testing.expectEqual(@as(?Size, null), sizeFromWinsize(24, 0, 0, 0));
    const s = sizeFromWinsize(30, 90, 900, 480).?;
    try std.testing.expectEqual(@as(u16, 90), s.cols);
    try std.testing.expectEqual(@as(u16, 30), s.rows);
    try std.testing.expectEqual(@as(u16, 900), s.px_w);
}

test "a 90x30 terminal lays out at 720x480 points, the canonical design size" {
    try std.testing.expectEqual(@as(u32, 720), layoutWidth(90));
    try std.testing.expectEqual(@as(u32, 480), layoutHeight(30));
    // A zero size can only ever mean "unset", never a zero-point frame.
    try std.testing.expectEqual(@as(u32, 640), layoutWidth(0));
    try std.testing.expectEqual(@as(u32, 384), layoutHeight(0));
}

test "points map back to the cell that contains them" {
    try std.testing.expectEqual(@as(i32, 0), colOf(0));
    try std.testing.expectEqual(@as(i32, 0), colOf(7.9));
    try std.testing.expectEqual(@as(i32, 1), colOf(8));
    try std.testing.expectEqual(@as(i32, 0), rowOf(15.9));
    try std.testing.expectEqual(@as(i32, 1), rowOf(16));
    try std.testing.expectEqual(@as(f32, 24), colX(3));
    try std.testing.expectEqual(@as(f32, 48), rowY(3));
}

test "sanitise turns an unset size into the 80x24 default" {
    const s = sanitise(.{ .cols = 0, .rows = 0 });
    try std.testing.expectEqual(@as(u16, 80), s.cols);
    try std.testing.expectEqual(@as(u16, 24), s.rows);
}
