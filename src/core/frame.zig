// Agnostic Clay frame helper: owns the per-frame + init boilerplate every Clay app repeats (measure/error wiring, arena init, pointer + layout sync.
const std = @import("std");
const log = @import("log.zig");
const audit = @import("audit.zig");
const builtin = @import("builtin");
const cl = @import("zclay");
const render = @import("render.zig");
const text = @import("text_backend.zig");
const click_registry = @import("component.zig").click_registry;
const semantics = @import("semantics.zig");
const text_editor = @import("text_editor.zig");
const zoom_mod = @import("zoom.zig");

// ---- Wayland cursor-shape (wp_cursor_shape_manager_v1) ---- Contract (registry crew owns components/click_registry.zig).
pub const Cursor = enum { default, pointer, text, ew_resize, ns_resize };

pub const shape_default: u32 = 1;
pub const shape_pointer: u32 = 4;
pub const shape_text: u32 = 9;
pub const shape_ew_resize: u32 = 26;
pub const shape_ns_resize: u32 = 27;
// Sentinel for Window.last_shape: 0 is not a valid shape (valid range starts at 1), so the first real shape always counts as a change.
pub const shape_sentinel: u32 = 0;

pub fn cursorShapeFromCursor(cursor: Cursor) u32 {
    return switch (cursor) {
        .default => shape_default,
        .pointer => shape_pointer,
        .text => shape_text,
        .ew_resize => shape_ew_resize,
        .ns_resize => shape_ns_resize,
    };
}

// Resolve the cursor for a pointer point.
pub fn hoverCursorShape(x: f32, y: f32) u32 {
    if (@hasDecl(click_registry, "hoverCursorAt")) {
        const cur = click_registry.hoverCursorAt(x, y);
        const name = @tagName(cur);
        if (std.mem.eql(u8, name, "pointer")) return shape_pointer;
        if (std.mem.eql(u8, name, "text")) return shape_text;
        if (std.mem.eql(u8, name, "ew_resize")) return shape_ew_resize;
        if (std.mem.eql(u8, name, "ns_resize")) return shape_ns_resize;
        return shape_default;
    }
    return shape_default;
}

// The pointer position and the frame clock, so a component can place a caret from a click and blink it without the app plumbing either through.
pub var ptr_x: f32 = 0;
pub var ptr_y: f32 = 0;
pub var time_s: f32 = 0;
pub var delta_s: f32 = 0;

// Frame-scoped scratch for strings a draw command points at, reset at the top of every frame: exactly as long as a render command needs them.
var text_arena: [1024 * 1024]u8 = undefined;
var text_used: usize = 0;

// Claim `n` bytes of frame scratch. An over-long request gets an empty slice, so a full arena degrades to a missing label, never a panic.
pub fn claimText(n: usize) []u8 {
    if (n == 0 or text_used + n > text_arena.len) return &[_]u8{};
    const start = text_used;
    text_used += n;
    return text_arena[start..text_used];
}

// Format a string into the frame's scratch, e.g. `frame.formatText("{d} rows", .{n})`. Valid until the next frame; sized to fit, never truncated.
pub fn formatText(comptime fmt: []const u8, args: anytype) []const u8 {
    const buf = claimText(std.fmt.count(fmt, args));
    if (buf.len == 0) return "";
    return std.fmt.bufPrint(buf, fmt, args) catch "";
}

// A frame-scoped element id, e.g. "grid.cell.3": the id a per-row component needs without building a string by hand.
pub fn elementId(prefix: []const u8, index: usize) []const u8 {
    return formatText("{s}.{d}", .{ prefix, index });
}

// The element id Clay hashes from a name, for the calls that need one without naming Clay's type.
pub fn clayId(name: []const u8) cl.ElementId {
    return cl.getElementId(name);
}

// The id of one item of an indexed list, without formatting a string for it.
pub fn itemId(prefix: []const u8, index: u32) cl.ElementId {
    return cl.ElementId.IDI(prefix, index);
}

// A laid-out box, in logical units.
pub const Bounds = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
};

// The box Clay laid out for an element this frame, or null when it was not declared.
pub fn bounds(id: cl.ElementId) ?Bounds {
    // Before the first frame Clay has no context at all, and its own lookup would dereference NULL: a box is simply not known yet.
    if (@intFromPtr(cl.getCurrentContext()) == 0) return null;
    const data = cl.getElementData(id);
    if (!data.found) return null;
    return .{
        .x = data.bounding_box.x,
        .y = data.bounding_box.y,
        .width = data.bounding_box.width,
        .height = data.bounding_box.height,
    };
}

// A frame-scoped element id with two indices, e.g. "grid.cell.3.1".
pub fn elementId2(prefix: []const u8, a: usize, b: usize) []const u8 {
    return formatText("{s}.{d}.{d}", .{ prefix, a, b });
}

// Whether the left button is held, and where that press began, so a field can tell a drag that started on it from one that wandered in.
pub var ptr_down: bool = false;
pub var ptr_press_x: f32 = 0;
pub var ptr_press_y: f32 = 0;
// Whether Shift was held for that press: a shift-click EXTENDS the selection instead of placing a caret.
pub var ptr_shift: bool = false;

// The wheel this frame consumed, in points: a strip with its own axis reads it, since a wheel has no horizontal one.
pub var scroll_dx: f32 = 0;
pub var scroll_dy: f32 = 0;

// Record the pointer position for this frame.
pub fn setPointer(x: f32, y: f32) void {
    ptr_x = x;
    ptr_y = y;
}

// Device pixels per logical point, as the window backend set it. 1.0 until a Retina window says otherwise.
pub var pixel_scale: f32 = 1;

// Content points per window point: what `Ctrl/Cmd +` / `-` / `0` set. A frame declares in content points and paints at this.
pub var content_zoom: f32 = 1;

// Device pixels per content point: the scale a run is rastered at and a box is painted at.
fn deviceScale() f32 {
    return pixel_scale * content_zoom;
}

// Record the window's backing scale, so a hairline can be snapped to real device pixels.
pub fn setPixelScale(s: f32) void {
    pixel_scale = if (s > 0) s else 1;
    // The rasteriser draws a run at round(size * scale), so the layout must measure that size or a caret drifts off it.
    text.setPixelScale(deviceScale());
}

// Set the content zoom. The frame keeps declaring in content points: the window simply shows fewer of them.
pub fn setZoom(factor: f32) void {
    content_zoom = zoom_mod.clamp(factor);
    text.setPixelScale(deviceScale());
}

// The content zoom in force, 1.0 when nothing asked for one.
pub fn zoom() f32 {
    return content_zoom;
}

// The window's width in the units a frame declares in, which is the width the layout is computed for.
pub fn contentWidth(w: u32) u32 {
    const scaled = @as(f32, @floatFromInt(w)) / content_zoom;
    return @intFromFloat(@max(1, @round(scaled)));
}

