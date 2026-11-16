//! Drag to reorder: a list's rows can be picked up and dropped at another index, when the list asks for it.
const std = @import("std");
const cl = @import("zclay");
const prop = @import("../props.zig");
const Color = @import("../color.zig").Color;
const frame_mod = @import("../frame.zig");

/// Where a drop lands relative to the row under the pointer: above it, inside it, or below it.
pub const Zone = enum {
    before,
    into,
    after,

    // True for the two zones that reorder siblings; `into` is a move to another parent.
    pub fn isReorder(self: Zone) bool {
        return self != .into;
    }
};

/// What a list hands in to make its rows draggable. Both handlers null (the default) means the list is not draggable.
pub const Reorder = struct {
    // Called once per drop on a plain list: the row that moved and the index it lands at AFTER the move, so an app can splice its own array.
    on_move: ?*const fn (?*anyopaque, usize, usize) void = null,
    // Called once per drop when the list knows zones: the row that moved, the row it was dropped ON, and where on it.
    on_drop: ?*const fn (?*anyopaque, usize, usize, Zone) void = null,
    ctx: ?*anyopaque = null,
    // The line drawn where the row would land, the ring around a container it would land in, and the tint of the row being dragged.
    line: Color = Color.rgb(0x7a, 0xb8, 0xff),
    ghost_bg: Color = Color.rgb(0x3a, 0x3a, 0x3a),
};

/// How far the pointer must travel before a press becomes a drag, in points: a click that wobbles is still a click.
pub const threshold_px: f32 = 4;

/// The most rows one frame may offer for dragging. Beyond this a list should page, not scroll.
const cap: usize = 512;

/// The line's float priority: over the rows it separates, under any card the app raises.
pub const z_index: i16 = 20;

// One draggable row, as declared this frame: which list owns it, where it sits, and what to call on a drop.
const Row = struct {
    list: []const u8,
    id: cl.ElementId,
    index: usize,
    spec: Reorder,
    // A row that holds children: the middle third of its band asks for `into` instead of a boundary.
    accepts_into: bool = false,
};

var rows: [cap]Row = undefined;
var row_count: usize = 0;

// The drag in flight, if any: the row picked up, the list it belongs to, and where it would land.
const Drag = struct {
    list: []const u8,
    spec: Reorder,
    from: usize,
    count: usize,
    // Arm on the press, become active once the pointer has moved far enough that this cannot be a click.
    active: bool = false,
    press_y: f32 = 0,
    // The boundary a plain list lands on: 0..count, where count is "after the last row".
    drop: usize = 0,
    // The row the pointer is over, and where on it a zone-aware list would drop.
    target: usize = 0,
    zone: Zone = .after,
};

var drag: ?Drag = null;

// A row under the pointer, and the zone the pointer asks of it.
const Target = struct { index: usize, zone: Zone };

/// Forget last frame's rows; the drag in flight survives, because it spans frames.
pub fn beginFrame() void {
    row_count = 0;
    // A row lifted off its slot owns the pointer: the list it came from must not drag-scroll with it.
    if (drag) |d| {
        if (d.active) frame_mod.claimDrag();
    }
}

/// A list offers a row for dragging; a spec with no handler registers nothing, so a static list costs one branch.
pub fn register(list: []const u8, id: cl.ElementId, index: usize, spec: Reorder) void {
    registerRow(list, id, index, spec, false);
}

/// The same, for a row that holds children: its middle third accepts a drop INTO it, not just before or after.
pub fn registerContainer(list: []const u8, id: cl.ElementId, index: usize, spec: Reorder) void {
    registerRow(list, id, index, spec, true);
}

fn registerRow(list: []const u8, id: cl.ElementId, index: usize, spec: Reorder, accepts_into: bool) void {
    if (spec.on_move == null and spec.on_drop == null) return;
    if (row_count >= cap) return;
    rows[row_count] = .{ .list = list, .id = id, .index = index, .spec = spec, .accepts_into = accepts_into };
    row_count += 1;
}

/// True while a row is being dragged, so a view can dim it and an app can skip its own click handling.
pub fn isDragging() bool {
    const d = drag orelse return false;
    return d.active;
}

/// The index a drag would insert at, for the list asking. Null when nothing is being dragged over it.
pub fn dropIndex(list: []const u8) ?usize {
    const d = drag orelse return null;
    if (!d.active) return null;
    if (!std.mem.eql(u8, d.list, list)) return null;
    return d.drop;
}

/// The row being dragged, or null. The view tints it so the row that is moving is the one under the pointer.
pub fn draggingIndex() ?usize {
    const d = drag orelse return null;
    if (!d.active) return null;
    return d.from;
}

