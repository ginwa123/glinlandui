// Agnostic Wayland GUI library: xdg-toplevel bootstrap, EGL init,
// frame-callback event loop, pointer/keyboard listeners. ZERO ui/*
// imports by design — everything app-specific (Clay tree, AppState,
// hit regions, renderer) lives in ui/views.zig and plugs in via
// `Delegate` below. Allowed imports: std, builtin, C system headers.
// Window geometry defaults are plain literals duplicating ui/theme.zig
// (the source of truth; ui/views_test.zig cross-checks them in tests).
const std = @import("std");
const builtin = @import("builtin");
// The backend-neutral window vocabulary. WindowConfig + Delegate are DEFINED
// there and re-exported below, not redeclared: the macOS and portable backends
// already re-export the same two types, and this file used to carry the only
// second copy of them. One definition means a field added for one backend
// cannot silently fail to reach Linux.
const contract = @import("../core/window_contract.zig");
const Color = @import("../core/color.zig").Color;
// The four role modules that mirror mac/ one for one. `window.zig` keeps the
// C-callback glue (the `callconv(.c)` listeners, the protocol bootstrap, the
// EGL setup and the frame loop); everything a reader would otherwise have to
// diff against the macOS backend lives in these files.
const adapter = @import("adapter.zig");
const input = @import("input.zig");
const keymap = @import("keymap.zig");
const present = @import("present.zig");

// Wayland client bootstrap + xdg-toplevel/EGL window (Task A, tiled).
// System headers (wayland-client, wayland-egl, EGL, GLES2) resolve via
// /usr/include; the generated xdg-shell header
// (xdg-shell-client-protocol.h, see build.zig genWaylandProtocol)
// resolves via the build.zig include paths on the exe module (and on
// the qs_settings_zig module for `zig build test`). The layer-shell
// header is kept for the legacy centeredAnchor/layerSize helpers below
// (their tests still pass); run() no longer uses it.
const c = @cImport({
    @cInclude("wayland-client.h");
    @cInclude("wayland-egl.h");
    @cInclude("EGL/egl.h");
    @cInclude("GLES2/gl2.h");
    @cInclude("wlr-layer-shell-unstable-v1-client-protocol.h");
    @cInclude("xdg-shell-client-protocol.h");
    @cInclude("cursor-shape-v1-client-protocol.h");
});

// Task A2: agnostic children — the GLES3 renderer + font utils live
// INSIDE the wayland library (src/linux/, ui/*-free by design;
// allowed imports: std, builtin, zclay, C system headers). Consumers
// use wayland.render / wayland.text (ui -> platform direction).
pub const render = @import("renderer.zig");
pub const text = @import("text.zig");
// Agnostic Clay frame helper (init + per-frame begin/declare/end/draw).
// Shell delegates here so app code is only the declare callback.
pub const frame = @import("../core/frame.zig");

/// Centered top-left corner of the 720x480 window.
pub const Placement = struct {
    x: i32,
    y: i32,
};

/// 5.1: center the 720x480 window in the output; clamp to 0,0 when the
/// output is smaller than the window. (Literals duplicate ui/theme.zig.)
pub fn computePlacement(out_w: u32, out_h: u32) Placement {
    const x: i32 = if (out_w > 720) @intCast((out_w - 720) / 2) else 0;
    const y: i32 = if (out_h > 480) @intCast((out_h - 480) / 2) else 0;
    return .{ .x = x, .y = y };
}

/// Tiled window size limits: min 520x360. A 0 dimension means the
/// compositor defers to the client -> keep the default size
/// (720x480, the initial size). Below min clamps to min.
pub const min_width: u32 = 520;
pub const min_height: u32 = 360;

pub fn clampSize(w: u32, h: u32) struct { w: u32, h: u32 } {
    const cw = if (w == 0) 720 else @max(w, min_width);
    const ch = if (h == 0) 480 else @max(h, min_height);
    return .{ .w = cw, .h = ch };
}

/// 5.3: Escape closes the window. Accept the linux input-event-codes
/// keycode (1) and the wl_keyboard keysym (0xff1b).
pub fn keyToClose(keycode: u32) bool {
    return keycode == 1 or keycode == 0xff1b;
}

/// Legacy (layer-shell era): centered anchor = all four edges
/// (TOP|BOTTOM|LEFT|RIGHT). Kept so the existing centeredAnchor test
/// stays green; run() no longer uses layer-shell.
pub fn centeredAnchor() u32 {
    return c.ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP |
        c.ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM |
        c.ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT |
        c.ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT;
}

/// Legacy (layer-shell era): fixed surface size 720x480 (duplicates
/// ui/theme.zig). Kept so the existing layerSize test stays green; the
/// tiled run() starts at config.width x config.height and then follows
/// compositor configures via Window.clamp.
pub const LayerSize = struct {
    w: u32,
    h: u32,
};

pub fn layerSize() LayerSize {
    return .{ .w = 720, .h = 480 };
}

/// Task A: EGL config attributes — RGBA8 + WINDOW_BIT +
/// OPENGL_ES3_BIT, terminated with EGL_NONE.
pub fn eglConfigAttribs() [13]c.EGLint {
    return .{
        c.EGL_RED_SIZE,        8,
        c.EGL_GREEN_SIZE,      8,
        c.EGL_BLUE_SIZE,       8,
        c.EGL_ALPHA_SIZE,      8,
        c.EGL_SURFACE_TYPE,    c.EGL_WINDOW_BIT,
        c.EGL_RENDERABLE_TYPE, c.EGL_OPENGL_ES3_BIT,
        c.EGL_NONE,
    };
}

/// Task A: parse QS_SETTINGS_TEST_FRAMES — null/empty/invalid means
/// "run until the compositor closes us" (production behavior).
pub fn parseTestFrames(env: ?[]const u8) ?u32 {
    const s = env orelse return null;
    if (s.len == 0) return null;
    return std.fmt.parseInt(u32, s, 10) catch null;
}

fn testFramesFromEnv() ?u32 {
    const raw = std.c.getenv("QS_SETTINGS_TEST_FRAMES") orelse return null;
    return parseTestFrames(std.mem.span(raw));
}

/// Window background (sidebar_bg #111111) as normalized RGBA floats for
/// glClearColor. GL wants 0-1 floats where Clay wants 0-255, so this is
/// `toClay()` divided by 255 — the one place the two scales meet.
fn clearColor() [4]f32 {
    const clay = Color.rgb(0x11, 0x11, 0x11).toClay();
    return .{
        clay[0] / 255.0,
        clay[1] / 255.0,
        clay[2] / 255.0,
        clay[3] / 255.0,
    };
}

const Globals = struct {
    compositor: bool = false,
    xdg_wm_base: bool = false,
    shm: bool = false,
    seat: bool = false,
    cursor_shape_manager: bool = false,
};

const RegistryState = struct {
    compositor_name: u32 = 0,
    xdg_wm_base_name: u32 = 0,
    seat_name: u32 = 0,
    cursor_shape_manager_name: u32 = 0,
    found: Globals = .{},
};

fn registryGlobal(
    data: ?*anyopaque,
    registry: ?*c.struct_wl_registry,
    name: u32,
    interface: ?[*:0]const u8,
    version: u32,
) callconv(.c) void {
    _ = registry;
    _ = version;
    const found: *Globals = @ptrCast(@alignCast(data orelse return));
    const iface = std.mem.span(interface orelse return);
    if (std.mem.eql(u8, iface, "wl_compositor")) {
        found.compositor = true;
    }
    if (std.mem.eql(u8, iface, "xdg_wm_base")) {
        found.xdg_wm_base = true;
    }
    if (std.mem.eql(u8, iface, "wl_shm")) found.shm = true;
    if (std.mem.eql(u8, iface, "wl_seat")) found.seat = true;
    if (std.mem.eql(u8, iface, "wp_cursor_shape_manager_v1")) found.cursor_shape_manager = true;
    _ = name;
}

