// Agnostic reusable Clay label widget (toolkit-style, library only).
const std = @import("std");
const cl = @import("zclay");
const headless = @import("../testing/headless.zig");
const Color = @import("../color.zig").Color;
const prop = @import("../props.zig");

/// Label props: one text run, and what may happen to it.
pub const TextProps = struct {
    label: prop.Label = .{},
    wrap: bool = false,
    disabled: bool = false,
    disabled_color: Color = Color.rgb(0x77, 0x77, 0x77),
};

/// Declare a single text element.
pub fn label(p: TextProps) void {
    cl.text(p.label.text, .{
        .font_size = p.label.size,
        .color = (if (p.disabled) p.disabled_color else p.label.color).toClay(),
        .wrap_mode = if (p.wrap) .words else .none,
    });
}

fn declareLabel() void {
    label(.{ .label = .{ .text = "Hello" } });
}

test "label emits exactly one text command, no rectangles" {
    const cmds = try headless.frameCommands(declareLabel);
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
}

test "TextProps needs nothing: a label is optional, so `.{}` is a valid text run" {
    const p = TextProps{};
    try std.testing.expectEqual(@as(usize, 0), p.label.text.len);
    try std.testing.expectEqual(@as(u16, 14), p.label.size);
}
