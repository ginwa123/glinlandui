// Engine-owned per-frame click registry (no alloc, fixed cap).
const std = @import("std");
const builtin = @import("builtin");
const cl = @import("zclay");
const headless = @import("../testing/headless.zig");

/// Every click target of one frame. The devtool overlay claims a slice of this for its own rows, so it sits above an app's own ceiling.
pub const cap: usize = 384;

/// Cursor kind for Wayland wl_pointer cursor shape: the same enum a widget's props name.
pub const Cursor = @import("../props.zig").Cursor;

/// The colour type a claim is tested with: only a fill that hides what is behind it stops a click.
const Color = @import("../color.zig").Color;

/// Click callback shapes (same as button.ClickFn / list row fn).
pub const ClickFn = *const fn (?*anyopaque) void;
pub const RowFn = *const fn (?*anyopaque, usize) void;

/// Per-row click target: distinct fn+ctx per row (Stage B).
pub const RowClick = struct {
    on_click: *const fn (?*anyopaque, usize) void,
    ctx: ?*anyopaque,
};

/// The viewports a target is clipped to, as ELEMENT IDS resolved at hit-test time, never as rects captured while declaring: a container's box is only known when its own layout closes, so such a rect is always the previous frame's, and the frame after a pane grows is the one the next click lands in.
pub const Clip = struct {
    ids: [clip_depth_max]cl.ElementId = undefined,
    n: u8 = 0,
};

/// Deepest scroll nesting a hit target remembers; a target four containers deep is already a design smell.
pub const clip_depth_max: usize = 8;

/// True when the point falls inside EVERY viewport in the chain; an absent chain, or a viewport this frame has no box for, clips nothing.
pub fn insideClip(c: ?Clip, x: f32, y: f32) bool {
    const chain = c orelse return true;
    for (chain.ids[0..chain.n]) |id| {
        const data = cl.getElementData(id);
        if (!data.found) continue;
        const bb = data.bounding_box;
        if (bb.width <= 0 or bb.height <= 0) continue;
        if (x < bb.x or x >= bb.x + bb.width or y < bb.y or y >= bb.y + bb.height) return false;
    }
    return true;
}

const Entry = struct {
    id: cl.ElementId,
    cb_row: ?*const fn (?*anyopaque, usize) void = null,
    cb_click: ?*const fn (?*anyopaque) void = null,
    /// Second click on the same spot; a target with one costs a single entry, not two.
    cb_double: ?*const fn (?*anyopaque) void = null,
    ctx: ?*anyopaque = null,
    index: usize = 0,
    /// Dispatch priority: highest-z containing match wins (overlay cards register above in-flow rows).
    z: i16 = 0,
    /// Hover cursor for this entry (Wayland cursor shape).
    cursor: Cursor = .default,
    /// Scroll-container viewport this target was declared inside, if any.
    clip: ?Clip = null,
    /// Declaration order inside the frame, which is paint order: a later target is drawn over an earlier one.
    seq: u32 = 0,
};

var entries: [cap]Entry = undefined;
var count: usize = 0;

/// One opaque surface: a widget that paints a fill hiding whatever is behind it. Its area answers a click for itself, so nothing registered BEFORE it is reachable there.
const Surface = struct {
    id: cl.ElementId,
    z: i16 = 0,
    seq: u32 = 0,
    clip: ?Clip = null,
};

/// How many opaque surfaces one frame may claim; a screen with more filled boxes than this is past the point where a per-frame fixed cap helps.
pub const surface_cap: usize = 512;

var surfaces: [surface_cap]Surface = undefined;
var surface_count: usize = 0;

/// A frame's single ordering counter, shared by targets and surfaces so paint order across both is comparable.
var seq_counter: u32 = 0;

fn nextSeq() u32 {
    const s = seq_counter;
    seq_counter +%= 1;
    return s;
}

/// Viewport chain in force while declaring; `pushClip` appends to it and `popClip` unwinds it.
var clip: ?Clip = null;
var clip_stack: [clip_depth_max]?Clip = undefined;
var clip_depth: usize = 0;

/// Clear the registry for a new frame.
pub fn beginFrame() void {
    count = 0;
    surface_count = 0;
    seq_counter = 0;
    clip = null;
    clip_depth = 0;
}

/// An opaque fill claims the area it covers: a click inside it is answered by IT, never by something painted underneath.
pub fn occlude(id: cl.ElementId) void {
    occludeZ(id, 0);
}