pub fn contentHeight(h: u32) u32 {
    const scaled = @as(f32, @floatFromInt(h)) / content_zoom;
    return @intFromFloat(@max(1, @round(scaled)));
}

// The box a frame is declaring in, in content points: the window divided by the zoom.
pub const Viewport = struct { w: f32 = 0, h: f32 = 0 };

var viewport_now: Viewport = .{};

// The content points this frame has, so a widget that needs the window reads it here instead of being handed it.
pub fn viewport() Viewport {
    return viewport_now;
}

// The frame sets this every frame; a harness that lays out on its own says the same thing here.
pub fn setViewport(v: Viewport) void {
    viewport_now = v;
}

// The viewport a window of this size gives, which is the whole zoom correction in one place.
pub fn viewportOf(w: u32, h: u32) Viewport {
    return .{ .w = @floatFromInt(contentWidth(w)), .h = @floatFromInt(contentHeight(h)) };
}

// Snap a caret's left edge to the device pixel grid. A 1 pt bar at a fractional x is antialiased across two device pixels, and the half-covered one

// blends into the character beside it — which is what makes a caret look like it is drawn on top of a glyph.
pub fn snapX(x: f32) f32 {
    const k = deviceScale();
    return @round(x * k) / k;
}

// One device pixel, in content points: the width a caret should be so it covers whole pixels and nothing more.
pub fn hairline() f32 {
    return 1 / deviceScale();
}

// Record the button state and the press origin for this frame.
pub fn setPointerButton(down: bool, press_x: f32, press_y: f32) void {
    ptr_down = down;
    ptr_press_x = press_x;
    ptr_press_y = press_y;
}

// Record whether Shift is held, so the click a release dispatches knows it is an extension and not a plain click.
pub fn setPointerShift(shift: bool) void {
    ptr_shift = shift;
}

// True while a component owns the pointer's drag: the Host must not ALSO drag-scroll the pane under it.
var drag_claim = false;

// Start a frame's claim: a component that owns a drag says so again in the declare that follows.
pub fn beginDragFrame() void {
    drag_claim = false;
}

// Claim the pointer's drag for this frame: the split line, the sidebar handle, a row being reordered.
pub fn claimDrag() void {
    drag_claim = true;
}

// True when the frame that just declared claimed the drag.
pub fn dragClaimed() bool {
    return drag_claim;
}

test "the drag claim lasts one frame: reset at the start, honoured until the next" {
    beginDragFrame();
    try std.testing.expect(!dragClaimed());
    claimDrag();
    try std.testing.expect(dragClaimed());
    beginDragFrame();
    try std.testing.expect(!dragClaimed());
}

// Record the frame clock. `delta` is the time since the previous frame, in seconds.
pub fn setTime(now: f32, delta: f32) void {
    time_s = now;
    delta_s = delta;
}

// Last shape resolved by clayFrame (updated every frame, including headless tests).
pub var current_shape: u32 = shape_default;

pub fn currentShape() u32 {
    return current_shape;
}

// Change-only gate (pure, unit-tested): true when the shape differs from the last applied one.
pub fn shouldApplyShape(last: u32, next: u32) bool {
    return last != next;
}

// Engine-side memoized immediate: output-hash draw skipping.
fn hashF32(h: u64, v: f32) u64 {
    var x: u64 = h ^ @as(u64, @as(u32, @bitCast(v)));
    x *%= 0x100000001b3;
    return x;
}

fn hashBytes(h: u64, b: []const u8) u64 {
    var x = h;
    for (b) |bte| {
        x ^= bte;
        x *%= 0x100000001b3;
    }
    return x;
}

fn hashColor(h: u64, c: [4]f32) u64 {
    var x = h;
    x = hashF32(x, c[0]);
    x = hashF32(x, c[1]);
    x = hashF32(x, c[2]);
    x = hashF32(x, c[3]);
    return x;
}

// The element that owns the keyboard: an id the app declared, copied because app ids usually live in the frame arena.
var focus_buf: [96]u8 = undefined;
var focus_len: usize = 0;
var focus_known: bool = false;
var focus_cleared: bool = false;

// Give the keyboard to `id` (a field's id). Pass null to drop it.
pub fn setFocus(id: ?[]const u8) void {
    focus_known = true;
    if (id) |s| {
        focus_len = @min(s.len, focus_buf.len);
        @memcpy(focus_buf[0..focus_len], s[0..focus_len]);
    } else {
        focus_len = 0;
    }
}

// Forget who owns the keyboard: a new host or window starts with nothing focused.
pub fn resetFocus() void {
    focus_len = 0;
    focus_known = false;
    focus_cleared = false;
}

// Drop the keyboard, and remember that this frame a press landed somewhere else.
pub fn clearFocus() void {
    focus_known = true;
    focus_len = 0;
    focus_cleared = true;
}

// True once a click has claimed or dropped the keyboard, so a view knows the toolkit owns focus from then on.
pub fn focusKnown() bool {
    return focus_known;
}

// True on the frame a press landed outside the focused element.
pub fn focusWasCleared() bool {
    return focus_cleared;
}

// The id that owns the keyboard, or null when no field has claimed it.
pub fn focusedId() ?[]const u8 {
    if (focus_len == 0) return null;
    return focus_buf[0..focus_len];
}

// True when `id` is the element that owns the keyboard.
pub fn isFocused(id: []const u8) bool {
    return focus_len == id.len and std.mem.eql(u8, focus_buf[0..focus_len], id);
}

test "focus follows the toolkit: a click elsewhere drops it" {
    setFocus("sidebar.search");
    try std.testing.expect(isFocused("sidebar.search"));
    try std.testing.expect(!isFocused("results.filter"));
    try std.testing.expectEqualStrings("sidebar.search", focusedId().?);
    // A press outside the focused element clears it and says so for exactly that frame.
    clearFocus();
    try std.testing.expect(focusedId() == null);
    try std.testing.expect(focusWasCleared());
    try std.testing.expect(!isFocused("sidebar.search"));
    // A field claiming the keyboard again wins, and the "was cleared" note belongs to the frame it happened in.
    setFocus("results.filter");
    try std.testing.expect(isFocused("results.filter"));
    try std.testing.expect(focusKnown());
}

// Clay multiplies a wheel delta by 10 internally. The toolkit cancels it, so one point of gesture moves one point of content.
pub const wheel_factor: f32 = 10.0;

// True when this frame's render commands are identical to the previous frame's: nothing on screen changed, so there is nothing to present.
var commands_repeated: bool = false;
// How many commands the frame just drawn produced, so a diagnostic can tell "same drawing" from "more rows" at a glance.
var last_command_count: usize = 0;

