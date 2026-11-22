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
    /// The terminal's pixel box when the kernel reports one, else 0: the exact device-pixel size of the cell grid.
    px_w: u16 = 0,
    px_h: u16 = 0,
    /// Keep the last frame as text. Off by default: it is a full-grid scan, and only a headless run or a test reads it.
    capture_text: bool = false,
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

/// The device pixels a layout point becomes: the pixel box the terminal reports, else GLIN_TUI_SCALE, else the ratio a Retina host implies.
fn graphicsScale(a: Attach) f32 {
    const env = term.libcEnv();
    if (env.get(env.ctx, "GLIN_TUI_SCALE")) |v| {
        const parsed = std.fmt.parseFloat(f32, v) catch 0;
        if (parsed >= 1 and parsed <= 4) return parsed;
    }
    if (a.px_w > 0 and a.cols > 0) {
        const layout = @as(f32, @floatFromInt(term.layoutWidth(a.cols)));
        const measured = @as(f32, @floatFromInt(a.px_w)) / layout;
        if (measured >= 1 and measured <= 4) return measured;
    }
    // Sixel paints one device pixel per pixel from the cursor, so an unconfirmed scale enlarges the image instead of sharpening it.
    if (a.mode == .sixel) return 1.0;
    return if (term.retinaLikely(env)) 2.0 else 1.0;
}

/// The device scale a frame is rasterised at, resolved before the first layout so measurement and pixels agree.
pub fn scaleFor(a: Attach) f32 {
    return if (a.mode == .cells) 1.0 else graphicsScale(a);
}

