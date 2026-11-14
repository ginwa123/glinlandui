// `MaterialTheme` for this example: one colour scheme and one type scale, handed down the tree.
// Components in this toolkit take their colours as props with neutral defaults and import no theme, so a theme
// is a plain value a screen passes down — which is what Compose's `CompositionLocal` does, minus the magic.
const std = @import("std");
const glinlandui = @import("glinlandui");
const Color = glinlandui.Color;
const box_mod = glinlandui.components.box;
const modifier = @import("modifier.zig");

// `MaterialTheme.colorScheme`, cut down to the roles this screen uses.
pub const Colors = struct {
    background: Color,
    surface: Color,
    surface_variant: Color,
    primary: Color,
    primary_hover: Color,
    on_primary: Color,
    text: Color,
    text_dim: Color,
    text_done: Color,
    divider: Color,
    hover: Color,
};

// `MaterialTheme.typography`, in the four sizes this screen needs.
pub const TypeScale = struct {
    title: u16,
    body: u16,
    label: u16,
    caption: u16,
};

pub const Theme = struct {
    colors: Colors,
    type_scale: TypeScale,
};

pub const dark = Theme{
    .colors = .{
        .background = Color.hexC("#141419"),
        .surface = Color.hexC("#1c1c22"),
        .surface_variant = Color.hexC("#26262e"),
        .primary = Color.hexC("#7aa2c4"),
        .primary_hover = Color.hexC("#8fb4d4"),
        .on_primary = Color.hexC("#101014"),
        .text = Color.hexC("#dcdce2"),
        .text_dim = Color.hexC("#8a8a94"),
        .text_done = Color.hexC("#6a6a74"),
        .divider = Color.hexC("#2e2e38"),
        .hover = Color.hexC("#1f1f26"),
    },
    .type_scale = .{ .title = 18, .body = 14, .label = 13, .caption = 12 },
};

// `Surface(Modifier.fillMaxSize())`: the root every screen sits on, painted with the theme's background.
pub fn Surface(t: Theme, id: []const u8, ctx: anytype, comptime children: fn (@TypeOf(ctx)) void) void {
    const props = (modifier.Modifier{}).fillMaxSize().apply(.{
        .id = id,
        .direction = .column,
        .bg = t.colors.background,
    }, .column);
    box_mod.box(props, ctx, children);
}

// ---- tests ---------------------------------------------------------------------------------------------------

test "the dark theme names every role the view reads" {
    const c = dark.colors;
    try std.testing.expect(c.background.r() != c.surface.r());
    try std.testing.expect(dark.type_scale.body > dark.type_scale.caption);
    try std.testing.expect(dark.type_scale.title > dark.type_scale.body);
}
