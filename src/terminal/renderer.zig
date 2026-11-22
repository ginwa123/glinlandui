//! The terminal renderer: the same `init`/`deinit`/`drawCommands` contract as every other backend, graphics first and CPU cells as the fallback.
const std = @import("std");
const cl = @import("zclay");
const soft = @import("../core/render_software.zig");
const term = @import("term.zig");
const cells = @import("cells.zig");
const ansi = @import("ansi.zig");
const sixel = @import("sixel.zig");
const kitty = @import("kitty.zig");

/// Where the escape stream goes: the terminal's stdin/stdout, a console handle, or a buffer in a test.
pub const Sink = struct {
    ctx: ?*anyopaque = null,
    write: *const fn (?*anyopaque, []const u8) void,
};

/// What the window publishes before the first frame, because `Renderer.init` only runs on that first frame.
pub const Attach = struct {
    sink: Sink = .{ .write = discard },
    cols: u16 = 80,
    rows: u16 = 24,
    mode: term.Mode = .cells,
    depth: term.Depth = .ansi256,
};

fn discard(_: ?*anyopaque, _: []const u8) void {}

var pending: ?Attach = null;

/// Publish the terminal this process opened. Called by the window before it drives a frame.
pub fn attach(a: Attach) void {
    pending = a;
}

/// Keep the most recent frame as text, so a headless run (and a test) can read what was painted.
var last_text: []const u8 = &.{};

/// The last frame the renderer produced, as one line per row. Owned by this module until the next frame.
pub fn lastFrameText() []const u8 {
    return last_text;
}

/// Release the frame text; a process that ran headless uses this before it exits.
pub fn deinitFrameText(alloc: std.mem.Allocator) void {
    if (last_text.len != 0) alloc.free(@constCast(last_text));
    last_text = &.{};
}

/// A cheap identity for a command list: enough to skip re-encoding a frame that draws exactly the same thing.
fn digest(commands: []const cl.RenderCommand) u64 {
    var h = std.hash.Wyhash.init(0);
    for (commands) |cmd| {
        const kind: u32 = @intFromEnum(cmd.command_type);
        h.update(std.mem.asBytes(&kind));
        h.update(std.mem.asBytes(&cmd.bounding_box));
        if (cmd.command_type == .text) {
            const n: u32 = @intCast(cmd.render_data.text.string_contents.length);
            h.update(std.mem.asBytes(&n));
        }
    }
    return h.final();
}

