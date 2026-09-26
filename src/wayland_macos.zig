//! Real macOS window backend (Cocoa/AppKit).
//!
//! The peer of `wayland.zig`, and the thing `platform/window_contract.zig`
//! anticipated when it said the native Wayland Window and "the macOS Window
//! both hold one of these".
//!
//! The division of labour is deliberate:
//!   - `cocoa_window.m` owns the NSWindow/NSView and turns AppKit events into
//!     C callbacks. It makes no decisions and is the only untestable part.
//!   - This file owns ALL the logic, and every decision it makes goes through
//!     a pure, unit-tested helper in `platform/`:
//!       * keycodes  -> platform/keymap_macos.zig  (mac virtual -> evdev)
//!       * the y axis -> platform/macos_adapter.zig (AppKit bottom-left -> top-left)
//!       * pixels     -> platform/blit.zig         (RGBA8 -> BGRA + row flip)
//!       * resizes    -> platform/macos_adapter.zig (coalesce, apply once)
//!
//! So a mistake in any of those four shows up as a failing test on every
//! platform rather than as "the macOS window looks a bit odd".
//!
//! Test builds never reach Cocoa at all: `wayland_api.zig` selects
//! `wayland_portable.zig` under `builtin.is_test`, which is what keeps the
//! cross-platform test count identical. That also means the Linux Wayland
//! module is not restructured by any of this.

const std = @import("std");
const builtin = @import("builtin");
const contract = @import("platform/window_contract.zig");
const keymap = @import("platform/keymap_macos.zig");
const adapter = @import("platform/macos_adapter.zig");
const blit = @import("platform/blit.zig");
const soft = @import("wayland/render_software.zig");

// The shim header is plain C by design (see cocoa_window.h), so @cImport
// never has to survive Objective-C macros or CoreGraphics typedefs.
const c = @cImport({
    @cInclude("cocoa_window.h");
});

pub const render = @import("wayland/render.zig");
pub const text = @import("wayland/text_backend.zig");
pub const frame = @import("wayland/frame.zig");

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

/// Headless-render result, kept identical to `wayland_portable.zig` so code
/// that calls `renderHeadless()` works on both backends.
pub const RenderResult = struct {
    width: u32,
    height: u32,
    painted_pixels: usize,
};

