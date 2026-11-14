//! The headless Clay harness every component test shares: one stub measurer, one layout, one command count.
const std = @import("std");
const cl = @import("zclay");

/// A deterministic text measurer: with no font file a box's width is a pure function of its text.
pub fn stubMeasure(s: []const u8, cfg: *cl.TextElementConfig, _: void) cl.Dimensions {
    return .{
        .w = @as(f32, @floatFromInt(s.len)) * @as(f32, @floatFromInt(cfg.font_size)) * 0.6,
        .h = @as(f32, @floatFromInt(cfg.font_size)),
    };
}

/// Start a 720x480 headless frame with the stub measurer and `pointer` already installed. Call `cl.endLayout()` to finish it.
pub fn begin(pointer: cl.Vector2, pressed: bool) void {
    // The ONLY `page_allocator` in the tree: Clay holds a process-global pointer into this arena and never releases it, so a leak-checking allocator would fail a correct test.
    const buf = std.heap.page_allocator.alloc(u8, cl.minMemorySize()) catch @panic("headless Clay arena");
    const arena = cl.Arena.init(buf);
    _ = cl.initialize(arena, .{ .w = 720, .h = 480 }, .{});
    cl.setMeasureTextFunction(void, {}, stubMeasure);
    cl.setPointerState(pointer, pressed);
}

/// One headless layout of `declare_fn`, with the pointer parked far outside so hover state is deterministic.
pub fn frameCommands(declare_fn: *const fn () void) ![]cl.RenderCommand {
    begin(.{ .x = 99999, .y = 99999 }, false);
    cl.beginLayout();
    declare_fn();
    return cl.endLayout();
}

/// How many rectangle and text commands `declare_fn` emits in one layout.
pub fn countCommands(declare_fn: *const fn () void, rects: *usize, texts: *usize) !void {
    const cmds = try frameCommands(declare_fn);
    var r: usize = 0;
    var t: usize = 0;
    for (cmds) |c| switch (c.command_type) {
        .rectangle => r += 1,
        .text => t += 1,
        else => {},
    };
    rects.* = r;
    texts.* = t;
}

test "the stub measurer scales width with length and height with font size" {
    var cfg = cl.TextElementConfig{ .font_size = 10 };
    const a = stubMeasure("ab", &cfg, {});
    const b = stubMeasure("abcd", &cfg, {});
    try std.testing.expect(b.w > a.w);
    cfg.font_size = 20;
    try std.testing.expectApproxEqAbs(@as(f32, 20), stubMeasure("ab", &cfg, {}).h, 0.001);
}