/// The list the drag in flight belongs to, so a view only draws the indicator over its own rows.
pub fn draggingList() ?[]const u8 {
    const d = drag orelse return null;
    if (!d.active) return null;
    return d.list;
}

/// The row the drag in flight would land on. A view draws its indicator there, whatever the zone.
pub fn dropTarget() ?usize {
    const d = drag orelse return null;
    if (!d.active) return null;
    return d.target;
}

/// Where on that row the drop would land: the middle third of a container asks for `into`, the rest for a boundary.
pub fn dropZone() ?Zone {
    const d = drag orelse return null;
    if (!d.active) return null;
    return d.zone;
}

/// A left press: arm the row under the pointer, if it belongs to a draggable list.
pub fn press(x: f32, y: f32) void {
    drag = null;
    var i: usize = 0;
    while (i < row_count) : (i += 1) {
        const row = rows[i];
        const bb = boxOf(row.id) orelse continue;
        if (x < bb.x or x >= bb.x + bb.width or y < bb.y or y >= bb.y + bb.height) continue;
        drag = .{
            .list = row.list,
            .spec = row.spec,
            .from = row.index,
            .count = countIn(row.list),
            .press_y = y,
            .target = row.index,
            .zone = .after,
        };
        return;
    }
}

/// A pointer move while a button is down: past the threshold the press becomes a drag, and the drop follows the pointer.
pub fn move(x: f32, y: f32) void {
    var d = &(drag orelse return);
    if (!d.active) {
        if (@abs(y - d.press_y) < threshold_px) return;
        d.active = true;
    }
    d.drop = boundaryAt(d.list, y, d.count);
    if (targetAt(d.list, y)) |t| {
        d.target = t.index;
        d.zone = t.zone;
    }
    _ = x;
}

/// The release: a completed drag reports its move and is consumed; a press that never moved leaves the click to the row.
pub fn release(x: f32, y: f32) bool {
    const d = drag orelse return false;
    drag = null;
    if (!d.active) return false;
    _ = x;
    const target = targetAt(d.list, y) orelse return true;
    // A drop on the row that was picked up changes nothing, in any zone.
    if (target.index == d.from) return true;
    if (d.spec.on_drop) |f| {
        f(d.spec.ctx, d.from, target.index, target.zone);
        return true;
    }
    // Dropping below the row's own position lands one index earlier, because the row leaves its slot first.
    const boundary = boundaryAt(d.list, y, d.count);
    const to = if (boundary > d.from) boundary - 1 else boundary;
    if (to == d.from) return true;
    if (d.spec.on_move) |f| f(d.spec.ctx, d.from, to);
    return true;
}

/// Abandon a drag (Escape, a window change): nothing is reported.
pub fn cancel() void {
    drag = null;
}

// The boundary the pointer is over: 0 before the first row, `count` after the last one.
fn boundaryAt(list: []const u8, y: f32, count: usize) usize {
    var boundary: usize = count;
    var i: usize = 0;
    while (i < row_count) : (i += 1) {
        const row = rows[i];
        if (!std.mem.eql(u8, row.list, list)) continue;
        const bb = boxOf(row.id) orelse continue;
        if (y < bb.y + bb.height * 0.5) {
            if (row.index < boundary) boundary = row.index;
        }
    }
    return boundary;
}

// The row the pointer is over, and its zone: clamped to the nearest row when the pointer is past either end.
fn targetAt(list: []const u8, y: f32) ?Target {
    var nearest: ?Target = null;
    var nearest_dist: f32 = 0;
    var i: usize = 0;
    while (i < row_count) : (i += 1) {
        const row = rows[i];
        if (!std.mem.eql(u8, row.list, list)) continue;
        const bb = boxOf(row.id) orelse continue;
        if (y >= bb.y and y < bb.y + bb.height) {
            return .{ .index = row.index, .zone = zoneIn(bb.y, bb.height, y, row.accepts_into) };
        }
        const above = y < bb.y;
        const dist = if (above) bb.y - y else y - (bb.y + bb.height);
        if (nearest == null or dist < nearest_dist) {
            nearest = .{ .index = row.index, .zone = if (above) .before else .after };
            nearest_dist = dist;
        }
    }
    return nearest;
}

// The thirds of a row's band: the outer two are a boundary, the inner one is `into` when the row holds children.
fn zoneIn(top: f32, height: f32, y: f32, accepts_into: bool) Zone {
    const third = height / 3;
    if (y < top + third) return .before;
    if (y >= top + third * 2) return .after;
    if (accepts_into) return .into;
    return if (y < top + height * 0.5) .before else .after;
}