fn registryGlobalWithNames(
    data: ?*anyopaque,
    registry: ?*c.struct_wl_registry,
    name: u32,
    interface: ?[*:0]const u8,
    version: u32,
) callconv(.c) void {
    _ = registry;
    _ = version;
    const state: *RegistryState = @ptrCast(@alignCast(data orelse return));
    const iface = std.mem.span(interface orelse return);
    if (std.mem.eql(u8, iface, "wl_compositor")) {
        state.found.compositor = true;
        if (state.compositor_name == 0) state.compositor_name = name;
    }
    if (std.mem.eql(u8, iface, "xdg_wm_base")) {
        state.found.xdg_wm_base = true;
        if (state.xdg_wm_base_name == 0) state.xdg_wm_base_name = name;
    }
    if (std.mem.eql(u8, iface, "wl_shm")) state.found.shm = true;
    if (std.mem.eql(u8, iface, "wl_seat")) {
        state.found.seat = true;
        if (state.seat_name == 0) state.seat_name = name;
    }
    if (std.mem.eql(u8, iface, "wp_cursor_shape_manager_v1")) {
        state.found.cursor_shape_manager = true;
        if (state.cursor_shape_manager_name == 0) state.cursor_shape_manager_name = name;
    }
}

fn registryGlobalRemove(
    data: ?*anyopaque,
    registry: ?*c.struct_wl_registry,
    name: u32,
) callconv(.c) void {
    _ = data;
    _ = registry;
    _ = name;
}

/// Engine-side motion dedup (memoized immediate, input half).
///
/// Re-exported, NOT redefined. This used to be a byte-identical COPY of
/// `core/window_contract.zig`'s function, which is precisely the drift hazard
/// the contract exists to remove — and on Linux the local copy silently won.
/// `linux/adapter.zig` owns the re-export and the full rationale.
pub const pointerPosChanged = adapter.pointerPosChanged;

/// Toolkit-style window configuration (GTK/GPUI/egui-like).
/// app_id/title go to the xdg-toplevel; width/height are the initial
/// EGL size; min_* feed the configure clamp. Geometry defaults are
/// plain literals duplicating ui/theme.zig (the source of truth).
/// Defined in core/window_contract.zig so every backend shares one
/// definition; re-exported here to keep `wayland.WindowConfig` resolving.
pub const WindowConfig = contract.WindowConfig;

/// UI delegate: Window owns the platform (xdg-toplevel bootstrap, EGL,
/// frame-callback loop, input listeners) and forwards input/lifecycle
/// here; the delegate owner (ui AppState + engine Host) does
/// all drawing in on_frame. Stored nullable on Window — null means no-ops so
/// headless/tests still run. Window swaps EGL buffers after on_frame
/// returns; the delegate only issues GL draws.
/// Defined in core/window_contract.zig; see the note there.
pub const Delegate = contract.Delegate;

fn xdgWmBasePing(
    data: ?*anyopaque,
    xdg_wm_base: ?*c.struct_xdg_wm_base,
    serial: u32,
) callconv(.c) void {
    _ = data;
    c.xdg_wm_base_pong(xdg_wm_base, serial);
}

fn xdgSurfaceConfigure(
    data: ?*anyopaque,
    xdg_surface: ?*c.struct_xdg_surface,
    serial: u32,
) callconv(.c) void {
    const win: *Window = @ptrCast(@alignCast(data orelse return));
    c.xdg_surface_ack_configure(xdg_surface, serial);
    win.configured = true;
    win.needs_draw = true;
    if (win.surface) |s| c.wl_surface_commit(s);
}

fn xdgToplevelConfigure(
    data: ?*anyopaque,
    toplevel: ?*c.struct_xdg_toplevel,
    width: i32,
    height: i32,
    states: ?*c.struct_wl_array,
) callconv(.c) void {
    _ = toplevel;
    _ = states;
    const win: *Window = @ptrCast(@alignCast(data orelse return));
    // Zero means the compositor defers to the client -> keep current.
    // Otherwise clamp to min and store as pending; the frame loop
    // applies it (egl resize + Clay dims + viewport).
    if (width == 0 and height == 0) return;
    const w: u32 = if (width <= 0) win.win_w else @intCast(width);
    const h: u32 = if (height <= 0) win.win_h else @intCast(height);
    const clamped = win.clamp(w, h);
    win.pending_w = clamped.w;
    win.pending_h = clamped.h;
    win.needs_draw = true;
}

fn xdgToplevelClose(
    data: ?*anyopaque,
    toplevel: ?*c.struct_xdg_toplevel,
) callconv(.c) void {
    _ = toplevel;
    const win: *Window = @ptrCast(@alignCast(data orelse return));
    if (win.delegate) |d| d.on_close(d.ptr);
    win.quit = true;
}

/// xdg_toplevel.configure_bounds (v4): a window-geometry hint. We already
/// size from xdg_toplevel.configure, so this is a no-op — but the listener
/// member MUST be non-null or libffi calls address 0x4 when the compositor
/// sends it.
fn xdgToplevelConfigureBounds(
    data: ?*anyopaque,
    toplevel: ?*c.struct_xdg_toplevel,
    width: i32,
    height: i32,
) callconv(.c) void {
    _ = data;
    _ = toplevel;
    _ = width;
    _ = height;
}

/// xdg_toplevel.wm_capabilities (v5): advertises window-manager features.
/// Not used by this client. Wired purely so the listener struct has no
/// null slots (see configure_bounds).
fn xdgToplevelWmCapabilities(
    data: ?*anyopaque,
    toplevel: ?*c.struct_xdg_toplevel,
    capabilities: ?*c.struct_wl_array,
) callconv(.c) void {
    _ = data;
    _ = toplevel;
    _ = capabilities;
}

fn frameDone(
    data: ?*anyopaque,
    callback: ?*c.struct_wl_callback,
    time: u32,
) callconv(.c) void {
    _ = time;
    const win: *Window = @ptrCast(@alignCast(data orelse return));
    c.wl_callback_destroy(callback);
    win.frame_done = true;
}

/// On-demand frame scheduler (pure, unit-tested): one loop iteration's
/// decision from frame-callback state + dirty flag.
/// - draw: a frame event arrived and content is dirty → render + swap.
/// - kick: dirty but no frame outstanding → request one so the
///   compositor wakes us (drawing waits for the frame event, so every
///   present carries a fresh buffer — no stall, no tearing).
/// - idle: nothing to do → block in dispatch (consumes a stale frame
///   event when one arrived without dirty content).
pub const FrameStep = enum { draw, kick, idle };

pub fn frameStep(frame_done: bool, needs_draw: bool, frame_pending: bool) FrameStep {
    if (frame_done and needs_draw) return .draw;
    if (frame_done) return .idle;
    if (needs_draw and !frame_pending) return .kick;
    return .idle;
}

// ---- Input state (folded into Window) ----
// Pointer position (surface-local px), button state, seat objects, and
// tiled dims all live on Window now; listeners receive *Window as
// user_data and forward input to the delegate (null = no-op).

// ---- Task B: wl_pointer listener ----

/// Local alias so the call sites below — and the `fixedToFloat` test further
/// down — read exactly as they did when this was defined here. The
/// implementation moved to linux/input.zig, which explains why it is pure and
/// takes `i32` rather than `c.wl_fixed_t`.
const fixedToFloat = input.fixedToFloat;

