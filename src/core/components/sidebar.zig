//! A resizable, collapsible panel with a vertical grab line: the app hands it children, it owns the width and the drag.
const std = @import("std");
const cl = @import("zclay");
const headless = @import("../testing/headless.zig");
const Color = @import("../color.zig").Color;
const prop = @import("../props.zig");
const frame_mod = @import("../frame.zig");
const registry = @import("click_registry.zig");
const semantics = @import("../semantics.zig");

/// Which side of its grab line the panel sits on: a left sidebar keeps the line on its right edge.
pub const Side = enum { left, right };

/// The panel's own state, owned by the app and mutated by the component across frames.
pub const State = struct {
    width: f32 = 280,
    /// The width a click brings back after a collapse.
    expanded_width: f32 = 280,
    collapsed: bool = false,
    // Drag bookkeeping, owned here so the app never has to track a gesture.
    dragging: bool = false,
    drag_origin_x: f32 = 0,
    drag_origin_width: f32 = 0,
};

pub const Props = struct {
    id: prop.Id,
    // Where the app declared this panel: `@src()` at the call site, which the devtool shows as the declaration.
    src: ?std.builtin.SourceLocation = null,
    state: *State,
    side: Side = .left,
    h: prop.Size = .grow,
    min_width: f32 = 160,
    max_width: f32 = 560,
    /// The width a collapsed panel keeps: 0 hides it, 48 leaves an icon rail.
    collapsed_width: u16 = 0,
    /// A drag narrower than this snaps the panel shut; 0 means a drag never collapses it.
    collapse_below: f32 = 110,
    handle_width: u16 = 7,
    /// How far either side of the line a press still grabs it, in points: a 7-point line is a small target.
    handle_slop: f32 = 3,
    bg: Color = Color.rgb(0x1c, 0x1c, 0x22),
    handle_bg: Color = Color.rgb(0x26, 0x26, 0x2e),
    handle_hover_bg: Color = Color.rgb(0x3c, 0x3c, 0x46),
    handle_active_bg: Color = Color.rgb(0x7a, 0xa2, 0xc4),
};

/// The width the panel draws at right now.
pub fn width(p: Props) f32 {
    if (p.state.collapsed) return @floatFromInt(p.collapsed_width);
    return clampWidth(p, p.state.width);
}

fn clampWidth(p: Props, want: f32) f32 {
    var w = want;
    if (w < p.min_width) w = p.min_width;
    if (p.max_width > p.min_width and w > p.max_width) w = p.max_width;
    return w;
}

/// Declare the panel and its grab line. The app declares whatever sits beside it after this call, with `.w = .grow`.
pub fn sidebar(p: Props, ctx: anytype, comptime children: fn (@TypeOf(ctx)) void) void {
    // The limits are props, so they are applied here every frame instead of being remembered in the state.
    p.state.width = clampWidth(p, p.state.width);
    trackDrag(p);
    if (p.side == .right) {
        handle(p);
        panel(p, ctx, children);
    } else {
        panel(p, ctx, children);
        handle(p);
    }
}

// The grab line's own element id: the panel keeps `id`, the line takes the (name, 1) pair beside it.
fn handleId(p: Props) cl.ElementId {
    return .IDI(p.id.str(), 1);
}

// The drag gesture: anchor on the press, follow the pointer, and let the width (or the collapse) fall out of it.
fn trackDrag(p: Props) void {
    const s = p.state;
    if (!frame_mod.ptr_down) {
        s.dragging = false;
        return;
    }
    if (!s.dragging) {
        if (!pressBeganOn(p)) return;
        s.dragging = true;
        // The anchor is where the pointer WENT DOWN, so the first move of a fast drag is not swallowed.
        s.drag_origin_x = frame_mod.ptr_press_x;
        s.drag_origin_width = width(p);
    }
    const delta = frame_mod.ptr_x - s.drag_origin_x;
    const moved = if (p.side == .left) delta else -delta;
    const want = s.drag_origin_width + moved;
    if (p.collapse_below > 0 and want < p.collapse_below) {
        s.collapsed = true;
        // Remember the minimum rather than ~0, so dragging back out reopens as soon as the pointer passes the threshold.
        s.width = p.min_width;
        return;
    }
    s.collapsed = false;
    s.width = clampWidth(p, want);
    s.expanded_width = s.width;
}