// The number of render commands the frame just drawn produced.
pub fn lastCommandCount() usize {
    return last_command_count;
}
var last_commands_digest: u64 = 0;
var has_last_digest: bool = false;

// True when the frame just drawn is byte-identical to the one before it.
pub fn commandsRepeated() bool {
    return commands_repeated;
}

// Forget the previous frame's digest: a new host or a new window starts with nothing on screen to compare against.
pub fn resetCommandsDigest() void {
    commands_repeated = false;
    has_last_digest = false;
}

// FNV-1a over the command count and each command's type, id, box and payload: the identity of a frame's output.
pub fn hashCommands(commands: []cl.RenderCommand) u64 {
    var h: u64 = 0xcbf29ce484222325;
    h ^= @as(u64, @intCast(commands.len));
    h *%= 0x100000001b3;
    for (commands) |*cmd| {
        h ^= @as(u64, @intFromEnum(cmd.command_type));
        h *%= 0x100000001b3;
        h ^= @as(u64, @intCast(cmd.id));
        h *%= 0x100000001b3;
        h = hashF32(h, cmd.bounding_box.x);
        h = hashF32(h, cmd.bounding_box.y);
        h = hashF32(h, cmd.bounding_box.width);
        h = hashF32(h, cmd.bounding_box.height);
        switch (cmd.command_type) {
            .rectangle => {
                h = hashColor(h, cmd.render_data.rectangle.background_color);
            },
            .text => {
                const td = cmd.render_data.text;
                const bytes = td.string_contents.chars[0..@intCast(td.string_contents.length)];
                h = hashBytes(h, bytes);
                h ^= @as(u64, td.font_size);
                h *%= 0x100000001b3;
                h = hashColor(h, td.text_color);
            },
            .border => {
                const bd = cmd.render_data.border;
                h = hashColor(h, bd.color);
                h ^= @as(u64, bd.width.left);
                h *%= 0x100000001b3;
                h ^= @as(u64, bd.width.right);
                h *%= 0x100000001b3;
                h ^= @as(u64, bd.width.top);
                h *%= 0x100000001b3;
                h ^= @as(u64, bd.width.bottom);
                h *%= 0x100000001b3;
            },
            else => {},
        }
    }
    return h;
}

// Per-engine memo state.
pub const FrameMemo = struct {
    last_hash: ?u64 = null,
    draws: u64 = 0,
    skips: u64 = 0,

    // Returns true when the caller should issue the GLES draw, for a digest it already has: `hashCommands` is a full FNV-1a pass, and the frame computes that digest anyway.
    pub fn shouldDrawHash(self: *FrameMemo, digest: u64) bool {
        if (self.last_hash) |prev| {
            if (prev == digest) {
                self.skips += 1;
                return false;
            }
        }
        self.last_hash = digest;
        self.draws += 1;
        return true;
    }

    // The commands-shaped form, for a caller (or a test) that has no digest in hand; it is the same decision, one digest later.
    pub fn shouldDraw(self: *FrameMemo, commands: []cl.RenderCommand) bool {
        return self.shouldDrawHash(hashCommands(commands));
    }

    pub fn reset(self: *FrameMemo) void {
        self.last_hash = null;
        self.draws = 0;
        self.skips = 0;
    }
};

// Engine-owned memo (single-window app).
pub var memo_enabled: bool = false;
var memo: FrameMemo = .{};

// Declare callback: app builds its Clay tree here (views.zig declareRoot).
pub const DeclareFn = *const fn (ctx: *anyopaque, w: u32, h: u32) void;

fn clayMeasure(text_bytes: []const u8, config: *cl.TextElementConfig, _: void) cl.Dimensions {
    const ext = text.measureText(text_bytes, config.font_size);
    return .{ .w = ext.w, .h = ext.h };
}

// Receives a duplicate element id instead of the default panic. A test installs one to assert the detection without dying; an app must leave it null.
pub var duplicate_id_sink: ?*const fn (msg: []const u8) void = null;

// The most elements one frame may declare; 0 keeps Clay's own default (8192). Set it BEFORE `Host.init`, which sizes the arena from it — memory grows linearly.
pub var max_elements: usize = 0;

// Receives a capacity overflow instead of the default panic. A test installs one to assert it; an app must leave it null.
pub var capacity_error_sink: ?*const fn (msg: []const u8) void = null;

// The two facts Clay keeps to itself (see the accessors appended to the generated clay.c in build.zig): how many elements the last frame ended up with, and whether it dropped the tail.
extern fn glin_clay_elements_exceeded() bool;
extern fn glin_clay_element_count() i32;

// True when the last frame was truncated by the element ceiling.
pub fn elementCeilingExceeded() bool {
    return glin_clay_elements_exceeded();
}

// The elements the last frame actually opened, root included.
pub fn lastElementCount() i32 {
    return glin_clay_element_count();
}

// A frame that declared more elements than the ceiling renders a PARTIAL tree and nothing else says so: Clay sets a flag, drops the rest and keeps going.
pub fn checkElementCeiling() void {
    if (!elementCeilingExceeded()) return;
    const msg = "a frame declared more elements than Clay's ceiling, so the rest of the tree was dropped: raise `frame.max_elements` before Host.init, or virtualise the list";
    if (capacity_error_sink) |sink| {
        sink(msg);
        return;
    }
    if (builtin.mode == .Debug) std.debug.panic("glinlandui: {s}", .{msg});
    if (!capacity_warned) {
        capacity_warned = true;
        std.log.err("glinlandui: {s}", .{msg});
    }
}

// A Release build logs a permanent overflow once, not sixty times a second.
var capacity_warned: bool = false;

// Past this many declared elements a frame warns once: README.md's cost model is linear in what an app DECLARES, so a tree that doubled is a regression the engine can name. 0 turns it off.
pub var warn_past_elements: usize = 4000;

var budget_warned: bool = false;

/// Say so, once per host, when a frame declares more elements than the documented budget: the app that got slower is cheaper to find at the frame that crossed it than in a profiler.
pub fn checkFrameBudget() void {
    if (warn_past_elements == 0 or budget_warned) return;
    const declared: usize = @intCast(@max(0, lastElementCount()));
    if (declared <= warn_past_elements) return;
    budget_warned = true;
    log.warn("this frame declared {d} elements, past the {d} the cost model assumes: frame cost is linear in declared elements, so virtualise the list (examples/lazy_scroll) or raise frame.max_elements deliberately", .{ declared, warn_past_elements });
}

// One slot of the per-frame id set: the key, plus the frame generation that wrote it, so a new frame invalidates the whole table by counting.
const IdSlot = struct { key: u64 = 0, gen: u32 = 0 };

// Sized from Clay's own element ceiling in `prepareIdSet`: the set used to be a fixed 4096 slots and went blind, silently, one id past it.
var id_slots: []IdSlot = &.{};
var id_slot_mask: u64 = 0;
var id_slot_alloc: ?std.mem.Allocator = null;
var id_gen: u32 = 1;

