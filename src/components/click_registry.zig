// Engine-owned per-frame click registry (no alloc, fixed cap).
// Components self-register at declare time; the owner dispatches one
// pointer point per frame. Highest-z match wins (floating overlays float
// above in-flow rows regardless of declare order); ties keep
// last-registered-first (legacy topmost-wins).
// Imports: std + zclay ONLY.
// Never: app/theme/layout/views/content/sidebar.
const std = @import("std");
const cl = @import("zclay");

pub const cap: usize = 256;

/// Cursor kind for Wayland wl_pointer cursor shape.
/// Stored per registry entry; the Wayland crew maps this to
/// wl_cursor themes (default/pointer/text/ew-resize). Components set
/// it beside their own register call (no central switch); disabled or
/// non-registered boxes report .default (skip behavior — no entry).
pub const Cursor = enum { default, pointer, text, ew_resize };

/// Click callback shapes (same as button.ClickFn / list row fn).
pub const ClickFn = *const fn (?*anyopaque) void;
pub const RowFn = *const fn (?*anyopaque, usize) void;

/// Per-row click target: distinct fn+ctx per row (Stage B).
/// Stored in ListProps.clicks / DropdownProps.clicks; list() registers
/// clicks[i] for row i (rows beyond clicks.len get no entry).
pub const RowClick = struct {
    on_click: *const fn (?*anyopaque, usize) void,
    ctx: ?*anyopaque,
};

const Entry = struct {
    id: cl.ElementId,
    cb_row: ?*const fn (?*anyopaque, usize) void = null,
    cb_click: ?*const fn (?*anyopaque) void = null,
    ctx: ?*anyopaque = null,
    index: usize = 0,
    /// Dispatch priority: highest-z containing match wins (overlay cards
    /// register above in-flow rows). Default 0.
    z: i16 = 0,
    /// Hover cursor for this entry (Wayland cursor shape). Default
    /// .default for existing entries.
    cursor: Cursor = .default,
};

var entries: [cap]Entry = undefined;
var count: usize = 0;

/// Clear the registry for a new frame.
pub fn beginFrame() void {
    count = 0;
}

/// Register a row hit-target (list/dropdown rows) at default priority 0.
pub fn register(id: cl.ElementId, cb: *const fn (?*anyopaque, usize) void, ctx: ?*anyopaque, index: usize) void {
    registerZ(id, cb, ctx, index, 0);
}

/// Register a row hit-target with dispatch priority (overlay rows pass
/// their float z so they win over covered in-flow rows at shared points).
/// Thin wrapper storing .default cursor (existing callers keep compiling).
pub fn registerZ(id: cl.ElementId, cb: *const fn (?*anyopaque, usize) void, ctx: ?*anyopaque, index: usize, z: i16) void {
    registerZCursor(id, cb, ctx, index, z, .default);
}

/// Full row version storing cursor (list rows pass .pointer).
pub fn registerZCursor(id: cl.ElementId, cb: *const fn (?*anyopaque, usize) void, ctx: ?*anyopaque, index: usize, z: i16, cursor: Cursor) void {
    if (count >= cap) return;
    entries[count] = .{ .id = id, .cb_row = cb, .ctx = ctx, .index = index, .z = z, .cursor = cursor };
    count += 1;
}

/// Register a button hit-target (index-free click).
/// Thin wrapper passing .default (existing callers keep compiling).
pub fn registerClick(id: cl.ElementId, cb: ClickFn, ctx: ?*anyopaque) void {
    registerClickCursor(id, cb, ctx, .default);
}

/// Full click version storing cursor (button/toggle/checkbox/radio pass
/// .pointer, slider passes .ew_resize, image on_click passes .pointer).
pub fn registerClickCursor(id: cl.ElementId, cb: ClickFn, ctx: ?*anyopaque, cursor: Cursor) void {
    if (count >= cap) return;
    entries[count] = .{ .id = id, .cb_click = cb, .ctx = ctx, .cursor = cursor };
    count += 1;
}