// How many rows the list declared this frame, which is where "after the last row" lives.
fn countIn(list: []const u8) usize {
    var highest: usize = 0;
    var i: usize = 0;
    while (i < row_count) : (i += 1) {
        const row = rows[i];
        if (!std.mem.eql(u8, row.list, list)) continue;
        if (row.index + 1 > highest) highest = row.index + 1;
    }
    return highest;
}

fn boxOf(id: cl.ElementId) ?cl.BoundingBox {
    const data = cl.getElementData(id);
    if (!data.found) return null;
    if (data.bounding_box.width <= 0 or data.bounding_box.height <= 0) return null;
    return data.bounding_box;
}

/// Draw the drop line for `list`, if a drag is over it. The list calls this after declaring its rows.
pub fn declareLine(list: []const u8) void {
    const d = drag orelse return;
    if (!d.active) return;
    if (!std.mem.eql(u8, d.list, list)) return;
    // A drop INTO a container is drawn as a ring by the view, not as a line between rows.
    if (d.zone == .into) return;
    const target = nearestRow(list, d.drop) orelse return;
    const bb = boxOf(target.id) orelse return;
    // Root-relative, from the row's own box: the line needs no parent id, so two rows of one list cannot be confused.
    const after = d.drop >= d.count;
    const y = if (after) bb.y + bb.height else bb.y;
    cl.UI()(.{
        .id = .ID("glin.reorder.line"),
        .layout = .{ .sizing = .{ .w = .fixed(bb.width), .h = .fixed(2) } },
        .floating = .{
            .attach_to = .to_root,
            .offset = .{ .x = bb.x, .y = y - 1 },
            .z_index = z_index,
            .pointer_capture_mode = .passthrough,
        },
        .background_color = d.spec.line.toClay(),
    })({});
}

// The row a boundary sits on: the one after it, or the last row when the boundary is past the end.
fn nearestRow(list: []const u8, boundary: usize) ?Row {
    var best_after: ?Row = null;
    var last: ?Row = null;
    var i: usize = 0;
    while (i < row_count) : (i += 1) {
        const row = rows[i];
        if (!std.mem.eql(u8, row.list, list)) continue;
        if (row.index >= boundary and (best_after == null or row.index < best_after.?.index)) best_after = row;
        if (last == null or row.index > last.?.index) last = row;
    }
    return best_after orelse last;
}

const testing = std.testing;
const headless = @import("../testing/headless.zig");
const list_mod = @import("list.zig");
const tree_mod = @import("tree.zig");

const canvas_w: u32 = 480;
const canvas_h: u32 = 400;

// ONE canvas for the file, never freed: Clay keeps a context pointer, so re-initialising after a free() faults.
var canvas: ?[]u8 = null;

fn canvasOnce() void {
    if (canvas != null) return;
    const mem = std.heap.page_allocator.alloc(u8, cl.minMemorySize()) catch @panic("OOM");
    const arena = cl.Arena.init(mem);
    _ = cl.initialize(arena, .{ .w = canvas_w, .h = canvas_h }, .{});
    cl.setMeasureTextFunction(void, {}, headless.stubMeasure);
    canvas = mem;
}

var move_ctx: struct { calls: usize = 0, from: usize = 0, to: usize = 0 } = .{};

fn onMove(ctx: ?*anyopaque, from: usize, to: usize) void {
    const c: *@TypeOf(move_ctx) = @ptrCast(@alignCast(ctx.?));
    c.calls += 1;
    c.from = from;
    c.to = to;
}

var drop_ctx: struct { calls: usize = 0, from: usize = 0, to: usize = 0, zone: Zone = .after } = .{};

fn onDrop(ctx: ?*anyopaque, from: usize, to: usize, zone: Zone) void {
    const c: *@TypeOf(drop_ctx) = @ptrCast(@alignCast(ctx.?));
    c.calls += 1;
    c.from = from;
    c.to = to;
    c.zone = zone;
}

const titles = [_][]const u8{ "Alpha", "Beta", "Gamma" };
const titles_slice: []const []const u8 = &titles;

fn rowCtx(_: void, title: []const u8, _: usize) void {
    _ = title;
}

fn frame(spec: ?Reorder) void {
    beginFrame();
    cl.setPointerState(.{ .x = 99999, .y = 99999 }, false);
    cl.beginLayout();
    list_mod.list(.{
        .id = .{ .text = "test-reorder-list" },
        .row_h = .{ .px = 40 },
        .reorder = spec,
    }, titles_slice, {}, rowCtx);
    _ = cl.endLayout();
}