// Keys already reported in a release build, so a duplicate that survives every frame is logged once, not 60 times a second.
var id_warned: [256]u64 = [_]u64{0} ** 256;
var id_warned_n: usize = 0;

fn idKey(id: cl.ElementId) u64 {
    const h = (@as(u64, id.id) << 32) | @as(u64, id.offset);
    // 0 marks an empty slot, so a real key must never be 0.
    return if (h == 0) 1 else h;
}

/// Size the duplicate-id set for a frame that may claim `elements` ids: a power of two above that ceiling, allocated from `alloc` and replaced on every call.
pub fn prepareIdSet(alloc: std.mem.Allocator, elements: usize) !void {
    deinitIdSet();
    var cap: usize = 16;
    while (cap <= elements) cap <<= 1;
    const slots = try alloc.alloc(IdSlot, cap);
    @memset(slots, .{});
    id_slots = slots;
    id_slot_mask = cap - 1;
    id_slot_alloc = alloc;
    id_gen = 1;
}

/// Hand the id set back to the allocator that sized it: safe when there is none, and safe twice.
pub fn deinitIdSet() void {
    if (id_slot_alloc) |alloc| {
        if (id_slots.len > 0) alloc.free(id_slots);
    }
    id_slots = &.{};
    id_slot_mask = 0;
    id_slot_alloc = null;
    id_gen = 1;
}

// Start a new frame's id set: a generation bump, not a memset of the table, which cost 32 KiB on every frame and scaled with nothing.
fn resetIds() void {
    id_gen +%= 1;
    if (id_gen == 0) {
        // The counter wrapped, so no slot can be blamed on this frame: start the table over rather than trust a stale generation.
        @memset(id_slots, .{});
        id_gen = 1;
    }
}

// Insert `key`; true when it was already there. A slot from an older generation is empty, which is what makes the frame reset O(1).
fn idSeenBefore(key: u64) bool {
    if (id_slots.len == 0) return false;
    var i: usize = @intCast(key & id_slot_mask);
    var probes: usize = 0;
    while (probes < id_slots.len) : (probes += 1) {
        const slot = &id_slots[i];
        if (slot.gen != id_gen) {
            slot.* = .{ .key = key, .gen = id_gen };
            return false;
        }
        if (slot.key == key) return true;
        i = (i + 1) & @as(usize, @intCast(id_slot_mask));
    }
    return false;
}

// Called for every element that declares an id, through `zclay.on_element`: the one place a duplicate can be NAMED.
pub fn claimId(id: cl.ElementId) void {
    const key = idKey(id);
    if (!idSeenBefore(key)) return;

    const len: usize = if (id.string_id.length > 0) @intCast(id.string_id.length) else 0;
    const name: []const u8 = if (len > 0) id.string_id.chars[0..len] else "<no name>";
    // The element's box from the previous frame, when it has one: a name is good, a place on screen is better.
    const prev = cl.getElementData(id);
    var buf: [192]u8 = undefined;
    const msg = if (prev.found)
        std.fmt.bufPrint(&buf, "\"{s}\" (offset {d}) at {d:.0},{d:.0} {d:.0}x{d:.0}", .{
            name, id.offset, prev.bounding_box.x, prev.bounding_box.y, prev.bounding_box.width, prev.bounding_box.height,
        }) catch name
    else
        std.fmt.bufPrint(&buf, "\"{s}\" (offset {d})", .{ name, id.offset }) catch name;

    if (duplicate_id_sink) |sink| {
        sink(msg);
        return;
    }
    if (builtin.mode == .Debug) {
        std.debug.panic("glinlandui: duplicate element id {s}: declared twice in one frame", .{msg});
    }
    for (id_warned[0..id_warned_n]) |k| {
        if (k == key) return;
    }
    if (id_warned_n < id_warned.len) {
        id_warned[id_warned_n] = key;
        id_warned_n += 1;
    }
    std.log.err("glinlandui: duplicate element id {s}: two elements share it, so a click, hover or cursor lookup can land on the other one", .{msg});
}

var dup_hits: usize = 0;

fn countDup(_: []const u8) void {
    dup_hits += 1;
}

test "the duplicate check still names a duplicate past 4096 unique ids" {
    // 4096 was a compilation constant, so the frame that declared the 4097th id lost the check and passed green; 5000 plus one repeat is that frame.

    // The shared headless canvas, not one of this test's own: Clay keeps a global context pointer, and a test that frees its arena leaves later tests reading freed memory.
    const headless = @import("testing/headless.zig");
    headless.begin(.{ .x = 99999, .y = 99999 }, false);
    try prepareIdSet(std.testing.allocator, @intCast(@max(1, cl.getMaxElementCount())));
    defer deinitIdSet();
    cl.on_element = claimId;
    cl.on_begin_frame = resetIds;
    defer {
        cl.on_element = null;
        cl.on_begin_frame = null;
    }
    duplicate_id_sink = countDup;
    defer duplicate_id_sink = null;
    dup_hits = 0;

    cl.beginLayout();
    var i: u32 = 0;
    while (i < 5000) : (i += 1) cl.UI()(.{ .id = .IDI("id-set-cap", i + 1) })({});
    // The repeat has to be an id declared PAST the old cap: one of the first 4096 was still in the full table, so it was caught even then.
    cl.UI()(.{ .id = .IDI("id-set-cap", 4800) })({});
    _ = cl.endLayout();

    try std.testing.expectEqual(@as(usize, 1), dup_hits);
}

var capacity_hits: usize = 0;

fn countCapacity(_: []const u8) void {
    capacity_hits += 1;
}

test "the element ceiling is a knob, and a frame under it stays whole" {
    // 9000 elements is past Clay's 8192 default: the frame that used to render a partial tree now fits, because the arena was measured for the raised count.
    const headless = @import("testing/headless.zig");
    const ceiling_before = cl.getMaxElementCount();
    max_elements = 12_000;
    defer max_elements = 0;
    capacity_error_sink = countCapacity;
    defer capacity_error_sink = null;
    const canvas = try initClay(std.testing.allocator, 720, 480);
    defer std.testing.allocator.free(canvas);
    defer deinitIdSet();
    // The restore runs FIRST among the defers, before the arena goes: `Clay_Initialize` reads the context it replaces, so it cannot be reading freed memory.
    defer {
        cl.on_element = null;
        cl.on_begin_frame = null;
        cl.setMaxElementCount(ceiling_before);
        headless.begin(.{ .x = 99999, .y = 99999 }, false);
    }
    capacity_hits = 0;
    try std.testing.expectEqual(@as(i32, 12_000), cl.getMaxElementCount());

    cl.beginLayout();
    var i: u32 = 0;
    while (i < 9000) : (i += 1) cl.UI()(.{ .id = .IDI("ceiling-knob", i + 1) })({});
    _ = cl.endLayout();

    try std.testing.expect(!elementCeilingExceeded());
    try std.testing.expectEqual(@as(usize, 0), capacity_hits);
}