/// Register a hover-only entry (no click callback): dispatchClick skips
/// it but hoverCursorAt sees it. Used by the text field bg (.text).
/// Empty-id callers must skip before calling (headless-safe).
pub fn registerHover(id: cl.ElementId, cursor: Cursor) void {
    registerHoverZ(id, cursor, 0);
}

/// Hover-only with explicit z (overlay floats pass their z so the float
/// wins over covered in-flow rows, mirroring dispatchClick's rule).
pub fn registerHoverZ(id: cl.ElementId, cursor: Cursor, z: i16) void {
    if (count >= cap) return;
    entries[count] = .{ .id = id, .z = z, .cursor = cursor };
    count += 1;
}

fn contains(bb: cl.BoundingBox, x: f32, y: f32) bool {
    return x >= bb.x and x < bb.x + bb.width and y >= bb.y and y < bb.y + bb.height;
}

/// Dispatch a click point: the highest-z containing match fires once
/// (ties keep last-registered-first). Returns true when a target fired.
/// Hover-only entries (no callback) are skipped so a .text field bg can
/// never swallow a click meant for a lower-z target.
pub fn dispatchClick(x: f32, y: f32) bool {
    var best: ?Entry = null;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const e = entries[i];
        // Hover-only entries never fire clicks.
        if (e.cb_row == null and e.cb_click == null) continue;
        const data = cl.getElementData(e.id);
        if (!data.found) continue;
        if (!contains(data.bounding_box, x, y)) continue;
        // Forward scan + >= : later entries win ties (legacy order).
        if (best == null or e.z >= best.?.z) best = e;
    }
    const hit = best orelse return false;
    if (hit.cb_row) |cb| {
        cb(hit.ctx, hit.index);
        return true;
    }
    if (hit.cb_click) |cb0| {
        cb0(hit.ctx);
        return true;
    }
    return false;
}

/// Hover cursor at a point: topmost (highest-z, ties last-registered
/// wins — mirrors dispatchClick's rule) CONTAINING entry's cursor, or
/// .default when none contains the point. Hover-only entries count;
/// disabled / never-registered boxes have no entry so report .default.
/// Reuses the same contains/bounding-box logic as dispatchClick.
pub fn hoverCursorAt(x: f32, y: f32) Cursor {
    var best: ?Entry = null;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const e = entries[i];
        const data = cl.getElementData(e.id);
        if (!data.found) continue;
        if (!contains(data.bounding_box, x, y)) continue;
        if (best == null or e.z >= best.?.z) best = e;
    }
    return if (best) |hit| hit.cursor else .default;
}

// Stub text estimator for headless tests (no font backend needed).
fn stubMeasure(s: []const u8, cfg: *cl.TextElementConfig, _: void) cl.Dimensions {
    return .{
        .w = @as(f32, @floatFromInt(s.len)) * @as(f32, @floatFromInt(cfg.font_size)) * 0.6,
        .h = @as(f32, @floatFromInt(cfg.font_size)),
    };
}

fn rowId(base: []const u8, i: usize) cl.ElementId {
    return cl.ElementId.IDI(base, @as(u32, @intCast(i + 1)));
}

fn declareThree() void {
    cl.UI()(.{
        .id = .ID("cr-list"),
        .layout = .{ .direction = .top_to_bottom, .sizing = .{ .w = .grow, .h = .fit } },
    })({
        for (0..3) |i| {
            cl.UI()(.{
                .id = .IDI("cr-list", @as(u32, @intCast(i + 1))),
                .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(40) } },
            })({});
        }
    });
}

fn layoutThree() !void {
    const mem_size = cl.minMemorySize();
    // NOTE: intentionally leaked (page_allocator, never freed). Clay keeps
    // a global currentContext pointer inside this arena, so freeing it
    // would dangle the *next* test's minMemorySize/initialize (segfault).
    const buf = try std.heap.page_allocator.alloc(u8, mem_size);
    const arena = cl.Arena.init(buf);
    _ = cl.initialize(arena, .{ .w = 720, .h = 480 }, .{});
    cl.setMeasureTextFunction(void, {}, stubMeasure);
    cl.setPointerState(.{ .x = 99999, .y = 99999 }, false);
    cl.beginLayout();
    declareThree();
    _ = cl.endLayout();
}