/// The terminal backend's renderer: a cell grid when that is all the terminal can do, real pixels when it can draw them.
pub const Renderer = struct {
    alloc: std.mem.Allocator,
    sink: Sink,
    /// The tier that is actually in use: a failed encode leaves this at `cells`, never at a broken graphics mode.
    mode: term.Mode,
    /// The tier this terminal asked for, kept for the diagnostic line and for a retry after a resize.
    want: term.Mode,
    depth: term.Depth,
    grid: cells.Grid,
    prev: cells.Grid,
    surface: ?soft.Surface = null,
    out: std.ArrayList(u8) = .empty,
    image_id: u32 = 1,
    frames: u32 = 0,
    have_digest: bool = false,
    last_digest: u64 = 0,
    err: []const u8 = "",

    pub fn init(alloc: std.mem.Allocator) !Renderer {
        const a = pending orelse Attach{ .mode = term.detectMode(term.libcEnv()), .depth = term.detectDepth(term.libcEnv()) };
        // A graphics tier needs a surface, and a surface needs an allocator: any doubt lands on the cell grid, which always works.
        const mode: term.Mode = a.mode;
        var self = Renderer{
            .alloc = alloc,
            .sink = a.sink,
            .mode = mode,
            .want = mode,
            .depth = a.depth,
            .grid = try cells.Grid.init(alloc, a.cols, a.rows),
            .prev = try cells.Grid.init(alloc, a.cols, a.rows),
        };
        errdefer self.deinit();
        // Cells are pixels here: a terminal has no display scale to apply.
        soft.setRenderScale(1.0);
        return self;
    }

    pub fn deinit(self: *Renderer) void {
        deinitFrameText(self.alloc);
        self.grid.deinit();
        self.prev.deinit();
        self.out.deinit(self.alloc);
        if (self.surface) |*s| s.deinit();
        self.surface = null;
    }

    /// The tier in force: `cells` means the CPU grid, anything else means a pixel protocol drew the frame.
    pub fn tier(self: *const Renderer) term.Mode {
        return self.mode;
    }

    /// Why the graphics tier was abandoned, or an empty slice when nothing failed.
    pub fn lastError(self: *const Renderer) []const u8 {
        return self.err;
    }

    /// The frame just painted, as text: how a headless run and a golden test read a cell frame.
    pub fn frameText(self: *const Renderer, alloc: std.mem.Allocator) ![]u8 {
        return self.grid.toText(alloc);
    }

    pub fn drawCommands(self: *Renderer, commands: []const cl.RenderCommand, win_w: i32, win_h: i32) void {
        if (win_w <= 0 or win_h <= 0) return;
        self.frames += 1;
        if (self.mode != .cells) {
            if (self.drawPixels(commands, win_w, win_h)) return;
            // The pixel tier failed: roll back to the CPU grid rather than leave the screen half-painted.
            self.mode = .cells;
        }
        self.drawCells(commands, win_w, win_h);
    }

    fn drawCells(self: *Renderer, commands: []const cl.RenderCommand, win_w: i32, win_h: i32) void {
        self.grid.clear(cells.Color.default_bg);
        self.grid.render(commands, win_w, win_h);
        self.out.clearRetainingCapacity();
        ansi.emit(&self.out, self.alloc, if (self.frames == 1) null else &self.prev, &self.grid, self.depth) catch return;
        if (self.out.items.len != 0) self.sink.write(self.sink.ctx, self.out.items);
        self.prev.clear(cells.Color.default_bg);
        self.prev.copyFrom(&self.grid);
        if (last_text.len != 0) self.alloc.free(@constCast(last_text));
        last_text = self.grid.toText(self.alloc) catch &.{};
    }

    fn drawPixels(self: *Renderer, commands: []const cl.RenderCommand, win_w: i32, win_h: i32) bool {
        const d = digest(commands);
        if (self.have_digest and d == self.last_digest) return true;
        const w: u32 = @intCast(win_w);
        const h: u32 = @intCast(win_h);
        if (self.surface == null) {
            self.surface = soft.Surface.init(self.alloc, w, h) catch |e| {
                self.err = @errorName(e);
                return false;
            };
        }
        const s = &self.surface.?;
        s.resize(w, h) catch |e| {
            self.err = @errorName(e);
            return false;
        };
        s.clear();
        s.renderCommands(commands);
        const bytes = switch (self.mode) {
            .kitty => kitty.encoded(self.alloc, s.pixels, w, h, self.grid.cols, self.grid.rows, self.image_id) catch |e| blk: {
                self.err = @errorName(e);
                break :blk null;
            },
            .sixel => sixel.encoded(self.alloc, s.pixels, w, h) catch |e| blk: {
                self.err = @errorName(e);
                break :blk null;
            },
            else => null,
        };
        const payload = bytes orelse return false;
        defer self.alloc.free(payload);
        // Home first: a kitty image is placed where the cursor is, and a sixel repaint starts on the row it was left on.
        self.sink.write(self.sink.ctx, "\x1b[H");
        self.sink.write(self.sink.ctx, payload);
        self.sink.write(self.sink.ctx, "\x1b[H");
        self.have_digest = true;
        self.last_digest = d;
        // The cell grid still tracks the frame, so a rollback mid-session does not paint a stale screen.
        self.grid.clear(cells.Color.default_bg);
        self.grid.render(commands, win_w, win_h);
        return true;
    }
};

// ===================== tests =====================

