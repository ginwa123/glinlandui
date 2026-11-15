//! Drag to reorder: a list's rows can be picked up and dropped at another index, when the list asks for it.
const std = @import("std");
const cl = @import("zclay");
const prop = @import("../props.zig");
const Color = @import("../color.zig").Color;

/// What a list hands in to make its rows draggable. `on_move` null (the default) means the list is not draggable.
pub const Reorder = struct {
    // Called once per drop: the row that moved and the index it lands at AFTER the move, so an app can splice its own array.
    on_move: ?*const fn (?*anyopaque, usize, usize) void = null,
    ctx: ?*anyopaque = null,
    // The line drawn where the row would land, and the tint of the row being dragged.
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
};

var rows: [cap]Row = undefined;
var row_count: usize = 0;

// The drag in flight, if any: the row picked up, the list it belongs to, and the boundary it would land on.
const Drag = struct {
    list: []const u8,
    spec: Reorder,
    from: usize,
    count: usize,
    // Arm on the press, become active once the pointer has moved far enough that this cannot be a click.
    active: bool = false,
    press_y: f32 = 0,
    // The boundary the row would land on: 0..count, where count is "after the last row".
    drop: usize = 0,
};

var drag: ?Drag = null;

/// Forget last frame's rows; the drag in flight survives, because it spans frames.
pub fn beginFrame() void {
    row_count = 0;
}

/// A list offers a row for dragging; a spec with no handler registers nothing, so a static list costs one branch.
pub fn register(list: []const u8, id: cl.ElementId, index: usize, spec: Reorder) void {
    if (spec.on_move == null) return;
    if (row_count >= cap) return;
    rows[row_count] = .{ .list = list, .id = id, .index = index, .spec = spec };
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

/// A left press: arm the row under the pointer, if it belongs to a draggable list.
pub fn press(x: f32, y: f32) void {
    drag = null;
    var i: usize = 0;
    while (i < row_count) : (i += 1) {
        const row = rows[i];
        const bb = boxOf(row.id) orelse continue;
        if (x < bb.x or x >= bb.x + bb.width or y < bb.y or y >= bb.y + bb.height) continue;
        drag = .{ .list = row.list, .spec = row.spec, .from = row.index, .count = countIn(row.list), .press_y = y };
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
    _ = x;
}

/// The release: a completed drag reports its move and is consumed; a press that never moved leaves the click to the row.
pub fn release(x: f32, y: f32) bool {
    const d = drag orelse return false;
    drag = null;
    if (!d.active) return false;
    _ = x;
    const boundary = boundaryAt(d.list, y, d.count);
    // Dropping below the row's own position lands one index earlier, because the row leaves its slot first.
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
    cancel();
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
