// Real macOS window backend (Cocoa/AppKit).

const std = @import("std");
const log = @import("../core/log.zig");
const builtin = @import("builtin");
const contract = @import("../core/window_contract.zig");
const keymap = @import("keymap.zig");
const adapter = @import("adapter.zig");
const input_macos = @import("input.zig");
const present = @import("present.zig");
const soft = @import("../core/render_software.zig");
const frame_mod = @import("../core/frame.zig");

// The shim header is plain C by design (see mac/shim.h), so @cImport never has to survive Objective-C macros or CoreGraphics typedefs.
const c = @cImport({
    @cInclude("shim.h");
});

// NOTE: no render/text/frame re-exports here.

// Shared, platform-neutral window API.
pub const Placement = contract.Placement;
pub const computePlacement = contract.computePlacement;
pub const min_width = contract.min_width;
pub const min_height = contract.min_height;
pub const clampSize = contract.clampSize;
pub const keyToClose = contract.keyToClose;
pub const centeredAnchor = contract.centeredAnchor;
pub const LayerSize = contract.LayerSize;
pub const layerSize = contract.layerSize;
pub const eglConfigAttribs = contract.eglConfigAttribs;
pub const parseTestFrames = contract.parseTestFrames;
pub const pointerPosChanged = contract.pointerPosChanged;
pub const FrameStep = contract.FrameStep;
pub const frameStep = contract.frameStep;
pub const WindowConfig = contract.WindowConfig;
pub const Delegate = contract.Delegate;

// Headless-render result, kept identical to `core/window_portable.zig` so code that calls `renderHeadless()` works on both backends.
pub const RenderResult = struct {
    width: u32,
    height: u32,
    painted_pixels: usize,
};

