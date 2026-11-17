// A theme as a value: the colours and the type scale an app passes down its tree.

// This is `MaterialTheme`'s shape, not a global palette — the components here take their colours as props, so a theme is something you hand to a screen.

// `dark` and `light` are neutral defaults; `dragon` is the Kanagawa Dragon kit, and an app may copy any of them.
const std = @import("std");
const Color = @import("color.zig").Color;
const prop = @import("props.zig");

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
    title: prop.Len,
    body: prop.Len,
    label: prop.Len,
    caption: prop.Len,

    // A scale written the way a designer says it, four sizes in points.
    pub fn of(title: f32, body: f32, label: f32, caption: f32) TypeScale {
        return .{ .title = prop.Len.of(title), .body = prop.Len.of(body), .label = prop.Len.of(label), .caption = prop.Len.of(caption) };
    }
};

// The spacing and shape a component's props fall back to: a role per field, so a theme retunes every widget at once.
pub const Metrics = struct {
    // Padding, by the kind of surface a widget is.
    control_pad: prop.Pad,
    field_pad: prop.Pad,
    chip_pad: prop.Pad,
    card_pad: prop.Pad,
    action_pad: prop.Pad,
    // Gaps: inside a control, between two rows, between a card's actions.
    control_gap: prop.Len,
    row_gap: prop.Len,
    action_gap: prop.Len,
    // Corners, from a ratio bar to a pill.
    radius_xs: prop.Len,
    radius_sm: prop.Len,
    radius_md: prop.Len,
    radius_lg: prop.Len,
    radius_pill: prop.Len,
    // The one-pixel rule a card is outlined with.
    hairline: prop.Len,

    // The numbers the components had hardcoded before the theme owned them: adopting this changes no pixel.
    pub const defaults: Metrics = .{
        .control_pad = prop.Pad.axes(6, 12),
        .field_pad = prop.Pad.axes(0, 10),
        .chip_pad = prop.Pad.axes(1, 6),
        .card_pad = prop.Pad.all(18),
        .action_pad = prop.Pad.axes(0, 14),
        .control_gap = prop.Len.of(8),
        .row_gap = prop.Len.of(12),
        .action_gap = prop.Len.of(8),
        .radius_xs = prop.Len.of(2),
        .radius_sm = prop.Len.of(4),
        .radius_md = prop.Len.of(6),
        .radius_lg = prop.Len.of(8),
        .radius_pill = prop.Len.of(9),
        .hairline = prop.Len.of(1),
    };

    // A corner as the radius a component takes: `metrics.corner(.sm)` reads better than picking the field by hand.
    pub fn corner(self: Metrics, size: Corner) prop.Radius {
        return prop.Radius.all(switch (size) {
            .xs => self.radius_xs.pts(),
            .sm => self.radius_sm.pts(),
            .md => self.radius_md.pts(),
            .lg => self.radius_lg.pts(),
            .pill => self.radius_pill.pts(),
        });
    }
};

// The corner ladder, by name.
pub const Corner = enum { xs, sm, md, lg, pill };

pub const Theme = struct {
    colors: Colors,
    type_scale: TypeScale,
    // The padding, gaps and corners a component prop defaults to; `Metrics.defaults` keeps today's numbers.
    metrics: Metrics,
};

// The theme in force, set by the Host once per frame from the Activity's own: what an unset prop resolves against.
var current_theme: Theme = dark;

// The theme a component reads when a prop left the decision to it.
pub fn current() Theme {
    return current_theme;
}

// The Host sets this each frame; an app that never calls it gets `dark`.
pub fn setCurrent(t: Theme) void {
    current_theme = t;
}

// Theme one subtree of a frame: `theme.scoped(compact, scope, drawList)` retunes the widgets inside it, then the outer theme is back.
pub fn scoped(t: Theme, ctx: anytype, comptime children: fn (@TypeOf(ctx)) void) void {
    const outer = current_theme;
    current_theme = t;
    children(ctx);
    current_theme = outer;
}

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
    .type_scale = TypeScale.of(18, 14, 13, 12),
    .metrics = Metrics.defaults,
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
    .type_scale = TypeScale.of(18, 14, 13, 12),
    .metrics = Metrics.defaults,
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
    .type_scale = TypeScale.of(18, 14, 13, 12),
    .metrics = Metrics.defaults,
};

