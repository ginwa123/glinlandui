//! A draggable divider between two panes: the app owns the pane's size, this owns the drag across frames.
const std = @import("std");
const cl = @import("zclay");
const headless = @import("../testing/headless.zig");
const Color = @import("../color.zig").Color;
const prop = @import("../props.zig");
const frame_mod = @import("../frame.zig");
const registry = @import("click_registry.zig");
const semantics = @import("../semantics.zig");

/// The line's own direction: a horizontal line separates panes stacked vertically and drags along Y.
pub const Axis = enum { horizontal, vertical };

/// Which side of the line the pane whose size this line drags sits on.
pub const Side = enum { before, after };

/// The app owns this: the size it asks for, plus the gesture the widget tracks.
pub const State = struct {
    size: f32 = 300,
    dragging: bool = false,
    // Where the pointer went down, and the size at that moment.
    origin: f32 = 0,
    origin_size: f32 = 0,
};

pub const Props = struct {
    id: prop.Id,
    // Where the app declared this line: `@src()` at the call site, which the devtool shows as the declaration.
    src: ?std.builtin.SourceLocation = null,
    state: *State,
    axis: Axis = .horizontal,
    /// A pane below a horizontal line (or right of a vertical one) grows when the line is dragged towards it.
    side: Side = .after,
    min: f32 = 120,
    /// The most the pane may take; 0 means "whatever is left", so the app passes the room it has.
    max: f32 = 0,
    thickness: u16 = 6,
    /// How far either side of the line a press still grabs it, in points: a 6-point line is a small target.
    slop: f32 = 3,
    bg: Color = Color.rgb(0x26, 0x26, 0x2e),
    hover_bg: Color = Color.rgb(0x3c, 0x3c, 0x46),
    active_bg: Color = Color.rgb(0x7a, 0xa2, 0xc4),
};

/// The size the pane draws at right now, with the props' limits applied.
pub fn size(p: Props) f32 {
    return clampSize(p, p.state.size);
}

fn clampSize(p: Props, want: f32) f32 {
    var v = want;
    if (v < p.min) v = p.min;
    if (p.max > p.min and v > p.max) v = p.max;
    return v;
}

fn cursorFor(axis: Axis) prop.Cursor {
    return switch (axis) {
        .horizontal => .ns_resize,
        .vertical => .ew_resize,
    };
}

/// Declare the line. The app gives its pane `size(...)` and lays the two panes out around this call.
pub fn grip(p: Props) void {
    // The limits are props, so they are applied here every frame instead of being remembered in the state.
    p.state.size = clampSize(p, p.state.size);
    trackDrag(p);
    const id = p.id.clay();
    cl.UI()(.{
        .id = id,
        .layout = .{ .sizing = switch (p.axis) {
            .horizontal => .{ .w = .grow, .h = .fixed(@floatFromInt(p.thickness)) },
            .vertical => .{ .w = .fixed(@floatFromInt(p.thickness)), .h = .grow },
        } },
        .background_color = (if (p.state.dragging) p.active_bg else if (cl.pointerOver(id)) p.hover_bg else p.bg).toClay(),
    })({});
    // The line is the drag affordance: it owns no click, so it only says what it does, and the cursor over it says it twice.
    registry.registerHover(id, cursorFor(p.axis));
    semantics.registerAt(@src(), .{
        .declared = semantics.declaredAt(p.src),
        .id = id,
        .tag = p.id.str(),
        .role = .button,
        .label = "Resize",
        .flags = .{ .enabled = true },
        .actions = .{ .drag = true },
    });
}

// The drag gesture: anchor on the press, follow the pointer, and let the size fall out of the delta.
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
        s.origin = pointerAlong(p.axis, frame_mod.ptr_press_x, frame_mod.ptr_press_y);
        s.origin_size = size(p);
    }
    const now = pointerAlong(p.axis, frame_mod.ptr_x, frame_mod.ptr_y);
    const delta = now - s.origin;
    // Towards the pane grows it: below the line that is up (a negative delta), above it down.
    const moved = if (p.side == .before) delta else -delta;
    s.size = clampSize(p, s.origin_size + moved);
}

fn pointerAlong(axis: Axis, x: f32, y: f32) f32 {
    return switch (axis) {
        .horizontal => y,
        .vertical => x,
    };
}

// The press is hit-tested against the line's box from the previous frame, which is the one the pointer went down on.
fn pressBeganOn(p: Props) bool {
    const data = cl.getElementData(p.id.clay());
    if (!data.found) return false;
    const box = data.bounding_box;
    const x = frame_mod.ptr_press_x;
    const y = frame_mod.ptr_press_y;
    const inside_x = x >= box.x and x <= box.x + box.width;
    const inside_y = y >= box.y and y <= box.y + box.height;
    return switch (p.axis) {
        // A horizontal line runs the whole width, so only the distance from it matters.
        .horizontal => inside_x and y >= box.y - p.slop and y <= box.y + box.height + p.slop,
        .vertical => inside_y and x >= box.x - p.slop and x <= box.x + box.width + p.slop,
    };
}

// ---- tests ---------------------------------------------------------------------------------------------------

var test_state: State = .{};

fn testProps() Props {
    return .{ .id = .{ .text = "test-split" }, .state = &test_state, .max = 600 };
}

fn propsBefore() Props {
    var p = testProps();
    p.id = .{ .text = "test-before" };
    p.side = .before;
    return p;
}

// The window: a pane that grows, the line, then the sized pane — which is the arrangement Kurir uses.
fn declareSplit() void {
    cl.UI()(.{
        .id = cl.getElementId("test-split.root"),
        .layout = .{ .direction = .top_to_bottom, .sizing = .{ .w = .fixed(400), .h = .fixed(600) } },
    })({
        pane("test-split.editor", .grow);
        grip(testProps());
        pane("test-split.pane", cl.SizingAxis.fixed(size(testProps())));
    });
}

