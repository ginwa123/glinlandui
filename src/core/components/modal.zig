//! A modal: a scrim over the whole window and a centred card with a title, a sentence and a row of actions.
const std = @import("std");
const cl = @import("zclay");
const prop = @import("../props.zig");
const theme_mod = @import("../theme.zig");
const Color = @import("../color.zig").Color;
const registry = @import("click_registry.zig");
const semantics = @import("../semantics.zig");

/// The card's own id suffix and its action rows' prefix: two string ids, so a row can never collide with its card.
pub const action_prefix = "glin.modal.action";
pub const scrim_prefix = "glin.modal.scrim";

/// Above the context menu (40): a question the app is blocked on owns the window, so no card floats over it.
pub const z_index: i16 = 50;

/// One action: a label, and whether it is the one a person means to press.
pub const Action = struct {
    label: []const u8,
    primary: bool = false,
};

pub const Props = struct {
    id: prop.Id,
    // Where the app declared this widget: `@src()` at the call site, which the devtool then shows as the declaration.
    src: ?std.builtin.SourceLocation = null,
    title: []const u8 = "",
    message: []const u8 = "",
    actions: []const Action = &.{},
    /// Called with the index of the action that was pressed, on the frame AFTER the press.
    on_action: prop.Select = .{},
    // The scrim's size, for a card that does NOT cover the window; 0 means the whole window, which is what an app wants.
    window_w: f32 = 0,
    window_h: f32 = 0,
    card_w: f32 = 420,
    // The card's padding, gap and corner are the theme's (`card_pad`, `row_gap`, `corner(.lg)`) unless the app does.
    pad: prop.Pad = prop.Pad.themed,
    gap: prop.Len = prop.Len.themed,
    radius: prop.Radius = prop.Radius.themed,
    title_size: u16 = 16,
    message_size: u16 = 13,
    action_size: u16 = 13,
    action_h: f32 = 28,
    action_pad: prop.Pad = prop.Pad.themed,
    action_gap: prop.Len = prop.Len.themed,
    action_radius: prop.Radius = prop.Radius.themed,
    scrim: Color = Color.rgba(0x08, 0x08, 0x0a, 170),
    bg: Color = Color.rgb(0x1e, 0x1e, 0x22),
    border: Color = Color.rgb(0x3a, 0x3a, 0x42),
    title_fg: Color = Color.rgb(0xf0, 0xf0, 0xf4),
    fg: Color = Color.rgb(0xc8, 0xc8, 0xd0),
    action_bg: Color = Color.rgb(0x2a, 0x2a, 0x30),
    action_hover: Color = Color.rgb(0x38, 0x38, 0x40),
    action_fg: Color = Color.rgb(0xe8, 0xe8, 0xee),
    primary: Color = Color.rgb(0x4a, 0x7a, 0x5a),
    primary_hover: Color = Color.rgb(0x55, 0x8c, 0x67),
    primary_fg: Color = Color.rgb(0xf4, 0xfa, 0xf6),
};

/// The handler the rows call: a press is dispatched on a later frame, so the props it came from are long gone.
var shown: ?prop.Select = null;

// A press on the scrim goes nowhere: the window under the question must not react to it.
fn onScrim(_: ?*anyopaque, _: usize) void {}

fn onAction(_: ?*anyopaque, index: usize) void {
    const sel = shown orelse return;
    if (sel.f) |f| f(sel.ctx, index);
}

/// The row ids: an action is `IDI(action_prefix, index)`, so a test can press one by name.
pub fn actionId(index: usize) cl.ElementId {
    return .IDI(action_prefix, @intCast(index));
}

/// Draw the scrim and the card. Called by the app, inside its own tree, while the question is up.
pub fn modal(p: Props) void {
    shown = p.on_action;
    const m = theme_mod.current().metrics;
    semantics.registerAt(@src(), .{
        .declared = semantics.declaredAt(p.src),
        .id = p.id.clay(),
        .tag = p.id.str(),
        .role = .list,
        .label = p.title,
        .flags = .{ .enabled = true },
    });

    // The scrim first: it is below the card, so the card's own targets win the hit test.
    cl.UI()(.{
        .id = .ID(scrim_prefix),
        // No size asked for means the root itself: a floating element that grows takes the dimensions it attaches to.
        .layout = .{ .sizing = .{
            .w = if (p.window_w > 0) .fixed(p.window_w) else .grow,
            .h = if (p.window_h > 0) .fixed(p.window_h) else .grow,
        } },
        .floating = .{
            .attach_to = .to_root,
            .attach_points = .{ .element = .left_top, .parent = .left_top },
            .z_index = z_index,
        },
        .background_color = p.scrim.toClay(),
    })({});
    registry.registerZ(.ID(scrim_prefix), onScrim, null, 0, z_index);

    cl.UI()(.{
        .id = p.id.clay(),
        .layout = .{
            .direction = .top_to_bottom,
            .sizing = .{ .w = .fixed(p.card_w), .h = .fit },
            .padding = p.pad.resolve(m.card_pad).clay(),
            .child_gap = p.gap.resolve(m.row_gap).whole(),
        },
        .floating = .{
            .attach_to = .to_root,
            .attach_points = .{ .element = .center_center, .parent = .center_center },
            .z_index = z_index + 1,
        },
        .background_color = p.bg.toClay(),
        .corner_radius = p.radius.resolve(m.corner(.lg)).clay(),
        .border = .{ .color = p.border.toClay(), .width = .outside(m.hairline.whole()) },
    })({
        if (p.title.len > 0) cl.text(p.title, .{ .font_size = p.title_size, .color = p.title_fg.toClay() });
        if (p.message.len > 0) cl.text(p.message, .{ .font_size = p.message_size, .color = p.fg.toClay(), .wrap_mode = .words });
        actionRow(p);
    });
}