// A denser kit: the same palette and type, with every spacing role shrunk. One value, and no component changes.
pub const compact = Theme{
    .colors = dark.colors,
    .type_scale = dark.type_scale,
    .metrics = .{
        .control_pad = prop.Pad.axes(3, 8),
        .field_pad = prop.Pad.axes(0, 6),
        .chip_pad = prop.Pad.axes(0, 4),
        .card_pad = prop.Pad.all(12),
        .action_pad = prop.Pad.axes(0, 10),
        .control_gap = prop.Len.of(6),
        .row_gap = prop.Len.of(8),
        .action_gap = prop.Len.of(6),
        .radius_xs = prop.Len.of(1),
        .radius_sm = prop.Len.of(3),
        .radius_md = prop.Len.of(4),
        .radius_lg = prop.Len.of(6),
        .radius_pill = prop.Len.of(7),
        .hairline = prop.Len.of(1),
    },
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
        try std.testing.expect(t.type_scale.title.pts() > t.type_scale.body.pts());
        try std.testing.expect(t.type_scale.body.pts() >= t.type_scale.label.pts());
        try std.testing.expect(t.type_scale.label.pts() > t.type_scale.caption.pts());
    }
}

test "the built-in themes carry the spacing the components used to hardcode" {
    // Every number here was a literal inside a component before the theme owned it, so adopting `defaults` moved no pixel.
    const m = Metrics.defaults;
    try std.testing.expectEqual(@as(f32, 6), m.control_pad.top.pts());
    try std.testing.expectEqual(@as(f32, 12), m.control_pad.left.pts());
    try std.testing.expectEqual(@as(f32, 0), m.field_pad.top.pts());
    try std.testing.expectEqual(@as(f32, 10), m.field_pad.left.pts());
    try std.testing.expectEqual(@as(f32, 1), m.chip_pad.top.pts());
    try std.testing.expectEqual(@as(f32, 18), m.card_pad.top.pts());
    try std.testing.expectEqual(@as(f32, 14), m.action_pad.left.pts());
    try std.testing.expectEqual(@as(f32, 8), m.control_gap.pts());
    try std.testing.expectEqual(@as(f32, 12), m.row_gap.pts());
    try std.testing.expectEqual(@as(f32, 2), m.radius_xs.pts());
    try std.testing.expectEqual(@as(f32, 4), m.radius_sm.pts());
    try std.testing.expectEqual(@as(f32, 6), m.radius_md.pts());
    try std.testing.expectEqual(@as(f32, 8), m.radius_lg.pts());
    try std.testing.expectEqual(@as(f32, 9), m.radius_pill.pts());
    try std.testing.expectEqual(@as(f32, 1), m.hairline.pts());
    // All three palettes start from them, so a theme is a palette plus metrics, not a palette instead of metrics.
    try std.testing.expectEqual(m.control_pad.left.pts(), dark.metrics.control_pad.left.pts());
    try std.testing.expectEqual(m.control_pad.left.pts(), light.metrics.control_pad.left.pts());
    try std.testing.expectEqual(m.control_pad.left.pts(), dragon.metrics.control_pad.left.pts());
}

test "a compact theme moves the padding every widget inherits, and leaves an explicit one alone" {
    // An unset pad follows the theme in force...
    try std.testing.expectEqual(@as(f32, 8), prop.Pad.themed.resolve(compact.metrics.control_pad).left.pts());
    try std.testing.expectEqual(@as(f32, 12), prop.Pad.themed.resolve(dark.metrics.control_pad).left.pts());
    // ...while a pad the app gave is the app's, under any theme.
    try std.testing.expectEqual(@as(f32, 0), prop.Pad.all(0).resolve(compact.metrics.control_pad).left.pts());
    // The compact kit is denser everywhere that matters, and never wider.
    try std.testing.expect(compact.metrics.control_pad.left.pts() < dark.metrics.control_pad.left.pts());
    try std.testing.expect(compact.metrics.row_gap.pts() < dark.metrics.row_gap.pts());
    try std.testing.expect(compact.metrics.corner(.lg).top_left.pts() < dark.metrics.corner(.lg).top_left.pts());
}

test "the theme in force is the window's, and a scoped theme comes back when the subtree ends" {
    setCurrent(dark);
    defer setCurrent(dark);
    const Outer = struct {
        var seen: f32 = 0;
        fn draw(_: *u8) void {
            seen = current().metrics.control_pad.left.pts();
        }
    };
    var ctx: u8 = 0;
    // The subtree sees the theme it was wrapped in...
    scoped(compact, &ctx, Outer.draw);
    try std.testing.expectEqual(@as(f32, 8), Outer.seen);
    // ...and the frame after it is back on the window's theme.
    try std.testing.expectEqual(@as(f32, 12), current().metrics.control_pad.left.pts());
    // An app that never sets one gets `dark`, not an empty theme.
    try std.testing.expectEqual(@as(f32, 12), current().metrics.control_pad.left.pts());
}