/// The same, for an overlay: a card floating with `z` claims its area at that priority, so an in-flow target behind it (z 0) stays unreachable.
pub fn occludeZ(id: cl.ElementId, z: i16) void {
    if (surface_count >= surface_cap) return;
    surfaces[surface_count] = .{ .id = id, .z = z, .seq = nextSeq(), .clip = clip };
    surface_count += 1;
}

/// The claim an opaque background makes; a translucent one (an alpha below 255) shows what is behind it, so it claims nothing.
pub fn occludeFill(id: cl.ElementId, bg: Color) void {
    if (bg.isOpaque()) occlude(id);
}

/// The same for a floating card: it claims at its own z, so the page it covers stays unreachable while its own rows (registered above) do not.
pub fn occludeFillZ(id: cl.ElementId, bg: Color, z: i16) void {
    if (bg.isOpaque()) occludeZ(id, z);
}

/// How many surfaces claimed something this frame (the devtool's tree and the tests read it).
pub fn surfaceCount() usize {
    return surface_count;
}

/// Enter a scroll container's viewport: targets declared until `popClip` answer only inside it.
pub fn pushClip(id: cl.ElementId) void {
    if (clip_depth < clip_stack.len) {
        clip_stack[clip_depth] = clip;
        clip_depth += 1;
    }
    var next = clip orelse Clip{};
    // A chain this deep is already off the map; the innermost viewports still bound the target.
    if (next.n < clip_depth_max) {
        next.ids[next.n] = id;
        next.n += 1;
    }
    clip = next;
}

/// Leave the innermost scroll container.
pub fn popClip() void {
    if (clip_depth == 0) return;
    clip_depth -= 1;
    clip = clip_stack[clip_depth];
}

/// The viewport chain in force, so a widget that hit-tests LATER (a context menu) is clipped the same way.
pub fn currentClip() ?Clip {
    return clip;
}

/// Register a row hit-target (list/dropdown rows) at default priority 0.
pub fn register(id: cl.ElementId, cb: *const fn (?*anyopaque, usize) void, ctx: ?*anyopaque, index: usize) void {
    registerZ(id, cb, ctx, index, 0);
}

/// Register a row hit-target with dispatch priority (overlay rows pass their float z so they win over covered in-flow rows at shared points).
pub fn registerZ(id: cl.ElementId, cb: *const fn (?*anyopaque, usize) void, ctx: ?*anyopaque, index: usize, z: i16) void {
    registerZCursor(id, cb, ctx, index, z, .default);
}

/// Full row version storing cursor (list rows pass .pointer).
pub fn registerZCursor(id: cl.ElementId, cb: *const fn (?*anyopaque, usize) void, ctx: ?*anyopaque, index: usize, z: i16, cursor: Cursor) void {
    if (count >= cap) return;
    entries[count] = .{ .id = id, .cb_row = cb, .ctx = ctx, .index = index, .z = z, .cursor = cursor, .clip = clip, .seq = nextSeq() };
    count += 1;
}

/// Register a button hit-target (index-free click).
pub fn registerClick(id: cl.ElementId, cb: ClickFn, ctx: ?*anyopaque) void {
    registerClickCursor(id, cb, ctx, .default);
}

/// Full click version storing cursor (button/toggle/checkbox/radio pass .pointer, slider passes .ew_resize, image on_click passes .pointer).
pub fn registerClickCursor(id: cl.ElementId, cb: ClickFn, ctx: ?*anyopaque, cursor: Cursor) void {
    registerClickCursorZ(id, cb, ctx, cursor, 0);
}

/// The same, with a dispatch priority: a field inside an overlay that swallows clicks must register ABOVE it, or the overlay eats the click.
pub fn registerClickCursorZ(id: cl.ElementId, cb: ClickFn, ctx: ?*anyopaque, cursor: Cursor, z: i16) void {
    if (count >= cap) return;
    entries[count] = .{ .id = id, .cb_click = cb, .ctx = ctx, .z = z, .cursor = cursor, .clip = clip, .seq = nextSeq() };
    count += 1;
}

/// Register a click target that also answers a double click (word select). One entry, two callbacks.
pub fn registerClickDoubleCursor(id: cl.ElementId, cb: ClickFn, cb_double: ClickFn, ctx: ?*anyopaque, cursor: Cursor) void {
    registerClickDoubleCursorZ(id, cb, cb_double, ctx, cursor, 0);
}