// The press is hit-tested against the line's box from the previous frame, which is the one the pointer went down on.
fn pressBeganOn(p: Props) bool {
    const data = cl.getElementData(handleId(p));
    if (!data.found) return false;
    const box = data.bounding_box;
    const x = frame_mod.ptr_press_x;
    const y = frame_mod.ptr_press_y;
    return x >= box.x - p.handle_slop and x <= box.x + box.width + p.handle_slop and
        y >= box.y and y <= box.y + box.height;
}

fn panel(p: Props, ctx: anytype, comptime children: fn (@TypeOf(ctx)) void) void {
    const w = width(p);
    if (w <= 0) return;
    cl.UI()(.{
        .id = p.id.clay(),
        .layout = .{
            .direction = .top_to_bottom,
            .sizing = .{ .w = .fixed(w), .h = p.h.clay() },
        },
        .background_color = p.bg.toClay(),
        // Narrower than its content: clip at the edge rather than paint over the area beside it.
        .clip = .{ .horizontal = true, .vertical = true },
    })({
        children(ctx);
    });
    semantics.registerAt(@src(), .{
        .declared = semantics.declaredAt(p.src),
        .id = p.id.clay(),
        .tag = p.id.str(),
        .role = .container,
        .flags = .{ .enabled = true },
    });
}

fn handle(p: Props) void {
    const s = p.state;
    const id = handleId(p);
    const active = s.dragging;
    cl.UI()(.{
        .id = id,
        .layout = .{ .sizing = .{ .w = .fixed(@floatFromInt(p.handle_width)), .h = p.h.clay() } },
        .background_color = (if (active) p.handle_active_bg else if (cl.pointerOver(id)) p.handle_hover_bg else p.handle_bg).toClay(),
    })({});
    // The line is the drag affordance, so it says so with the resize cursor; a click reopens a collapsed panel.
    registry.registerClickCursor(id, onHandleClick, s, .ew_resize);
    semantics.registerAt(@src(), .{
        .declared = semantics.declaredAt(p.src),
        .id = id,
        .tag = "sidebar.handle",
        .role = .button,
        .label = "Resize",
        .flags = .{ .enabled = true },
        .actions = .{ .click = true, .drag = true },
    });
}

// A click on the line reopens a collapsed panel. A drag is what resizes it, and the registry only fires when the pointer barely moved.
fn onHandleClick(raw: ?*anyopaque) void {
    const s: *State = @ptrCast(@alignCast(raw.?));
    if (!s.collapsed) return;
    s.collapsed = false;
    s.width = s.expanded_width;
}

// ---- tests ---------------------------------------------------------------------------------------------------

var test_state: State = .{};

fn testProps() Props {
    return .{ .id = .{ .text = "test-sidebar" }, .state = &test_state };
}

fn noChildren(_: void) void {}

fn declareSidebar() void {
    sidebar(testProps(), {}, noChildren);
}

// A press on the line, one frame, the way the Host delivers one.
fn pressLine(x: f32, y: f32) void {
    frame(x, y, true, x, y);
}

// One frame driven the way the Host drives one: pointer, press origin, registries, layout — Clay's context is initialized once.
fn frame(pointer_x: f32, pointer_y: f32, down: bool, press_x: f32, press_y: f32) void {
    registry.beginFrame();
    frame_mod.setPointer(pointer_x, pointer_y);
    frame_mod.setPointerButton(down, press_x, press_y);
    cl.setPointerState(.{ .x = pointer_x, .y = pointer_y }, down);
    cl.beginLayout();
    declareSidebar();
    _ = cl.endLayout();
}

fn panelBox() cl.BoundingBox {
    return cl.getElementData(cl.getElementId("test-sidebar")).bounding_box;
}