pub const Window = struct {
    state: contract.WindowState = contract.WindowState.init(.{}),
    /// Same public field name as the other backends, so
    /// `window.delegate = host.delegate()` is one line on every platform.
    delegate: ?Delegate = null,

    /// The Cocoa handle, null until `run()` (or `renderHeadless()`) creates it.
    handle: ?*c.GlinCocoaWindow = null,
    /// The blit destination, allocated on first use and reused every frame.
    blit_buf: []u8 = &.{},
    /// Frames composited so far. Used to report only the first one, so a
    /// long interactive run does not spam the log.
    diag_frames: u32 = 0,

    pub fn init(config: WindowConfig) Window {
        return .{ .state = contract.WindowState.init(config) };
    }

    pub fn clamp(self: Window, w: u32, h: u32) struct { w: u32, h: u32 } {
        return self.state.clamp(w, h);
    }

    pub fn appDelegate(self: Window) ?Delegate {
        return self.delegate;
    }

    /// Open a real window and run the AppKit event loop. Blocks until quit.
    ///
    /// `QS_SETTINGS_TEST_FRAMES` caps the frame count (parsed by the shared
    /// `contract.parseTestFrames`) so CI gets a deterministic run it can
    /// screenshot, instead of an interactive one that never returns.
    pub fn run(self: *Window) !void {
        // Headless test builds must never touch Cocoa: `zig build test` runs
        // on every platform and must not need a window server.
        if (builtin.is_test) return;

        const d = self.delegate orelse return error.NoDelegate;
        self.state.delegate = d;

        // `config.title` is already a NUL-terminated string, which is exactly
        // what the C `const char *` parameter wants, so it passes straight
        // through with no copy and no lifetime concern.
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

        const max_frames: i32 = blk: {
            // Same env var, same helper, same semantics as the Wayland
            // backend's `testFramesFromEnv`, so the two run under one harness.
            const raw = std.c.getenv("QS_SETTINGS_TEST_FRAMES") orelse break :blk 0;
            const n = contract.parseTestFrames(std.mem.span(raw)) orelse break :blk 0;
            break :blk @intCast(n);
        };
        c.glin_cocoa_window_run(handle, max_frames);
    }

    // ---- callbacks handed to the shim ----

    fn ctx(p: ?*anyopaque) *Window {
        return @ptrCast(@alignCast(p.?));
    }

    /// `-drawRect:`. Runs the delegate's frame (Clay layout + the software
    /// rasterizer), then hands the converted pixels back to the shim, which
    /// composites them.
    fn onFrame(p: ?*anyopaque) callconv(.c) void {
        const self = ctx(p);
        const w = self.state.win_w;
        const h = self.state.win_h;

        // Adopt at most one coalesced resize per frame (macos_adapter), so a
        // live drag lays out once per drawn frame instead of per event.
        if (adapter.applyPendingResize(&self.state)) {
            onResized(self);
        }
        if (adapter.resolveQuit(&self.state)) return;

        const d = self.delegate orelse return;
        d.on_frame(d.ptr, w, h);
        self.present();
    }

    /// Copy the surface the delegate just drew into the shim's bitmap.
    fn present(self: *Window) void {
        const handle = self.handle orelse return;
        const surface = soft.currentSurface() orelse return;
        if (!blit.blitSizeValid(surface.width, surface.height)) return;

        const need = blit.blitBufLen(surface.width, surface.height);
        if (self.blit_buf.len < need) {
            self.blit_buf = std.heap.c_allocator.alloc(u8, need) catch return;
        }
        // The channel swap and the row flip both live in the tested helper.
        blit.rgba8ToBgraFlipped(surface.pixels, self.blit_buf, surface.width, surface.height);
        self.diag_frames += 1;
        if (self.diag_frames == 1) reportFirstFrame(self.blit_buf, surface);
        c.glin_cocoa_present(handle, self.blit_buf.ptr, @intCast(surface.width), @intCast(surface.height));
    }

    /// Apply a coalesced resize. There is no surface to resize here: the
    /// renderer owns it and the Host resizes it at the start of the next
    /// frame, so all this needs to do is note that the size moved (which
    /// `applyPendingResize` already did) and keep the blit buffer correct,
    /// which `present` handles by length.
    ///
    /// Kept as a named function so `onFrame` reads as the four steps it is,
    /// and so the empty body is documented rather than looking like an
    /// oversight.
    fn onResized(_: *Window) void {}

    fn onPointer(p: ?*anyopaque, x: f64, y: f64, pressed: c_int, button: c_int) callconv(.c) void {
        const self = ctx(p);
        const d = self.delegate orelse return;
        const w = self.state.win_w;
        const h = self.state.win_h;
        // AppKit's y is bottom-left; the toolkit's is top-left. This flip is
        // the difference between a working keypad and a mirrored one.
        const pt = adapter.toToolkitPoint(w, h, @floatCast(x), @floatCast(y));
        self.state.needs_draw = true;
        d.on_pointer(d.ptr, pt.x, pt.y, pressed != 0, @intCast(button));
    }

    fn onScroll(p: ?*anyopaque, dx: f64, dy: f64) callconv(.c) void {
        const self = ctx(p);
        const d = self.delegate orelse return;
        const delta = d.on_scroll orelse return;
        const s = adapter.scrollDelta(@floatCast(dx), @floatCast(dy));
        self.state.needs_draw = true;
        delta(d.ptr, s.dx, s.dy);
    }

    fn onKey(p: ?*anyopaque, mac_keycode: c_int, pressed: c_int) callconv(.c) c_int {
        const self = ctx(p);
        const d = self.delegate orelse return 0;
        // Translate to the evdev code the Delegate contract promises, so the
        // widget layer and `components.input` need no macOS awareness.
        const ev = keymap.evdevFor(@intCast(mac_keycode));
        if (ev == keymap.KEY_NONE) return 0;
        self.state.needs_draw = true;
        const consumed = d.on_key(d.ptr, ev, pressed != 0);
        return if (consumed) 1 else 0;
    }

    fn onResize(p: ?*anyopaque, w: c_int, h: c_int) callconv(.c) void {
        const self = ctx(p);
        if (w <= 0 or h <= 0) return;
        // Record only: the delegate is notified from applyPendingResize, once
        // per drawn frame.
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
    /// Exposed so tools and the demo's headless path keep working on macOS
    /// without a window server.
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

/// Report the first composited frame.
///
/// macOS will NOT let an automated test screenshot this app's window without
/// Screen Recording permission (`screencapture` then captures only the
/// desktop), so a screenshot is not a usable proof — on CI or on a stock
/// machine. Reporting the frame's size, its painted-pixel count and a checksum
/// of the exact bytes handed to CoreGraphics gives CI something it can assert
/// on, and proves the whole chain ran: layout -> rasterizer -> blit -> CG.
fn reportFirstFrame(bgra: []const u8, surface: *const soft.Surface) void {
    var painted: usize = 0;
    var i: usize = 0;
    while (i + 3 < surface.pixels.len) : (i += 4) {
        if (surface.pixels[i] != surface.clear_rgb[0] or
            surface.pixels[i + 1] != surface.clear_rgb[1] or
            surface.pixels[i + 2] != surface.clear_rgb[2]) painted += 1;
    }
    // FNV-1a over the composited bytes: a one-line "did anything actually
    // change" probe that a flat window cannot fake.
    var hash: u64 = 0xcbf29ce484222325;
    for (bgra) |byte| {
        hash ^= byte;
        hash *%= 0x100000001b3;
    }
    std.log.info(
        "macOS first frame: {d}x{d}, {d} painted pixels, blit checksum 0x{x}",
        .{ surface.width, surface.height, painted, hash },
    );
    // Optional raw dump of the composited bytes, for eyeballing a frame on a
    // machine where screencapture cannot see our window. Off by default.
    if (std.c.getenv("GLIN_DUMP_BGRA")) |path| {
        const f = std.c.fopen(path, "wb") orelse return;
        _ = std.c.fwrite(bgra.ptr, 1, bgra.len, f);
        _ = std.c.fclose(f);
        std.log.info("wrote {d} bytes of BGRA to {s}", .{ bgra.len, path });
    }
}