pub const Window = struct {
    state: contract.WindowState = contract.WindowState.init(.{}),
    // Same public field name as the other backends, so `window.delegate = host.delegate()` is one line on every platform.
    delegate: ?Delegate = null,

    // The Cocoa handle, null until `run()` (or `renderHeadless()`) creates it.
    handle: ?*c.GlinCocoaWindow = null,
    // The blit destination, allocated on first use and reused every frame.
    blit_buf: []u8 = &.{},
    // The cursor shape last handed to AppKit, so a frame that did not change it costs nothing.
    last_shape: u32 = 0,
    // The size the last completed layout used; the pointer is flipped in THIS space, never a pending one.
    layout_w: u32 = 0,
    layout_h: u32 = 0,
    // Is the primary button currently held?
    left_held: bool = false,
    // The last pointer state delivered, so a motion event that moves nothing costs no repaint.
    last_ptr_x: f64 = -1e9,
    last_ptr_y: f64 = -1e9,
    last_ptr_pressed: bool = false,
    // Frames composited so far.
    diag_frames: u32 = 0,

    pub fn init(alloc: std.mem.Allocator, config: WindowConfig) Window {
        // The allocator is accepted for signature parity with the web backend, which genuinely needs it (`wasm_allocator` is the only allocator that grows a.
        _ = alloc;
        return .{ .state = contract.WindowState.init(config) };
    }

    pub fn clamp(self: Window, w: u32, h: u32) struct { w: u32, h: u32 } {
        return self.state.clamp(w, h);
    }

    pub fn appDelegate(self: Window) ?Delegate {
        return self.delegate;
    }

    // Open a real window and run the AppKit event loop.
    pub fn run(self: *Window) !void {
        // Headless test builds must never touch Cocoa: `zig build test` runs on every platform and must not need a window server.
        if (builtin.is_test) return;

        const d = self.delegate orelse return error.NoDelegate;
        self.state.delegate = d;

        // `config.title` is already a NUL-terminated string, which is exactly what the C `const char *` parameter wants, so it passes straight through with no.
        const cfg = self.state.config;
        const handle = c.glin_cocoa_window_create(
            cfg.title,
            @intCast(cfg.width),
            @intCast(cfg.height),
            @intCast(cfg.min_width),
            @intCast(cfg.min_height),
        ) orelse return error.NoWindowServer;
        self.handle = handle;
        defer self.handle = null;

        c.glin_cocoa_window_set_callbacks(
            handle,
            onFrame,
            onPointer,
            onScroll,
            onKey,
            onResize,
            onClose,
            self,
        );

        // The window may not be the size that was asked for: macOS constrains it to the screen's visible frame and sends no resize for that, so the first frame

        // would lay out at a size the view does not have.
        var cw: c_int = 0;
        var ch: c_int = 0;
        c.glin_cocoa_content_size(handle, &cw, &ch);
        if (cw > 0 and ch > 0) _ = adapter.noteResize(&self.state, @intCast(cw), @intCast(ch));

        std.log.info(
            "macOS window: {d}x{d} ({s})",
            .{ cfg.width, cfg.height, cfg.title },
        );

        const requested: i32 = blk: {
            // Same env var, same helper, same semantics as the Wayland backend's `testFramesFromEnv`, so the two run under one harness.
            const raw = std.c.getenv("QS_SETTINGS_TEST_FRAMES") orelse break :blk 0;
            const n = contract.parseTestFrames(std.mem.span(raw)) orelse break :blk 0;
            break :blk @intCast(n);
        };
        // A cap above one is unreachable through AppKit, so it is clamped here rather than handed to the shim, where it would hang instead of failing.
        const max_frames = adapter.effectiveMaxFrames(requested);
        if (max_frames != requested) {
            log.warn(
                "QS_SETTINGS_TEST_FRAMES={d} clamped to {d}: Cocoa composites one frame and then stops redrawing",
                .{ requested, max_frames },
            );
        }
        c.glin_cocoa_window_run(handle, max_frames);
    }

    // ---- callbacks handed to the shim ----

    fn ctx(p: ?*anyopaque) *Window {
        return @ptrCast(@alignCast(p.?));
    }

    // `-drawRect:`.
    fn onFrame(p: ?*anyopaque) callconv(.c) void {
        const self = ctx(p);
        // Adopt a coalesced resize FIRST (macos_adapter): the frame must lay out at the size it is about to draw, or the pointer space and the boxes disagree.
        if (adapter.applyPendingResize(&self.state)) {
            onResized(self);
        }
        if (adapter.resolveQuit(&self.state)) return;
        const w = self.state.win_w;
        const h = self.state.win_h;

        // Render at the display's backing scale, so text is rasterized at device resolution rather than upscaled.
        if (self.handle) |win_handle| soft.setRenderScale(@floatCast(c.glin_cocoa_backing_scale(win_handle)));
        // The components snap hairlines to this grid, so the caret lands on whole device pixels.
        frame_mod.setPixelScale(soft.renderScale());

        const d = self.delegate orelse return;
        d.on_frame(d.ptr, w, h);
        // Record the space those boxes were laid out in, so a pointer event that arrives before the next frame flips in it.
        self.layout_w = w;
        self.layout_h = h;
        self.applyCursor();
        self.presentFrame();
    }

    // Start or stop the frame pump. An app with its own animation calls this with `true` while it is running and `false` when it stops; the pump redraws at

    // the display's refresh rate in between.
    pub fn setAnimating(self: *Window, on: bool) void {
        if (self.handle) |handle| c.glin_cocoa_set_animating(handle, if (on) 1 else 0);
    }

    // Apply the cursor shape the frame resolved, when it changed.
    fn applyCursor(self: *Window) void {
        if (self.handle == null) return;
        const shape = frame_mod.currentShape();
        if (shape == self.last_shape) return;
        self.last_shape = shape;
        c.glin_cocoa_set_cursor(@intCast(shape));
    }

    // Copy the surface the delegate just drew into the shim's bitmap.
    fn presentFrame(self: *Window) void {
        const handle = self.handle orelse return;
        const surface = soft.currentSurface() orelse return;
        if (!present.blitSizeValid(surface.width, surface.height)) return;

        // No intermediate buffer: the hand-off is byte-identical (NO channel swap, NO vertical flip — see mac/present.zig for how that was measured), and the

        // shim copies into its bitmap anyway. Copying here as well cost a second full-surface memcpy per frame: 27 MB at 2x on a large window, ~10 ms of the

        // budget for nothing.
        self.diag_frames += 1;
        if (self.diag_frames == 1) reportFirstFrame(surface.pixels, surface);
        if (std.c.getenv("GLIN_DUMP_SURFACE")) |p| dumpRaw(p, surface.pixels);
        c.glin_cocoa_present(handle, surface.pixels.ptr, @intCast(surface.width), @intCast(surface.height));
    }

    // Apply a coalesced resize.
    fn onResized(_: *Window) void {}

    fn onPointer(
        p: ?*anyopaque,
        kind: c_int,
        button_number: c_int,
        x: f64,
        y: f64,
        _: c_int,
    ) callconv(.c) void {
        const self = ctx(p);
        const d = self.delegate orelse return;
        // AppKit delivers motion events nobody asked for (a noisy device, a re-keyed window), and repainting on one of
        // those is what keeps an idle app at 60 frames a second. A pointer event that changes nothing is dropped here.
        const pressed_now = kind == input_macos.DOWN or (kind == input_macos.MOTION and self.left_held);
        if (x == self.last_ptr_x and y == self.last_ptr_y and pressed_now == self.last_ptr_pressed) return;
        self.last_ptr_x = x;
        self.last_ptr_y = y;
        self.last_ptr_pressed = pressed_now;
        // The last layout's size, not the window's: a resize adopted but not yet drawn would shift every hit test.
        const space = contract.pointerSpace(self.layout_w, self.layout_h, self.state.win_w, self.state.win_h);
        const w = space.w;
        const h = space.h;

        // Translate to the Delegate's contract: evdev button code on a transition, 0 on motion, and the y axis flipped.
        const t = input_macos.translate(w, h, .{
            .kind = @intCast(kind),
            .button_number = button_number,
            .x = @floatCast(x),
            .y = @floatCast(y),
        }, self.left_held);
        if (t.pressed and kind == input_macos.DOWN) self.left_held = true;
        if (!t.pressed and kind == input_macos.UP) self.left_held = false;

        self.state.needs_draw = true;
        d.on_pointer(d.ptr, t.x, t.y, t.pressed, t.button);
        // AppKit only redraws when asked, so ask.
        c.glin_cocoa_invalidate(self.handle);
    }

    fn onScroll(p: ?*anyopaque, dx: f64, dy: f64) callconv(.c) void {
        const self = ctx(p);
        const d = self.delegate orelse return;
        const delta = d.on_scroll orelse return;
        // A zero delta is not a scroll: repainting for one is what made an idle window burn a core.
        if (dx == 0 and dy == 0) return;
        const s = adapter.scrollDelta(@floatCast(dx), @floatCast(dy));
        self.state.needs_draw = true;
        delta(d.ptr, s.dx, s.dy);
        // Scrolling moves the view; AppKit must be told or nothing repaints.
        c.glin_cocoa_invalidate(self.handle);
    }

    fn onKey(p: ?*anyopaque, mac_keycode: c_int, pressed: c_int, text: ?[*:0]const u8) callconv(.c) c_int {
        const self = ctx(p);
        const d = self.delegate orelse return 0;
        // Text first: AppKit already applied Caps Lock, Shift and the keyboard layout, so this path types `A`, `*`, `(` and `é`, which a keycode table cannot.
        if (pressed != 0) {
            if (d.on_text) |on_text| {
                if (text) |t| {
                    const composed = std.mem.span(t);
                    if (composed.len != 0) {
                        self.state.needs_draw = true;
                        on_text(d.ptr, composed);
                        // The glyph is in the buffer now, so the window must repaint.
                        c.glin_cocoa_invalidate(self.handle);
                        return 1;
                    }
                }
            }
        }
        // Everything else is a key: translate to the evdev code the Delegate contract promises, so the widget layer needs no macOS awareness.
        const ev = keymap.evdevFor(@intCast(mac_keycode));
        if (ev == keymap.KEY_NONE) return 0;
        self.state.needs_draw = true;
        const consumed = d.on_key(d.ptr, ev, pressed != 0);
        // Typing changes the display; without this the keystroke is consumed but the window keeps showing the old value.
        c.glin_cocoa_invalidate(self.handle);
        if (adapter.resolveQuit(&self.state)) c.glin_cocoa_quit(self.handle);
        return if (consumed) 1 else 0;
    }

    fn onResize(p: ?*anyopaque, w: c_int, h: c_int) callconv(.c) void {
        const self = ctx(p);
        if (w <= 0 or h <= 0) return;
        // Record only: the delegate is notified from applyPendingResize, once per drawn frame.
        _ = adapter.noteResize(&self.state, @intCast(w), @intCast(h));
    }

    fn onClose(p: ?*anyopaque) callconv(.c) void {
        const self = ctx(p);
        const d = self.delegate orelse return;
        d.on_close(d.ptr);
        self.state.quit = true;
        c.glin_cocoa_quit(self.handle);
    }

    // Drive one real frame into a software surface and report what was drawn.
    pub fn renderHeadless(self: *Window) !RenderResult {
        const d = self.delegate orelse return error.NoDelegate;
        const w = self.state.win_w;
        const h = self.state.win_h;
        if (w == 0 or h == 0) return error.InvalidSize;
        d.on_frame(d.ptr, w, h);

        const surface = soft.currentSurface() orelse return error.NoSurface;
        if (surface.width == 0 or surface.height == 0) return error.EmptySurface;

        const clear = surface.clear_rgb;
        var painted: usize = 0;
        var i: usize = 0;
        while (i + 3 < surface.pixels.len) : (i += 4) {
            const r = @as(f32, @floatFromInt(surface.pixels[i]));
            const g = @as(f32, @floatFromInt(surface.pixels[i + 1]));
            const b = @as(f32, @floatFromInt(surface.pixels[i + 2]));
            if (r != clear[0] or g != clear[1] or b != clear[2]) painted += 1;
        }
        return .{ .width = surface.width, .height = surface.height, .painted_pixels = painted };
    }
};