/// The same, with a dispatch priority (see `registerClickCursorZ`).
pub fn registerClickDoubleCursorZ(id: cl.ElementId, cb: ClickFn, cb_double: ClickFn, ctx: ?*anyopaque, cursor: Cursor, z: i16) void {
    const before = count;
    registerClickCursorZ(id, cb, ctx, cursor, z);
    // Only when it actually landed: a full registry must not rewrite somebody else's entry.
    if (count > before) entries[count - 1].cb_double = cb_double;
}

/// Register a hover-only entry (no click callback): dispatchClick skips it but hoverCursorAt sees it.
pub fn registerHover(id: cl.ElementId, cursor: Cursor) void {
    registerHoverZ(id, cursor, 0);
}

/// Hover-only with explicit z (overlay floats pass their z so the float wins over covered in-flow rows, mirroring dispatchClick's rule).
pub fn registerHoverZ(id: cl.ElementId, cursor: Cursor, z: i16) void {
    if (count >= cap) return;
    entries[count] = .{ .id = id, .z = z, .cursor = cursor, .clip = clip, .seq = nextSeq() };
    count += 1;
}

fn contains(bb: cl.BoundingBox, x: f32, y: f32) bool {
    return x >= bb.x and x < bb.x + bb.width and y >= bb.y and y < bb.y + bb.height;
}

/// True when an opaque surface fills this point ABOVE the priority given: it is painted later (or floats higher), so whatever is underneath is not what the user is pointing at.
fn filledAbove(x: f32, y: f32, z: i16, seq: u32) bool {
    var i: usize = 0;
    while (i < surface_count) : (i += 1) {
        const s = surfaces[i];
        // Ordering is (z, declaration): a surface with a lower z or an earlier declare is BEHIND this target.
        if (s.z < z) continue;
        if (s.z == z and s.seq <= seq) continue;
        const data = cl.getElementData(s.id);
        if (!data.found) continue;
        if (!contains(data.bounding_box, x, y)) continue;
        if (!insideClip(s.clip, x, y)) continue;
        return true;
    }
    return false;
}

/// The highest-z entry containing the point (ties keep last-registered-first), or null.
pub fn topmostAt(x: f32, y: f32) ?Entry {
    var best: ?Entry = null;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const e = entries[i];
        // Hover-only entries never fire clicks.
        if (e.cb_row == null and e.cb_click == null and e.cb_double == null) continue;
        const data = cl.getElementData(e.id);
        if (!data.found) continue;
        if (!contains(data.bounding_box, x, y)) continue;
        if (!insideClip(e.clip, x, y)) continue;
        // Forward scan + >= : later entries win ties (legacy order).
        if (best == null or e.z >= best.?.z) best = e;
    }
    // A filled surface painted over this target takes the click: an input behind a pane must not answer through it.
    if (best) |b| if (filledAbove(x, y, b.z, b.seq)) return null;
    return best;
}

// A freestanding target (the browser build) must never ANALYSE `getenv` or `std.debug.print` — the latter reaches `std.Io.Threaded`, which cannot exist there — so both sit behind the same comptime guard core/log.zig uses, around a call to a separate function.
const can_trace = !builtin.is_test and !builtin.cpu.arch.isWasm() and builtin.link_libc;

/// `GLIN_CLICK_TRACE=1`: every dispatched click, the target it found and that target's box, or what was near the point when nothing answered.
fn traceEnabled() bool {
    if (comptime !can_trace) return false;
    return traceFromEnv();
}

fn traceFromEnv() bool {
    const v = std.c.getenv("GLIN_CLICK_TRACE") orelse return false;
    return v[0] != 0 and v[0] != '0';
}

fn tracePrint(comptime fmt: []const u8, args: anytype) void {
    if (comptime can_trace) tracePrintNative(fmt, args);
}

fn tracePrintNative(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt, args);
}