fn pointerEnter(data: ?*anyopaque, pointer: ?*c.struct_wl_pointer, serial: u32, surface: ?*c.struct_wl_surface, sx: c.wl_fixed_t, sy: c.wl_fixed_t) callconv(.c) void {
    _ = surface;
    const win: *Window = @ptrCast(@alignCast(data orelse return));
    // Cursor-shape: the compositor requires the latest enter serial for
    // set_shape — store it (never discard) and re-send the current shape
    // with the fresh serial below.
    win.enter_serial = serial;
    // Create the shape device once (null-manager tolerant: absent
    // manager -> all cursor ops no-op, arrow behavior preserved).
    if (win.shape_device == null) {
        if (win.cursor_shape_manager) |mgr| {
            if (pointer) |p| {
                const dev = c.wp_cursor_shape_manager_v1_get_pointer(mgr, p);
                if (dev) |d| win.shape_device = d;
            }
        }
    }
    // Force-apply the current shape with the fresh serial (re-send on
    // every enter per protocol; the per-frame loop is change-only).
    if (win.shape_device) |dev| {
        if (!builtin.is_test) {
            const shape = frame.currentShape();
            c.wp_cursor_shape_device_v1_set_shape(dev, serial, shape);
            win.last_shape = shape;
        }
    }
    const nx = fixedToFloat(sx);
    const ny = fixedToFloat(sy);
    if (pointerPosChanged(win.pointer_x, win.pointer_y, nx, ny)) win.needs_draw = true;
    win.pointer_x = nx;
    win.pointer_y = ny;
    if (win.delegate) |d| d.on_pointer(d.ptr, win.pointer_x, win.pointer_y, win.pointer_down, 0);
}

fn pointerLeave(data: ?*anyopaque, pointer: ?*c.struct_wl_pointer, serial: u32, surface: ?*c.struct_wl_surface) callconv(.c) void {
    _ = data;
    _ = pointer;
    _ = serial;
    _ = surface;
}

fn pointerMotion(data: ?*anyopaque, pointer: ?*c.struct_wl_pointer, time: u32, sx: c.wl_fixed_t, sy: c.wl_fixed_t) callconv(.c) void {
    _ = pointer;
    _ = time;
    const win: *Window = @ptrCast(@alignCast(data orelse return));
    const nx = fixedToFloat(sx);
    const ny = fixedToFloat(sy);
    if (pointerPosChanged(win.pointer_x, win.pointer_y, nx, ny)) win.needs_draw = true;
    win.pointer_x = nx;
    win.pointer_y = ny;
    if (win.delegate) |d| d.on_pointer(d.ptr, win.pointer_x, win.pointer_y, win.pointer_down, 0);
}

fn pointerButton(data: ?*anyopaque, pointer: ?*c.struct_wl_pointer, serial: u32, time: u32, button: u32, state: u32) callconv(.c) void {
    _ = pointer;
    _ = serial;
    _ = time;
    const win: *Window = @ptrCast(@alignCast(data orelse return));
    // BTN_LEFT is 272 (0x110). Layout-agnostic: track button state and forward
    // to the delegate, which maps the evdev code to hit regions / quit.
    // `kindFromState` / `evdevButton` are the same names `mac/input.zig` uses,
    // so the two backends answer "what did the user press?" identically.
    const kind = input.kindFromState(state);
    if (button == input.BTN_LEFT and kind == input.DOWN) {
        win.pointer_down = true;
    } else if (button == input.BTN_LEFT) {
        win.pointer_down = false;
    }
    win.needs_draw = true;
    if (win.delegate) |d| {
        d.on_pointer(d.ptr, win.pointer_x, win.pointer_y, kind == input.DOWN, input.evdevButton(button));
        if (d.is_quit(d.ptr)) win.quit = true;
    }
}

fn pointerAxis(data: ?*anyopaque, pointer: ?*c.struct_wl_pointer, time: u32, axis: u32, value: c.wl_fixed_t) callconv(.c) void {
    _ = pointer;
    _ = time;
    const win: *Window = @ptrCast(@alignCast(data orelse return));
    // wl_pointer axis: 0 = vertical, 1 = horizontal. Value is wl_fixed
    // pixels (trackpads send fractional; wheels send ~10-15px clicks).
    // Accumulate into the pending scroll delta; the frame loop forwards
    // it to the delegate (Host) which feeds Clay's scroll containers.
    const v = fixedToFloat(value);
    adapter.applyScrollAxis(axis, v, &win.scroll_dx, &win.scroll_dy);
    win.needs_draw = true;
    if (win.delegate) |d| {
        const delta = adapter.scrollDelta(axis, v);
        if (d.on_scroll) |f| f(d.ptr, delta.dx, delta.dy);
        if (d.is_quit(d.ptr)) win.quit = true;
    }
}

fn pointerFrame(data: ?*anyopaque, pointer: ?*c.struct_wl_pointer) callconv(.c) void {
    _ = data;
    _ = pointer;
}

fn pointerAxisSource(data: ?*anyopaque, pointer: ?*c.struct_wl_pointer, axis_source: u32) callconv(.c) void {
    _ = data;
    _ = pointer;
    _ = axis_source;
}

fn pointerAxisStop(data: ?*anyopaque, pointer: ?*c.struct_wl_pointer, time: u32, axis: u32) callconv(.c) void {
    _ = data;
    _ = pointer;
    _ = time;
    _ = axis;
}

fn pointerAxisDiscrete(data: ?*anyopaque, pointer: ?*c.struct_wl_pointer, axis: u32, discrete: i32) callconv(.c) void {
    _ = data;
    _ = pointer;
    _ = axis;
    _ = discrete;
}

/// wl_pointer.axis_value120 (since seat v8) carries the same scroll delta
/// as .axis but in 1/120ths of a degree. It MUST be wired: leaving the
/// member null makes libffi call address 0x4 the moment the compositor
/// sends it, killing the process. Deliberately a no-op — scrolling is
/// driven by .axis — but present so the listener struct is complete.
fn pointerAxisValue120(data: ?*anyopaque, pointer: ?*c.struct_wl_pointer, axis: u32, value120: i32) callconv(.c) void {
    _ = data;
    _ = pointer;
    _ = axis;
    _ = value120;
}

fn pointerAxisRelativeDirection(data: ?*anyopaque, pointer: ?*c.struct_wl_pointer, axis: u32, direction: u32) callconv(.c) void {
    _ = data;
    _ = pointer;
    _ = axis;
    _ = direction;
}

fn pointerWarp(data: ?*anyopaque, pointer: ?*c.struct_wl_pointer, sx: c.wl_fixed_t, sy: c.wl_fixed_t) callconv(.c) void {
    _ = pointer;
    const win: *Window = @ptrCast(@alignCast(data orelse return));
    const nx = fixedToFloat(sx);
    const ny = fixedToFloat(sy);
    if (pointerPosChanged(win.pointer_x, win.pointer_y, nx, ny)) win.needs_draw = true;
    win.pointer_x = nx;
    win.pointer_y = ny;
    if (win.delegate) |d| d.on_pointer(d.ptr, win.pointer_x, win.pointer_y, win.pointer_down, 0);
}

// ---- Task B: wl_keyboard listener ----

fn keyboardKeymap(data: ?*anyopaque, keyboard: ?*c.struct_wl_keyboard, format: u32, fd: i32, size: u32) callconv(.c) void {
    _ = data;
    _ = keyboard;
    _ = format;
    _ = fd;
    _ = size;
}

fn keyboardEnter(data: ?*anyopaque, keyboard: ?*c.struct_wl_keyboard, serial: u32, surface: ?*c.struct_wl_surface, keys: ?*c.struct_wl_array) callconv(.c) void {
    _ = data;
    _ = keyboard;
    _ = serial;
    _ = surface;
    _ = keys;
}

fn keyboardLeave(data: ?*anyopaque, keyboard: ?*c.struct_wl_keyboard, serial: u32, surface: ?*c.struct_wl_surface) callconv(.c) void {
    _ = data;
    _ = keyboard;
    _ = serial;
    _ = surface;
}

fn keyboardKey(data: ?*anyopaque, keyboard: ?*c.struct_wl_keyboard, serial: u32, time: u32, key: u32, state: u32) callconv(.c) void {
    _ = keyboard;
    _ = serial;
    _ = time;
    const win: *Window = @ptrCast(@alignCast(data orelse return));
    // Forward presses AND releases with state; the delegate (Shell)
    // interprets raw evdev codes (Backspace arrives as 14 on this
    // compositor — no +8 adjustment) and tracks modifiers from
    // release events for text input.
    if (state == 1 or state == 0) {
        win.needs_draw = true;
        if (win.delegate) |d| {
            if (d.on_key(d.ptr, keymap.toEvdev(key), state == 1)) win.quit = true;
        }
    }
}

