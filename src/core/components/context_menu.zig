//! The context menu: right click a component that offers one and it raises a card of actions at the pointer.
const std = @import("std");
const cl = @import("zclay");
const prop = @import("../props.zig");
const Color = @import("../color.zig").Color;
const frame_mod = @import("../frame.zig");
const registry = @import("click_registry.zig");

// The engine owns the lifecycle: an app declares `props.ContextMenu` on a component and nothing else. No items (the default) = no reaction.

/// The card's own id, and its rows' prefix: two string ids, so a row can never collide with the card it sits in.
pub const menu_id = "glin.context_menu";
pub const row_prefix = "glin.context_menu.row";

/// How many components in one frame may offer a menu; a row-shaped list needs one per row, so this is generous.
pub const target_cap: usize = 128;

/// Where the card sits relative to the pointer, so the first row is under the cursor rather than on it.
pub const pointer_inset: f32 = 2;

/// The float priority of the card: above every in-flow target, below the devtool's overlay.
pub const z_index: i16 = 40;

/// The row ids: a card row is `IDI(row_prefix, index)`, so a test can click one by name.
pub fn rowId(index: usize) cl.ElementId {
    return .IDI(row_prefix, @intCast(index));
}

/// One component that offered a menu this frame. The menu is COPIED, because a component's props live on the declare stack.
const Target = struct {
    id: cl.ElementId,
    menu: prop.ContextMenu,
    clip: ?registry.Clip = null,
    z: i16 = 0,
};

var targets: [target_cap]Target = undefined;
var target_count: usize = 0;

/// The card that is up, if any: what to draw, and where the pointer asked for it.
const Shown = struct {
    menu: prop.ContextMenu,
    x: f32,
    y: f32,
};

var shown: ?Shown = null;

/// Forget last frame's targets; the OPEN card survives, because it was raised before this frame and is drawn in it.
pub fn beginFrame() void {
    target_count = 0;
}

/// A component offers its menu: called by whichever widget carries `props.ContextMenu` when it is not empty.
pub fn register(id: cl.ElementId, menu: prop.ContextMenu, z: i16) void {
    if (menu.items.len == 0) return;
    if (target_count >= target_cap) return;
    targets[target_count] = .{ .id = id, .menu = menu, .clip = registry.currentClip(), .z = z };
    target_count += 1;
}

/// True while a card is up, so the Host knows a press or a key belongs to it.
pub fn isOpen() bool {
    return shown != null;
}

/// The open card's top-left corner, or null. Read by a test, and by the Host to dismiss.
pub fn origin() ?struct { x: f32, y: f32 } {
    const card = shown orelse return null;
    return .{ .x = card.x, .y = card.y };
}

/// Close the card. Harmless when nothing is up.
pub fn close() void {
    shown = null;
}

// The highest-priority target containing the point; a target clipped out of its viewport does not answer.
fn targetAt(x: f32, y: f32) ?Target {
    var best: ?Target = null;
    var i: usize = 0;
    while (i < target_count) : (i += 1) {
        const t = targets[i];
        const data = cl.getElementData(t.id);
        if (!data.found) continue;
        const bb = data.bounding_box;
        if (bb.width <= 0 or bb.height <= 0) continue;
        if (x < bb.x or x >= bb.x + bb.width or y < bb.y or y >= bb.y + bb.height) continue;
        if (!registry.insideClip(t.clip, x, y)) continue;
        if (best == null or t.z >= best.?.z) best = t;
    }
    return best;
}

// The card's own box from the last frame, or null before it was ever drawn.
fn cardBox() ?cl.BoundingBox {
    const data = cl.getElementData(cl.getElementId(menu_id));
    if (!data.found) return null;
    if (data.bounding_box.width <= 0 or data.bounding_box.height <= 0) return null;
    return data.bounding_box;
}

/// A right press at `(x, y)` opens the menu of the component under the pointer, and answers true.
pub fn secondaryClick(x: f32, y: f32, window_w: f32, window_h: f32) bool {
    const target = targetAt(x, y) orelse {
        close();
        return false;
    };
    // The component learns that its card is up before the card exists: a field places its caret at the click here.
    if (target.menu.on_open.f) |f| f(target.menu.on_open.ctx);
    openAt(target.menu, x, y, window_w, window_h);
    return true;
}

