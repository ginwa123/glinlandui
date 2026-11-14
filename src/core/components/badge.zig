//! A badge: a short label in a rounded pill, for a type, a count or a state.

const std = @import("std");
const cl = @import("zclay");
const prop = @import("../props.zig");
const Color = @import("../color.zig").Color;

pub const BadgeProps = struct {
    id: prop.Id,
    label: []const u8,
    bg: Color = Color.rgb(0x26, 0x26, 0x2c),
    fg: Color = Color.rgb(0x8a, 0x8a, 0x94),
    font_size: u16 = 11,
    pad_tb: u16 = 1,
    pad_lr: u16 = 6,
    radius: u32 = 4,
};

/// Declare a badge.
pub fn badge(props: BadgeProps) void {
    cl.UI()(.{
        .id = props.id.clay(),
        .layout = .{
            .direction = .left_to_right,
            .sizing = .{ .w = .fit, .h = .fit },
            .padding = .axes(props.pad_tb, props.pad_lr),
            .child_alignment = .{ .x = .center, .y = .center },
        },
        .background_color = props.bg.toClay(),
        .corner_radius = .all(@floatFromInt(props.radius)),
    })({
        cl.text(props.label, .{ .font_size = props.font_size, .color = props.fg.toClay() });
    });
}

// ---- tests ----

fn stubMeasure(s: []const u8, cfg: *cl.TextElementConfig, _: void) cl.Dimensions {
    return .{
        .w = @as(f32, @floatFromInt(s.len)) * @as(f32, @floatFromInt(cfg.font_size)) * 0.6,
        .h = @as(f32, @floatFromInt(cfg.font_size)),
    };
}

fn countCommands(declare_fn: *const fn () void, rects: *usize, texts: *usize) !void {
    const mem_size = cl.minMemorySize();
    const buf = try std.heap.page_allocator.alloc(u8, mem_size);
    const arena = cl.Arena.init(buf);
    _ = cl.initialize(arena, .{ .w = 720, .h = 480 }, .{});
    cl.setMeasureTextFunction(void, {}, stubMeasure);
    cl.setPointerState(.{ .x = 99999, .y = 99999 }, false);
    cl.beginLayout();
    declare_fn();
    const cmds = cl.endLayout();
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

fn declareSample() void {
    badge(.{ .id = .{ .text = "b" }, .label = "INTEGER" });
}

test "a badge is one rect and one text" {
    var rects: usize = 0;
    var texts: usize = 0;
    try countCommands(declareSample, &rects, &texts);
    try std.testing.expectEqual(@as(usize, 1), rects);
    try std.testing.expectEqual(@as(usize, 1), texts);
}