pub fn describeAt(x: f32, y: f32) void {
    if (topmostAt(x, y)) |hit| {
        const data = cl.getElementData(hit.id);
        tracePrint("[click] ({d:.1},{d:.1}) -> id {d}/{d} z={d} box {d:.1},{d:.1} {d:.1}x{d:.1}\n", .{
            x,                   y,                   hit.id.id,               hit.id.offset,            hit.z,
            data.bounding_box.x, data.bounding_box.y, data.bounding_box.width, data.bounding_box.height,
        });
        return;
    }
    // A filled surface over a target is the one case where a target exists and must not answer, so the trace says it.
    var best: ?Entry = null;
    var j: usize = 0;
    while (j < count) : (j += 1) {
        const e = entries[j];
        const data = cl.getElementData(e.id);
        if (!data.found or !contains(data.bounding_box, x, y) or !insideClip(e.clip, x, y)) continue;
        if (e.cb_row != null or e.cb_click != null) best = e;
    }
    if (best) |b| {
        tracePrint("[click] ({d:.1},{d:.1}) -> COVERED: id {d}/{d} is painted under a filled surface\n", .{ x, y, b.id.id, b.id.offset });
        return;
    }
    tracePrint("[click] ({d:.1},{d:.1}) -> NOTHING ({d} entries)\n", .{ x, y, count });
    // The boxes that contain the x but not the y, which is what a vertical offset looks like.
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const e = entries[i];
        if (e.cb_row == null and e.cb_click == null) continue;
        const data = cl.getElementData(e.id);
        if (!data.found) continue;
        const bb = data.bounding_box;
        if (bb.width <= 0 or bb.height <= 0) continue;
        if (x < bb.x or x >= bb.x + bb.width) continue;
        tracePrint("[click]   near: y {d:.1}..{d:.1} (point y {d:.1}, off by {d:.1}) z={d} clipped={}\n", .{
            bb.y, bb.y + bb.height, y, y - bb.y, e.z, !insideClip(e.clip, x, y),
        });
    }
}