fn declareBefore() void {
    cl.UI()(.{
        .id = cl.getElementId("test-before.root"),
        .layout = .{ .direction = .top_to_bottom, .sizing = .{ .w = .fixed(400), .h = .fixed(600) } },
    })({
        pane("test-before.pane", cl.SizingAxis.fixed(size(propsBefore())));
        grip(propsBefore());
        pane("test-before.editor", .grow);
    });
}

fn pane(id: []const u8, h: cl.SizingAxis) void {
    cl.UI()(.{
        .id = cl.getElementId(id),
        .layout = .{ .sizing = .{ .w = .grow, .h = h } },
    })({});
}

// One frame driven the way the Host drives one: pointer, press origin, registries, layout — Clay's context is initialized once.
fn frame(x: f32, y: f32, down: bool, press_x: f32, press_y: f32) void {
    frameWith(declareSplit, x, y, down, press_x, press_y);
}

fn frameWith(comptime declare_fn: fn () void, x: f32, y: f32, down: bool, press_x: f32, press_y: f32) void {
    registry.beginFrame();
    frame_mod.setPointer(x, y);
    frame_mod.setPointerButton(down, press_x, press_y);
    cl.setPointerState(.{ .x = x, .y = y }, down);
    cl.beginLayout();
    declare_fn();
    _ = cl.endLayout();
}

fn boxOf(id: []const u8) cl.BoundingBox {
    return cl.getElementData(cl.getElementId(id)).bounding_box;
}

// A fresh state and a fresh Clay context; every frame after this one shares that context.
fn begin() void {
    test_state = .{};
    registry.beginFrame();
    frame_mod.setPointer(99999, 99999);
    frame_mod.setPointerButton(false, 0, 0);
    headless.begin(.{ .x = 99999, .y = 99999 }, false);
    cl.beginLayout();
    declareSplit();
    _ = cl.endLayout();
}

test "the line spans the pane and sits between the two panes it divides" {
    begin();
    const body = boxOf("test-split.editor");
    const line = boxOf("test-split");
    const pane_box = boxOf("test-split.pane");

    // The sized pane took exactly the size, the line sits right above it, and the editor took the rest.
    try std.testing.expectEqual(@as(f32, 300), pane_box.height);
    try std.testing.expectEqual(@as(f32, 294), line.y);
    try std.testing.expectEqual(@as(f32, 6), line.height);
    try std.testing.expectEqual(@as(f32, 400), line.width);
    try std.testing.expectEqual(@as(f32, 294), body.height);
    try std.testing.expectEqual(@as(f32, 300), pane_box.y);
}

test "a drag away from the pane grows it while the pane sits after the line, and the props clamp it" {
    begin();
    const line = boxOf("test-split");
    const grab_y = line.y + line.height * 0.5;

    // A press on the line starts the gesture, and the first move of a fast drag is not swallowed.
    frame(200, grab_y, true, 200, grab_y);
    try std.testing.expect(test_state.dragging);
    try std.testing.expectApproxEqAbs(@as(f32, 300), test_state.size, 0.01);

    // Up by 100: a pane below the line grows.
    frame(200, grab_y - 100, true, 200, grab_y);
    try std.testing.expectApproxEqAbs(@as(f32, 400), test_state.size, 0.01);

    // Down past the minimum: clamped, not followed.
    frame(200, grab_y + 500, true, 200, grab_y);
    try std.testing.expectApproxEqAbs(@as(f32, 120), test_state.size, 0.01);

    // Far up past the maximum: clamped too, and the release ends the gesture where the drag left it.
    frame(200, grab_y - 900, true, 200, grab_y);
    try std.testing.expectApproxEqAbs(@as(f32, 600), test_state.size, 0.01);
    frame(200, grab_y - 900, false, 200, grab_y);
    try std.testing.expect(!test_state.dragging);
    try std.testing.expectApproxEqAbs(@as(f32, 600), test_state.size, 0.01);
}

test "a pane before the line grows the other way: the sign follows the side" {
    // The suite shares the state, so this test starts from the default size like the others.
    test_state = .{};
    headless.begin(.{ .x = 99999, .y = 99999 }, false);
    registry.beginFrame();
    frame_mod.setPointer(99999, 99999);
    frame_mod.setPointerButton(false, 0, 0);
    cl.beginLayout();
    declareBefore();
    _ = cl.endLayout();

    const line = boxOf("test-before");
    const grab_y = line.y + line.height * 0.5;
    try std.testing.expectApproxEqAbs(@as(f32, 300), size(propsBefore()), 0.01);

    // Down by 60: the pane ABOVE the line grows.
    frameWith(declareBefore, 200, grab_y + 60, true, 200, grab_y);
    try std.testing.expectApproxEqAbs(@as(f32, 360), test_state.size, 0.01);
}

test "a press that began off the line does not resize the pane" {
    begin();
    // Pressed inside the editor, well away from the line, then dragged across it.
    frame(200, 100, true, 200, 100);
    try std.testing.expect(!test_state.dragging);
    frame(200, 400, true, 200, 100);
    try std.testing.expectApproxEqAbs(@as(f32, 300), test_state.size, 0.01);
}

test "the line is a hover target with a resize cursor, and registers no click" {
    begin();
    const line = boxOf("test-split");
    // Nothing to click: a line resizes nothing on a click, so it must not swallow one either.
    try std.testing.expect(!registry.dispatchClick(200, line.y + line.height * 0.5));
    try std.testing.expectEqual(prop.Cursor.ns_resize, registry.hoverCursorAt(200, line.y + line.height * 0.5));
}