// The actions sit at the card's right edge, the primary one last: the order a person reads them in.
fn actionRow(p: Props) void {
    const m = theme_mod.current().metrics;
    cl.UI()(.{
        .id = .IDI(p.id.str(), 1),
        .layout = .{
            .direction = .left_to_right,
            .sizing = .{ .w = .grow, .h = .fit },
            .child_gap = p.action_gap.resolve(m.action_gap).whole(),
            .child_alignment = .{ .x = .right, .y = .center },
        },
    })({
        for (p.actions, 0..) |action, i| actionButton(p, action, i);
    });
}

fn actionButton(p: Props, action: Action, index: usize) void {
    const m = theme_mod.current().metrics;
    const id = actionId(index);
    const hovered = cl.pointerOver(id);
    cl.UI()(.{
        .id = id,
        .layout = .{
            .sizing = .{ .w = .fit, .h = .fixed(p.action_h) },
            .padding = p.action_pad.resolve(m.action_pad).clay(),
            .child_alignment = .center,
        },
        .background_color = (if (hovered)
            (if (action.primary) p.primary_hover else p.action_hover)
        else
            (if (action.primary) p.primary else p.action_bg)).toClay(),
        .corner_radius = p.action_radius.resolve(m.corner(.md)).clay(),
    })({
        cl.text(action.label, .{
            .font_size = p.action_size,
            .color = (if (action.primary) p.primary_fg else p.action_fg).toClay(),
        });
    });
    registry.registerZ(id, onAction, null, index, z_index + 2);
}

const testing = std.testing;
const headless = @import("../testing/headless.zig");

// The size `headless.begin` gives the root: the scrim covers it and the card centres inside it.
const canvas_w: u32 = 720;
const canvas_h: u32 = 480;

const pick = struct {
    var calls: usize = 0;
    var last: usize = 0;
};

fn onPick(ctx: ?*anyopaque, index: usize) void {
    _ = ctx;
    pick.calls += 1;
    pick.last = index;
}

const actions = [_]Action{ .{ .label = "Cancel" }, .{ .label = "Save and quit", .primary = true } };

fn draw() []cl.RenderCommand {
    registry.beginFrame();
    headless.begin(.{ .x = 99999, .y = 99999 }, false);
    cl.beginLayout();
    modal(.{
        .id = .{ .text = "test-modal" },
        .title = "Unsaved changes",
        .message = "This endpoint is not saved yet.",
        .actions = &actions,
        .on_action = .{ .f = onPick, .ctx = null },
    });
    return cl.endLayout();
}

test "a modal draws its title, its sentence and one row per action, centred in the window" {
    pick.calls = 0;
    pick.last = 0;
    _ = draw();

    const card = cl.getElementData(cl.getElementId("test-modal")).bounding_box;
    try testing.expect(card.width > 0 and card.height > 0);
    try testing.expectApproxEqAbs(@as(f32, @floatFromInt(canvas_w)) / 2, card.x + card.width / 2, 1.5);
    try testing.expectApproxEqAbs(@as(f32, @floatFromInt(canvas_h)) / 2, card.y + card.height / 2, 1.5);
    // No window size was handed in: the scrim took the whole root, which is what an app should get for free.
    const scrim = cl.getElementData(.ID(scrim_prefix)).bounding_box;
    try testing.expectApproxEqAbs(@as(f32, 0), scrim.x, 0.5);
    try testing.expectApproxEqAbs(@as(f32, 0), scrim.y, 0.5);
    try testing.expectApproxEqAbs(@as(f32, @floatFromInt(canvas_w)), scrim.width, 0.5);
    try testing.expectApproxEqAbs(@as(f32, @floatFromInt(canvas_h)), scrim.height, 0.5);
    for (actions, 0..) |_, i| try testing.expect(cl.getElementData(actionId(i)).found);

    // Every action sits inside the card it belongs to, in the order it was handed in.
    const first = cl.getElementData(actionId(0)).bounding_box;
    const second = cl.getElementData(actionId(1)).bounding_box;
    try testing.expect(first.x >= card.x and first.x + first.width <= card.x + card.width);
    try testing.expect(second.x > first.x);
}

test "pressing an action reports its index, and a press on the scrim goes nowhere" {
    pick.calls = 0;
    pick.last = 0;
    _ = draw();

    // Outside the card, over the dimmed window: swallowed, so the app under it never reacts.
    try testing.expect(registry.dispatchClick(4, 4));
    try testing.expectEqual(@as(usize, 0), pick.calls);

    const second = cl.getElementData(actionId(1)).bounding_box;
    try testing.expect(registry.dispatchClick(second.x + second.width * 0.5, second.y + second.height * 0.5));
    try testing.expectEqual(@as(usize, 1), pick.calls);
    try testing.expectEqual(@as(usize, 1), pick.last);
}

test "a modal with no actions still draws its question, and the scrim still holds the window" {
    registry.beginFrame();
    headless.begin(.{ .x = 99999, .y = 99999 }, false);
    cl.beginLayout();
    modal(.{
        .id = .{ .text = "test-modal-bare" },
        .title = "Working",
        .window_w = @floatFromInt(canvas_w),
        .window_h = @floatFromInt(canvas_h),
    });
    _ = cl.endLayout();
    try testing.expect(cl.getElementData(cl.getElementId("test-modal-bare")).found);
    try testing.expect(!cl.getElementData(actionId(0)).found);
}