fn handleBox() cl.BoundingBox {
    return cl.getElementData(cl.ElementId.IDI("test-sidebar", 1)).bounding_box;
}

// A fresh state and a fresh Clay context; every frame after this one shares that context.
fn begin() void {
    test_state = .{};
    registry.beginFrame();
    frame_mod.setPointer(99999, 99999);
    frame_mod.setPointerButton(false, 0, 0);
    headless.begin(.{ .x = 99999, .y = 99999 }, false);
    cl.beginLayout();
    declareSidebar();
    _ = cl.endLayout();
}

test "the panel takes the state's width and the grab line sits on its trailing edge" {
    begin();
    test_state.width = 300;
    frame(99999, 99999, false, 0, 0);

    const body = panelBox();
    const grip = handleBox();
    try std.testing.expectEqual(@as(f32, 300), body.width);
    try std.testing.expectEqual(body.x + 300, grip.x);
    try std.testing.expectEqual(@as(f32, 7), grip.width);
    try std.testing.expectEqual(@as(f32, 480), grip.height);
}

test "a drag on the line widens the panel, and stops at the maximum" {
    begin();
    const grip = handleBox();
    const grab_x = grip.x + grip.width * 0.5;

    pressLine(grab_x, 200);
    try std.testing.expect(test_state.dragging);
    try std.testing.expectApproxEqAbs(@as(f32, 280), test_state.width, 0.01);
    frame(grab_x + 100, 200, true, grab_x, 200);
    try std.testing.expectApproxEqAbs(@as(f32, 380), test_state.width, 0.01);

    // Far past the maximum: clamped, not followed.
    frame(grab_x + 900, 200, true, grab_x, 200);
    try std.testing.expectApproxEqAbs(@as(f32, 560), test_state.width, 0.01);
    // And the release ends the gesture, leaving the width where the drag put it.
    frame(grab_x + 900, 200, false, grab_x, 200);
    try std.testing.expect(!test_state.dragging);
    try std.testing.expectApproxEqAbs(@as(f32, 560), test_state.width, 0.01);
}

test "dragging the line past the threshold collapses the panel, and a click on it reopens it" {
    begin();
    const grip = handleBox();
    const grab_x = grip.x + grip.width * 0.5;

    pressLine(grab_x, 200);
    // Left of the panel's minimum: the panel snaps shut rather than becoming a sliver.
    frame(grab_x - 400, 200, true, grab_x, 200);
    try std.testing.expect(test_state.collapsed);
    try std.testing.expectEqual(@as(f32, 0), width(testProps()));

    // A collapsed panel still draws its line, at the window's edge, or nothing could reopen it.
    frame(grab_x - 400, 200, false, grab_x, 200);
    const closed = handleBox();
    try std.testing.expectEqual(@as(f32, 7), closed.width);
    try std.testing.expectEqual(@as(f32, 0), closed.x);

    // The line is a click target: clicking it puts the panel back to the width it had.
    const centre_x = closed.x + closed.width * 0.5;
    frame(centre_x, 200, false, 0, 0);
    try std.testing.expect(registry.dispatchClick(centre_x, 200));
    try std.testing.expect(!test_state.collapsed);
    try std.testing.expectApproxEqAbs(@as(f32, 280), test_state.width, 0.01);
}

test "a press that began off the line does not resize the panel" {
    begin();
    // Pressed inside the panel, well away from the line, then dragged across it.
    frame(40, 200, true, 40, 200);
    try std.testing.expect(!test_state.dragging);
    frame(400, 200, true, 40, 200);
    try std.testing.expectApproxEqAbs(@as(f32, 280), test_state.width, 0.01);
}

test "a collapsed panel keeps the rail width the app asked for" {
    test_state = .{ .collapsed = true };
    var p = testProps();
    p.collapsed_width = 48;
    try std.testing.expectEqual(@as(f32, 48), width(p));

    headless.begin(.{ .x = 99999, .y = 99999 }, false);
    cl.beginLayout();
    sidebar(p, {}, noChildren);
    _ = cl.endLayout();
    try std.testing.expectEqual(@as(f32, 48), panelBox().width);
}