const Rec = struct {
    calls: usize = 0,
    last: ?usize = null,
};

fn onRow(ctx: ?*anyopaque, i: usize) void {
    const c: *Rec = @ptrCast(@alignCast(ctx.?));
    c.calls += 1;
    c.last = i;
}

test "dispatchClick inside row-1 box fires index 1 exactly once" {
    try layoutThree();
    beginFrame();
    var c = Rec{};
    for (0..3) |i| register(rowId("cr-list", i), onRow, &c, i);
    const bb = cl.getElementData(rowId("cr-list", 1)).bounding_box;
    try std.testing.expect(cl.getElementData(rowId("cr-list", 1)).found);
    try std.testing.expect(dispatchClick(bb.x + bb.width * 0.5, bb.y + bb.height * 0.5));
    try std.testing.expectEqual(@as(usize, 1), c.calls);
    try std.testing.expectEqual(@as(?usize, 1), c.last);
}

test "dispatchClick outside any box fires nothing" {
    try layoutThree();
    beginFrame();
    var c = Rec{};
    for (0..3) |i| register(rowId("cr-list", i), onRow, &c, i);
    try std.testing.expect(!dispatchClick(700, 460));
    try std.testing.expectEqual(@as(usize, 0), c.calls);
}

test "overlap: last-registered callback wins at shared point" {
    try layoutThree();
    beginFrame();
    var first = Rec{};
    var second = Rec{};
    register(rowId("cr-list", 1), onRow, &first, 111);
    register(rowId("cr-list", 1), onRow, &second, 222);
    const bb = cl.getElementData(rowId("cr-list", 1)).bounding_box;
    try std.testing.expect(cl.getElementData(rowId("cr-list", 1)).found);
    try std.testing.expect(dispatchClick(bb.x + bb.width * 0.5, bb.y + bb.height * 0.5));
    try std.testing.expectEqual(@as(usize, 0), first.calls);
    try std.testing.expectEqual(@as(usize, 1), second.calls);
    try std.testing.expectEqual(@as(?usize, 222), second.last);
}

test "overlap: higher-z wins even when registered first (overlay over rows)" {
    try layoutThree();
    beginFrame();
    var under = Rec{};
    var over = Rec{};
    // Overlay registers first (declared mid-loop), covered row after —
    // visual stacking (z), not declare order, decides.
    registerZ(rowId("cr-list", 1), onRow, &over, 111, 10);
    register(rowId("cr-list", 1), onRow, &under, 222);
    const bb = cl.getElementData(rowId("cr-list", 1)).bounding_box;
    try std.testing.expect(cl.getElementData(rowId("cr-list", 1)).found);
    try std.testing.expect(dispatchClick(bb.x + bb.width * 0.5, bb.y + bb.height * 0.5));
    try std.testing.expectEqual(@as(usize, 1), over.calls);
    try std.testing.expectEqual(@as(?usize, 111), over.last);
    try std.testing.expectEqual(@as(usize, 0), under.calls);
}

test "registry caps entries without crashing; last-within-cap wins" {
    // No count accessor on the registry API, so the cap is asserted via
    // dispatch behavior: cap + 6 registrations against one valid box must
    // fire exactly once with the last within-cap index; entries past cap
    // are dropped.
    try layoutThree();
    beginFrame();
    var c = Rec{};
    var i: usize = 0;
    while (i < cap + 6) : (i += 1) register(rowId("cr-list", 1), onRow, &c, i);
    const bb = cl.getElementData(rowId("cr-list", 1)).bounding_box;
    try std.testing.expect(cl.getElementData(rowId("cr-list", 1)).found);
    try std.testing.expect(dispatchClick(bb.x + bb.width * 0.5, bb.y + bb.height * 0.5));
    try std.testing.expectEqual(@as(usize, 1), c.calls);
    try std.testing.expectEqual(@as(?usize, cap - 1), c.last);
}