/// Dispatch a click point: the highest-z containing match fires once (ties keep last-registered-first).
pub fn dispatchClick(x: f32, y: f32) bool {
    if (traceEnabled()) describeAt(x, y);
    const hit = topmostAt(x, y) orelse return false;
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

/// Dispatch a double click: the same hit test, preferring the double callback and falling back to the single one.
pub fn dispatchDoubleClick(x: f32, y: f32) bool {
    const hit = topmostAt(x, y) orelse return false;
    if (hit.cb_double) |cb| {
        cb(hit.ctx);
        return true;
    }
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

/// Hover cursor at a point: topmost (highest-z, ties last-registered wins — mirrors dispatchClick's rule) CONTAINING entry's cursor, or .default when.
pub fn hoverCursorAt(x: f32, y: f32) Cursor {
    var best: ?Entry = null;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const e = entries[i];
        const data = cl.getElementData(e.id);
        if (!data.found) continue;
        if (!contains(data.bounding_box, x, y)) continue;
        if (!insideClip(e.clip, x, y)) continue;
        if (best == null or e.z >= best.?.z) best = e;
    }
    // The same rule a click follows: a field covered by an opaque card is not an I-beam, it is the card.
    if (best) |b| if (filledAbove(x, y, b.z, b.seq)) return .default;
    return if (best) |hit| hit.cursor else .default;
}

// ---- Read-only view for consumers that need "what is clickable this frame" without owning the dispatch logic (the semantics layer).

/// One hit-target entry, stripped of its callback pointers.
pub const Hit = struct {
    id: cl.ElementId,
    z: i16,
    cursor: Cursor,
    clickable: bool,
    clip: ?Clip,
};

pub fn hitCount() usize {
    return count;
}

pub fn hitAt(i: usize) ?Hit {
    if (i >= count) return null;
    const e = entries[i];
    return .{
        .id = e.id,
        .z = e.z,
        .cursor = e.cursor,
        .clickable = (e.cb_row != null or e.cb_click != null),
        .clip = e.clip,
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
    headless.begin(.{ .x = 99999, .y = 99999 }, false);
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
    // Overlay registers first (declared mid-loop), covered row after — visual stacking (z), not declare order, decides.
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
    // No count accessor on the registry API, so the cap is asserted via dispatch behavior: cap + 6 registrations against one valid box must fire exactly.
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
    // Disabled components skip registration entirely, so a declared but never-registered box must report .default on hover.
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

// ---- Clip chain (by element id) ---- A target inside a scroll container answers only inside it, and the container is named by ID: its box is not known while it is still being declared.

const ClipRec = struct {
    calls: usize = 0,
    last: ?usize = null,
};

/// A click-shaped recorder (no index), for the targets the clip tests register.
const ClipClick = struct {
    calls: usize = 0,
};

fn onClipClick(ctx: ?*anyopaque) void {
    const r: *ClipClick = @ptrCast(@alignCast(ctx.?));
    r.calls += 1;
}

fn onClipRow(ctx: ?*anyopaque, i: usize) void {
    const r: *ClipRec = @ptrCast(@alignCast(ctx.?));
    r.calls += 1;
    r.last = i;
}

fn clipRowId(i: usize) cl.ElementId {
    return cl.ElementId.IDI("cr-inner", @as(u32, @intCast(i + 1)));
}

/// A `viewport_h` scroll container of `rows` 20pt rows, each registering its click target while the clip is pushed (the only place a component can register).
fn declareScrolled(rows: usize, viewport_h: f32, rec: *ClipRec) void {
    cl.UI()(.{
        .id = .ID("cr-scroll"),
        .layout = .{ .sizing = .{ .w = .fixed(200), .h = .fixed(viewport_h) } },
    })({
        pushClip(cl.ElementId.ID("cr-scroll"));
        cl.UI()(.{
            .id = .ID("cr-inner"),
            .layout = .{ .direction = .top_to_bottom, .sizing = .{ .w = .grow, .h = .fit } },
        })({
            for (0..rows) |i| {
                cl.UI()(.{
                    .id = .IDI("cr-inner", @as(u32, @intCast(i + 1))),
                    .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(20) } },
                })({});
                registerZCursor(clipRowId(i), onClipRow, rec, i, 0, .pointer);
            }
        });
        popClip();
    });
}

fn layoutScrolled(rows: usize, viewport_h: f32, rec: *ClipRec) void {
    beginFrame();
    headless.begin(.{ .x = 99999, .y = 99999 }, false);
    cl.beginLayout();
    declareScrolled(rows, viewport_h, rec);
    _ = cl.endLayout();
}

fn rowCentre(i: usize) cl.Vector2 {
    const bb = cl.getElementData(clipRowId(i)).bounding_box;
    return .{ .x = bb.x + bb.width * 0.5, .y = bb.y + bb.height * 0.5 };
}

test "a scroll container answers inside itself and nowhere else" {
    var rec = ClipRec{};
    layoutScrolled(8, 40, &rec);

    const inside = rowCentre(0);
    try std.testing.expect(dispatchClick(inside.x, inside.y));
    try std.testing.expectEqual(@as(?usize, 0), rec.last);

    // Row 5 sits below the 40pt viewport: it must answer nothing, or it would swallow the click on whatever is under it.
    const outside = rowCentre(5);
    try std.testing.expect(!dispatchClick(outside.x, outside.y));
    try std.testing.expectEqual(@as(usize, 1), rec.calls);
}

test "a row revealed when the pane grows answers at once (the clip follows the layout, not the last frame)" {
    // THE regression: the viewport is 40pt, then the pane grows to 160pt in one frame (what a resize leaves behind). While the clip was a rect read during declaration, that frame clipped its rows to the OLD box, so rows in the revealed strip sat on screen and refused clicks.
    var rec = ClipRec{};
    layoutScrolled(8, 40, &rec);
    layoutScrolled(8, 160, &rec);

    const row = rowCentre(6);
    try std.testing.expect(row.y > 40);
    try std.testing.expect(dispatchClick(row.x, row.y));
    try std.testing.expectEqual(@as(?usize, 6), rec.last);
}

test "nested scroll containers both clip, and the chain unwinds for a sibling" {
    var rec = ClipClick{};
    beginFrame();
    headless.begin(.{ .x = 99999, .y = 99999 }, false);
    cl.beginLayout();
    cl.UI()(.{ .id = .ID("cr-outer"), .layout = .{ .sizing = .{ .w = .fixed(200), .h = .fixed(100) } } })({
        cl.UI()(.{ .id = .ID("cr-inner-scroll"), .layout = .{ .sizing = .{ .w = .fixed(100), .h = .fixed(40) } } })({
            pushClip(cl.ElementId.ID("cr-inner-scroll"));
            cl.UI()(.{ .id = .ID("cr-leaf"), .layout = .{ .sizing = .{ .w = .grow, .h = .grow } } })({});
            registerClick(.ID("cr-leaf"), onClipClick, &rec);
            popClip();
        });
        // A sibling declared after the pop: it is not inside the inner viewport, so only its own ancestry bounds it.
        cl.UI()(.{ .id = .ID("cr-sibling"), .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(40) } } })({});
        registerClick(.ID("cr-sibling"), onClipClick, &rec);
    });
    _ = cl.endLayout();

    const leaf = cl.getElementData(cl.ElementId.ID("cr-leaf")).bounding_box;
    try std.testing.expect(dispatchClick(leaf.x + leaf.width * 0.5, leaf.y + leaf.height * 0.5));
    const sib = cl.getElementData(cl.ElementId.ID("cr-sibling")).bounding_box;
    try std.testing.expect(dispatchClick(sib.x + sib.width * 0.5, sib.y + sib.height * 0.5));
    try std.testing.expectEqual(@as(usize, 2), rec.calls);
}

