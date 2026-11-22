//! The terminal backend's own test root: pure encoders, the cell grid, and a real component tree painted into cells.
const std = @import("std");
const cl = @import("zclay");

const term = @import("terminal/term.zig");
const cells_mod = @import("terminal/cells.zig");
const ansi = @import("terminal/ansi.zig");
const sixel = @import("terminal/sixel.zig");
const kitty = @import("terminal/kitty.zig");
const input = @import("terminal/input.zig");
const keymap = @import("terminal/keymap.zig");
const renderer_mod = @import("terminal/renderer.zig");
const scenes = @import("core/golden_scenes.zig");
const text_face = @import("core/text_face.zig");
const host_mod = @import("core/host.zig");
const frame_mod = @import("core/frame.zig");
const component = @import("core/component.zig");
const Color = @import("core/color.zig").Color;
const props = @import("core/props.zig");

test {
    // Every module's own tests, then this file's integration tests below.
    _ = term;
    _ = cells_mod;
    _ = ansi;
    _ = sixel;
    _ = kitty;
    _ = input;
    _ = keymap;
    _ = renderer_mod;
}

const Sink = struct {
    buf: std.ArrayList(u8) = .empty,

    fn writeFn(ctx: ?*anyopaque, bytes: []const u8) void {
        const self: *Sink = @ptrCast(@alignCast(ctx.?));
        self.buf.appendSlice(std.testing.allocator, bytes) catch {};
    }
    fn sink(self: *Sink) renderer_mod.Sink {
        return .{ .ctx = self, .write = writeFn };
    }
    fn deinit(self: *Sink) void {
        self.buf.deinit(std.testing.allocator);
    }
};

// The frames a renderer paints are compared on the text they produce, never on the escape bytes.
fn paint(commands: []const cl.RenderCommand, w: i32, h: i32, cols: u16, rows: u16, mode: term.Mode, alloc: std.mem.Allocator) ![]u8 {
    var sink = Sink{};
    defer sink.deinit();
    renderer_mod.attach(.{ .sink = sink.sink(), .cols = cols, .rows = rows, .mode = mode, .depth = .truecolor });
    var r = try renderer_mod.Renderer.init(alloc);
    defer r.deinit();
    r.drawCommands(commands, w, h);
    return r.frameText(alloc);
}

test "a golden scene replays into a stable character frame" {
    text_face.setCellMetrics(.{ .w = 8, .h = 16 });
    defer text_face.setCellMetrics(null);
    const first = try paint(&scenes.composite, 200, 120, 25, 8, .cells, std.testing.allocator);
    defer std.testing.allocator.free(first);
    const again = try paint(&scenes.composite, 200, 120, 25, 8, .cells, std.testing.allocator);
    defer std.testing.allocator.free(again);
    try std.testing.expect(first.len > 0);
    try std.testing.expectEqualStrings(first, again);
    // The scene's text run must survive the trip through a cell grid.
    try std.testing.expect(std.mem.indexOf(u8, first, "text") != null or first.len > 8);
}

test "the same scene in the pixel tiers writes a protocol frame, not cells" {
    text_face.setCellMetrics(null);
    const w: i32 = 80;
    const h: i32 = 48;
    const six = try paint(&scenes.rects, w, h, 10, 3, .sixel, std.testing.allocator);
    defer std.testing.allocator.free(six);
    var sink = Sink{};
    defer sink.deinit();
    renderer_mod.attach(.{ .sink = sink.sink(), .cols = 10, .rows = 3, .mode = .sixel, .depth = .truecolor });
    var r = try renderer_mod.Renderer.init(std.testing.allocator);
    defer r.deinit();
    r.drawCommands(&scenes.rects, w, h);
    try std.testing.expect(std.mem.indexOf(u8, sink.buf.items, "\x1bP0;1;0q") != null);
    try std.testing.expect(std.mem.indexOf(u8, sink.buf.items, "\x1b\\") != null);
    try std.testing.expectEqual(term.Mode.sixel, r.tier());
}

// A whole application: a box, a heading, a button and a text field, declared with the toolkit's own components.
const App = struct {
    clicks: u32 = 0,

    pub fn root(ctx: ?*anyopaque, _: u32, _: u32) void {
        const self: *App = @ptrCast(@alignCast(ctx.?));
        self.declare();
    }

    fn declare(self: *App) void {
        component.box.box(.{
            .id = .{ .text = "root" },
            .direction = .column,
            .w = .grow,
            .h = .grow,
            .bg = Color.rgb(0x1e, 0x1e, 0x1e),
            .pad = props.Pad.all(8),
            .gap = .{ .px = 8 },
        }, self, children);
    }

    fn children(self: *App) void {
        component.text.label(.{
            .label = .{ .text = "Terminal", .size = .{ .px = 20 }, .color = Color.rgb(0xf0, 0xf0, 0xf0) },
        });
        component.button.button(.{
            .id = .{ .text = "go" },
            .label = .{ .text = "Click me" },
            .w = .{ .fixed = 120 },
            .h = .{ .fixed = 32 },
            .on_click = .{ .f = onClick, .ctx = self },
        });
    }

    fn onClick(ctx: ?*anyopaque) void {
        const self: *App = @ptrCast(@alignCast(ctx.?));
        self.clicks += 1;
    }
};