/// Raise a menu as if it had been right-clicked at `(x, y)`; an app can also open one from a button.
pub fn openAt(menu: prop.ContextMenu, x: f32, y: f32, window_w: f32, window_h: f32) void {
    if (menu.items.len == 0) return;
    // Keep the card on screen: a click near the right or bottom edge flips it back inside.
    const width = cardWidth(menu);
    const height = menu.row_h.pts() * @as(f32, @floatFromInt(menu.items.len)) + 2 * menu.pad.pts();
    var left = x + pointer_inset;
    var top = y + pointer_inset;
    if (left + width > window_w) left = @max(0, x - width - pointer_inset);
    if (top + height > window_h) top = @max(0, y - height - pointer_inset);
    shown = .{ .menu = menu, .x = frame_mod.snapX(left), .y = top };
}

// An estimate wide enough for the longest label: the card is placed before it is measured, and hanging off the edge is worse than being too wide.
fn cardWidth(menu: prop.ContextMenu) f32 {
    var widest: usize = 0;
    for (menu.items) |label| widest = @max(widest, label.len);
    const glyphs: f32 = @as(f32, @floatFromInt(widest)) * menu.font_size.pts() * 0.62;
    return glyphs + 2 * menu.pad.pts() + menu.row_pad.pts() * 2 + 8;
}

/// A left press at `(x, y)`: true when the card swallowed it, which is a press outside the card that also closes it.
pub fn leftPress(x: f32, y: f32) bool {
    const card = shown orelse return false;
    _ = card;
    if (cardBox()) |bb| {
        const inside = x >= bb.x and x < bb.x + bb.width and y >= bb.y and y < bb.y + bb.height;
        // Inside the card the press belongs to a row, which fires on release through the registry.
        if (inside) return false;
    }
    close();
    return true;
}

// A row was picked: run the handler, then close. The card is gone either way.
fn pick(index: usize) void {
    const card = shown orelse return;
    shown = null;
    // A dimmed row is not an action, even if a click reached it (a test can, and an app may call `pick` through a trampoline).
    if (card.menu.isDisabled(index)) return;
    if (card.menu.on_select.f) |f| f(card.menu.on_select.ctx, index);
}

fn onRow(_: ?*anyopaque, index: usize) void {
    pick(index);
}

// A dimmed row: the card goes away and nothing else happens.
fn onDeadRow(_: ?*anyopaque, _: usize) void {
    close();
}

/// Draw the card: the Host calls this after the app's tree and before the devtool, which stays on top.
pub fn declare() void {
    const card = shown orelse return;
    const menu = card.menu;
    cl.UI()(.{
        .id = .ID(menu_id),
        .layout = .{
            .direction = .top_to_bottom,
            .sizing = .{ .w = .fit, .h = .fit },
            .padding = .all(menu.pad.whole()),
            .child_gap = 0,
        },
        .floating = .{
            .attach_to = .to_root,
            .attach_points = .{ .element = .left_top, .parent = .left_top },
            .offset = .{ .x = card.x, .y = card.y },
            .z_index = z_index,
        },
        .background_color = menu.bg.toClay(),
        .corner_radius = .all(menu.radius.pts()),
        .border = .{ .color = menu.border.toClay(), .width = .outside(1) },
    })({
        // The card is a surface: a click that misses every row is still the card's, never the widget it covers.
        registry.occludeFillZ(.ID(menu_id), menu.bg, z_index);
        for (menu.items, 0..) |label, i| row(menu, label, i);
    });
}

fn row(menu: prop.ContextMenu, label: []const u8, index: usize) void {
    const id = rowId(index);
    // A row nobody can pick draws dim, never highlights, and registers no target at all.
    const dead = menu.isDisabled(index);
    cl.UI()(.{
        .id = id,
        .layout = .{
            .direction = .left_to_right,
            .sizing = .{ .w = .grow, .h = .fixed(menu.row_h.pts()) },
            .padding = .{ .left = menu.row_pad.whole(), .right = menu.row_pad.whole() },
            .child_alignment = .{ .x = .left, .y = .center },
        },
        .background_color = (if (!dead and cl.pointerOver(id)) menu.hover_bg else menu.bg).toClay(),
        .corner_radius = .all(@max(menu.radius.pts() - 2, 0)),
    })({
        cl.text(label, .{ .font_size = menu.font_size.whole(), .color = (if (dead) menu.disabled_fg else menu.fg).toClay() });
    });
    if (dead) {
        // A dimmed row still swallows its click, so the widget under the card never takes it, and does nothing.
        registry.registerZ(id, onDeadRow, null, index, z_index + 1);
        return;
    }
    // The index rides in the entry's own field, so one trampoline serves every row.
    registry.registerZCursor(id, onRow, null, index, z_index + 1, .pointer);
}