fn rowCenter(index: usize) struct { x: f32, y: f32 } {
    const id = list_mod.rowId("test-reorder-list", index);
    const bb = cl.getElementData(id).bounding_box;
    return .{ .x = bb.x + bb.width * 0.5, .y = bb.y + bb.height * 0.5 };
}

fn reset() void {
    canvasOnce();
    move_ctx = .{};
    drop_ctx = .{};
    cancel();
}

// The tree fixture: row 0 is a container, row 1 a request, row 2 a container that is collapsed.
const zone_rows = [_]tree_mod.Row{
    .{ .label = "Folder", .depth = 0, .has_children = true, .expanded = true, .kind = .group },
    .{ .label = "Request", .depth = 1 },
    .{ .label = "Other", .depth = 1, .has_children = true, .kind = .group },
};

fn treeFrame(spec: Reorder) void {
    beginFrame();
    cl.setPointerState(.{ .x = 99999, .y = 99999 }, false);
    cl.beginLayout();
    tree_mod.tree(.{
        .id = .{ .text = "test-reorder-tree" },
        .rows = &zone_rows,
        .row_h = .{ .px = 30 },
        .reorder = spec,
    });
    _ = cl.endLayout();
}

fn treeBox(index: usize) struct { x: f32, y: f32, w: f32, h: f32 } {
    const bb = cl.getElementData(tree_mod.rowId("test-reorder-tree", index)).bounding_box;
    return .{ .x = bb.x, .y = bb.y, .w = bb.width, .h = bb.height };
}

// A point in the row's band: `f` 0 is its top edge, 1 its bottom edge.
fn treePoint(index: usize, f: f32) struct { x: f32, y: f32 } {
    const bb = treeBox(index);
    return .{ .x = bb.x + bb.w * 0.5, .y = bb.y + bb.h * f };
}

fn treeReset() void {
    canvasOnce();
    drop_ctx = .{};
    cancel();
    treeFrame(.{ .on_drop = onDrop, .ctx = &drop_ctx });
}

test "a list with no reorder spec never drags" {
    reset();
    frame(null);
    const first = rowCenter(0);
    press(first.x, first.y);
    const last = rowCenter(2);
    move(last.x, last.y);
    try testing.expect(!isDragging());
    _ = release(last.x, last.y);
    try testing.expectEqual(@as(usize, 0), move_ctx.calls);
}

test "dragging the first row past the last one reports a move to the end" {
    reset();
    const spec = Reorder{ .on_move = onMove, .ctx = &move_ctx };
    frame(spec);

    const first = rowCenter(0);
    press(first.x, first.y);
    // A press that never moves is a click: no drag, no move.
    try testing.expect(!isDragging());
    const third = rowCenter(2);
    move(third.x, third.y + 4);
    try testing.expect(isDragging());
    try testing.expectEqual(@as(?usize, 3), dropIndex("test-reorder-list"));
    try testing.expectEqual(@as(?usize, 0), draggingIndex());
    try testing.expect(release(third.x, third.y + 4));
    try testing.expectEqual(@as(usize, 1), move_ctx.calls);
    try testing.expectEqual(@as(usize, 0), move_ctx.from);
    try testing.expectEqual(@as(usize, 2), move_ctx.to);
    try testing.expect(!isDragging());
}

test "a press that does not move is left to the row's own click" {
    reset();
    const spec = Reorder{ .on_move = onMove, .ctx = &move_ctx };
    frame(spec);

    const second = rowCenter(1);
    press(second.x, second.y);
    // Two points of travel is a shaky hand, not a drag.
    move(second.x, second.y + 2);
    try testing.expect(!isDragging());
    try testing.expect(!release(second.x, second.y + 2));
    try testing.expectEqual(@as(usize, 0), move_ctx.calls);
}

test "dropping a row back where it came from reports nothing" {
    reset();
    const spec = Reorder{ .on_move = onMove, .ctx = &move_ctx };
    frame(spec);

    const second = rowCenter(1);
    press(second.x, second.y);
    move(second.x, second.y + 6);
    try testing.expect(isDragging());
    try testing.expect(release(second.x, second.y + 6));
    try testing.expectEqual(@as(usize, 0), move_ctx.calls);
}

test "the thirds of a row band split into before, into and after" {
    // A container: the outer thirds are a boundary, the middle one is a drop INTO it.
    try testing.expectEqual(Zone.before, zoneIn(100, 30, 104, true));
    try testing.expectEqual(Zone.into, zoneIn(100, 30, 115, true));
    try testing.expectEqual(Zone.after, zoneIn(100, 30, 126, true));
    // A row that holds nothing can never be filled, so its middle third is the nearer boundary.
    try testing.expectEqual(Zone.before, zoneIn(100, 30, 112, false));
    try testing.expectEqual(Zone.after, zoneIn(100, 30, 118, false));
    try testing.expect(Zone.into.isReorder() == false);
    try testing.expect(Zone.before.isReorder() and Zone.after.isReorder());
}