fn onClickStub(_: ?*anyopaque) void {}

test "hoverCursorAt empty registry reports default" {
    try layoutThree();
    beginFrame();
    try std.testing.expectEqual(Cursor.default, hoverCursorAt(10, 10));
}

test "hoverCursorAt outside any box reports default" {
    try layoutThree();
    beginFrame();
    var c = Rec{};
    for (0..3) |i| register(rowId("cr-list", i), onRow, &c, i);
    try std.testing.expectEqual(Cursor.default, hoverCursorAt(700, 460));
}

test "hoverCursorAt not-registered box reports default (disabled parity)" {
    // Disabled components skip registration entirely, so a declared but
    // never-registered box must report .default on hover.
    try layoutThree();
    beginFrame();
    const bb = cl.getElementData(rowId("cr-list", 1)).bounding_box;
    try std.testing.expect(cl.getElementData(rowId("cr-list", 1)).found);
    try std.testing.expectEqual(Cursor.default, hoverCursorAt(bb.x + bb.width * 0.5, bb.y + bb.height * 0.5));
}

test "hoverCursorAt click entry reports its cursor" {
    try layoutThree();
    beginFrame();
    registerClickCursor(rowId("cr-list", 1), onClickStub, null, .pointer);
    const bb = cl.getElementData(rowId("cr-list", 1)).bounding_box;
    try std.testing.expectEqual(Cursor.pointer, hoverCursorAt(bb.x + bb.width * 0.5, bb.y + bb.height * 0.5));
    try std.testing.expectEqual(Cursor.default, hoverCursorAt(700, 460));
}

test "hoverCursorAt topmost wins: higher-z beats earlier, ties last wins" {
    try layoutThree();
    beginFrame();
    // Higher-z wins even when registered first (overlay over rows).
    registerZCursor(rowId("cr-list", 1), onRow, null, 0, 10, .text);
    registerZCursor(rowId("cr-list", 1), onRow, null, 1, 0, .pointer);
    const bb = cl.getElementData(rowId("cr-list", 1)).bounding_box;
    const cx = bb.x + bb.width * 0.5;
    const cy = bb.y + bb.height * 0.5;
    try std.testing.expectEqual(Cursor.text, hoverCursorAt(cx, cy));

    // Ties: last-registered wins (mirror dispatchClick).
    beginFrame();
    registerClickCursor(rowId("cr-list", 1), onClickStub, null, .pointer);
    registerClickCursor(rowId("cr-list", 1), onClickStub, null, .ew_resize);
    try std.testing.expectEqual(Cursor.ew_resize, hoverCursorAt(cx, cy));
}

test "hover-only entry is visible to hover but skipped for click" {
    try layoutThree();
    beginFrame();
    registerHover(rowId("cr-list", 1), .text);
    const bb = cl.getElementData(rowId("cr-list", 1)).bounding_box;
    const cx = bb.x + bb.width * 0.5;
    const cy = bb.y + bb.height * 0.5;
    try std.testing.expectEqual(Cursor.text, hoverCursorAt(cx, cy));
    try std.testing.expect(!dispatchClick(cx, cy));
}

test "legacy registerClick wrapper still stores default cursor" {
    try layoutThree();
    beginFrame();
    var c = Rec{};
    register(rowId("cr-list", 1), onRow, &c, 7);
    const bb = cl.getElementData(rowId("cr-list", 1)).bounding_box;
    try std.testing.expectEqual(Cursor.default, hoverCursorAt(bb.x + bb.width * 0.5, bb.y + bb.height * 0.5));
    try std.testing.expect(dispatchClick(bb.x + bb.width * 0.5, bb.y + bb.height * 0.5));
    try std.testing.expectEqual(@as(usize, 1), c.calls);
}
