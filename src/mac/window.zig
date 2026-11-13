//! Real macOS window backend (Cocoa/AppKit).

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

/// Headless-render result, kept identical to `core/window_portable.zig` so code that calls `renderHeadless()` works on both backends.
pub const RenderResult = struct {
    width: u32,
    height: u32,
    painted_pixels: usize,
};

pub const Window = struct {
    state: contract.WindowState = contract.WindowState.init(.{}),
    /// Same public field name as the other backends, so `window.delegate = host.delegate()` is one line on every platform.
    delegate: ?Delegate = null,

    /// The Cocoa handle, null until `run()` (or `renderHeadless()`) creates it.
    handle: ?*c.GlinCocoaWindow = null,
    /// The blit destination, allocated on first use and reused every frame.
    blit_buf: []u8 = &.{},
    /// The cursor shape last handed to AppKit, so a frame that did not change it costs nothing.
    last_shape: u32 = 0,
    /// Is the primary button currently held?
    left_held: bool = false,
    /// Frames composited so far.
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

    /// Open a real window and run the AppKit event loop.
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

    /// `-drawRect:`.
    fn onFrame(p: ?*anyopaque) callconv(.c) void {
        const self = ctx(p);
        const w = self.state.win_w;
        const h = self.state.win_h;

        // Adopt at most one coalesced resize per frame (macos_adapter), so a live drag lays out once per drawn frame instead of per event.
        if (adapter.applyPendingResize(&self.state)) {
            onResized(self);
        }
        if (adapter.resolveQuit(&self.state)) return;

        // Render at the display's backing scale, so text is rasterized at device resolution rather than upscaled.
        if (self.handle) |win_handle| soft.setRenderScale(@floatCast(c.glin_cocoa_backing_scale(win_handle)));

        const d = self.delegate orelse return;
        d.on_frame(d.ptr, w, h);
        self.applyCursor();
        self.presentFrame();
    }

    /// Apply the cursor shape the frame resolved, when it changed.
    fn applyCursor(self: *Window) void {
        if (self.handle == null) return;
        const shape = frame_mod.currentShape();
        if (shape == self.last_shape) return;
        self.last_shape = shape;
        c.glin_cocoa_set_cursor(@intCast(shape));
    }

    /// Copy the surface the delegate just drew into the shim's bitmap.
    fn presentFrame(self: *Window) void {
        const handle = self.handle orelse return;
        const surface = soft.currentSurface() orelse return;
        if (!present.blitSizeValid(surface.width, surface.height)) return;

        const need = present.blitBufLen(surface.width, surface.height);
        if (self.blit_buf.len < need) {
            self.blit_buf = std.heap.c_allocator.alloc(u8, need) catch return;
        }
        // The hand-off contract (NO channel swap, NO vertical flip) lives in the tested helper; see mac/present.zig for how that was measured.
        present.identityRgba8(surface.pixels, self.blit_buf, surface.width, surface.height);
        self.diag_frames += 1;
        if (self.diag_frames == 1) reportFirstFrame(self.blit_buf, surface);
        if (std.c.getenv("GLIN_DUMP_SURFACE")) |p| dumpRaw(p, surface.pixels);
        if (std.c.getenv("GLIN_DUMP_BGRA")) |p| dumpRaw(p, self.blit_buf);
        c.glin_cocoa_present(handle, self.blit_buf.ptr, @intCast(surface.width), @intCast(surface.height));
    }

    /// Apply a coalesced resize.
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
        const w = self.state.win_w;
        const h = self.state.win_h;

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

    /// Drive one real frame into a software surface and report what was drawn.
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

/// Write raw bytes to a file.
fn dumpRaw(path: [*:0]const u8, bytes: []const u8) void {
    const f = std.c.fopen(path, "wb") orelse return;
    _ = std.c.fwrite(bytes.ptr, 1, bytes.len, f);
    _ = std.c.fclose(f);
    std.log.info("wrote {d} raw bytes to {s}", .{ bytes.len, std.mem.span(path) });
}
/// macOS will NOT let an automated test screenshot this app's window without Screen Recording permission (`screencapture` then captures only the.
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