fn keyboardModifiers(data: ?*anyopaque, keyboard: ?*c.struct_wl_keyboard, serial: u32, mods_depressed: u32, mods_latched: u32, mods_locked: u32, group: u32) callconv(.c) void {
    _ = data;
    _ = keyboard;
    _ = serial;
    _ = mods_depressed;
    _ = mods_latched;
    _ = mods_locked;
    _ = group;
}

fn keyboardRepeatInfo(data: ?*anyopaque, keyboard: ?*c.struct_wl_keyboard, rate: i32, delay: i32) callconv(.c) void {
    _ = data;
    _ = keyboard;
    _ = rate;
    _ = delay;
}

// ---- Listener constructors (single source of truth) -------------
//
// Each *_add_listener call must use one of these, and the resulting
// struct is STORED ON WINDOW - never a local. libwayland keeps the
// caller's pointer (wl_proxy_add_listener does not copy), so a local
// dangles as soon as the registering function returns.
//
// Every slot is filled, including the Wayland >= 1.22 additions
// (warp, axis_value120). A null slot is a live segfault the moment the
// compositor sends that event, so the regression tests at the bottom of
// this file assert completeness reflectively over the real struct types.

fn pointerListener() c.struct_wl_pointer_listener {
    var full = c.struct_wl_pointer_listener{
        .enter = pointerEnter,
        .leave = pointerLeave,
        .motion = pointerMotion,
        .button = pointerButton,
        .axis = pointerAxis,
        .frame = pointerFrame,
        .axis_source = pointerAxisSource,
        .axis_stop = pointerAxisStop,
        .axis_discrete = pointerAxisDiscrete,
        .axis_relative_direction = pointerAxisRelativeDirection,
    };
    // `warp` and `axis_value120` (both seat v8) exist only on Wayland
    // >= 1.22 headers; we bind v7, so they are conditional. Both are
    // still required whenever the header provides them.
    if (comptime @hasField(c.struct_wl_pointer_listener, "warp")) {
        full.warp = pointerWarp;
    }
    if (comptime @hasField(c.struct_wl_pointer_listener, "axis_value120")) {
        full.axis_value120 = pointerAxisValue120;
    }
    return full;
}

fn keyboardListener() c.struct_wl_keyboard_listener {
    return .{
        .keymap = keyboardKeymap,
        .enter = keyboardEnter,
        .leave = keyboardLeave,
        .key = keyboardKey,
        .modifiers = keyboardModifiers,
        .repeat_info = keyboardRepeatInfo,
    };
}

fn seatListener() c.struct_wl_seat_listener {
    return .{
        .capabilities = seatCapabilities,
        .name = seatName,
    };
}

fn registryListener() c.struct_wl_registry_listener {
    return .{
        .global = registryGlobalWithNames,
        .global_remove = registryGlobalRemove,
    };
}

fn callbackListener() c.struct_wl_callback_listener {
    return .{ .done = frameDone };
}

fn xdgWmBaseListener() c.struct_xdg_wm_base_listener {
    return .{ .ping = xdgWmBasePing };
}

fn xdgSurfaceListener() c.struct_xdg_surface_listener {
    return .{ .configure = xdgSurfaceConfigure };
}

fn xdgToplevelListener() c.struct_xdg_toplevel_listener {
    return .{
        .configure = xdgToplevelConfigure,
        .close = xdgToplevelClose,
        .configure_bounds = xdgToplevelConfigureBounds,
        .wm_capabilities = xdgToplevelWmCapabilities,
    };
}

// ---- Task B: wl_seat listener ----

fn seatCapabilities(data: ?*anyopaque, seat: ?*c.struct_wl_seat, capabilities: u32) callconv(.c) void {
    const win: *Window = @ptrCast(@alignCast(data orelse return));
    const has_pointer = capabilities & 1 != 0;
    const has_keyboard = capabilities & 2 != 0;
    if (has_pointer and win.pointer_obj == null) {
        const p = c.wl_seat_get_pointer(seat);
        win.pointer_obj = p;
        if (p) |ptr| {
            // Storage is win.pointer_listener (lives as long as the
            // proxy) - NOT a local, which would dangle on return.
            _ = c.wl_pointer_add_listener(ptr, &win.pointer_listener, win);
        }
    }
    if (has_keyboard and win.keyboard_obj == null) {
        const k = c.wl_seat_get_keyboard(seat);
        win.keyboard_obj = k;
        if (k) |kb| {
            _ = c.wl_keyboard_add_listener(kb, &win.keyboard_listener, win);
        }
    }
}

fn seatName(data: ?*anyopaque, seat: ?*c.struct_wl_seat, name: ?[*:0]const u8) callconv(.c) void {
    _ = data;
    _ = seat;
    _ = name;
}

