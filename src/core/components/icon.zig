// Agnostic reusable Clay icon widget (toolkit-style, library only).
const std = @import("std");
const cl = @import("zclay");
const headless = @import("../testing/headless.zig");
const prop = @import("../props.zig");
const Color = @import("../color.zig").Color;

// ---- Glyph table (Font Awesome codepoints, present in Nerd Fonts) ---- Drill-in / expand affordances (replace the ASCII ">" chevron).
pub const chevron_right: []const u8 = "\u{F054}";
pub const chevron_down: []const u8 = "\u{F078}";
// Sidebar navigation (one per Page, same order as sidebar_items).
pub const gear: []const u8 = "\u{F013}";
pub const wifi: []const u8 = "\u{F1EB}";
pub const bluetooth: []const u8 = "\u{F293}";
pub const power: []const u8 = "\u{F011}";
pub const bars: []const u8 = "\u{F0C9}";
pub const grid: []const u8 = "\u{F00A}";
pub const image: []const u8 = "\u{F03E}";
// Search field prompt (replaces the ASCII ">" prompt).
pub const search: []const u8 = "\u{F002}";
// Status affordances (wifi settings rows: connected check, secured lock).
pub const check: []const u8 = "\u{F00C}";
pub const lock: []const u8 = "\u{F023}";

/// Icon props.
pub const IconProps = struct {
    glyph: []const u8 = "",
    font_size: prop.Len = .{ .px = 14 },
    color: Color = Color.rgb(0xe8, 0xe8, 0xe8),
    disabled: bool = false,
    disabled_color: Color = Color.rgb(0x77, 0x77, 0x77),
};

/// Declare a single icon element.
pub fn icon(props: IconProps) void {
    cl.text(props.glyph, .{
        .font_size = props.font_size.whole(),
        .color = (if (props.disabled) props.disabled_color else props.color).toClay(),
    });
}

fn declareIcon() void {
    icon(.{ .glyph = chevron_right });
}

test "icon emits exactly one text command, no rectangles" {
    var rects: usize = 0;
    var texts: usize = 0;
    try headless.countCommands(declareIcon, &rects, &texts);
    try std.testing.expectEqual(@as(usize, 0), rects);
    try std.testing.expectEqual(@as(usize, 1), texts);
}

test "IconProps carries neutral defaults" {
    const p = IconProps{ .glyph = chevron_right };
    try std.testing.expectEqual(@as(f32, 14), p.font_size.pts());
    try std.testing.expectEqual(Color.rgb(0xe8, 0xe8, 0xe8), p.color);
    try std.testing.expect(!p.disabled);
    try std.testing.expectEqual(Color.rgb(0x77, 0x77, 0x77), p.disabled_color);
}

fn declareDisabledIcon() void {
    icon(.{ .glyph = chevron_right, .disabled = true });
}

test "disabled icon emits one text with the disabled color" {
    headless.begin(.{ .x = 99999, .y = 99999 }, false);
    cl.beginLayout();
    declareDisabledIcon();
    const cmds = cl.endLayout();
    var texts: usize = 0;
    for (cmds) |c| {
        if (c.command_type == .text) {
            texts += 1;
            try std.testing.expectEqual(Color.rgb(0x77, 0x77, 0x77).toClay(), c.render_data.text.text_color);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), texts);
}

test "glyph table entries are non-empty UTF-8" {
    const glyphs = [_][]const u8{ chevron_right, chevron_down, gear, wifi, bluetooth, power, bars, grid, image, search };
    for (glyphs) |g| {
        try std.testing.expect(g.len > 0);
        // All table entries are 3-byte UTF-8 (U+F000-U+FFFF private use).
        try std.testing.expectEqual(@as(usize, 3), g.len);
    }
}

test "status glyphs are non-empty UTF-8 slices" {
    try std.testing.expect(check.len > 0);
    try std.testing.expect(lock.len > 0);
    try std.testing.expect(check.ptr != lock.ptr);
}

test "IconProps needs nothing: an empty glyph is a valid icon" {
    const p = IconProps{};
    try std.testing.expectEqual(@as(usize, 0), p.glyph.len);
}
