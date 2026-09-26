// Agnostic Clay frame helper: owns the per-frame + init boilerplate
// every Clay app repeats (measure/error wiring, arena init, pointer +
// layout sync, begin/declare/end, lazy GLES3 renderer + draw).
//
// ZERO ui/* imports by design — app code supplies only a declare callback:
//   fn declare(ctx: *anyopaque, w: u32, h: u32) void
// Shell keeps its AppState/hit-testing/callbacks; frame() shrinks to one
// engine call. Headless-safe: layout always runs (CPU-only, populates
// element data for tests); GL draws are pruned in `builtin.is_test` and
// fall back to clear-only when Renderer.init fails.
const std = @import("std");
const builtin = @import("builtin");
const cl = @import("zclay");
const render = @import("render.zig");
const text = @import("text_backend.zig");
const click_registry = @import("components/click_registry.zig");

// ---- Wayland cursor-shape (wp_cursor_shape_manager_v1) ----
// Contract (registry crew owns components/click_registry.zig):
//   components.click_registry.hoverCursorAt(x, y) -> Cursor
//   Cursor = enum { default, pointer, text, ew_resize }
// Map: .default -> SHAPE_DEFAULT (1), .pointer -> _POINTER (4),
// .text -> _TEXT (9), .ew_resize -> _EW_RESIZE (26).
// Values mirror cursor-shape-v1.xml <enum name="shape"> entries; the
// wayland.zig shape-mapping test asserts them against the generated
// WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_* constants.
//
// Compatibility: the registry crew lands Cursor/hoverCursorAt in
// parallel — @hasDecl guards keep this compiling both before (fallback
// .default) and after (live lookup) their change. Never touch
// src/core/components/ here (other crew owns it).
pub const Cursor = enum { default, pointer, text, ew_resize };

pub const shape_default: u32 = 1;
pub const shape_pointer: u32 = 4;
pub const shape_text: u32 = 9;
pub const shape_ew_resize: u32 = 26;
/// Sentinel for Window.last_shape: 0 is not a valid shape (valid range
/// starts at 1), so the first real shape always counts as a change.
pub const shape_sentinel: u32 = 0;

pub fn cursorShapeFromCursor(cursor: Cursor) u32 {
    return switch (cursor) {
        .default => shape_default,
        .pointer => shape_pointer,
        .text => shape_text,
        .ew_resize => shape_ew_resize,
    };
}

/// Resolve the cursor for a pointer point. Uses the registry's
/// hoverCursorAt when present (registry crew), else .default.
/// Tag-name comparison (not type coercion) so this compiles against any
/// registry Cursor with matching tags.
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

/// Last shape resolved by clayFrame (updated every frame, including
/// headless tests). Window.run reads this after on_frame returns
/// (Delegate.on_frame stays void so ui/* delegates keep compiling) and
/// calls set_shape change-only. Host.frame threads the same value as
/// its return for future direct callers.
pub var current_shape: u32 = shape_default;

pub fn currentShape() u32 {
    return current_shape;
}

/// Change-only gate (pure, unit-tested): true when the shape differs
/// from the last applied one.
pub fn shouldApplyShape(last: u32, next: u32) bool {
    return last != next;
}

/// Engine-side memoized immediate: output-hash draw skipping.
///
/// The app's declare callback stays a pure per-frame immediate-mode
/// function (no app-side caches required). Instead the engine hashes
/// the Clay render commands after layout and skips the GLES draw when
/// the output is bit-identical to the previous frame (e.g. hover motion
/// within one row, or a 60fps frame event with a 1-second clock
/// preview). Layout still runs every dirty frame so hit-test element
/// data stays fresh; only the GPU upload + draw calls are skipped.
/// File-scope `memo` owns the last hash — `clayFrame` keeps its exact
/// signature, so no business-app (ui/*) change is needed.
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

/// FNV-1a over command count + per-command type, id, bbox bits and
/// type-specific payload (rect color, text bytes/size/color, border
/// color/widths). Pure + headless-testable.
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