const testing = std.testing;
const headless = @import("../testing/headless.zig");
const box_mod = @import("box.zig");

const canvas_w: u32 = 480;
const canvas_h: u32 = 320;

// ONE canvas for the file: Clay keeps a context pointer, so re-initialising after a free() reads released memory.
var canvas: ?[]u8 = null;

fn canvasOnce() void {
    if (canvas != null) return;
    const mem = std.heap.page_allocator.alloc(u8, cl.minMemorySize()) catch @panic("OOM");
    const arena = cl.Arena.init(mem);
    _ = cl.initialize(arena, .{ .w = canvas_w, .h = canvas_h }, .{});
    cl.setMeasureTextFunction(void, {}, headless.stubMeasure);
    canvas = mem;
}

var pick_ctx: struct { calls: usize = 0, last: usize = 0 } = .{};

fn onPick(ctx: ?*anyopaque, index: usize) void {
    const c: *@TypeOf(pick_ctx) = @ptrCast(@alignCast(ctx.?));
    c.calls += 1;
    c.last = index;
}

const items = [_][]const u8{ "Rename", "Duplicate", "Delete" };

fn declareRow(menu: prop.ContextMenu) void {
    box_mod.box(.{
        .id = .{ .text = "test-cm-row" },
        .direction = .row,
        .w = .{ .fixed = 200 },
        .h = .{ .fixed = 40 },
        .context_menu = menu,
    }, {}, struct {
        fn children(_: void) void {}
    }.children);
}

// One frame: the app's tree, and the card when the engine has one open.
fn draw(menu: prop.ContextMenu, card: bool) []cl.RenderCommand {
    registry.beginFrame();
    beginFrame();
    cl.setPointerState(.{ .x = 99999, .y = 99999 }, false);
    cl.beginLayout();
    declareRow(menu);
    if (card) declare();
    return cl.endLayout();
}

fn rowBox() cl.BoundingBox {
    return cl.getElementData(cl.getElementId("test-cm-row")).bounding_box;
}

fn reset() void {
    canvasOnce();
    pick_ctx = .{};
    close();
}

test "a component with no menu never answers a right click" {
    reset();
    _ = draw(.{}, false);
    const empty = prop.ContextMenu{};
    try testing.expect(empty.isNone());
    // The row is there, and a right click on it is nobody's: the devtool would get it.
    const bb = rowBox();
    try testing.expect(!secondaryClick(bb.x + 5, bb.y + 5, canvas_w, canvas_h));
    try testing.expect(!isOpen());
}

test "a right click opens the menu at the pointer, and a row runs the app's handler" {
    reset();
    const menu = prop.ContextMenu{ .items = &items, .on_select = .{ .f = onPick, .ctx = &pick_ctx } };

    _ = draw(menu, false);
    const bb = rowBox();
    try testing.expect(secondaryClick(bb.x + 10, bb.y + 10, canvas_w, canvas_h));
    try testing.expect(isOpen());
    const at = origin().?;
    // Just past the pointer, so the first row is under the cursor rather than on it.
    try testing.expectEqual(bb.x + 10 + pointer_inset, at.x);

    // The card is drawn on the next frame: every row has a box, and the card sits where the click was.
    _ = draw(menu, true);
    for (0..items.len) |i| {
        try testing.expect(cl.getElementData(rowId(i)).found);
    }
    const card = cl.getElementData(cl.getElementId(menu_id)).bounding_box;
    try testing.expectApproxEqAbs(bb.x + 10 + pointer_inset, card.x, 1.5);
    try testing.expectApproxEqAbs(bb.y + 10 + pointer_inset, card.y, 1.5);
    try testing.expect(card.width > 0 and card.height > 0);
    const row1 = cl.getElementData(rowId(1)).bounding_box;
    try testing.expect(registry.dispatchClick(row1.x + row1.width * 0.5, row1.y + row1.height * 0.5));
    try testing.expectEqual(@as(usize, 1), pick_ctx.calls);
    try testing.expectEqual(@as(usize, 1), pick_ctx.last);
    // Picking a row closes the card.
    try testing.expect(!isOpen());
}

// Colours are compared value by value: `expectEqualDeep` reports, it does not answer.
fn sameColor(a: [4]f32, b: [4]f32) bool {
    for (a, b) |x, y| {
        if (x != y) return false;
    }
    return true;
}

var open_count: usize = 0;

fn onOpenCount(_: ?*anyopaque) void {
    open_count += 1;
}

