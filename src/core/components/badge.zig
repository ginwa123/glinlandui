//! A badge: a short label in a rounded pill, for a type, a count or a state.

const std = @import("std");
const cl = @import("zclay");
const headless = @import("../testing/headless.zig");
const prop = @import("../props.zig");
const theme_mod = @import("../theme.zig");
const Color = @import("../color.zig").Color;

pub const BadgeProps = struct {
    id: prop.Id,
    label: prop.Label = .{ .size = .{ .px = 11 }, .color = Color.rgb(0x8a, 0x8a, 0x94) },
    bg: Color = Color.rgb(0x26, 0x26, 0x2c),
    // A chip is the smallest surface: the theme's chip padding and its small corner unless the app says otherwise.
    pad: prop.Pad = prop.Pad.themed,
    radius: prop.Radius = prop.Radius.themed,
};

/// Declare a badge.
pub fn badge(props: BadgeProps) void {
    cl.UI()(.{
        .id = props.id.clay(),
        .layout = .{
            .direction = .left_to_right,
            .sizing = .{ .w = .fit, .h = .fit },
            .padding = props.pad.resolve(theme_mod.current().metrics.chip_pad).clay(),
            .child_alignment = .{ .x = .center, .y = .center },
        },
        .background_color = props.bg.toClay(),
        .corner_radius = props.radius.resolve(theme_mod.current().metrics.corner(.sm)).clay(),
    })({
        cl.text(props.label.text, .{ .font_size = props.label.size.whole(), .color = props.label.color.toClay() });
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