/// Task A (tiled): full Wayland bootstrap — connect, registry
/// roundtrip, bind wl_compositor (v4) + xdg_wm_base (v1), create an
/// xdg_toplevel with the config app_id/title, bootstrap EGL (RGBA8 ES3
/// context on a wl_egl_window), clear once to the background color,
/// then run a frame-callback-driven dispatch loop until the compositor
/// closes us (or QS_SETTINGS_TEST_FRAMES frames when set). Live
/// resize: xdg_toplevel.configure stores a pending size; the frame
/// loop applies it via wl_egl_window_resize + glViewport and forwards
/// on_resize to the delegate.
///
/// Input (wl_seat pointer + keyboard) forwards to the delegate; the
/// delegate draws in on_frame and Window swaps after it returns.
/// Normal focus (no exclusive grab); quit when the delegate says so.
pub const Window = struct {
    config: WindowConfig,
    delegate: ?Delegate = null,
    pointer_x: f32 = 0,
    pointer_y: f32 = 0,
    pointer_down: bool = false,
    /// Pending wheel scroll delta (px, accumulated by pointerAxis,
    /// consumed by the frame loop). Positive dy = scroll down.
    scroll_dx: f32 = 0,
    scroll_dy: f32 = 0,
    pointer_obj: ?*c.struct_wl_pointer = null,
    keyboard_obj: ?*c.struct_wl_keyboard = null,
    surface: ?*c.struct_wl_surface = null,
    // ---- cursor-shape (wp_cursor_shape_manager_v1, optional) ----
    // Null-tolerant: compositor may not advertise the manager -> all
    // cursor ops no-op and today's arrow behavior is preserved.
    cursor_shape_manager: ?*c.struct_wp_cursor_shape_manager_v1 = null,
    shape_device: ?*c.struct_wp_cursor_shape_device_v1 = null,
    /// Most recent wl_pointer.enter serial (compositor requires a valid
    /// serial for set_shape; re-sent on every enter).
    enter_serial: u32 = 0,
    /// Last applied shape; shape_sentinel (0, invalid) forces the first
    /// real shape to count as a change.
    last_shape: u32 = 0,
    // Tiled size: current committed size + pending configure size.
    win_w: u32 = 720,
    win_h: u32 = 480,
    pending_w: u32 = 0,
    pending_h: u32 = 0,
    quit: bool = false,
    frame_done: bool = false,
    configured: bool = false,
    /// On-demand rendering: true when state changed since the last draw
    /// (input, resize, configure). The loop draws only on dirty frames
    /// and stops requesting frame callbacks when idle, so a static
    /// window blocks in dispatch at ~0% CPU instead of redrawing at the
    /// compositor refresh rate. Starts true for the initial frame.
    needs_draw: bool = true,
    /// A wl_surface_frame request is outstanding (compositor owes us a
    /// frame.done). Guards the kick path against stacking requests.
    frame_pending: bool = false,

    // ---- Listener storage (MUST outlive the proxy) ----
    //
    // wl_proxy_add_listener does NOT copy the listener struct - it keeps
    // the caller's pointer. A listener declared as a local in the
    // function that registers it dangles the moment that function
    // returns, and the next compositor event calls into dead stack
    // (this crashed qs-settings on the first pointer event). Every
    // listener therefore lives here, on the Window that owns the
    // proxies, and is built by the *Listener() constructors above.
    pointer_listener: c.struct_wl_pointer_listener = pointerListener(),
    keyboard_listener: c.struct_wl_keyboard_listener = keyboardListener(),
    seat_listener: c.struct_wl_seat_listener = seatListener(),
    registry_listener: c.struct_wl_registry_listener = registryListener(),
    callback_listener: c.struct_wl_callback_listener = callbackListener(),
    wm_listener: c.struct_xdg_wm_base_listener = xdgWmBaseListener(),
    xdg_surface_listener: c.struct_xdg_surface_listener = xdgSurfaceListener(),
    toplevel_listener: c.struct_xdg_toplevel_listener = xdgToplevelListener(),

    pub fn init(config: WindowConfig) Window {
        return .{
            .config = config,
            .win_w = config.width,
            .win_h = config.height,
        };
    }

    /// 0 in a dimension defers to the client -> config default size;
    /// otherwise max(dim, config min).
    pub fn clamp(self: Window, w: u32, h: u32) struct { w: u32, h: u32 } {
        const cw = if (w == 0) self.config.width else @max(w, self.config.min_width);
        const ch = if (h == 0) self.config.height else @max(h, self.config.min_height);
        return .{ .w = cw, .h = ch };
    }

    /// Close intent (delegate on_close / on_key true) returns cleanly
    /// through the deferred disconnect below.
    pub fn run(self: *Window) !void {
        // Headless tests never touch a compositor: pure logic above is what
        // `zig build test` exercises. Pruned at comptime, so test binaries need
        // no Wayland link.
        if (builtin.is_test) return;
        const display = c.wl_display_connect(null) orelse return error.NoWaylandDisplay;
        defer c.wl_display_disconnect(display);
        const registry = c.wl_display_get_registry(display) orelse return error.NoRegistry;
        defer c.wl_registry_destroy(registry);
        var reg: RegistryState = .{};
        _ = c.wl_registry_add_listener(registry, &self.registry_listener, &reg);
        if (c.wl_display_roundtrip(display) < 0) return error.RoundtripFailed;
        std.log.info(
            "wayland globals: compositor={} xdg_wm_base={} shm={} seat={}",
            .{ reg.found.compositor, reg.found.xdg_wm_base, reg.found.shm, reg.found.seat },
        );
        if (reg.compositor_name == 0) return error.NoCompositor;
        if (reg.xdg_wm_base_name == 0) return error.NoXdgWmBase;

        const comp_ptr = c.wl_registry_bind(registry, reg.compositor_name, &c.wl_compositor_interface, 4) orelse
            return error.BindFailed;
        const compositor: *c.struct_wl_compositor = @ptrCast(@alignCast(comp_ptr));
        defer c.wl_compositor_destroy(compositor);
        const wm_ptr = c.wl_registry_bind(registry, reg.xdg_wm_base_name, &c.xdg_wm_base_interface, 1) orelse
            return error.BindFailed;
        const wm_base: *c.struct_xdg_wm_base = @ptrCast(@alignCast(wm_ptr));
        defer c.xdg_wm_base_destroy(wm_base);

        const surface = c.wl_compositor_create_surface(compositor) orelse return error.NoSurface;
        defer c.wl_surface_destroy(surface);

        const xdg_surface = c.xdg_wm_base_get_xdg_surface(wm_base, surface) orelse return error.NoXdgSurface;
        defer c.xdg_surface_destroy(xdg_surface);
        const toplevel = c.xdg_surface_get_toplevel(xdg_surface) orelse return error.NoToplevel;
        defer c.xdg_toplevel_destroy(toplevel);

        c.xdg_toplevel_set_app_id(toplevel, self.config.app_id);
        c.xdg_toplevel_set_title(toplevel, self.config.title);

        self.surface = surface;
        self.win_w = self.config.width;
        self.win_h = self.config.height;
        _ = c.xdg_wm_base_add_listener(wm_base, &self.wm_listener, self);
        _ = c.xdg_surface_add_listener(xdg_surface, &self.xdg_surface_listener, self);
        _ = c.xdg_toplevel_add_listener(toplevel, &self.toplevel_listener, self);
        c.wl_surface_commit(surface);
        if (c.wl_display_roundtrip(display) < 0) return error.RoundtripFailed;

        // ---- Task B: optional seat input (pointer + keyboard) ----
        var seat: ?*c.struct_wl_seat = null;
        defer if (seat) |s| c.wl_seat_destroy(s);
        defer {
            if (self.shape_device) |d| c.wp_cursor_shape_device_v1_destroy(d);
            self.shape_device = null;
            if (self.cursor_shape_manager) |m| c.wp_cursor_shape_manager_v1_destroy(m);
            self.cursor_shape_manager = null;
            if (self.pointer_obj) |p| c.wl_pointer_destroy(p);
            self.pointer_obj = null;
            if (self.keyboard_obj) |k| c.wl_keyboard_destroy(k);
            self.keyboard_obj = null;
        }
        if (reg.seat_name != 0) {
            const seat_ptr = c.wl_registry_bind(registry, reg.seat_name, &c.wl_seat_interface, 7);
            if (seat_ptr) |sp| {
                seat = @ptrCast(@alignCast(sp));
                _ = c.wl_seat_add_listener(seat, &self.seat_listener, self);
                if (c.wl_display_roundtrip(display) < 0) return error.RoundtripFailed;
            } else {
                std.log.warn("wl_seat bind failed; running without pointer/keyboard input", .{});
            }
        } else {
            std.log.warn("no wl_seat global; running without pointer/keyboard input", .{});
        }

        // ---- cursor-shape manager (optional, version 1) ----
        // Null-tolerant: older compositors don't advertise
        // wp_cursor_shape_manager_v1 -> manager stays null and every cursor
        // op below no-ops (today's arrow behavior preserved).
        if (reg.cursor_shape_manager_name != 0) {
            const mgr_ptr = c.wl_registry_bind(
                registry,
                reg.cursor_shape_manager_name,
                &c.wp_cursor_shape_manager_v1_interface,
                1,
            );
            if (mgr_ptr) |mp| {
                self.cursor_shape_manager = @ptrCast(@alignCast(mp));
            } else {
                std.log.warn("wp_cursor_shape_manager_v1 bind failed; running without cursor shapes", .{});
            }
        }

        // ---- EGL bootstrap (initial size from config) ----
        const egl_display = c.eglGetDisplay(@ptrCast(display));
        if (egl_display == c.EGL_NO_DISPLAY) return error.EglNoDisplay;
        var major: c.EGLint = 0;
        var minor: c.EGLint = 0;
        if (c.eglInitialize(egl_display, &major, &minor) == c.EGL_FALSE) return error.EglInitFailed;
        defer _ = c.eglTerminate(egl_display);
        if (c.eglBindAPI(c.EGL_OPENGL_ES_API) == c.EGL_FALSE) return error.EglBindFailed;
        var attribs = eglConfigAttribs();
        var egl_config: c.EGLConfig = null;
        var nconfigs: c.EGLint = 0;
        if (c.eglChooseConfig(egl_display, &attribs, &egl_config, 1, &nconfigs) == c.EGL_FALSE or nconfigs == 0)
            return error.EglConfigFailed;
        const ctx_attribs = [_]c.EGLint{ c.EGL_CONTEXT_MAJOR_VERSION, 3, c.EGL_NONE };
        const egl_ctx = c.eglCreateContext(egl_display, egl_config, c.EGL_NO_CONTEXT, &ctx_attribs);
        if (egl_ctx == c.EGL_NO_CONTEXT) return error.EglContextFailed;
        defer _ = c.eglDestroyContext(egl_display, egl_ctx);

        const egl_window = c.wl_egl_window_create(surface, @intCast(self.config.width), @intCast(self.config.height)) orelse
            return error.EglWindowFailed;
        defer c.wl_egl_window_destroy(egl_window);
        const egl_surface = c.eglCreateWindowSurface(egl_display, egl_config, @ptrCast(egl_window), null);
        if (egl_surface == c.EGL_NO_SURFACE) return error.EglSurfaceFailed;
        defer _ = c.eglDestroySurface(egl_display, egl_surface);
        if (c.eglMakeCurrent(egl_display, egl_surface, egl_surface, egl_ctx) == c.EGL_FALSE)
            return error.EglMakeCurrentFailed;

        const cc = clearColor();
        c.glClearColor(cc[0], cc[1], cc[2], cc[3]);
        c.glClear(c.GL_COLOR_BUFFER_BIT);
        present.present(egl_display, egl_surface);

        // ---- event loop: on-demand rendering (dirty-flag driven).
        // A static window must not burn CPU: frames are drawn only when
        // needs_draw is set (input, resize, configure, initial frame).
        // frameStep() decides each iteration: draw on a dirty frame event,
        // kick (request a frame + commit) when dirty with none outstanding,
        // idle otherwise — idle blocks in dispatch at ~0% CPU and requests
        // no further frames until input arrives. Drawing always waits for
        // the frame event, so every present carries a fresh buffer (no
        // stall, no tearing), and motion floods coalesce into one frame.
        // QS_SETTINGS_TEST_FRAMES forces continuous drawing (old behavior)
        // so the frame-count harness keeps working.
        const max_frames = testFramesFromEnv();
        var frames: u32 = 0;
        var frame_cb = c.wl_surface_frame(surface) orelse return error.NoFrameCallback;
        _ = c.wl_callback_add_listener(frame_cb, &self.callback_listener, self);
        self.frame_pending = true;
        // The frame request is surface state: it needs a commit to take
        // effect (the pre-loop present already happened, so without
        // this commit dispatch would block forever waiting for a frame
        // event the compositor was never asked to send).
        c.wl_surface_commit(surface);
        while (!self.quit) {
            if (c.wl_display_dispatch(display) < 0) break;
            // Test harness: every iteration is dirty (continuous drawing).
            if (max_frames != null) self.needs_draw = true;
            // Delegate-driven quit (e.g. a close-box click during dispatch
            // set Shell.quit_requested): observe every iteration, not just
            // on frames, so quit is prompt even when idle.
            if (self.delegate) |d| {
                if (d.is_quit(d.ptr)) self.quit = true;
            }
            if (self.quit) break;
            switch (frameStep(self.frame_done, self.needs_draw, self.frame_pending)) {
                .draw => {
                    self.frame_done = false;
                    self.frame_pending = false;
                    self.needs_draw = false;
                    // Live resize: apply pending configure size once per draw.
                    if (self.pending_w != 0 and self.pending_h != 0 and
                        (self.pending_w != self.win_w or self.pending_h != self.win_h))
                    {
                        self.win_w = self.pending_w;
                        self.win_h = self.pending_h;
                        self.pending_w = 0;
                        self.pending_h = 0;
                        c.wl_egl_window_resize(egl_window, @intCast(self.win_w), @intCast(self.win_h), 0, 0);
                        c.glViewport(0, 0, @intCast(self.win_w), @intCast(self.win_h));
                        if (self.delegate) |d| d.on_resize(d.ptr, self.win_w, self.win_h);
                    }
                    c.glClear(c.GL_COLOR_BUFFER_BIT);
                    // Drawing happens in the delegate; Window swaps after it returns.
                    if (self.delegate) |d| d.on_frame(d.ptr, self.win_w, self.win_h);
                    // Per-frame cursor-shape apply (change-only): clayFrame
                    // resolved the contract Cursor -> shape AFTER endLayout
                    // into frame.currentShape(). Send set_shape only when the
                    // shape differs from last_shape, using the most recent
                    // enter serial. All null-guarded (null manager/device ->
                    // skip; absent manager preserves arrow behavior).
                    if (self.shape_device) |dev| {
                        const shape = frame.currentShape();
                        if (frame.shouldApplyShape(self.last_shape, shape)) {
                            c.wp_cursor_shape_device_v1_set_shape(dev, self.enter_serial, shape);
                            self.last_shape = shape;
                        }
                    }
                    present.present(egl_display, egl_surface);
                    frames += 1;
                    if (max_frames) |n| {
                        if (frames >= n) break;
                    }
                    if (self.quit) break;
                    // More work arrived mid-draw (or test harness): keep going.
                    if (self.needs_draw) {
                        frame_cb = c.wl_surface_frame(surface) orelse break;
                        _ = c.wl_callback_add_listener(frame_cb, &self.callback_listener, self);
                        self.frame_pending = true;
                        c.wl_surface_commit(surface);
                    }
                },
                .kick => {
                    frame_cb = c.wl_surface_frame(surface) orelse break;
                    _ = c.wl_callback_add_listener(frame_cb, &self.callback_listener, self);
                    self.frame_pending = true;
                    c.wl_surface_commit(surface);
                },
                .idle => {
                    // Consume a stale frame event (arrived with clean state);
                    // request nothing — the next input kick restarts us.
                    self.frame_done = false;
                },
            }
        }
    }
};