test "a frame past the element ceiling is loud instead of half-drawn" {
    // At the default 8192 a 8200-element frame is the case the issue calls a silently truncated screen: one log line, no failure, most of the UI missing.
    const headless = @import("testing/headless.zig");
    const ceiling_before = cl.getMaxElementCount();
    capacity_error_sink = countCapacity;
    defer capacity_error_sink = null;
    const canvas = try initClay(std.testing.allocator, 720, 480);
    defer std.testing.allocator.free(canvas);
    defer deinitIdSet();
    // The restore runs FIRST among the defers, before the arena goes: `Clay_Initialize` reads the context it replaces, so it cannot be reading freed memory.
    defer {
        cl.on_element = null;
        cl.on_begin_frame = null;
        cl.setMaxElementCount(ceiling_before);
        headless.begin(.{ .x = 99999, .y = 99999 }, false);
    }
    capacity_hits = 0;
    try std.testing.expect(ceiling_before >= 1);

    cl.beginLayout();
    var i: u32 = 0;
    while (i <= @as(u32, @intCast(ceiling_before)) + 7) : (i += 1) cl.UI()(.{ .id = .IDI("ceiling-over", i + 1) })({});
    _ = cl.endLayout();

    try std.testing.expect(elementCeilingExceeded());
    try std.testing.expect(lastElementCount() <= ceiling_before);
    checkElementCeiling();
    try std.testing.expectEqual(@as(usize, 1), capacity_hits);
}

fn clayErrorHandler(err: cl.ErrorData) callconv(.c) void {
    const msg = err.error_text.chars[0..@intCast(err.error_text.length)];
    // Clay's duplicate message never names the id and `claimId` already reports it, so this would only add a nameless line.
    if (err.error_type == .duplicate_id) return;
    // A frame past the element ceiling renders a PARTIAL tree: to a user that is a half-drawn screen, and to a test that reads anything but the command count it is nothing at all.
    if (err.error_type == .elements_capacity_exceeded) {
        if (capacity_error_sink) |sink| {
            sink(msg);
            return;
        }
        if (builtin.mode == .Debug) std.debug.panic("glinlandui: {s}", .{msg});
    }
    std.log.err("clay {s}: {s}", .{ @tagName(err.error_type), msg });
}

// Init the Clay arena for a w x h window.
pub fn initClay(alloc: std.mem.Allocator, w: u32, h: u32) ![]u8 {
    // Clay sizes every per-element array from its own ceiling and `minMemorySize()` answers for whatever is in force, so the knob has to be applied FIRST.
    if (max_elements > 0) cl.setMaxElementCount(@intCast(max_elements));
    const clay_mem_size = cl.minMemorySize();
    const clay_mem = try alloc.alloc(u8, clay_mem_size);
    errdefer alloc.free(clay_mem);
    const arena = cl.Arena.init(clay_mem);
    _ = cl.initialize(arena, .{ .w = @floatFromInt(w), .h = @floatFromInt(h) }, .{ .error_handler_function = clayErrorHandler });
    cl.setMeasureTextFunction(void, {}, clayMeasure);
    // Clay's element ceiling is the most ids a single frame can claim, so a set sized from it cannot go blind the way the fixed 4096 did.
    try prepareIdSet(alloc, @intCast(@max(1, cl.getMaxElementCount())));
    // Every identified element passes through this hook, so a duplicate is caught and named where it happens.
    cl.on_element = claimId;
    cl.on_begin_frame = resetIds;
    capacity_warned = false;
    budget_warned = false;
    memo.reset();
    return clay_mem;
}

// Per-frame text measurement override used by headless tests.
pub const MeasureFn = *const fn (
    text: []const u8,
    config: *cl.TextElementConfig,
    user_data: ?*anyopaque,
) cl.Dimensions;

// Called synchronously after Clay finishes layout and before rendering.
pub const FrameProbeFn = *const fn (
    user_data: ?*anyopaque,
    commands: []const cl.RenderCommand,
    width: u32,
    height: u32,
) void;

// Optional seams used by the reusable headless testing module.
pub const FrameOptions = struct {
    measure: ?MeasureFn = null,
    measure_user_data: ?*anyopaque = null,
    probe: ?FrameProbeFn = null,
    probe_user_data: ?*anyopaque = null,
    // Resolve the semantics tree (core/semantics.zig) immediately after layout, once Clay has computed every bounding box.
    resolve_semantics: bool = false,
    // Skip the renderer entirely: a headless CLI has no window to present to, and a shipping binary is not under `is_test`.
    no_present: bool = false,
};

const default_frame_options: FrameOptions = .{};

fn measureWithOptions(
    text_bytes: []const u8,
    config: *cl.TextElementConfig,
    options: *const FrameOptions,
) cl.Dimensions {
    return options.measure.?(text_bytes, config, options.measure_user_data);
}

fn invokeProbe(
    options: *const FrameOptions,
    commands: []const cl.RenderCommand,
    w: u32,
    h: u32,
) void {
    if (options.probe) |probe| {
        probe(options.probe_user_data, commands, w, h);
    }
}

// One Clay frame: sync pointer + layout dims, begin, run the app's declare callback, end, then draw (lazy renderer init, clear-only fallback on.
pub fn clayFrame(
    alloc: std.mem.Allocator,
    renderer: *?render.Renderer,
    renderer_attempted: *bool,
    pointer_x: f32,
    pointer_y: f32,
    pointer_down: bool,
    wheel_dx: f32,
    wheel_dy: f32,
    w: u32,
    h: u32,
    declare: DeclareFn,
    ctx: *anyopaque,
) u32 {
    return clayFrameWithOptions(
        alloc,
        renderer,
        renderer_attempted,
        pointer_x,
        pointer_y,
        pointer_down,
        wheel_dx,
        wheel_dy,
        w,
        h,
        declare,
        ctx,
        &default_frame_options,
    );
}

// Every length Clay emitted is in content points, and a zoomed frame paints them at `zoom` more window points.
fn scaleCommands(commands: []cl.RenderCommand, z: f32) void {
    if (z == 1) return;
    for (commands) |*cmd| {
        cmd.bounding_box.x *= z;
        cmd.bounding_box.y *= z;
        cmd.bounding_box.width *= z;
        cmd.bounding_box.height *= z;
        switch (cmd.command_type) {
            .text => {
                const t = &cmd.render_data.text;
                t.font_size = scaleWhole(t.font_size, z);
                t.line_height = scaleWhole(t.line_height, z);
                t.letter_spacing = scaleWhole(t.letter_spacing, z);
            },
            .rectangle => scaleRadius(&cmd.render_data.rectangle.corner_radius, z),
            .border => {
                scaleRadius(&cmd.render_data.border.corner_radius, z);
                const w = &cmd.render_data.border.width;
                w.left = scaleSide(w.left, z);
                w.right = scaleSide(w.right, z);
                w.top = scaleSide(w.top, z);
                w.bottom = scaleSide(w.bottom, z);
            },
            else => {},
        }
    }
}