// Write raw bytes to a file.
fn dumpRaw(path: [*:0]const u8, bytes: []const u8) void {
    const f = std.c.fopen(path, "wb") orelse return;
    _ = std.c.fwrite(bytes.ptr, 1, bytes.len, f);
    _ = std.c.fclose(f);
    std.log.info("wrote {d} raw bytes to {s}", .{ bytes.len, std.mem.span(path) });
}
// macOS will NOT let an automated test screenshot this app's window without Screen Recording permission (`screencapture` then captures only the.
fn reportFirstFrame(bgra: []const u8, surface: *const soft.Surface) void {
    var painted: usize = 0;
    var i: usize = 0;
    while (i + 3 < surface.pixels.len) : (i += 4) {
        if (surface.pixels[i] != surface.clear_rgb[0] or
            surface.pixels[i + 1] != surface.clear_rgb[1] or
            surface.pixels[i + 2] != surface.clear_rgb[2]) painted += 1;
    }
    // FNV-1a over the composited bytes: a one-line "did anything actually change" probe that a flat window cannot fake.
    var hash: u64 = 0xcbf29ce484222325;
    for (bgra) |byte| {
        hash ^= byte;
        hash *%= 0x100000001b3;
    }
    std.log.info(
        "macOS first frame: {d}x{d}, {d} painted pixels, blit checksum 0x{x}",
        .{ surface.width, surface.height, painted, hash },
    );
    // Optional raw dump of the composited bytes, for eyeballing a frame on a machine where screencapture cannot see our window.
    if (std.c.getenv("GLIN_DUMP_BGRA")) |path| {
        const f = std.c.fopen(path, "wb") orelse return;
        _ = std.c.fwrite(bgra.ptr, 1, bgra.len, f);
        _ = std.c.fclose(f);
        std.log.info("wrote {d} bytes of BGRA to {s}", .{ bgra.len, path });
    }
}