test "computePlacement centers 720x480 in 1920x1080" {
    const p = computePlacement(1920, 1080);
    try std.testing.expectEqual(@as(i32, 600), p.x);
    try std.testing.expectEqual(@as(i32, 300), p.y);
}

test "computePlacement centers 720x480 in 1280x720" {
    const p = computePlacement(1280, 720);
    try std.testing.expectEqual(@as(i32, 280), p.x);
    try std.testing.expectEqual(@as(i32, 120), p.y);
}

test "computePlacement clamps smaller output to 0,0" {
    const p = computePlacement(640, 400);
    try std.testing.expectEqual(@as(i32, 0), p.x);
    try std.testing.expectEqual(@as(i32, 0), p.y);
}

test "keyToClose accepts Escape keycode 1 and keysym 0xff1b" {
    try std.testing.expect(keyToClose(1));
    try std.testing.expect(keyToClose(0xff1b));
    try std.testing.expect(!keyToClose(30));
    try std.testing.expect(!keyToClose(9));
}

test "frameStep draws only on dirty frames, kicks when dirty-idle, idles otherwise" {
    // Dirty frame event → draw.
    try std.testing.expectEqual(FrameStep.draw, frameStep(true, true, false));
    try std.testing.expectEqual(FrameStep.draw, frameStep(true, true, true));
    // Clean frame event → idle (consume, request nothing).
    try std.testing.expectEqual(FrameStep.idle, frameStep(true, false, false));
    try std.testing.expectEqual(FrameStep.idle, frameStep(true, false, true));
    // Dirty with no frame outstanding → kick a request.
    try std.testing.expectEqual(FrameStep.kick, frameStep(false, true, false));
    // Dirty while a frame is already pending → wait for it.
    try std.testing.expectEqual(FrameStep.idle, frameStep(false, true, true));
    // Clean and quiet → idle (blocks in dispatch).
    try std.testing.expectEqual(FrameStep.idle, frameStep(false, false, false));
    try std.testing.expectEqual(FrameStep.idle, frameStep(false, false, true));
}

test "pointerPosChanged dedups identical hover events" {
    try std.testing.expect(!pointerPosChanged(10.5, 20.5, 10.5, 20.5));
    try std.testing.expect(pointerPosChanged(10.5, 20.5, 11.5, 20.5));
    try std.testing.expect(pointerPosChanged(10.5, 20.5, 10.5, 21.5));
    // Sub-pixel jitter inside one pixel cell must NOT dirty the loop
    // (Wayland fixed 1/256px precision floods motion events).
    try std.testing.expect(!pointerPosChanged(0, 0, 0.00390625, 0));
    try std.testing.expect(!pointerPosChanged(10.1, 20.9, 10.9, 20.1));
    // Crossing a pixel boundary does dirty (hover cell changed).
    try std.testing.expect(pointerPosChanged(10.9, 20.9, 11.1, 20.9));
}

