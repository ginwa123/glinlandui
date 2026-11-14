// The app's palette, and the surface it sits on.
// The engine ships `glinlandui.theme.Theme` and a neutral dark default; an app copies it and changes the roles it
// cares about. Nothing here is global: the theme is a value the screen passes down, so a second screen may differ.
const std = @import("std");
const glinlandui = @import("glinlandui");
const Color = glinlandui.Color;
const box_mod = glinlandui.components.box;
const Theme = glinlandui.theme.Theme;

// The engine's dark theme with this app's accent: a warmer blue than the neutral default.
pub const dark = blk: {
    var t = glinlandui.theme.dark;
    t.colors.primary = Color.hexC("#8aa9c9");
    t.colors.primary_hover = Color.hexC("#9dbad9");
    break :blk t;
};

// `Surface(Modifier.fillMaxSize())`: the root every screen sits on. A box, plus the background role.
pub fn Surface(t: Theme, id: []const u8, ctx: anytype, comptime children: fn (@TypeOf(ctx)) void) void {
    box_mod.box(.{
        .id = id,
        .w = .grow,
        .h = .grow,
        .direction = .column,
        .bg = t.colors.background,
    }, ctx, children);
}

// ---- tests ---------------------------------------------------------------------------------------------------

test "the app's accent differs from the engine's default, and nothing else moved" {
    try std.testing.expect(dark.colors.primary.value != glinlandui.theme.dark.colors.primary.value);
    try std.testing.expectEqual(glinlandui.theme.dark.colors.background.value, dark.colors.background.value);
    try std.testing.expectEqual(glinlandui.theme.dark.type_scale.body, dark.type_scale.body);
}