// ---- occlusion: an opaque fill claims the area it covers ---------------------------------------------- A target painted UNDER a filled surface is not what the user is pointing at, so it must not answer. This is the rule that keeps a click on a pane from reaching an input that the pane covers.

var oc_rec = ClipClick{};

fn onOcClick(ctx: ?*anyopaque) void {
    const r: *ClipClick = @ptrCast(@alignCast(ctx.?));
    r.calls += 1;
}

// A 120x40 target at the origin, then (optionally) a 200x120 surface floating over it: the pane-over-a-row shape.
fn declareOcclusion(claim: bool, translucent: bool) void {
    cl.UI()(.{ .id = .ID("oc-under"), .layout = .{ .sizing = .{ .w = .fixed(120), .h = .fixed(40) } } })({});
    registerClick(.ID("oc-under"), onOcClick, &oc_rec);
    registerHover(.ID("oc-under"), .text);
    cl.UI()(.{
        .id = .ID("oc-over"),
        .layout = .{ .sizing = .{ .w = .fixed(200), .h = .fixed(120) } },
        .floating = .{ .attach_to = .to_root, .attach_points = .{ .element = .left_top, .parent = .left_top }, .z_index = 0 },
    })({});
    if (!claim) return;
    if (translucent) occludeFill(.ID("oc-over"), @import("../color.zig").Color.rgba(0, 0, 0, 80)) else occludeFill(.ID("oc-over"), @import("../color.zig").Color.rgb(0x1e, 0x1e, 0x1e));
}

// ONE canvas for this file's occlusion tests: Clay keeps a process-global context pointer, so the same arena is re-initialised instead of a new one being handed out per test.
var oc_canvas: ?[]u8 = null;

fn ocBegin() void {
    if (oc_canvas == null) {
        oc_canvas = std.heap.page_allocator.alloc(u8, cl.minMemorySize()) catch @panic("occlusion Clay arena");
    }
    _ = cl.initialize(cl.Arena.init(oc_canvas.?), .{ .w = 720, .h = 480 }, .{});
    const fm = @import("../frame.zig");
    fm.setViewport(fm.viewportOf(720, 480));
    cl.setMeasureTextFunction(void, {}, headless.stubMeasure);
    cl.setPointerState(.{ .x = 99999, .y = 99999 }, false);
}

fn layOutOcclusion(claim: bool, translucent: bool) void {
    beginFrame();
    ocBegin();
    cl.beginLayout();
    declareOcclusion(claim, translucent);
    _ = cl.endLayout();
}

fn underCentre() cl.Vector2 {
    const bb = cl.getElementData(cl.ElementId.ID("oc-under")).bounding_box;
    return .{ .x = bb.x + bb.width * 0.5, .y = bb.y + bb.height * 0.5 };
}

test "a filled surface over a target stops the click reaching it" {
    oc_rec = ClipClick{};
    // Without a claim the target answers, which is the defect this rule exists to remove.
    layOutOcclusion(false, false);
    const p = underCentre();
    try std.testing.expect(dispatchClick(p.x, p.y));
    try std.testing.expectEqual(@as(usize, 1), oc_rec.calls);

    // With the pane's fill claiming the area, the same point answers nothing.
    layOutOcclusion(true, false);
    try std.testing.expectEqual(@as(usize, 1), surfaceCount());
    try std.testing.expect(!dispatchClick(p.x, p.y));
    try std.testing.expectEqual(@as(usize, 1), oc_rec.calls);
}

test "a translucent fill hides nothing, so the target underneath still answers" {
    oc_rec = ClipClick{};
    layOutOcclusion(true, true);
    const p = underCentre();
    try std.testing.expect(dispatchClick(p.x, p.y));
    try std.testing.expectEqual(@as(usize, 1), oc_rec.calls);
}