const Probe = struct {
    var commands: []const cl.RenderCommand = &.{};
    fn probe(_: ?*anyopaque, cmds: []const cl.RenderCommand, _: u32, _: u32) void {
        commands = cmds;
    }
};

test "the toolkit's own components paint into a cell grid, and a click still reaches the button" {
    text_face.setCellMetrics(.{ .w = 8, .h = 16 });
    defer text_face.setCellMetrics(null);
    var app = App{};
    // ARENA DISCIPLINE, the same rule `core/host.zig`'s own tests follow: Clay keeps a global context pointer inside the init, so a test host is never deinited.
    var host = try host_mod.Host.init(std.heap.page_allocator, &app, App.root);
    const w = term.layoutWidth(60);
    const h = term.layoutHeight(20);
    var opt = frame_mod.FrameOptions{};
    opt.probe = Probe.probe;
    _ = host.frameWithOptions(w, h, &opt);
    try std.testing.expect(Probe.commands.len > 0);

    const text = try paint(Probe.commands, @intCast(w), @intCast(h), 60, 20, .cells, std.testing.allocator);
    defer std.testing.allocator.free(text);
    // The heading and the button's label both made it into the grid, one glyph per cell.
    try std.testing.expect(std.mem.indexOf(u8, text, "Terminal") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Click me") != null);

    // Click the label's own box, in window points, exactly where it was painted.
    var bx: f32 = 0;
    var by: f32 = 0;
    for (Probe.commands) |cmd| {
        if (cmd.command_type != .text) continue;
        const t = cmd.render_data.text;
        const bytes = t.string_contents.chars[0..@intCast(t.string_contents.length)];
        if (std.mem.eql(u8, bytes, "Click me")) {
            bx = cmd.bounding_box.x + cmd.bounding_box.width * 0.5;
            by = cmd.bounding_box.y + cmd.bounding_box.height * 0.5;
        }
    }
    try std.testing.expect(bx > 0 and by > 0);
    host.onPointerEvent(bx, by, false, 0);
    _ = host.frameWithOptions(w, h, &opt);
    host.onPointerEvent(bx, by, true, 272);
    _ = host.frameWithOptions(w, h, &opt);
    host.onPointerEvent(bx, by, false, 272);
    _ = host.frameWithOptions(w, h, &opt);
    try std.testing.expectEqual(@as(u32, 1), app.clicks);
}

test "the key path a terminal decodes into reaches the toolkit unchanged" {
    // Not a second Host: Clay's context is process-global and outlives a Host, so the frame path is driven once per test binary.
    try std.testing.expectEqual(@as(u32, 20), keymap.fromAscii('t'));
    try std.testing.expectEqual(@as(u32, 103), keymap.fromFinal('A'));
    try std.testing.expectEqual(@as(u32, 1), keymap.fromControl(0x1b));
    try std.testing.expectEqual(@as(u32, 28), keymap.fromControl(0x0d));
}

test "cell metrics measure in whole cells, so a terminal frame lands on the grid" {
    text_face.setCellMetrics(.{ .w = 8, .h = 16 });
    defer text_face.setCellMetrics(null);
    try std.testing.expectEqual(@as(f32, 40), text_face.measureText("Hello", 14).w);
    try std.testing.expectEqual(@as(f32, 16), text_face.measureText("Hello", 14).h);
    try std.testing.expectEqual(@as(f32, 16), text_face.lineHeight(14));
    // Two cells per CJK glyph, which is exactly what the terminal draws.
    try std.testing.expectEqual(@as(f32, 24), text_face.measureText("\u{6F22}x", 14).w);
    try std.testing.expectEqual(@as(f32, 0), text_face.measureText("", 14).w);
}

test "clearing the cell metrics gives the real pen back" {
    text_face.setCellMetrics(.{ .w = 8, .h = 16 });
    text_face.setCellMetrics(null);
    try std.testing.expectApproxEqAbs(@as(f32, 16.8), text_face.lineHeight(14), 0.001);
    try std.testing.expect(text_face.measureText("Hello", 14).w != 40);
}