// A font size or a line height: whole points, never zero.
fn scaleWhole(v: u16, z: f32) u16 {
    if (v == 0) return 0;
    const scaled = @as(f32, @floatFromInt(v)) * z;
    return @intFromFloat(@max(1, @round(scaled)));
}

// A border side keeps at least one point: a 1 pt rule at 50% must still be a line.
fn scaleSide(v: u16, z: f32) u16 {
    if (v == 0) return 0;
    const scaled = @as(f32, @floatFromInt(v)) * z;
    return @intFromFloat(@max(1, @round(scaled)));
}

fn scaleRadius(r: *cl.CornerRadius, z: f32) void {
    r.top_left *= z;
    r.top_right *= z;
    r.bottom_left *= z;
    r.bottom_right *= z;
}

// True when the last frame's wheel delta moved a scroll container: a glide over a list at its end must not ask for frames that change nothing.
var wheel_moved: bool = false;

/// Whether this frame's wheel delta found a container with room to move.
pub fn wheelMoved() bool {
    return wheel_moved;
}

// The wheel moves the deepest scroll container under the pointer, and once that one is at its end the same gesture keeps moving the page behind it.
fn applyWheel(dx: f32, dy: f32) void {
    wheel_moved = false;
    var ids: [8]cl.ElementId = undefined;
    var before: [8]cl.Vector2 = undefined;
    var n: usize = 0;
    if (dx != 0 or dy != 0) {
        for (cl.getPointerOverIds()) |id| {
            if (n >= ids.len) break;
            const data = cl.getScrollContainerData(id);
            if (!data.found) continue;
            ids[n] = id;
            before[n] = data.scroll_position.*;
            n += 1;
        }
    }
    // Clay's built-in drag stays OFF (touch-style, inverted for a slider), and its wheel delta is divided by its own 10x factor: 1 point of gesture, 1 point of content.
    cl.updateScrollContainers(false, .{ .x = -dx / wheel_factor, .y = -dy / wheel_factor }, 1.0 / 60.0);
    if (n == 0) return;
    // A container that moved is this gesture's answer, and nothing chains off it.
    for (ids[0..n], 0..) |id, i| {
        const data = cl.getScrollContainerData(id);
        if (!data.found) continue;
        if (data.scroll_position.x != before[i].x or data.scroll_position.y != before[i].y) {
            wheel_moved = true;
            return;
        }
    }
    // Nothing moved: the container the gesture reached is at its end, so the outermost one under the pointer takes the rest.
    var page: ?cl.ScrollContainerData = null;
    var page_area: f32 = 0;
    for (ids[0..n]) |id| {
        const data = cl.getScrollContainerData(id);
        if (!data.found or !wheelRoom(data, dx, dy)) continue;
        const area = data.scroll_container_dimensions.w * data.scroll_container_dimensions.h;
        if (area <= page_area) continue;
        page_area = area;
        page = data;
    }
    if (page) |data| {
        wheel_moved = true;
        wheelNudge(data, dx, dy);
    }
}

// Whether a container still has room in the direction the gesture is going.
fn wheelRoom(data: cl.ScrollContainerData, dx: f32, dy: f32) bool {
    const max_x = @max(0, data.content_dimensions.w - data.scroll_container_dimensions.w);
    const max_y = @max(0, data.content_dimensions.h - data.scroll_container_dimensions.h);
    if (dy > 0 and data.scroll_position.y > -max_y) return true;
    if (dy < 0 and data.scroll_position.y < 0) return true;
    if (dx > 0 and data.scroll_position.x > -max_x) return true;
    if (dx < 0 and data.scroll_position.x < 0) return true;
    return false;
}

// The one point of gesture, applied to a container Clay did not pick: positive dy is content up, as the backends report it.
fn wheelNudge(data: cl.ScrollContainerData, dx: f32, dy: f32) void {
    const max_x = @max(0, data.content_dimensions.w - data.scroll_container_dimensions.w);
    const max_y = @max(0, data.content_dimensions.h - data.scroll_container_dimensions.h);
    data.scroll_position.x = std.math.clamp(data.scroll_position.x - dx, -max_x, 0);
    data.scroll_position.y = std.math.clamp(data.scroll_position.y - dy, -max_y, 0);
}

// A frame a screen asked for outside an input event — a route change, a timer, a finished job.
var repaint_requested: bool = false;

/// Ask the backend for one more frame: a screen that changed with no event to carry it must not wait for the next click.
pub fn requestFrame() void {
    repaint_requested = true;
}

/// One-shot, drained by a backend loop before it decides to idle.
pub fn takeRepaintRequest() bool {
    const pending = repaint_requested;
    repaint_requested = false;
    return pending;
}