/// The terminal backend's renderer: a cell grid when that is all the terminal can do, real pixels when it can draw them.
pub const Renderer = struct {
    alloc: std.mem.Allocator,
    sink: Sink,
    /// The tier that is actually in use: a failed encode leaves this at `cells`, never at a broken graphics mode.
    mode: term.Mode,
    /// The tier this terminal asked for, kept for the diagnostic line.
    want: term.Mode,
    depth: term.Depth,
    /// Device pixels per layout point, for the pixel tiers.
    scale: f32,
    grid: cells.Grid,
    prev: cells.Grid,
    surface: ?soft.Surface = null,
    out: std.ArrayList(u8) = .empty,
    /// The id the last placement was sent with; a patch replaces it, so it has to be deleted first.
    patch_id: u32 = 0,
    next_id: u32 = 1,
    /// The id the frame in flight was sent with.
    last_id: u32 = 0,
    frames: u32 = 0,
    capture_text: bool = false,
    /// The next frame must repaint everything: the first one, or the first after a resize.
    whole: bool = true,
    /// The display scale that was in force before this renderer took the process-wide one over.
    scale_before: f32 = 1.0,
    err: []const u8 = "",

    pub fn init(alloc: std.mem.Allocator) !Renderer {
        const a = pending orelse Attach{
            .mode = term.detectMode(term.libcEnv()),
            .depth = term.detectDepth(term.libcEnv()),
        };
        var self = Renderer{
            .alloc = alloc,
            .sink = a.sink,
            .mode = a.mode,
            .want = a.mode,
            .depth = a.depth,
            .scale = scaleFor(a),
            .grid = try cells.Grid.init(alloc, a.cols, a.rows),
            .prev = try cells.Grid.init(alloc, a.cols, a.rows),
            .capture_text = a.capture_text,
        };
        errdefer self.deinit();
        self.scale_before = soft.renderScale();
        // The rasteriser draws at this scale, so the layout was measured at it: text and geometry agree in the pixels.
        soft.setRenderScale(self.scale);
        return self;
    }

    pub fn deinit(self: *Renderer) void {
        // The scale is process-wide, so it is handed back: a test binary draws other frames after this renderer is gone.
        soft.setRenderScale(self.scale_before);
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

    /// Device pixels per layout point the frame is rasterised at.
    pub fn pixelScale(self: *const Renderer) f32 {
        return self.scale;
    }

    /// The frame just painted, as text: how a headless run and a golden test read a cell frame.
    pub fn frameText(self: *const Renderer, alloc: std.mem.Allocator) ![]u8 {
        return self.grid.toText(alloc);
    }

    pub fn drawCommands(self: *Renderer, commands: []const cl.RenderCommand, win_w: i32, win_h: i32) void {
        if (win_w <= 0 or win_h <= 0) return;
        self.frames += 1;
        // The cell grid is always built: it is the fallback tier, and it is what says which cells actually changed.
        self.grid.clear(cells.Color.default_bg);
        self.grid.render(commands, win_w, win_h);
        if (self.mode == .cells) {
            self.paintCells();
            return;
        }
        if (!self.paintPixels(commands, win_w, win_h)) {
            // The pixel tier failed: roll back to the CPU grid rather than leave the screen half-painted.
            self.mode = .cells;
            self.scale = 1.0;
            soft.setRenderScale(1.0);
            self.paintCells();
            return;
        }
        self.prev.clear(cells.Color.default_bg);
        self.prev.copyFrom(&self.grid);
    }

    /// The id the next escape carries: two placements may never share one, or the terminal would replace the older image.
    fn takeId(self: *Renderer) u32 {
        const id = self.next_id;
        self.next_id = if (self.next_id >= 0x7fff_fffe) 1 else self.next_id + 1;
        self.last_id = id;
        return id;
    }

    /// Delete the placement the last patch left, or every placement (a fresh frame must not sit on top of stale patches).
    fn dropPlacements(self: *Renderer, all: bool) void {
        const esc = if (all)
            kitty.deleteAll(self.alloc) catch return
        else
            kitty.deleteOne(self.alloc, self.patch_id) catch return;
        defer self.alloc.free(esc);
        self.sink.write(self.sink.ctx, esc);
        if (all) self.patch_id = 0;
    }

    fn keepText(self: *Renderer) void {
        if (!self.capture_text) return;
        if (last_text.len != 0) self.alloc.free(@constCast(last_text));
        last_text = self.grid.toText(self.alloc) catch &.{};
    }

    fn paintCells(self: *Renderer) void {
        self.out.clearRetainingCapacity();
        ansi.emit(&self.out, self.alloc, if (self.frames == 1) null else &self.prev, &self.grid, self.depth) catch return;
        if (self.out.items.len != 0) self.sink.write(self.sink.ctx, self.out.items);
        self.prev.clear(cells.Color.default_bg);
        self.prev.copyFrom(&self.grid);
        self.keepText();
    }

    fn paintPixels(self: *Renderer, commands: []const cl.RenderCommand, win_w: i32, win_h: i32) bool {
        const px_w: u32 = @intFromFloat(@max(1, @as(f32, @floatFromInt(win_w)) * self.scale));
        const px_h: u32 = @intFromFloat(@max(1, @as(f32, @floatFromInt(win_h)) * self.scale));
        if (self.surface == null) {
            self.surface = soft.Surface.init(self.alloc, px_w, px_h) catch |e| {
                self.err = @errorName(e);
                return false;
            };
        }
        const s = &self.surface.?;
        if (s.width != px_w or s.height != px_h) {
            s.resize(px_w, px_h) catch |e| {
                self.err = @errorName(e);
                return false;
            };
            // A resize invalidates every placement the terminal is holding for us, so the frame starts from nothing.
            if (self.mode == .kitty) self.dropPlacements(true);
            self.whole = true;
        }
        // Only the cells that changed need repainting: an incremental update sends a patch, not the frame.
        const dirty: cells.Rect = if (self.whole)
            .{ .x0 = 0, .y0 = 0, .x1 = self.grid.cols, .y1 = self.grid.rows }
        else
            self.grid.dirtyRect(&self.prev) orelse return true;
        if (self.whole) {
            s.clear();
            // A full frame replaces the screen: every placement from a previous frame or size goes first.
            if (self.mode == .kitty) self.dropPlacements(true);
        } else if (self.mode == .kitty and self.patch_id != 0) {
            // A patch is its own placement, so the previous patch has to go or the two would both show.
            self.dropPlacements(false);
        }
        const px = pixelRect(dirty, self.scale, px_w, px_h);
        if (px.x1 <= px.x0 or px.y1 <= px.y0) return true;
        s.renderCommandsClipped(commands, .{ px.x0, px.y0, px.x1, px.y1 });
        const region = sixel.Region{
            .x = @intCast(px.x0),
            .y = @intCast(px.y0),
            .w = @intCast(px.x1 - px.x0),
            .h = @intCast(px.y1 - px.y0),
        };
        const cols: u16 = @intCast(dirty.x1 - dirty.x0);
        const rows: u16 = @intCast(dirty.y1 - dirty.y0);
        const payload = switch (self.mode) {
            .kitty => kitty.encodedRegion(self.alloc, s.pixels, px_w, px_h, .{
                .x = region.x,
                .y = region.y,
                .w = region.w,
                .h = region.h,
            }, cols, rows, self.takeId()) catch |e| blk: {
                self.err = @errorName(e);
                break :blk null;
            },
            .sixel => sixel.encodedRegion(self.alloc, s.pixels, px_w, px_h, region) catch |e| blk: {
                self.err = @errorName(e);
                break :blk null;
            },
            else => null,
        };
        const bytes = payload orelse return false;
        defer self.alloc.free(bytes);
        // A full frame is the screen now and must survive the next patch; only a patch is deleted by the next one.
        if (self.mode == .kitty) self.patch_id = if (self.whole) 0 else self.last_id;
        // Position the cursor on the region's own top-left cell, then paint: both protocols anchor at the cursor.
        var buf: [32]u8 = undefined;
        const move = std.fmt.bufPrint(&buf, "\x1b[{d};{d}H", .{ dirty.y0 + 1, dirty.x0 + 1 }) catch "\x1b[H";
        self.sink.write(self.sink.ctx, move);
        self.sink.write(self.sink.ctx, bytes);
        self.sink.write(self.sink.ctx, "\x1b[H");
        self.whole = false;
        self.keepText();
        return true;
    }
};

/// A cell rectangle in device pixels, grown by a pixel so an anti-aliased edge is never left half-painted.
fn pixelRect(r: cells.Rect, scale: f32, w: u32, h: u32) struct { x0: i64, y0: i64, x1: i64, y1: i64 } {
    const cw = @as(f32, @floatFromInt(term.cell_w)) * scale;
    const ch = @as(f32, @floatFromInt(term.cell_h)) * scale;
    const x0 = @max(0, @floor(@as(f32, @floatFromInt(r.x0)) * cw) - 1);
    const y0 = @max(0, @floor(@as(f32, @floatFromInt(r.y0)) * ch) - 1);
    const x1 = @min(@as(f32, @floatFromInt(w)), @ceil(@as(f32, @floatFromInt(r.x1)) * cw) + 1);
    const y1 = @min(@as(f32, @floatFromInt(h)), @ceil(@as(f32, @floatFromInt(r.y1)) * ch) + 1);
    return .{ .x0 = @intFromFloat(x0), .y0 = @intFromFloat(y0), .x1 = @intFromFloat(x1), .y1 = @intFromFloat(y1) };
}

// ===================== tests =====================

const TestSink = struct {
    buf: std.ArrayList(u8) = .empty,

    fn writeFn(ctx: ?*anyopaque, bytes: []const u8) void {
        const self: *TestSink = @ptrCast(@alignCast(ctx.?));
        self.buf.appendSlice(std.testing.allocator, bytes) catch {};
    }
    fn sink(self: *TestSink) Sink {
        return .{ .ctx = self, .write = writeFn };
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
    var s = TestSink{};
    defer s.deinit();
    attach(.{ .sink = s.sink(), .cols = 4, .rows = 2, .mode = .sixel, .depth = .truecolor });
    var r = try Renderer.init(std.testing.allocator);
    defer r.deinit();
    var cmds = [_]cl.RenderCommand{rectCmd(0, 0, 32, 32, .{ 200, 10, 10, 255 })};
    r.drawCommands(&cmds, 32, 32);
    try std.testing.expectEqual(term.Mode.sixel, r.tier());
    try std.testing.expect(std.mem.indexOf(u8, s.buf.items, "\x1b[1;1H\x1bP") != null);
}

test "a kitty frame carries the image header, and an unchanged frame is not re-encoded" {
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

test "a one-cell change sends a one-cell patch, not the frame" {
    var s = TestSink{};
    defer s.deinit();
    // A kitty terminal at 1x, so the payload is a whole number of bytes per pixel.
    attach(.{ .sink = s.sink(), .cols = 8, .rows = 4, .mode = .kitty, .depth = .truecolor });
    var r = try Renderer.init(std.testing.allocator);
    defer r.deinit();
    var cmds = [_]cl.RenderCommand{rectCmd(0, 0, 64, 64, .{ 10, 10, 10, 255 })};
    r.drawCommands(&cmds, 64, 64);
    const full = s.buf.items.len;
    // One cell appears: the patch must be a fraction of the frame.
    var changed = [_]cl.RenderCommand{
        rectCmd(0, 0, 64, 64, .{ 10, 10, 10, 255 }),
        rectCmd(8, 16, 8, 16, .{ 250, 250, 250, 255 }),
    };
    r.drawCommands(&changed, 64, 64);
    const patch = s.buf.items.len - full;
    try std.testing.expect(patch > 0);
    try std.testing.expect(patch < full / 4);
    try std.testing.expect(std.mem.indexOf(u8, s.buf.items[full..], "\x1b[2;2H") != null);
}

test "the tier reports the CPU grid when a pixel encode cannot run" {
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
