// A theme as a value: the colours and the type scale an app passes down its tree.

// This is `MaterialTheme`'s shape, not a global palette — the components here take their colours as props, so a theme is something you hand to a screen.

// `dark` and `light` are neutral defaults; `dragon` is the Kanagawa Dragon kit, and an app may copy any of them.
const std = @import("std");
const Color = @import("color.zig").Color;

// The colour roles a screen reads. Fewer than Material's thirty, and each one is a role rather than a shade.
pub const Colors = struct {
    // The screen's base, behind everything.
    background: Color,
    // Raised surfaces: fields, cards, the row a pointer is over.
    surface: Color,
    surface_variant: Color,
    // The accent: a primary button, a caret, a checked box.
    primary: Color,
    primary_hover: Color,
    // Text drawn ON the primary colour.
    on_primary: Color,
    // Text roles.
    text: Color,
    text_dim: Color,
    // Text of something already done: present, and deliberately quiet.
    text_done: Color,
    // Hairlines and field borders.
    divider: Color,
    // The row under the pointer.
    hover: Color,
};

// The type scale, in points. Four sizes cover a list screen; an app that needs more adds fields.
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

pub const light = Theme{
    .colors = .{
        .background = Color.hexC("#fbfbfd"),
        .surface = Color.hexC("#ffffff"),
        .surface_variant = Color.hexC("#eeeef3"),
        .primary = Color.hexC("#2f6ea8"),
        .primary_hover = Color.hexC("#3d80bd"),
        .on_primary = Color.hexC("#ffffff"),
        .text = Color.hexC("#1a1a1e"),
        .text_dim = Color.hexC("#66666e"),
        .text_done = Color.hexC("#9a9aa2"),
        .divider = Color.hexC("#d8d8de"),
        .hover = Color.hexC("#f0f0f5"),
    },
    .type_scale = .{ .title = 18, .body = 14, .label = 13, .caption = 12 },
};

// Kanagawa Dragon: the same eleven roles, ink on paper — the palette the UI kit specifies.
pub const dragon = Theme{
    .colors = .{
        .background = Color.hexC("#0d0c0c"),
        .surface = Color.hexC("#12120f"),
        .surface_variant = Color.hexC("#1d1c19"),
        .primary = Color.hexC("#8ba4b0"),
        .primary_hover = Color.hexC("#a3b9c3"),
        .on_primary = Color.hexC("#0d0c0c"),
        .text = Color.hexC("#c5c9c5"),
        .text_dim = Color.hexC("#a6a69c"),
        .text_done = Color.hexC("#625e5a"),
        .divider = Color.hexC("#393836"),
        .hover = Color.hexC("#282727"),
    },
    .type_scale = .{ .title = 18, .body = 14, .label = 13, .caption = 12 },
};

// The one tone no role covers: the selected row. A fill is not a cue on its own, so a component draws a bar too.
pub const selected = Color.hexC("#223249");

// ---- tests ---------------------------------------------------------------------------------------------------

test "both palettes name every role, and the two differ where it matters" {
    const roles = std.meta.fields(Colors);
    try std.testing.expectEqual(@as(usize, 11), roles.len);

    // Text must be readable on the background it is drawn over, in both directions.
    try std.testing.expect(dark.colors.text.r() > dark.colors.background.r());
    try std.testing.expect(light.colors.text.r() < light.colors.background.r());
    // A hover tone is a step away from the surface it sits on, not the same colour.
    try std.testing.expect(dark.colors.hover.r() != dark.colors.background.r());
}

test "dragon is the kit's ink-on-paper palette" {
    const c = dragon.colors;
    // Body text on the background is what the kit's 11.7:1 claim rests on.
    try std.testing.expect(c.text.r() > c.background.r());
    try std.testing.expect(c.text_dim.r() > c.background.r());
    // The accent is cooler than the paper, and its label is the background tone, not white.
    try std.testing.expect(c.primary.b() > c.primary.r());
    try std.testing.expectEqual(c.background, c.on_primary);
    // Every surface is a step up from the background, so a panel reads as a panel.
    try std.testing.expect(c.surface.r() > c.background.r());
    try std.testing.expect(c.surface_variant.r() > c.surface.r());
    try std.testing.expect(c.hover.r() > c.surface_variant.r());
    // The selection tone is a fill, not the accent: it never competes with the one accent a view gets.
    try std.testing.expect(selected.r() < c.primary.r());
}

test "the type scale is ordered, so a caption is never larger than a title" {
    for ([_]Theme{ dark, light, dragon }) |t| {
        try std.testing.expect(t.type_scale.title > t.type_scale.body);
        try std.testing.expect(t.type_scale.body >= t.type_scale.label);
        try std.testing.expect(t.type_scale.label > t.type_scale.caption);
    }
}
