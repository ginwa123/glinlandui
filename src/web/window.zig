//! Real browser window backend.
//!
//! The peer of `linux/window.zig` and `mac/window.zig`, and the third
//! implementation of the contract `core/window_contract.zig` anticipated.
//!
//! ## The one structural difference: control is INVERTED
//!
//! Both native backends own their event loop. `linux/window.zig` polls a Wayland
//! fd and a dirty flag; `mac/window.zig` hands `[NSApp run]` the process and is
//! called back from `-drawRect:`. Neither can work here: a browser owns its event
//! loop and a wasm module has no way to block it, because blocking the main thread
//! freezes the tab.
//!
//! So the direction of control flips. `run()` **arms and returns**, and the page
//! drives everything afterwards:
//!
//!     JS                                  this file
//!     ───────────────────────────────────  ─────────────────────────────────
//!     rAF → glin_web_needs_frame()   →    needsFrame()   (a dirty-flag read)
//!     rAF → glin_web_frame(t)        →    frame()        (layout + rasterize)
//!     canvas.putImageData(surface)   ←    surfaceInfo()  (ptr/len/w/h only)
//!     pointerdown/move/up            →    pointer()
//!     wheel                          →    wheel()
//!     keydown/keyup                  →    key()
//!     ResizeObserver                 →    resize()
//!     pagehide                       →    shutdown()
//!
//! Every decision on the right-hand side is pure Zig — `keymap.zig`,
//! `input.zig`, `adapter.zig`, `present.zig` — and every one of those is in the
//! cross-platform parity suite. `web/shim.js` translates DOM properties into
//! these calls and makes no decisions at all, which is the same division of
//! labour `mac/shim.m` has.
//!
//! ## Why reading the dirty flag BEFORE doing work matters
//!
//! `core/frame.zig` documents that its engine-side output-hash frame skip
//! (`FrameMemo`) is disabled, because on Wayland `glClear → on_frame →
//! eglSwapBuffers` sits inside the run loop and a skip after the clear presents a
//! blank buffer. It says a correct skip must suppress clear + draw + swap
//! *together*, and that restructuring was ruled out.
//!
//! Here that restructuring is free, because the page controls the present:
//! `needs_frame()` is consulted first, so an idle UI costs one i32 read per
//! animation frame — no layout, no rasterization, no pixel copy. That is the
//! atomic "clear + draw + swap together" the note asked for.
//!
//! ## No logging, no `std.log`
//!
//! `mac/window.zig` reports the first frame as a log line CI greps. A browser has
//! no stderr, and `std.debug.print` needs a writer and a lock that a
//! freestanding wasm module does not have. So the same information is exposed as
//! NUMBERS — `painted_pixels`, `frame_hash`, `frames` — which the page can log if
//! it wants and `web/smoke.mjs` asserts. The measurement itself is lazy: it runs
//! only when something asks, so a browser that never reads the numbers never pays
//! for the O(pixels) scan.
//!
//! ## Test builds never reach any of this
//!
//! `platform.zig` selects `core/window_portable.zig` under `builtin.is_test`, so
//! `zig build test` analyses neither this file nor `wasm_allocator`, and the
//! cross-platform test count is untouched (invariant I2).

const std = @import("std");
const builtin = @import("builtin");
const contract = @import("../core/window_contract.zig");
const keymap = @import("keymap.zig");
const adapter = @import("adapter.zig");
const input_web = @import("input.zig");
const present = @import("present.zig");
const soft = @import("../core/render_software.zig");
const glyphs = @import("../core/glyphs.zig");

// NOTE: no render/text/frame re-exports here. See the same note in
// core/window_portable.zig: this module is imported by platform.zig, and the
// core facades resolve back to platform.zig, so re-exporting them would close an
// import cycle. Nothing used them; use `glinlandui.render` instead.

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