const TestSink = struct {
    buf: std.ArrayList(u8) = .empty,

    fn write(ctx: ?*anyopaque, bytes: []const u8) void {
        const self: *TestSink = @ptrCast(@alignCast(ctx.?));
        self.buf.appendSlice(std.testing.allocator, bytes) catch {};
    }
    fn sink(self: *TestSink) Sink {
        return .{ .ctx = self, .write = write };
    }
    fn deinit(self: *TestSink) void {
        self.buf.deinit(std.testing.allocator);
    }
};

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

test "a renderer with no terminal attached still paints, on the cell grid" {
    attach(.{ .cols = 4, .rows = 2, .mode = .cells, .depth = .truecolor });
    var s = TestSink{};
    defer s.deinit();
    attach(.{ .sink = s.sink(), .cols = 4, .rows = 2, .mode = .cells, .depth = .truecolor });
    var r = try Renderer.init(std.testing.allocator);
    defer r.deinit();
    var cmds = [_]cl.RenderCommand{rectCmd(0, 0, 32, 32, .{ 1, 2, 3, 255 })};
    r.drawCommands(&cmds, 32, 32);
    try std.testing.expectEqual(term.Mode.cells, r.tier());
    try std.testing.expect(s.buf.items.len > 0);
}

test "a sixel frame that the terminal asked for is encoded as a sixel image" {
    attach(.{ .cols = 4, .rows = 2, .mode = .sixel, .depth = .truecolor });
    var s = TestSink{};
    defer s.deinit();
    attach(.{ .sink = s.sink(), .cols = 4, .rows = 2, .mode = .sixel, .depth = .truecolor });
    var r = try Renderer.init(std.testing.allocator);
    defer r.deinit();
    var cmds = [_]cl.RenderCommand{rectCmd(0, 0, 32, 32, .{ 200, 10, 10, 255 })};
    r.drawCommands(&cmds, 32, 32);
    try std.testing.expectEqual(term.Mode.sixel, r.tier());
    try std.testing.expect(std.mem.startsWith(u8, s.buf.items, "\x1b[H\x1bP"));
}

test "a kitty frame carries the image header, and an unchanged frame is not re-encoded" {
    attach(.{ .cols = 4, .rows = 2, .mode = .kitty, .depth = .truecolor });
    var s = TestSink{};
    defer s.deinit();
    attach(.{ .sink = s.sink(), .cols = 4, .rows = 2, .mode = .kitty, .depth = .truecolor });
    var r = try Renderer.init(std.testing.allocator);
    defer r.deinit();
    var cmds = [_]cl.RenderCommand{rectCmd(0, 0, 32, 32, .{ 200, 10, 10, 255 })};
    r.drawCommands(&cmds, 32, 32);
    const first = s.buf.items.len;
    try std.testing.expect(std.mem.indexOf(u8, s.buf.items[0..first], "\x1b_Ga=T") != null);
    r.drawCommands(&cmds, 32, 32);
    try std.testing.expectEqual(first, s.buf.items.len);
}

test "the tier reports the CPU grid when a pixel encode cannot run" {
    // A zero-size surface is the honest way to make the graphics tier fail on the first frame.
    attach(.{ .cols = 4, .rows = 2, .mode = .kitty, .depth = .truecolor });
    var s = TestSink{};
    defer s.deinit();
    attach(.{ .sink = s.sink(), .cols = 4, .rows = 2, .mode = .kitty, .depth = .truecolor });
    var r = try Renderer.init(std.testing.allocator);
    defer r.deinit();
    var cmds = [_]cl.RenderCommand{rectCmd(0, 0, 0, 0, .{ 1, 1, 1, 255 })};
    r.drawCommands(&cmds, 0, 0);
    // A zero-sized frame is ignored outright, and the tier is untouched.
    try std.testing.expectEqual(term.Mode.kitty, r.tier());
    try std.testing.expectEqual(@as(usize, 0), s.buf.items.len);
}