test "centeredAnchor sets all four edges (TOP|BOTTOM|LEFT|RIGHT = 15)" {
    try std.testing.expectEqual(@as(u32, 15), centeredAnchor());
    try std.testing.expect(centeredAnchor() & c.ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP != 0);
    try std.testing.expect(centeredAnchor() & c.ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM != 0);
    try std.testing.expect(centeredAnchor() & c.ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT != 0);
    try std.testing.expect(centeredAnchor() & c.ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT != 0);
}

test "layerSize matches theme 720x480" {
    const sz = layerSize();
    try std.testing.expectEqual(@as(u32, 720), sz.w);
    try std.testing.expectEqual(@as(u32, 480), sz.h);
}

test "delegate defaults to null (headless no-op)" {
    const win = Window.init(.{});
    try std.testing.expect(win.delegate == null);
}

test "attached delegate round-trips on_key/on_close/is_quit" {
    const State = struct {
        quit: bool = false,
        frames: u32 = 0,
        last_w: u32 = 0,
        last_h: u32 = 0,
    };
    const fns = struct {
        fn onFrame(ptr: *anyopaque, w: u32, h: u32) void {
            const s: *State = @ptrCast(@alignCast(ptr));
            s.frames += 1;
            s.last_w = w;
            s.last_h = h;
        }
        fn onPointer(_: *anyopaque, _: f32, _: f32, _: bool, _: u32) void {}
        fn onKey(ptr: *anyopaque, keycode: u32, pressed: bool) bool {
            const s: *State = @ptrCast(@alignCast(ptr));
            if (pressed and keyToClose(keycode)) {
                s.quit = true;
                return true;
            }
            return false;
        }
        fn onResize(_: *anyopaque, _: u32, _: u32) void {}
        fn onClose(ptr: *anyopaque) void {
            const s: *State = @ptrCast(@alignCast(ptr));
            s.quit = true;
        }
        fn isQuit(ptr: *anyopaque) bool {
            const s: *State = @ptrCast(@alignCast(ptr));
            return s.quit;
        }
    };
    var state = State{};
    var win = Window.init(.{});
    win.delegate = .{
        .ptr = &state,
        .on_frame = fns.onFrame,
        .on_pointer = fns.onPointer,
        .on_key = fns.onKey,
        .on_resize = fns.onResize,
        .on_close = fns.onClose,
        .is_quit = fns.isQuit,
    };
    const d = win.delegate.?;
    d.on_frame(d.ptr, 720, 480);
    try std.testing.expectEqual(@as(u32, 1), state.frames);
    try std.testing.expectEqual(@as(u32, 720), state.last_w);
    try std.testing.expect(!d.on_key(d.ptr, 30, true));
    try std.testing.expect(!d.is_quit(d.ptr));
    // Release never quits, even for Escape.
    try std.testing.expect(!d.on_key(d.ptr, 1, false));
    try std.testing.expect(!d.is_quit(d.ptr));
    try std.testing.expect(d.on_key(d.ptr, 1, true));
    try std.testing.expect(d.is_quit(d.ptr));
}

test "eglConfigAttribs requests RGBA8 ES3 window surface terminated by NONE" {
    const a = eglConfigAttribs();
    try std.testing.expect(a[a.len - 1] == c.EGL_NONE);
    var red: c.EGLint = -1;
    var green: c.EGLint = -1;
    var blue: c.EGLint = -1;
    var alpha: c.EGLint = -1;
    var surface_type: c.EGLint = -1;
    var renderable: c.EGLint = -1;
    var i: usize = 0;
    while (i + 1 < a.len) : (i += 2) {
        if (a[i] == c.EGL_NONE) break;
        if (a[i] == c.EGL_RED_SIZE) red = a[i + 1];
        if (a[i] == c.EGL_GREEN_SIZE) green = a[i + 1];
        if (a[i] == c.EGL_BLUE_SIZE) blue = a[i + 1];
        if (a[i] == c.EGL_ALPHA_SIZE) alpha = a[i + 1];
        if (a[i] == c.EGL_SURFACE_TYPE) surface_type = a[i + 1];
        if (a[i] == c.EGL_RENDERABLE_TYPE) renderable = a[i + 1];
    }
    try std.testing.expectEqual(@as(c.EGLint, 8), red);
    try std.testing.expectEqual(@as(c.EGLint, 8), green);
    try std.testing.expectEqual(@as(c.EGLint, 8), blue);
    try std.testing.expectEqual(@as(c.EGLint, 8), alpha);
    try std.testing.expect(surface_type & c.EGL_WINDOW_BIT != 0);
    try std.testing.expect(renderable & c.EGL_OPENGL_ES3_BIT != 0);
}

test "parseTestFrames parses N, rejects null/empty/invalid" {
    try std.testing.expectEqual(@as(?u32, 5), parseTestFrames("5"));
    try std.testing.expectEqual(@as(?u32, 0), parseTestFrames("0"));
    try std.testing.expectEqual(@as(?u32, null), parseTestFrames(null));
    try std.testing.expectEqual(@as(?u32, null), parseTestFrames(""));
    try std.testing.expectEqual(@as(?u32, null), parseTestFrames("abc"));
}

test "fixedToFloat converts wl_fixed 24.8 to float" {
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), fixedToFloat(256), 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), fixedToFloat(128), 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), fixedToFloat(0), 1e-6);
}

test "RED clampSize enforces min 520x360, 0 defers to client size" {
    // Same cases via the Window.clamp method form (default config).
    const win = Window.init(.{});
    // 0 means the compositor defers to the client -> keep default size.
    try std.testing.expectEqual(@as(u32, 720), win.clamp(0, 0).w);
    try std.testing.expectEqual(@as(u32, 480), win.clamp(0, 0).h);
    // Below min clamps to min.
    try std.testing.expectEqual(@as(u32, 520), win.clamp(100, 100).w);
    try std.testing.expectEqual(@as(u32, 360), win.clamp(100, 100).h);
    // Above min passes through.
    try std.testing.expectEqual(@as(u32, 1000), win.clamp(1000, 700).w);
    try std.testing.expectEqual(@as(u32, 700), win.clamp(1000, 700).h);
    // Free function delegates to the default-config method.
    try std.testing.expectEqual(@as(u32, 720), clampSize(0, 0).w);
    try std.testing.expectEqual(@as(u32, 520), clampSize(100, 100).w);
}

test "RED Window.init stores custom config" {
    const win = Window.init(.{
        .app_id = "qs-settings",
        .title = "Settings",
        .width = 800,
        .height = 600,
    });
    try std.testing.expectEqualStrings("qs-settings", std.mem.span(win.config.app_id));
    try std.testing.expectEqualStrings("Settings", std.mem.span(win.config.title));
    try std.testing.expectEqual(@as(u32, 800), win.config.width);
    try std.testing.expectEqual(@as(u32, 600), win.config.height);
    try std.testing.expectEqual(@as(u32, 800), win.win_w);
    try std.testing.expectEqual(@as(u32, 600), win.win_h);
}

test "Window defaults are 720x480 + 520/360 (literals; see ui/theme.zig)" {
    const win = Window.init(.{});
    try std.testing.expectEqual(@as(u32, 720), win.config.width);
    try std.testing.expectEqual(@as(u32, 480), win.config.height);
    try std.testing.expectEqual(@as(u32, 520), win.config.min_width);
    try std.testing.expectEqual(@as(u32, 360), win.config.min_height);
    try std.testing.expectEqualStrings("qs-settings", std.mem.span(win.config.app_id));
    try std.testing.expectEqualStrings("Settings", std.mem.span(win.config.title));
    try std.testing.expect(win.delegate == null);
}