/// Headless-render result, kept identical to `core/window_portable.zig` and
/// `mac/window.zig` so code that calls `renderHeadless()` works on all backends.
pub const RenderResult = struct {
    width: u32,
    height: u32,
    painted_pixels: usize,
};

/// What the page needs in order to present a frame: a pointer into wasm memory
/// and the geometry. NOT a buffer — see `web/present.zig` for why publishing
/// `(ptr, len)` and rebuilding the JS view is the only correct hand-off, and for
/// the `memory.grow()` detaching rule that makes it so.
pub const SurfaceInfo = struct {
    ptr: [*]const u8,
    len: usize,
    width: u32,
    height: u32,
};

pub const Window = struct {
    state: contract.WindowState = contract.WindowState.init(.{}),
    /// Same public field name as the other backends, so
    /// `window.delegate = host.delegate()` is one line on every platform.
    delegate: ?Delegate = null,

    /// The allocator the page's entry point supplied. On wasm that is
    /// `std.heap.wasm_allocator` — the one allocator that grows linear memory.
    /// It is stored rather than reached for globally because `core/` must stay
    /// able to compile for every host (rule R3), and because the page's entry
    /// point is where the choice belongs.
    alloc: std.mem.Allocator,

    /// True once `run()` armed the loop. Every event entry point refuses to do
    /// anything before that, so a stray DOM event delivered between
    /// `WebAssembly.instantiate` and `glin_web_run` cannot drive a half-built
    /// Host.
    live: bool = false,

    /// The device pixel ratio the page last reported. Owned here rather than
    /// applied only in JS because the same scale has to undo itself when a DOM
    /// coordinate comes back in: `present.toBackingPoint` is its inverse.
    device_scale: f32 = 1.0,

    /// Is the primary button currently held? Motion reports `pressed` as this,
    /// because the dispatcher uses it to enter its drag arm. The DOM's own
    /// `buttons` bitmask is not trusted for this — `pointercancel` and focus
    /// loss both leave it stale.
    left_held: bool = false,

    /// The pointer's last known position, in backing-store pixels. Kept so a
    /// synthetic release (`blur`, `pointercancel`) can be reported where the
    /// pointer actually was rather than at an arbitrary corner — see `blur`.
    last_x: f32 = 0,
    last_y: f32 = 0,

    /// Frames this backend has drawn.
    frames: u32 = 0,

    /// Lazy diagnostics. `diag_frame` records which frame index the two numbers
    /// below describe, so a reader that never asks pays nothing and a reader that
    /// asks twice in one frame scans once.
    diag_frame: u32 = std.math.maxInt(u32),
    painted_pixels: usize = 0,
    frame_hash: u64 = 0,

    /// Font bytes handed over by the page. Owned for process lifetime (see
    /// `glyphs.Font.fromBytes` on why the installed font must never be freed),
    /// so this is kept only to make that ownership explicit and to let a later
    /// reader see what was installed.
    font_bytes: []u8 = &.{},

    /// Why the last `installFontBytes` failed, as a number. 0 means it did not.
    ///
    /// See `glin_web_font_error` in `web/exports.zig` for the encoding. This
    /// exists because a bare 0/1 made a browser showing bars indistinguishable
    /// from a browser with no font at all, and the only way to tell was to guess.
    font_error: u32 = 0,

    /// `init` takes an allocator, matching the native backends' signature so an
    /// application's `main` is identical on every platform. The web backend
    /// genuinely needs it — `std.heap.wasm_allocator` is the only allocator that
    /// grows a wasm module's linear memory — whereas the native backends ignore
    /// it because their allocator is a process global.
    pub fn init(alloc: std.mem.Allocator, config: WindowConfig) Window {
        return .{
            .alloc = alloc,
            .state = contract.WindowState.init(config),
        };
    }

    pub fn clamp(self: Window, w: u32, h: u32) struct { w: u32, h: u32 } {
        return self.state.clamp(w, h);
    }

    pub fn appDelegate(self: Window) ?Delegate {
        return self.delegate;
    }

    /// Arm the loop. **Blocks on no platform and returns immediately.**
    ///
    /// This is the whole control inversion: there is no event loop to start,
    /// because the page already owns one. All this does is latch the delegate
    /// into the shared window state and mark the backend live, so the exported
    /// entry points become meaningful.
    pub fn run(self: *Window) !void {
        // Test builds must never arm a real frame loop: `zig build test` runs on
        // every platform and this module is not even selected under `is_test`,
        // but the guard is kept for symmetry with the other backends and as a
        // trap for anyone who adds this file to a test root.
        if (builtin.is_test) return;
        const d = self.delegate orelse return error.NoDelegate;
        self.state.delegate = d;
        self.state.needs_draw = true;
        self.live = true;
    }

    /// Whether the page should bother drawing this animation frame.
    ///
    /// The cheap read that makes an idle tab cost nothing. It is consulted
    /// BEFORE `frame()`, so "nothing to do" means no layout, no rasterization and
    /// no pixel copy — the atomicity `core/frame.zig`'s memo note says Wayland
    /// could not achieve.
    pub fn needsFrame(self: *const Window) bool {
        if (!self.live) return false;
        if (self.state.quit) return false;
        if (self.state.needs_draw) return true;
        // A coalesced resize is work even if no event marked the frame dirty.
        if (adapter.sizeChanged(&self.state)) return true;
        return false;
    }

    /// Draw one frame: adopt at most one coalesced resize, run the delegate
    /// (Clay layout + the software rasterizer), then publish the pixels.
    pub fn frame(self: *Window) void {
        if (!self.live) return;
        if (self.state.quit) return;
        // Adopt at most one coalesced resize per frame, so a live window drag
        // lays out once per drawn frame instead of once per ResizeObserver call.
        _ = adapter.applyPendingResize(&self.state);
        if (adapter.resolveQuit(&self.state)) return;

        const d = self.delegate orelse return;
        const w = self.state.win_w;
        const h = self.state.win_h;
        d.on_frame(d.ptr, w, h);
        // The dirty flag is consumed here, not in the delegate: a new input event
        // sets it again. Clearing it is what lets `needsFrame` idle out.
        self.state.needs_draw = false;
        self.frames += 1;
    }

    /// The frame just drawn, for the page to present. Null before the first
    /// frame, or if the renderer produced nothing.
    pub fn surfaceInfo(self: *Window) ?SurfaceInfo {
        _ = self;
        const surface = soft.currentSurface() orelse return null;
        if (!present.blitSizeValid(surface.width, surface.height)) return null;
        return .{
            .ptr = surface.pixels.ptr,
            .len = surface.pixels.len,
            .width = surface.width,
            .height = surface.height,
        };
    }

    /// Measure the current surface lazily, once per frame, on demand.
    fn ensureDiag(self: *Window) void {
        if (self.diag_frame == self.frames) return;
        const surface = soft.currentSurface() orelse return;
        self.painted_pixels = present.countPainted(surface.pixels, surface.clear_rgb);
        self.frame_hash = present.frameHash(surface.pixels);
        self.diag_frame = self.frames;
    }

    /// Pixels that differ from the clear colour. The browser peer of the macOS
    /// job's blit checksum: a blank canvas still paints every pixel, so "it
    /// exited 0" proves nothing and this is what does.
    pub fn paintedPixels(self: *Window) usize {
        self.ensureDiag();
        return self.painted_pixels;
    }

    /// FNV-1a over the frame. A flat frame cannot fake a non-zero value.
    pub fn frameHash(self: *Window) u64 {
        self.ensureDiag();
        return self.frame_hash;
    }

    // ---- input, all synchronous and all of it non-blocking ----

    /// One DOM pointer event. `kind` is one of `input_web.MOTION/DOWN/UP`.
    ///
    /// Unlike AppKit there is no "ask to redraw" call: marking the frame dirty is
    /// enough, because the page's `requestAnimationFrame` loop is always looking
    /// at `needsFrame()`.
    pub fn pointer(self: *Window, kind: u8, button: i32, x: f32, y: f32) void {
        if (!self.live) return;
        const d = self.delegate orelse return;
        const w = self.state.win_w;
        const h = self.state.win_h;

        // Translate to the Delegate's contract: evdev button code on a
        // transition, 0 on motion, coordinates clamped into the canvas. All of
        // it lives in input_web.zig because getting any part wrong is silent — a
        // wrong button code means clicks never fire at all.
        const t = input_web.translate(w, h, .{ .kind = kind, .button = button, .x = x, .y = y }, self.left_held);
        if (t.pressed and kind == input_web.DOWN) self.left_held = true;
        if (!t.pressed and kind == input_web.UP) self.left_held = false;
        // Remember where the pointer is, for a later synthetic release.
        self.last_x = t.x;
        self.last_y = t.y;

        self.state.needs_draw = true;
        d.on_pointer(d.ptr, t.x, t.y, t.pressed, t.button);
    }

    /// A browser-cancelled gesture (`pointercancel`). Reported as a release of
    /// whatever was held — see `input_web.cancelRelease` for why the toolkit has
    /// no other vocabulary for it and what the honest consequence is.
    pub fn cancelPointer(self: *Window, x: f32, y: f32) void {
        if (!self.live) return;
        const d = self.delegate orelse return;
        const t = input_web.cancelRelease(self.left_held, self.state.win_w, self.state.win_h, x, y) orelse return;
        self.left_held = false;
        self.state.needs_draw = true;
        d.on_pointer(d.ptr, t.x, t.y, t.pressed, t.button);
    }

    /// One wheel event. `mode` is the DOM's `deltaMode`, normalised by
    /// `adapter.scrollDelta` — and the SIGN IS NOT TOUCHED, unlike macOS.
    pub fn wheel(self: *Window, dx: f32, dy: f32, mode: adapter.WheelDeltaMode) void {
        if (!self.live) return;
        const d = self.delegate orelse return;
        const scroll = d.on_scroll orelse return;
        // Trackpads emit a tail of zero-delta events; each would otherwise mark
        // the frame dirty and force a full re-rasterization.
        if (adapter.wheelIsNoop(dx, dy)) return;
        const s = adapter.scrollDelta(dx, dy, mode, self.state.win_h);
        if (adapter.wheelIsNoop(s.dx, s.dy)) return;
        self.state.needs_draw = true;
        scroll(d.ptr, s.dx, s.dy);
    }

    /// One keyboard event. `code` is `KeyboardEvent.code`, translated here to the
    /// evdev code the Delegate contract promises, so the widget layer and
    /// `components.input` need no browser awareness.
    ///
    /// Returns whether the app CONSUMED the key, which the page uses to decide
    /// whether to `preventDefault`. That decision has to come from here rather
    /// than from a list in `shim.js`: the toolkit's own text fields want Tab, the
    /// arrows and Space, and duplicating even a subset of `keymap.zig` in
    /// JavaScript would put untestable logic in the one place that has no tests.
    ///
    /// Escape works with no browser-specific code: `keymap` maps it to evdev 1 and
    /// `keyToClose` already accepts that — the app's own `on_key` sets its quit
    /// flag and `frame()`'s `resolveQuit` notices.
    pub fn key(self: *Window, code: []const u8, pressed: bool) bool {
        if (!self.live) return false;
        const d = self.delegate orelse return false;
        const ev = keymap.evdevFor(code);
        // An unmapped code is silence rather than a guess: a wrong mapping types
        // the wrong character, which is far more confusing than typing nothing.
        if (ev == keymap.KEY_NONE) return false;
        self.state.needs_draw = true;
        const consumed = d.on_key(d.ptr, ev, pressed);
        _ = adapter.resolveQuit(&self.state);
        return consumed;
    }

    /// A proposed canvas size, in BACKING-STORE pixels (the page multiplies the
    /// CSS size by the device ratio before calling). Recorded, not applied: a
    /// live window drag sends one of these per animation frame, and
    /// `frame()` adopts at most the last.
    pub fn resize(self: *Window, w: u32, h: u32) void {
        if (!self.live) return;
        _ = adapter.noteResize(&self.state, w, h);
    }

    /// The page's `devicePixelRatio` changed (the window moved to a display with
    /// a different density, or the user zoomed).
    pub fn setScale(self: *Window, scale: f32) void {
        if (scale > 0 and scale <= present.max_device_scale) self.device_scale = scale;
        self.state.needs_draw = true;
    }

    /// Focus was lost. Releases the held button, because a tab that loses focus
    /// mid-drag never receives the matching `pointerup` — leaving `left_held` set
    /// would make the next motion drag the UI with no button down.
    ///
    /// The release is reported at the pointer's LAST known position, not at the
    /// window's bottom-right corner: `dispatch.pointerEvent` fires a click on
    /// release when the press was in-bounds and never dragged, so a synthetic
    /// release at a corner would click whatever happens to be there. Reporting it
    /// where the pointer actually was keeps the outcome the same as a real
    /// release at that spot.
    pub fn blur(self: *Window) void {
        if (!self.left_held) return;
        self.left_held = false;
        const d = self.delegate orelse return;
        self.state.needs_draw = true;
        d.on_pointer(d.ptr, self.last_x, self.last_y, false, input_web.BTN_LEFT);
    }

    /// The page is going away (`pagehide`). Notifies the app so it can persist
    /// anything it wants; the wasm instance itself is the page's to discard.
    pub fn shutdown(self: *Window) void {
        const d = self.delegate orelse return;
        d.on_close(d.ptr);
        self.state.quit = true;
        self.live = false;
    }

    /// Take ownership of font bytes and install them as the process-wide glyph
    /// source. Returns false if the bytes are not a loadable font, in which case
    /// the page may retry or accept glyph-free text.
    ///
    /// The bytes are kept even when parsing fails, because `fromBytes` may have
    /// borrowed nothing but the caller has already handed ownership over — leaking
    /// a failed font fetch for the lifetime of the tab is strictly better than
    /// double-freeing it, and there is exactly one of these per page.
    pub fn installFontBytes(self: *Window, bytes: []u8) bool {
        self.font_bytes = bytes;
        const f = glyphs.Font.fromBytes(bytes) catch |err| {
            // Record WHY, so the page can distinguish "not a font" from "stb
            // refused it" instead of seeing a bare 0. See `glin_web_font_error`.
            self.font_error = switch (err) {
                error.FontNotFound => 1,
                error.FontInitFailed => 2,
            };
            return false;
        };
        glyphs.installFont(f);
        self.font_error = 0;
        self.state.needs_draw = true;
        return true;
    }

    /// Drive one real frame into a software surface and report what was drawn.
    /// Exposed so the Node smoke test — and any future test harness — can assert
    /// pixels with no browser at all, exactly as `mac/window.zig`'s version lets
    /// tools work without a window server.
    pub fn renderHeadless(self: *Window) !RenderResult {
        const d = self.delegate orelse return error.NoDelegate;
        const w = self.state.win_w;
        const h = self.state.win_h;
        if (w == 0 or h == 0) return error.InvalidSize;
        d.on_frame(d.ptr, w, h);
        self.frames += 1;

        const surface = soft.currentSurface() orelse return error.NoSurface;
        if (surface.width == 0 or surface.height == 0) return error.EmptySurface;
        return .{
            .width = surface.width,
            .height = surface.height,
            .painted_pixels = present.countPainted(surface.pixels, surface.clear_rgb),
        };
    }
};