test "a component's on_open runs when its card is raised, and not again while it is drawn" {
    reset();
    open_count = 0;
    const menu = prop.ContextMenu{ .items = &items, .on_select = .{ .f = onPick, .ctx = &pick_ctx }, .on_open = .{ .f = onOpenCount } };
    _ = draw(menu, false);
    try testing.expectEqual(@as(usize, 0), open_count);
    const bb = rowBox();
    try testing.expect(secondaryClick(bb.x + 10, bb.y + 10, canvas_w, canvas_h));
    try testing.expectEqual(@as(usize, 1), open_count);
    // Drawing the card is not raising it: a card that stays up must not re-run the open handler every frame.
    _ = draw(menu, true);
    try testing.expectEqual(@as(usize, 1), open_count);
    close();
}

test "a disabled row draws dim, swallows its click and runs nothing" {
    reset();
    const flags = [_]bool{ false, true, false };
    const menu = prop.ContextMenu{ .items = &items, .disabled = &flags, .on_select = .{ .f = onPick, .ctx = &pick_ctx } };
    _ = draw(menu, false);
    const bb = rowBox();
    try testing.expect(secondaryClick(bb.x + 10, bb.y + 10, canvas_w, canvas_h));

    // Its label is drawn in the dim colour, a live row keeps the card's own colour.
    const cmds = draw(menu, true);
    var saw_live = false;
    var saw_dim = false;
    for (cmds) |c| {
        if (c.command_type != .text) continue;
        const run = c.render_data.text.string_contents;
        const bytes = run.chars[0..@intCast(run.length)];
        if (std.mem.eql(u8, bytes, "Duplicate")) saw_dim = sameColor(menu.disabled_fg.toClay(), c.render_data.text.text_color);
        if (std.mem.eql(u8, bytes, "Rename")) saw_live = sameColor(menu.fg.toClay(), c.render_data.text.text_color);
    }
    try testing.expect(saw_live);
    try testing.expect(saw_dim);

    // The click is swallowed by the card, so the widget under it never sees it, and no handler runs.
    const dead = cl.getElementData(rowId(1)).bounding_box;
    try testing.expect(registry.dispatchClick(dead.x + 4, dead.y + 4));
    try testing.expectEqual(@as(usize, 0), pick_ctx.calls);
    try testing.expect(!isOpen());

    // A live row still answers on the same card.
    _ = draw(menu, false);
    _ = secondaryClick(bb.x + 10, bb.y + 10, canvas_w, canvas_h);
    _ = draw(menu, true);
    const live = cl.getElementData(rowId(0)).bounding_box;
    try testing.expect(registry.dispatchClick(live.x + 4, live.y + 4));
    try testing.expectEqual(@as(usize, 1), pick_ctx.calls);
}

test "a right click on nothing closes the card, and a left press outside it dismisses and swallows" {
    reset();
    const menu = prop.ContextMenu{ .items = &items, .on_select = .{ .f = onPick, .ctx = &pick_ctx } };

    _ = draw(menu, false);
    const bb = rowBox();
    try testing.expect(secondaryClick(bb.x + 10, bb.y + 10, canvas_w, canvas_h));
    try testing.expect(isOpen());

    // Somewhere no component offers a menu: the card goes away and the caller is free to use the click.
    try testing.expect(!secondaryClick(canvas_w - 40, canvas_h - 20, canvas_w, canvas_h));
    try testing.expect(!isOpen());

    // A left press outside an open card dismisses it, and is swallowed so it cannot press a button underneath.
    _ = secondaryClick(bb.x + 10, bb.y + 10, canvas_w, canvas_h);
    _ = draw(menu, true);
    try testing.expect(leftPress(canvas_w - 10, canvas_h - 10));
    try testing.expect(!isOpen());

    // A left press INSIDE the card belongs to a row, which answers on release: the card stays.
    _ = secondaryClick(bb.x + 10, bb.y + 10, canvas_w, canvas_h);
    _ = draw(menu, true);
    const row0 = cl.getElementData(rowId(0)).bounding_box;
    try testing.expect(!leftPress(row0.x + 2, row0.y + 2));
    try testing.expect(isOpen());
    close();
}

test "a card near the edge of the window is moved back inside" {
    reset();
    const menu = prop.ContextMenu{ .items = &items, .on_select = .{ .f = onPick, .ctx = &pick_ctx } };

    _ = draw(menu, false);
    // Right-clicked in the very corner: the card must not hang off the right or bottom edge.
    openAt(menu, canvas_w - 10, canvas_h - 10, canvas_w, canvas_h);
    const at = origin().?;
    try testing.expect(at.x < canvas_w - 10);
    try testing.expect(at.y < canvas_h - 10);
    close();
}
