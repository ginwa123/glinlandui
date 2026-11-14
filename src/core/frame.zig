// Agnostic Clay frame helper: owns the per-frame + init boilerplate every Clay app repeats (measure/error wiring, arena init, pointer + layout sync.
const std = @import("std");
const log = @import("log.zig");
const audit = @import("audit.zig");
const builtin = @import("builtin");
const cl = @import("zclay");
const render = @import("render.zig");
const text = @import("text_backend.zig");
const click_registry = @import("components/click_registry.zig");
const semantics = @import("semantics.zig");

// ---- Wayland cursor-shape (wp_cursor_shape_manager_v1) ---- Contract (registry crew owns components/click_registry.zig).
pub const Cursor = enum { default, pointer, text, ew_resize };

pub const shape_default: u32 = 1;
pub const shape_pointer: u32 = 4;
pub const shape_text: u32 = 9;
pub const shape_ew_resize: u32 = 26;
// Sentinel for Window.last_shape: 0 is not a valid shape (valid range starts at 1), so the first real shape always counts as a change.
pub const shape_sentinel: u32 = 0;

pub fn cursorShapeFromCursor(cursor: Cursor) u32 {
    return switch (cursor) {
        .default => shape_default,
        .pointer => shape_pointer,
        .text => shape_text,
        .ew_resize => shape_ew_resize,
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

// A frame-scoped element id with two indices, e.g. "grid.cell.3.1".
pub fn elementId2(prefix: []const u8, a: usize, b: usize) []const u8 {
    return formatText("{s}.{d}.{d}", .{ prefix, a, b });
}

// Whether the left button is held, and where that press began, so a field can tell a drag that started on it from one that wandered in.
pub var ptr_down: bool = false;
pub var ptr_press_x: f32 = 0;
pub var ptr_press_y: f32 = 0;

// Record the pointer position for this frame.
pub fn setPointer(x: f32, y: f32) void {
    ptr_x = x;
    ptr_y = y;
}

// Device pixels per logical point, as the window backend set it. 1.0 until a Retina window says otherwise.
pub var pixel_scale: f32 = 1;

// Record the window's backing scale, so a hairline can be snapped to real device pixels.
pub fn setPixelScale(s: f32) void {
    pixel_scale = if (s > 0) s else 1;
}

// Snap a caret's left edge to the device pixel grid. A 1 pt bar at a fractional x is antialiased across two device pixels, and the half-covered one

// blends into the character beside it — which is what makes a caret look like it is drawn on top of a glyph.
pub fn snapX(x: f32) f32 {
    const k = pixel_scale;
    return @round(x * k) / k;
}

// One device pixel, in logical points: the width a caret should be so it covers whole pixels and nothing more.
pub fn hairline() f32 {
    return 1 / pixel_scale;
}

// Record the button state and the press origin for this frame.
pub fn setPointerButton(down: bool, press_x: f32, press_y: f32) void {
    ptr_down = down;
    ptr_press_x = press_x;
    ptr_press_y = press_y;
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

// FNV-1a over command count + per-command type, id, bbox bits and type-specific payload (rect color, text bytes/size/color, border color/widths).
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

    // Returns true when the caller should issue the GLES draw.
    pub fn shouldDraw(self: *FrameMemo, commands: []cl.RenderCommand) bool {
        const h = hashCommands(commands);
        if (self.last_hash) |prev| {
            if (prev == h) {
                self.skips += 1;
                return false;
            }
        }
        self.last_hash = h;
        self.draws += 1;
        return true;
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

// The ids declared so far this frame, open-addressed. A key of 0 is an empty slot (the "no id" case never gets here).
const id_set_cap = 4096;
var id_keys: [id_set_cap]u64 = [_]u64{0} ** id_set_cap;

// Keys already reported in a release build, so a duplicate that survives every frame is logged once, not 60 times a second.
var id_warned: [256]u64 = [_]u64{0} ** 256;
var id_warned_n: usize = 0;

fn idKey(id: cl.ElementId) u64 {
    const h = (@as(u64, id.id) << 32) | @as(u64, id.offset);
    // 0 marks an empty slot, so a real key must never be 0.
    return if (h == 0) 1 else h;
}

// Clear the per-frame id set. Called from `zclay.on_begin_frame`, so it runs for every frame however it was started.
fn resetIds() void {
    @memset(&id_keys, 0);
}

// Insert `key`; true when it was already there.
fn idSeenBefore(key: u64) bool {
    var i: usize = @intCast(key % id_set_cap);
    var probes: usize = 0;
    while (probes < id_set_cap) : (probes += 1) {
        if (id_keys[i] == 0) {
            id_keys[i] = key;
            return false;
        }
        if (id_keys[i] == key) return true;
        i = (i + 1) % id_set_cap;
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

fn clayErrorHandler(err: cl.ErrorData) callconv(.c) void {
    const msg = err.error_text.chars[0..@intCast(err.error_text.length)];
    // Clay's duplicate message never names the id and `claimId` already reports it, so this would only add a nameless line.
    if (err.error_type == .duplicate_id) return;
    std.log.err("clay {s}: {s}", .{ @tagName(err.error_type), msg });
}

// Init the Clay arena for a w x h window.
pub fn initClay(alloc: std.mem.Allocator, w: u32, h: u32) ![]u8 {
    const clay_mem_size = cl.minMemorySize();
    const clay_mem = try alloc.alloc(u8, clay_mem_size);
    errdefer alloc.free(clay_mem);
    const arena = cl.Arena.init(clay_mem);
    _ = cl.initialize(arena, .{ .w = @floatFromInt(w), .h = @floatFromInt(h) }, .{ .error_handler_function = clayErrorHandler });
    cl.setMeasureTextFunction(void, {}, clayMeasure);
    // Every identified element passes through this hook, so a duplicate is caught and named where it happens.
    cl.on_element = claimId;
    cl.on_begin_frame = resetIds;
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
    scroll_dx: f32,
    scroll_dy: f32,
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
        scroll_dx,
        scroll_dy,
        w,
        h,
        declare,
        ctx,
        &default_frame_options,
    );
}

// Frame variant with injectable measurement and a synchronous command probe.
pub fn clayFrameWithOptions(
    alloc: std.mem.Allocator,
    renderer: *?render.Renderer,
    renderer_attempted: *bool,
    pointer_x: f32,
    pointer_y: f32,
    pointer_down: bool,
    scroll_dx: f32,
    scroll_dy: f32,
    w: u32,
    h: u32,
    declare: DeclareFn,
    ctx: *anyopaque,
    options: *const FrameOptions,
) u32 {
    cl.setPointerState(.{ .x = pointer_x, .y = pointer_y }, pointer_down);
    // Clay's built-in drag stays OFF: it is touch-style (content follows the finger), inverted for a scrollbar slider.
    cl.updateScrollContainers(false, .{ .x = -scroll_dx, .y = -scroll_dy }, 1.0 / 60.0);
    cl.setLayoutDimensions(.{ .w = @floatFromInt(w), .h = @floatFromInt(h) });
    if (options.measure) |_| {
        cl.setMeasureTextFunction(*const FrameOptions, options, measureWithOptions);
    } else {
        cl.setMeasureTextFunction(void, {}, clayMeasure);
    }
    cl.beginLayout();
    // The frame's scratch strings are released here, so an app never has to remember to reset them.
    text_used = 0;
    declare(ctx, w, h);
    const commands = cl.endLayout();
    // The audit runs on the frames a developer actually sees, not only in tests: the caret, hairline and hit-target failures it catches are invisible to a

    // unit test and obvious here.
    if (audit.enabled) _ = audit.frame(commands, pixel_scale);
    // Semantics resolve AFTER layout (that is when Clay has bounding boxes) and BEFORE the probe, so a probe that inspects the tree sees resolved geometry.
    if (options.resolve_semantics) {
        semantics.resolve(@floatFromInt(w), @floatFromInt(h));
    }
    invokeProbe(options, commands, w, h);
    // Registries are populated by declare above — resolve the cursor now.
    const shape = hoverCursorShape(pointer_x, pointer_y);
    current_shape = shape;
    // Headless tests: layout ran (element data populated), renderer pruned (no GL context) — callback wiring stays testable headless.
    if (builtin.is_test) return shape;
    if (!renderer_attempted.*) {
        renderer_attempted.* = true;
        renderer.* = render.Renderer.init(alloc) catch |err| blk: {
            log.warn("renderer init failed ({s}); running clear-only", .{@errorName(err)});
            break :blk null;
        };
    }
    if (renderer.*) |*r| {
        if (memo_enabled) {
            if (memo.shouldDraw(commands)) {
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
