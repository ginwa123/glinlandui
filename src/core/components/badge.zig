//! A badge: a short label in a rounded pill, for a type, a count or a state.

const std = @import("std");
const cl = @import("zclay");
const headless = @import("../testing/headless.zig");
const prop = @import("../props.zig");
const Color = @import("../color.zig").Color;

pub const BadgeProps = struct {
    id: prop.Id,
    label: prop.Label = .{ .size = 11, .color = Color.rgb(0x8a, 0x8a, 0x94) },
    bg: Color = Color.rgb(0x26, 0x26, 0x2c),
    pad: prop.Pad = prop.Pad.axes(1, 6),
    radius: prop.Radius = prop.Radius.all(4),
};

/// Declare a badge.
pub fn badge(props: BadgeProps) void {
    cl.UI()(.{
        .id = props.id.clay(),
        .layout = .{
            .direction = .left_to_right,
            .sizing = .{ .w = .fit, .h = .fit },
            .padding = props.pad.clay(),
            .child_alignment = .{ .x = .center, .y = .center },
        },
        .background_color = props.bg.toClay(),
        .corner_radius = props.radius.clay(),
    })({
        cl.text(props.label.text, .{ .font_size = props.label.size, .color = props.label.color.toClay() });
    });
}

fn declareSample() void {
    badge(.{ .id = .{ .text = "b" }, .label = .{ .text = "INTEGER" } });
}

test "a badge is one rect and one text" {
    var rects: usize = 0;
    var texts: usize = 0;
    try headless.countCommands(declareSample, &rects, &texts);
    try std.testing.expectEqual(@as(usize, 1), rects);
    try std.testing.expectEqual(@as(usize, 1), texts);
}