// Frame variant with injectable measurement and a synchronous command probe.
pub fn clayFrameWithOptions(
    alloc: std.mem.Allocator,
    renderer: *?render.Renderer,
    renderer_attempted: *bool,
    pointer_x: f32,
    pointer_y: f32,
    pointer_down: bool,
    wheel_dx: f32,
    wheel_dy: f32,
    w: u32,
    h: u32,
    declare: DeclareFn,
    ctx: *anyopaque,
    options: *const FrameOptions,
) u32 {
    cl.setPointerState(.{ .x = pointer_x, .y = pointer_y }, pointer_down);
    // The delta stays readable for the whole declare: a component that scrolls on its own axis cannot get it from Clay.
    scroll_dx = wheel_dx;
    scroll_dy = wheel_dy;
    applyWheel(wheel_dx, wheel_dy);
    // A zoomed window shows fewer content points: the layout is computed for the smaller box the app declares in.
    const lw = contentWidth(w);
    const lh = contentHeight(h);
    viewport_now = viewportOf(w, h);
    cl.setLayoutDimensions(.{ .w = @floatFromInt(lw), .h = @floatFromInt(lh) });
    if (options.measure) |_| {
        cl.setMeasureTextFunction(*const FrameOptions, options, measureWithOptions);
    } else {
        cl.setMeasureTextFunction(void, {}, clayMeasure);
    }
    cl.beginLayout();
    // The frame's scratch strings and the caret-blink schedule are released here, so an app never has to remember either.
    text_used = 0;
    focus_cleared = false;
    text_editor.beginBlinkFrame();
    declare(ctx, lw, lh);
    const commands = cl.endLayout();
    // Before the truncated commands are used for anything: this is the only place a frame that overflowed the element ceiling becomes visible.
    checkElementCeiling();

    checkFrameBudget();
    // What the app declared is the truth; the window paints it at the zoom in force.
    scaleCommands(@constCast(commands), content_zoom);
    // A frame that draws exactly what the last one did does not need presenting: the window already shows those pixels.
    last_command_count = commands.len;
    const digest = hashCommands(@constCast(commands));
    commands_repeated = has_last_digest and digest == last_commands_digest;
    last_commands_digest = digest;
    has_last_digest = true;
    // The audit runs on the frames a developer actually sees, not only in tests: the caret, hairline and hit-target failures it catches are invisible to a

    // unit test and obvious here.
    if (audit.enabled) _ = audit.frame(commands, pixel_scale);
    // Semantics resolve AFTER layout (that is when Clay has bounding boxes) and BEFORE the probe, so a probe that inspects the tree sees resolved geometry.
    if (options.resolve_semantics) {
        // Semantics are about the tree the app declared, which is in content points.
        semantics.resolve(@floatFromInt(lw), @floatFromInt(lh));
    }
    invokeProbe(options, commands, lw, lh);
    // Registries are populated by declare above — resolve the cursor now.
    const shape = hoverCursorShape(pointer_x, pointer_y);
    current_shape = shape;
    // Headless tests and a headless CLI: layout ran (element data populated), renderer pruned (no GL context) — callback wiring stays testable.
    if (builtin.is_test or options.no_present) return shape;
    if (!renderer_attempted.*) {
        renderer_attempted.* = true;
        renderer.* = render.Renderer.init(alloc) catch |err| blk: {
            log.warn("renderer init failed ({s}); running clear-only", .{@errorName(err)});
            break :blk null;
        };
    }
    if (renderer.*) |*r| {
        if (memo_enabled) {
            // The digest above, not a second pass: it is already the identity of exactly these commands.
            if (memo.shouldDrawHash(digest)) {
                r.drawCommands(commands, @intCast(w), @intCast(h));
            }
        } else {
            r.drawCommands(commands, @intCast(w), @intCast(h));
        }
    }
    return shape;
}

fn testRectCmd(x: f32, y: f32, w: f32, h: f32, color: [4]f32) cl.RenderCommand {
    return .{
        .bounding_box = .{ .x = x, .y = y, .width = w, .height = h },
        .render_data = .{ .rectangle = .{ .background_color = color, .corner_radius = .{} } },
        .user_data = null,
        .id = 1,
        .z_index = 0,
        .command_type = .rectangle,
    };
}

test "scaleCommands paints every length at the zoom in force" {
    const scenes = @import("golden_scenes.zig");
    var cmds = [_]cl.RenderCommand{
        testRectCmd(10, 20, 100, 40, .{ 9, 9, 9, 255 }),
        scenes.textCmd(0, 0, 100, 20, "hi", 14, .{ 255, 255, 255, 255 }),
        scenes.sideBorder(0, 0, 100, 40, .{ .left = 2 }, .{ 255, 255, 255, 255 }),
    };
    scaleCommands(&cmds, 2.0);
    try std.testing.expectEqual(@as(f32, 20), cmds[0].bounding_box.x);
    try std.testing.expectEqual(@as(f32, 40), cmds[0].bounding_box.y);
    try std.testing.expectEqual(@as(f32, 200), cmds[0].bounding_box.width);
    try std.testing.expectEqual(@as(f32, 80), cmds[0].bounding_box.height);
    // A run doubles its font size, so the glyphs the layout reserved room for are the glyphs that are painted.
    try std.testing.expectEqual(@as(u16, 28), cmds[1].render_data.text.font_size);
    // A one-sided border stays one-sided, and its width doubles with everything else.
    try std.testing.expectEqual(@as(u16, 4), cmds[2].render_data.border.width.left);
    try std.testing.expectEqual(@as(u16, 0), cmds[2].render_data.border.width.top);
}

test "a zoomed window holds fewer content points, and the ladder clamps" {
    setZoom(2.0);
    defer setZoom(1.0);
    try std.testing.expectEqual(@as(u32, 360), contentWidth(720));
    try std.testing.expectEqual(@as(u32, 240), contentHeight(480));
    // The same correction in one value: a widget reads content points and never divides by the zoom itself.
    try std.testing.expectEqual(Viewport{ .w = 360, .h = 240 }, viewportOf(720, 480));
    // Never zero, whatever the rounding says: a layout of no points is not a layout.
    setZoom(3.0);
    try std.testing.expectEqual(@as(u32, 1), contentWidth(1));
    // A factor off the ladder snaps onto it instead of collapsing the window.
    setZoom(9.0);
    try std.testing.expectEqual(@as(f32, 3.0), zoom());
    setZoom(0);
    try std.testing.expectEqual(@as(f32, 1.0), zoom());
}

test "a repaint request is answered once, so a loop that idles stays idle" {
    _ = takeRepaintRequest();
    try std.testing.expect(!takeRepaintRequest());
    requestFrame();
    try std.testing.expect(takeRepaintRequest());
    try std.testing.expect(!takeRepaintRequest());
    // Two changes before the loop wakes are still one frame: the second request is the same request.
    requestFrame();
    requestFrame();
    try std.testing.expect(takeRepaintRequest());
    try std.testing.expect(!takeRepaintRequest());
}

test "the viewport a frame reports is the box it was last given, and zero before any frame" {
    setZoom(1.0);
    setViewport(.{});
    try std.testing.expectEqual(Viewport{ .w = 0, .h = 0 }, viewport());
    setViewport(viewportOf(1280, 840));
    try std.testing.expectEqual(Viewport{ .w = 1280, .h = 840 }, viewport());
    setZoom(1.5);
    defer setZoom(1.0);
    setViewport(viewportOf(1280, 840));
    // 1280 / 1.5 = 853.3 points, so a window at 150% has 853 points to declare in.
    try std.testing.expectEqual(@as(f32, 853), viewport().w);
    try std.testing.expectEqual(@as(f32, 560), viewport().h);
}

test "hashCommands is stable for identical output" {
    var cmds = [_]cl.RenderCommand{
        testRectCmd(0, 0, 200, 480, .{ 17, 17, 17, 255 }),
        testRectCmd(0, 60, 200, 40, .{ 38, 38, 38, 255 }),
    };
    try std.testing.expectEqual(hashCommands(&cmds), hashCommands(&cmds));
}

test "hashCommands changes when a rect moves or recolors" {
    var a = [_]cl.RenderCommand{testRectCmd(0, 60, 200, 40, .{ 38, 38, 38, 255 })};
    var moved = [_]cl.RenderCommand{testRectCmd(0, 100, 200, 40, .{ 38, 38, 38, 255 })};
    var recolored = [_]cl.RenderCommand{testRectCmd(0, 60, 200, 40, .{ 99, 99, 99, 255 })};
    try std.testing.expect(hashCommands(&a) != hashCommands(&moved));
    try std.testing.expect(hashCommands(&a) != hashCommands(&recolored));
}