test "RED Window.clamp honors custom mins" {
    const win = Window.init(.{ .width = 720, .height = 480, .min_width = 520, .min_height = 360 });
    try std.testing.expectEqual(@as(u32, 720), win.clamp(0, 0).w);
    try std.testing.expectEqual(@as(u32, 480), win.clamp(0, 0).h);
    try std.testing.expectEqual(@as(u32, 520), win.clamp(100, 100).w);
    try std.testing.expectEqual(@as(u32, 360), win.clamp(100, 100).h);
    try std.testing.expectEqual(@as(u32, 1000), win.clamp(1000, 700).w);
    try std.testing.expectEqual(@as(u32, 700), win.clamp(1000, 700).h);
    const custom = Window.init(.{ .width = 800, .height = 600, .min_width = 400, .min_height = 300 });
    try std.testing.expectEqual(@as(u32, 400), custom.clamp(100, 100).w);
    try std.testing.expectEqual(@as(u32, 300), custom.clamp(100, 100).h);
    try std.testing.expectEqual(@as(u32, 800), custom.clamp(0, 0).w);
    try std.testing.expectEqual(@as(u32, 600), custom.clamp(0, 0).h);
}

test "registry records wp_cursor_shape_manager_v1 global" {
    var state = RegistryState{};
    try std.testing.expect(!state.found.cursor_shape_manager);
    try std.testing.expectEqual(@as(u32, 0), state.cursor_shape_manager_name);
    registryGlobalWithNames(&state, null, 7, "wl_compositor", 4);
    try std.testing.expect(state.found.compositor);
    try std.testing.expect(!state.found.cursor_shape_manager);
    registryGlobalWithNames(&state, null, 12, "wp_cursor_shape_manager_v1", 1);
    try std.testing.expect(state.found.cursor_shape_manager);
    try std.testing.expectEqual(@as(u32, 12), state.cursor_shape_manager_name);
    // First name wins (mirror seat/compositor behavior).
    registryGlobalWithNames(&state, null, 13, "wp_cursor_shape_manager_v1", 1);
    try std.testing.expectEqual(@as(u32, 12), state.cursor_shape_manager_name);
    // Plain Globals handler flags it too.
    var g = Globals{};
    registryGlobal(&g, null, 12, "wp_cursor_shape_manager_v1", 1);
    try std.testing.expect(g.cursor_shape_manager);
}

test "cursor shape mapping matches protocol constants" {
    // frame.zig literals vs generated cursor-shape-v1 header.
    try std.testing.expectEqual(@as(u32, c.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_DEFAULT), frame.shape_default);
    try std.testing.expectEqual(@as(u32, c.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_POINTER), frame.shape_pointer);
    try std.testing.expectEqual(@as(u32, c.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_TEXT), frame.shape_text);
    try std.testing.expectEqual(@as(u32, c.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_EW_RESIZE), frame.shape_ew_resize);
    // Contract: Cursor enum -> shape u32.
    try std.testing.expectEqual(frame.shape_default, frame.cursorShapeFromCursor(.default));
    try std.testing.expectEqual(frame.shape_pointer, frame.cursorShapeFromCursor(.pointer));
    try std.testing.expectEqual(frame.shape_text, frame.cursorShapeFromCursor(.text));
    try std.testing.expectEqual(frame.shape_ew_resize, frame.cursorShapeFromCursor(.ew_resize));
    // Change-only gate + sentinel default on fresh windows.
    try std.testing.expect(frame.shouldApplyShape(frame.shape_sentinel, frame.shape_default));
    try std.testing.expect(!frame.shouldApplyShape(frame.shape_default, frame.shape_default));
    const win = Window.init(.{});
    try std.testing.expectEqual(@as(u32, 0), win.enter_serial);
    try std.testing.expect(win.shape_device == null);
    try std.testing.expect(win.cursor_shape_manager == null);
    try std.testing.expectEqual(frame.shape_sentinel, win.last_shape);
}

// ---- Listener wiring contract (regression guard) ------------------
//
// Two properties MUST hold for every `*_add_listener` call, and neither
// is checked by the compiler or by any runtime assert:
//
//   1. NO NULL SLOTS. libwayland dispatches through the listener struct
//      with no null check; a null member means libffi calls address
//      0x4 the instant the compositor sends that event -> SIGSEGV.
//      This is how `wl_pointer.axis_value120` (added in Wayland 1.22)
//      killed qs-settings: it was simply never wired.
//
//   2. THE STRUCT MUST OUTLIVE THE PROXY. wl_proxy_add_listener does
//      NOT copy the struct - it stores the caller's pointer
//      (`mov %rsi,0x8(%rdi)` in libwayland). A listener declared as a
//      local in the function that registers it dangles the moment that
//      function returns, and the proxy then calls into freed stack.
//
// assertListenerComplete walks the type's fields reflectively so a NEW
// protocol version adding an event fails the build instead of shipping.
// Assert every function-pointer member of a listener struct is non-null.
// Reflection is over the REAL cimport type, so when a newer Wayland
// header adds an event, the new field is simply not assigned and this
// fails at `zig build native-test` instead of segfaulting at runtime.
fn assertListenerComplete(comptime T: type, listener: T) !void {
    const fields = @typeInfo(T).@"struct".fields;
    inline for (fields) |f| {
        const ti = @typeInfo(@TypeOf(@field(listener, f.name)));
        // Only optional C-callback members are listener slots; skip anything
        // else (a protocol is free to add a plain data member).
        if (ti != .optional) continue;
        const child = ti.optional.child;
        const child_ti = @typeInfo(child);
        if (child_ti != .@"fn") continue;
        if (child_ti.@"fn".calling_convention != .c) continue;
        try std.testing.expect(@field(listener, f.name) != null);
    }
}

test "RED every wayland listener has a non-null handler in EVERY slot" {
    // Pointer: a new header can add members (axis_value120, warp) at any
    // time. Reflecting over the real struct type means an unwired member
    // fails here rather than crashing on the first scroll.
    try assertListenerComplete(c.struct_wl_pointer_listener, pointerListener());
    try assertListenerComplete(c.struct_wl_keyboard_listener, keyboardListener());
    try assertListenerComplete(c.struct_wl_seat_listener, seatListener());
    try assertListenerComplete(c.struct_wl_registry_listener, registryListener());
    try assertListenerComplete(c.struct_wl_callback_listener, callbackListener());
    try assertListenerComplete(c.struct_xdg_wm_base_listener, xdgWmBaseListener());
    try assertListenerComplete(c.struct_xdg_surface_listener, xdgSurfaceListener());
    try assertListenerComplete(c.struct_xdg_toplevel_listener, xdgToplevelListener());
}

test "RED listener structs are owned by Window so they outlive their proxy" {
    // Storage lives on Window, which is alive for the whole run() call.
    // A local `var full = ...` inside seatCapabilities() would compile,
    // pass every other test, and then segfault on the first pointer
    // event, because libwayland keeps the pointer after the frame dies.
    // Each field must therefore be present AND complete — ownership alone
    // is not enough, it must not smuggle in null slots.
    const win = Window.init(.{});
    inline for (.{
        .{ "pointer", c.struct_wl_pointer_listener, win.pointer_listener },
        .{ "keyboard", c.struct_wl_keyboard_listener, win.keyboard_listener },
        .{ "seat", c.struct_wl_seat_listener, win.seat_listener },
        .{ "registry", c.struct_wl_registry_listener, win.registry_listener },
        .{ "callback", c.struct_wl_callback_listener, win.callback_listener },
        .{ "wm_base", c.struct_xdg_wm_base_listener, win.wm_listener },
        .{ "xdg_surface", c.struct_xdg_surface_listener, win.xdg_surface_listener },
        .{ "xdg_toplevel", c.struct_xdg_toplevel_listener, win.toplevel_listener },
    }) |entry| {
        _ = entry[0];
        try assertListenerComplete(@TypeOf(entry[2]), entry[2]);
    }
}