test "a drop on the middle of a container row reports into, with the row it landed on" {
    treeReset();
    const from = treePoint(1, 0.5);
    press(from.x, from.y);
    const onto = treePoint(2, 0.5);
    move(onto.x, onto.y);
    try testing.expectEqual(@as(?Zone, .into), dropZone());
    try testing.expectEqual(@as(?usize, 2), dropTarget());
    // The view draws a ring for an `into`, so no line is declared.
    _ = release(onto.x, onto.y);
    try testing.expectEqual(@as(usize, 1), drop_ctx.calls);
    try testing.expectEqual(@as(usize, 1), drop_ctx.from);
    try testing.expectEqual(@as(usize, 2), drop_ctx.to);
    try testing.expectEqual(Zone.into, drop_ctx.zone);
}

test "the top and the bottom of a container row are a boundary, not a drop inside it" {
    treeReset();
    const from = treePoint(1, 0.5);
    press(from.x, from.y);

    const top = treePoint(2, 0.1);
    move(top.x, top.y);
    try testing.expectEqual(@as(?Zone, .before), dropZone());
    _ = release(top.x, top.y);
    try testing.expectEqual(Zone.before, drop_ctx.zone);
    try testing.expectEqual(@as(usize, 2), drop_ctx.to);

    // A second drag, dropped near the bottom edge of the same row.
    treeReset();
    press(from.x, from.y);
    const bottom = treePoint(2, 0.95);
    move(bottom.x, bottom.y);
    try testing.expectEqual(@as(?Zone, .after), dropZone());
    _ = release(bottom.x, bottom.y);
    try testing.expectEqual(Zone.after, drop_ctx.zone);
}

test "a row that holds nothing is never a drop INTO it, even in the middle third" {
    treeReset();
    const from = treePoint(2, 0.5);
    press(from.x, from.y);
    const onto = treePoint(1, 0.5);
    move(onto.x, onto.y);
    const zone = dropZone() orelse return error.NoDrag;
    try testing.expect(zone.isReorder());
    _ = release(onto.x, onto.y);
    try testing.expect(drop_ctx.zone.isReorder());
}

test "a pointer above the first row and below the last clamp to that row's outer edge" {
    treeReset();
    const from = treePoint(1, 0.5);
    press(from.x, from.y);
    const first = treeBox(0);
    move(first.x + 10, first.y - 20);
    try testing.expectEqual(@as(?usize, 0), dropTarget());
    try testing.expectEqual(@as(?Zone, .before), dropZone());
    const last = treeBox(2);
    move(last.x + 10, last.y + last.h + 20);
    try testing.expectEqual(@as(?usize, 2), dropTarget());
    try testing.expectEqual(@as(?Zone, .after), dropZone());
    _ = release(last.x + 10, last.y + last.h + 20);
    try testing.expectEqual(Zone.after, drop_ctx.zone);
}

test "a plain list keeps on_move, and never reports a zone" {
    reset();
    const spec = Reorder{ .on_move = onMove, .ctx = &move_ctx, .on_drop = onDrop };
    // The list registers its rows through `register`, so the boundary path reports the index, never a zone.
    try testing.expect(spec.on_drop != null);
    const list_spec = Reorder{ .on_move = onMove, .ctx = &move_ctx };
    frame(list_spec);
    const first = rowCenter(0);
    press(first.x, first.y);
    const third = rowCenter(2);
    move(third.x, third.y + 4);
    _ = release(third.x, third.y + 4);
    try testing.expectEqual(@as(usize, 1), move_ctx.calls);
    try testing.expectEqual(@as(usize, 0), drop_ctx.calls);
}

test "a drag is over one list at a time, and only that list draws its indicator" {
    treeReset();
    const from = treePoint(1, 0.5);
    press(from.x, from.y);
    const onto = treePoint(2, 0.5);
    move(onto.x, onto.y);
    try testing.expectEqualStrings("test-reorder-tree", draggingList().?);
    try testing.expectEqual(@as(?usize, 1), draggingIndex());
    // Nothing is dropped on the row that was picked up.
    _ = release(from.x, from.y);
    try testing.expectEqual(@as(usize, 0), drop_ctx.calls);
    try testing.expectEqual(@as(?Zone, null), dropZone());
}