test "FrameMemo draws first frame, skips identical repeat" {
    var m = FrameMemo{};
    var cmds = [_]cl.RenderCommand{testRectCmd(0, 0, 720, 480, .{ 17, 17, 17, 255 })};
    try std.testing.expect(m.shouldDraw(&cmds));
    try std.testing.expect(!m.shouldDraw(&cmds));
    try std.testing.expectEqual(@as(u64, 1), m.draws);
    try std.testing.expectEqual(@as(u64, 1), m.skips);
    var changed = [_]cl.RenderCommand{testRectCmd(0, 0, 720, 480, .{ 18, 18, 18, 255 })};
    try std.testing.expect(m.shouldDraw(&changed));
    try std.testing.expectEqual(@as(u64, 2), m.draws);
}

fn declareCullRow(i: u32) void {
    cl.UI()(.{ .id = .IDI("cull-row", i + 1), .layout = .{ .sizing = .{ .h = .fixed(60) } }, .background_color = .{ 30, 30, 30, 255 } })({});
}

fn declareCullColumn() void {
    // One column, so the rows are STACKED: elements declared at the root are separate trees and all start at the origin, where nothing is off screen.
    cl.UI()(.{ .id = .ID("cull-column"), .layout = .{ .direction = .top_to_bottom, .sizing = .{ .w = .grow, .h = .fit } } })({
        var i: u32 = 0;
        while (i < 40) : (i += 1) declareCullRow(i);
    });
}

test "an off-screen background costs no render command, and culling off brings every one back" {
    const headless = @import("testing/headless.zig");
    // 40 rows of 60 pt in a 480 pt viewport: eight are visible, so the other 32 must not reach the renderer — or the digest, which hashes every command.
    headless.begin(.{ .x = 99999, .y = 99999 }, false);
    cl.beginLayout();
    declareCullColumn();
    const culled = cl.endLayout();
    try std.testing.expectEqual(@as(usize, 9), culled.len);

    // Culling disabled is the escape hatch for an app doing its own scrolling; then every row must come back.
    headless.begin(.{ .x = 99999, .y = 99999 }, false);
    cl.setCullingEnabled(false);
    defer cl.setCullingEnabled(true);
    cl.beginLayout();
    declareCullColumn();
    const all = cl.endLayout();
    try std.testing.expectEqual(@as(usize, 40), all.len);
}

var budget_warnings: usize = 0;

fn countWarn(_: log.Level, _: []const u8) void {
    budget_warnings += 1;
}

test "a frame past the declared-element budget warns once, and only once" {
    const headless = @import("testing/headless.zig");
    const budget_before = warn_past_elements;
    warn_past_elements = 4;
    defer warn_past_elements = budget_before;
    budget_warnings = 0;
    log.setSink(countWarn);
    defer log.resetSink();

    var round: usize = 0;
    while (round < 2) : (round += 1) {
        headless.begin(.{ .x = 99999, .y = 99999 }, false);
        cl.beginLayout();
        var i: u32 = 0;
        while (i < 10) : (i += 1) cl.UI()(.{ .id = .IDI("budget-row", i + 1) })({});
        _ = cl.endLayout();
        checkFrameBudget();
    }

    // Ten declared elements against a budget of four, on two frames: the app hears it once, not sixty times a second.
    try std.testing.expectEqual(@as(usize, 1), budget_warnings);
}

test "shouldDrawHash answers exactly as shouldDraw does, on the digest the frame already computed" {
    // The frame hashes once for `commandsRepeated` and hands that digest to the memo; `shouldDraw` would hash the same commands a second time.
    var by_commands = FrameMemo{};
    var by_digest = FrameMemo{};
    var cmds = [_]cl.RenderCommand{testRectCmd(0, 0, 720, 480, .{ 17, 17, 17, 255 })};
    const digest = hashCommands(&cmds);
    try std.testing.expectEqual(by_commands.shouldDraw(&cmds), by_digest.shouldDrawHash(digest));
    try std.testing.expectEqual(by_commands.shouldDraw(&cmds), by_digest.shouldDrawHash(digest));
    var changed = [_]cl.RenderCommand{testRectCmd(0, 0, 720, 480, .{ 18, 18, 18, 255 })};
    try std.testing.expectEqual(by_commands.shouldDraw(&changed), by_digest.shouldDrawHash(hashCommands(&changed)));
    try std.testing.expectEqual(by_commands.draws, by_digest.draws);
    try std.testing.expectEqual(by_commands.skips, by_digest.skips);
}

test "cursorShapeFromCursor maps Cursor enum to protocol shapes" {
    // Contract: .default -> 1, .pointer -> 4, .text -> 9, .ew_resize -> 26 (cursor-shape-v1.xml shape enum; wayland.zig asserts these against the generated.
    try std.testing.expectEqual(shape_default, cursorShapeFromCursor(.default));
    try std.testing.expectEqual(shape_pointer, cursorShapeFromCursor(.pointer));
    try std.testing.expectEqual(shape_text, cursorShapeFromCursor(.text));
    try std.testing.expectEqual(shape_ew_resize, cursorShapeFromCursor(.ew_resize));
    try std.testing.expectEqual(@as(u32, 1), cursorShapeFromCursor(.default));
    try std.testing.expectEqual(@as(u32, 4), cursorShapeFromCursor(.pointer));
    try std.testing.expectEqual(@as(u32, 9), cursorShapeFromCursor(.text));
    try std.testing.expectEqual(@as(u32, 26), cursorShapeFromCursor(.ew_resize));
}

test "shouldApplyShape gates change-only set_shape" {
    try std.testing.expect(shouldApplyShape(shape_sentinel, shape_default));
    try std.testing.expect(!shouldApplyShape(shape_default, shape_default));
    try std.testing.expect(shouldApplyShape(shape_default, shape_pointer));
    try std.testing.expect(!shouldApplyShape(shape_pointer, shape_pointer));
}

test "hoverCursorShape falls back to default without registry Cursor" {
    // Registry crew hasn't landed hoverCursorAt yet -> @hasDecl false -> default shape.
    if (!@hasDecl(click_registry, "hoverCursorAt")) {
        try std.testing.expectEqual(shape_default, hoverCursorShape(10, 20));
        try std.testing.expectEqual(shape_default, hoverCursorShape(0, 0));
    } else {
        // Registry landed: empty frame still resolves a valid shape.
        const s = hoverCursorShape(10, 20);
        try std.testing.expect(s == shape_default or s == shape_pointer or s == shape_text or s == shape_ew_resize);
    }
}