/// Per-engine memo state. `draws` counts GLES draws issued, `skips`
/// counts identical-output frames where the draw was skipped.
pub const FrameMemo = struct {
    last_hash: ?u64 = null,
    draws: u64 = 0,
    skips: u64 = 0,

    /// Returns true when the caller should issue the GLES draw.
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

/// Engine-owned memo (single-window app). Reset on initClay so a
/// re-init (resize path) never reuses a stale hash across arenas.
///
/// NOTE (2026-09-06 regression): `memo_enabled` is OFF. Skipping
/// `drawCommands` here is NOT atomic with the present: Window.run does
/// `glClear → on_frame → eglSwapBuffers`, so a skip after the clear
/// presents a blank buffer (black window whenever the cursor is idle,
/// content flashing back on cursor move). A correct skip must suppress
/// clear+draw+swap together, but the app sits between layout (inside
/// on_frame) and present (run loop) — restructuring needs app-wiring
/// changes, which we ruled out. `hashCommands`/`FrameMemo` stay as
/// tested utilities for a future atomic design; the live savings come
/// from the wayland.zig motion dedup (fewer dirty frames, zero risk).
pub var memo_enabled: bool = false;
var memo: FrameMemo = .{};

/// Declare callback: app builds its Clay tree here (views.zig declareRoot).
/// ctx is the app owner (e.g. *AppState); w/h are the current window dims.
pub const DeclareFn = *const fn (ctx: *anyopaque, w: u32, h: u32) void;

fn clayMeasure(text_bytes: []const u8, config: *cl.TextElementConfig, _: void) cl.Dimensions {
    const ext = text.measureText(text_bytes, config.font_size);
    return .{ .w = ext.w, .h = ext.h };
}

fn clayErrorHandler(err: cl.ErrorData) callconv(.c) void {
    const msg = err.error_text.chars[0..@intCast(err.error_text.length)];
    std.log.err("clay {s}: {s}", .{ @tagName(err.error_type), msg });
}

/// Init the Clay arena for a w x h window. Pure CPU (no GL/display).
/// Returns the owned backing slice; caller frees it on deinit.
pub fn initClay(alloc: std.mem.Allocator, w: u32, h: u32) ![]u8 {
    const clay_mem_size = cl.minMemorySize();
    const clay_mem = try alloc.alloc(u8, clay_mem_size);
    errdefer alloc.free(clay_mem);
    const arena = cl.Arena.init(clay_mem);
    _ = cl.initialize(arena, .{ .w = @floatFromInt(w), .h = @floatFromInt(h) }, .{ .error_handler_function = clayErrorHandler });
    cl.setMeasureTextFunction(void, {}, clayMeasure);
    memo.reset();
    return clay_mem;
}

/// Per-frame text measurement override used by headless tests. The
/// callback is stored in the caller's FrameOptions, so the options value
/// must remain alive until the next Clay frame (testing.Driver keeps it
/// alive for its whole lifetime).
pub const MeasureFn = *const fn (
    text: []const u8,
    config: *cl.TextElementConfig,
    user_data: ?*anyopaque,
) cl.Dimensions;

/// Called synchronously after Clay finishes layout and before rendering.
/// `commands` is valid only for the duration of the callback/current frame.
pub const FrameProbeFn = *const fn (
    user_data: ?*anyopaque,
    commands: []const cl.RenderCommand,
    width: u32,
    height: u32,
) void;

/// Optional seams used by the reusable headless testing module. Production
/// callers can leave both null; the defaults preserve the existing
/// Pango + GLES behavior.
pub const FrameOptions = struct {
    measure: ?MeasureFn = null,
    measure_user_data: ?*anyopaque = null,
    probe: ?FrameProbeFn = null,
    probe_user_data: ?*anyopaque = null,
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

/// One Clay frame: sync pointer + layout dims, begin, run the app's
/// declare callback, end, then draw (lazy renderer init, clear-only
/// fallback on failure). renderer/renderer_attempted are the app's stored
/// slots so the GL context is created once, inside the frame loop where a
/// current EGL context exists.
///
/// Cursor-shape threading: AFTER cl.endLayout() the registries are
/// populated for this frame, so hoverCursorShape(pointer_x, pointer_y)
/// resolves the contract Cursor -> shape u32 here. The shape is stored
/// in current_shape AND returned (pick: return; documented here) so
/// Window.run's frame loop can set_shape change-only. In headless tests
/// layout still runs and the shape resolves; only GL is pruned.
///
/// Wheel scrolling: scroll_dx/dy arrive in Wayland axis coords
/// (positive = down/right). Clay's convention is inverted (its
/// scrollPosition runs 0 at start to negative at end, so a scroll-down
/// needs a NEGATIVE delta) — negate at this boundary so callers stay in
/// natural coords. Zero = no-op. dt is fixed at 1/60 (60fps budget).
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

/// Frame variant with injectable measurement and a synchronous command
/// probe. The probe runs in both production and test builds immediately
/// after endLayout, which makes it useful for tests without changing the
/// normal Host path.
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
    // Clay's built-in drag stays OFF: it is touch-style (content follows
    // the finger), inverted for a scrollbar slider. Drag goes through
    // scroll.dragScroll (slider-style, 1:1 clamped) driven by Host motion
    // events instead. Wheel deltas are negated here (Wayland + = down,
    // Clay - = down); zero delta still runs bookkeeping (pruning).
    cl.updateScrollContainers(false, .{ .x = -scroll_dx, .y = -scroll_dy }, 1.0 / 60.0);
    cl.setLayoutDimensions(.{ .w = @floatFromInt(w), .h = @floatFromInt(h) });
    if (options.measure) |_| {
        cl.setMeasureTextFunction(*const FrameOptions, options, measureWithOptions);
    } else {
        cl.setMeasureTextFunction(void, {}, clayMeasure);
    }
    cl.beginLayout();
    declare(ctx, w, h);
    const commands = cl.endLayout();
    invokeProbe(options, commands, w, h);
    // Registries are populated by declare above — resolve the cursor now.
    const shape = hoverCursorShape(pointer_x, pointer_y);
    current_shape = shape;
    // Headless tests: layout ran (element data populated), renderer
    // pruned (no GL context) — callback wiring stays testable headless.
    if (builtin.is_test) return shape;
    if (!renderer_attempted.*) {
        renderer_attempted.* = true;
        renderer.* = render.Renderer.init(alloc) catch |err| blk: {
            std.log.warn("renderer init failed ({s}); running clear-only", .{@errorName(err)});
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
    // Contract: .default -> 1, .pointer -> 4, .text -> 9, .ew_resize -> 26
    // (cursor-shape-v1.xml shape enum; wayland.zig asserts these against
    // the generated WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_* constants).
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
    // Registry crew hasn't landed hoverCursorAt yet -> @hasDecl false ->
    // default shape. Headless-safe: no Wayland connection needed.
    if (!@hasDecl(click_registry, "hoverCursorAt")) {
        try std.testing.expectEqual(shape_default, hoverCursorShape(10, 20));
        try std.testing.expectEqual(shape_default, hoverCursorShape(0, 0));
    } else {
        // Registry landed: empty frame still resolves a valid shape.
        const s = hoverCursorShape(10, 20);
        try std.testing.expect(s == shape_default or s == shape_pointer or s == shape_text or s == shape_ew_resize);
    }
}
