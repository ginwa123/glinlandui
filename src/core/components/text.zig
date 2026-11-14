// Agnostic reusable Clay label widget (toolkit-style, library only).
const std = @import("std");
const cl = @import("zclay");
const Color = @import("../color.zig").Color;
const prop = @import("../props.zig");

/// Click callback: plain fn pointer + opaque ctx (no closures).
pub const ClickFn = ?*const fn (?*anyopaque) void;

/// Label props: one text run, and what may happen to it.
pub const TextProps = struct {
    label: prop.Label = .{},
    wrap: bool = false,
    disabled: bool = false,
    disabled_color: Color = Color.rgb(0x77, 0x77, 0x77),
    on_click: ClickFn = null,
    ctx: ?*anyopaque = null,
};

/// Declare a single text element.
pub fn label(p: TextProps) void {
    cl.text(p.label.text, .{
        .font_size = p.label.size,
        .color = (if (p.disabled) p.disabled_color else p.label.color).toClay(),
        .wrap_mode = if (p.wrap) .words else .none,
    });
}

// Stub text estimator for headless tests (no font backend needed).
fn stubMeasure(s: []const u8, cfg: *cl.TextElementConfig, _: void) cl.Dimensions {
    return .{
        .w = @as(f32, @floatFromInt(s.len)) * @as(f32, @floatFromInt(cfg.font_size)) * 0.6,
        .h = @as(f32, @floatFromInt(cfg.font_size)),
    };
}

fn declareLabel() void {
    label(.{ .label = .{ .text = "Hello" } });
}

fn frameCommands(declare_fn: *const fn () void) ![]cl.RenderCommand {
    const mem_size = cl.minMemorySize();
    // NOTE: intentionally leaked (page_allocator, never freed).
    const buf = try std.heap.page_allocator.alloc(u8, mem_size);
    const arena = cl.Arena.init(buf);
    _ = cl.initialize(arena, .{ .w = 720, .h = 480 }, .{});
    cl.setMeasureTextFunction(void, {}, stubMeasure);
    cl.setPointerState(.{ .x = 99999, .y = 99999 }, false);
    cl.beginLayout();
    declare_fn();
    return cl.endLayout();
}

test "label emits exactly one text command, no rectangles" {
    const cmds = try frameCommands(declareLabel);
    var rects: usize = 0;
    var texts: usize = 0;
    for (cmds) |c| switch (c.command_type) {
        .rectangle => rects += 1,
        .text => texts += 1,
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 0), rects);
    try std.testing.expectEqual(@as(usize, 1), texts);
}

test "TextProps carries neutral defaults" {
    const p = TextProps{ .label = .{ .text = "x" } };
    try std.testing.expectEqual(@as(u16, 14), p.label.size);
    try std.testing.expectEqual(Color.rgb(0xe8, 0xe8, 0xe8), p.label.color);
    try std.testing.expect(!p.wrap);
    try std.testing.expect(!p.disabled);
    try std.testing.expectEqual(Color.rgb(0x77, 0x77, 0x77), p.disabled_color);
    try std.testing.expect(p.on_click == null);
}

test "TextProps needs nothing: a label is optional, so `.{}` is a valid text run" {
    const p = TextProps{};
    try std.testing.expectEqual(@as(usize, 0), p.label.text.len);
    try std.testing.expectEqual(@as(u16, 14), p.label.size);
}