test "a target declared INSIDE the covering surface answers as usual" {
    // The pane claims its area, then its own child registers: paint order decides, and the child is later.
    oc_rec = ClipClick{};
    beginFrame();
    headless.begin(.{ .x = 99999, .y = 99999 }, false);
    cl.beginLayout();
    cl.UI()(.{ .id = .ID("oc-card"), .layout = .{ .sizing = .{ .w = .fixed(200), .h = .fixed(120) } } })({
        occludeFill(.ID("oc-card"), @import("../color.zig").Color.rgb(0x1e, 0x1e, 0x1e));
        cl.UI()(.{ .id = .ID("oc-child"), .layout = .{ .sizing = .{ .w = .fixed(80), .h = .fixed(30) } } })({});
        registerClick(.ID("oc-child"), onOcClick, &oc_rec);
    });
    _ = cl.endLayout();

    const bb = cl.getElementData(cl.ElementId.ID("oc-child")).bounding_box;
    try std.testing.expect(dispatchClick(bb.x + bb.width * 0.5, bb.y + bb.height * 0.5));
    try std.testing.expectEqual(@as(usize, 1), oc_rec.calls);
}

test "a surface painted BEFORE a target does not hide it" {
    // A card drawn first, the target on top of it: the later target is what the user sees.
    oc_rec = ClipClick{};
    beginFrame();
    headless.begin(.{ .x = 99999, .y = 99999 }, false);
    cl.beginLayout();
    cl.UI()(.{
        .id = .ID("oc-behind"),
        .layout = .{ .sizing = .{ .w = .fixed(200), .h = .fixed(120) } },
        .floating = .{ .attach_to = .to_root, .attach_points = .{ .element = .left_top, .parent = .left_top }, .z_index = 0 },
    })({});
    occludeFill(.ID("oc-behind"), @import("../color.zig").Color.rgb(0x1e, 0x1e, 0x1e));
    cl.UI()(.{ .id = .ID("oc-above"), .layout = .{ .sizing = .{ .w = .fixed(80), .h = .fixed(30) } } })({});
    registerClick(.ID("oc-above"), onOcClick, &oc_rec);
    _ = cl.endLayout();

    const bb = cl.getElementData(cl.ElementId.ID("oc-above")).bounding_box;
    try std.testing.expect(dispatchClick(bb.x + bb.width * 0.5, bb.y + bb.height * 0.5));
    try std.testing.expectEqual(@as(usize, 1), oc_rec.calls);
}

test "an overlay above the covering surface still answers" {
    // An in-flow pane claims at z 0; a dropdown card floating at z 10 is painted over it, so its row must win.
    oc_rec = ClipClick{};
    beginFrame();
    headless.begin(.{ .x = 99999, .y = 99999 }, false);
    cl.beginLayout();
    cl.UI()(.{
        .id = .ID("oc-pane"),
        .layout = .{ .sizing = .{ .w = .fixed(300), .h = .fixed(200) } },
        .floating = .{ .attach_to = .to_root, .attach_points = .{ .element = .left_top, .parent = .left_top }, .z_index = 0 },
    })({});
    occlude(.ID("oc-pane"));
    cl.UI()(.{
        .id = .ID("oc-popup"),
        .layout = .{ .sizing = .{ .w = .fixed(90), .h = .fixed(24) } },
        .floating = .{ .attach_to = .to_root, .attach_points = .{ .element = .left_top, .parent = .left_top }, .z_index = 10 },
    })({});
    occludeZ(.ID("oc-popup"), 10);
    registerZ(.ID("oc-popup"), onClipRow, &oc_rec, 0, 10);
    _ = cl.endLayout();

    const bb = cl.getElementData(cl.ElementId.ID("oc-popup")).bounding_box;
    try std.testing.expect(dispatchClick(bb.x + bb.width * 0.5, bb.y + bb.height * 0.5));
    try std.testing.expectEqual(@as(usize, 1), oc_rec.calls);
}

test "the hover cursor of a covered field is not an I-beam" {
    layOutOcclusion(false, false);
    const p = underCentre();
    try std.testing.expectEqual(Cursor.text, hoverCursorAt(p.x, p.y));

    // The pane's claim covers it, so the pointer is the pane's own shape.
    layOutOcclusion(true, false);
    try std.testing.expectEqual(Cursor.default, hoverCursorAt(p.x, p.y));
}
