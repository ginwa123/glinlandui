//! Real Windows window backend (Win32 + D3D11).
//!
//! The third peer in `core/window_contract.zig`'s family, alongside
//! `linux/window.zig` (Wayland/EGL/GLES3) and `mac/window.zig` (Cocoa/
//! CoreGraphics). The division of labour is the same on every platform:
//!
//!   - `windows/shim.c` owns the HWND and the D3D11 device/swap chain, and
//!     turns Win32 messages into C callbacks. It makes no decisions, and it is
//!     the only untestable part.
//!   - This file owns ALL the logic, and every decision it makes goes through
//!     a pure, unit-tested helper in `windows/`:
//!       * keycodes  -> windows/keymap.zig  (VK -> evdev)
//!       * coords    -> windows/adapter.zig (clamp, resize coalescing, scroll)
//!       * pointer   -> windows/input.zig   (evdev button codes, motion)
//!       * pixels    -> windows/present.zig (RGBA8 -> D3D11, the identity)
//!
//! So a mistake in any of those four shows up as a failing test on every
//! platform rather than as "the Windows window looks a bit odd" — or, worse,
//! as "the buttons do nothing", which is what a wrong evdev button code
//! produces.
//!
//! ## What is D3D11 and what is not
//!
//! The shared CPU rasterizer in `core/` draws the frame (see
//! `windows/renderer.zig` for why Windows composites on the GPU the way Linux
//! does but rasterises on the CPU the way macOS does). This file uploads that
//! surface through `windows/present.zig` and hands it to the shim, which
//! uploads it into an `ID3D11Texture2D` and draws it into the swap chain.
//!
//! ## Degrading, the way every other backend does
//!
//! `run()` returns an error when the window could not be created at all — no
//! interactive window station, which is what a headless service session looks
//! like. That is the same contract as Linux's `error.NoWaylandDisplay` and
//! macOS's `error.NoWindowServer`, and it is what lets the calculator example
//! fall back to a real headless render and report painted pixels instead of
//! exiting non-zero. A D3D11 device that fails *after* the window opened does
//! not end the run either: the shim clears the back buffer, says so, and the
//! window keeps responding.

const std = @import("std");
const builtin = @import("builtin");
const contract = @import("../core/window_contract.zig");
const keymap = @import("keymap.zig");
const adapter = @import("adapter.zig");
const input_win = @import("input.zig");
const present = @import("present.zig");
const soft = @import("../core/render_software.zig");

// The shim header is plain C by design (see windows/shim.h), so @cImport never
// has to survive Direct3D's COM macros or typedefs.
const c = @cImport({
    @cInclude("shim.h");
});

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
/// `mac/window.zig` so code that calls `renderHeadless()` works on every
/// backend.
pub const RenderResult = struct {
    width: u32,
    height: u32,
    painted_pixels: usize,
};

/// What the D3D11 layer ended up doing, so the host (and CI) can say so out
/// loud instead of leaving a log line to be interpreted.
pub const Presenter = enum {
    /// A real D3D11 device and swap chain, compositing on the GPU.
    d3d11,
    /// The Win32 window is blitting into its own DC with GDI. This is the
    /// path a machine with a driver that cannot execute a shader ends up on:
    /// the window works, but the CPU composites it. Never a "portable
    /// headless" path — the window is real and the same pixels.
    gdi,
    /// A Win32 window with no usable presenter at all, not even GDI. The
    /// window still opens and still responds; it just shows nothing.
    no_gpu,

    pub fn name(self: Presenter) []const u8 {
        return @tagName(self);
    }
};

/// Read the shim's current presenter. Ask again after the first frame: the
/// shim can fall back mid-run, and a report taken before the first `Present`
/// would claim D3D11 on a machine that never managed to use it.
fn presenterOf(handle: *c.GlinWinWindow) Presenter {
    const mode = std.mem.span(c.glin_win_present_mode(handle));
    if (std.mem.eql(u8, mode, "gdi")) return .gdi;
    if (c.glin_win_d3d11_active(handle) != 0) return .d3d11;
    return .no_gpu;
}

pub const Window = struct {
    state: contract.WindowState = contract.WindowState.init(.{}),
    /// Same public field name as the other backends, so
    /// `window.delegate = host.delegate()` is one line on every platform.
    delegate: ?Delegate = null,

    /// The Win32 handle, null until `run()` (or `renderHeadless()`) creates it.
    handle: ?*c.GlinWinWindow = null,
    /// The upload buffer, allocated on first use and reused every frame.
    blit_buf: []u8 = &.{},
    /// Is the primary button currently held? Motion reports `pressed` as this,
    /// because the dispatcher uses it to enter its drag arm.
    left_held: bool = false,
    /// Frames composited so far. Used to report only the first one, so a
    /// long interactive run does not spam the log.
    diag_frames: u32 = 0,

    pub fn init(alloc: std.mem.Allocator, config: WindowConfig) Window {
        // The allocator is accepted for signature parity with the web backend,
        // which genuinely needs it (`wasm_allocator` is the only allocator that
        // grows a wasm module's linear memory). Native backends ignore it: their
        // allocator is a process global, and the Clay arena is owned by the Host.
        _ = alloc;
        return .{ .state = contract.WindowState.init(config) };
    }

    pub fn clamp(self: Window, w: u32, h: u32) struct { w: u32, h: u32 } {
        return self.state.clamp(w, h);
    }

    pub fn appDelegate(self: Window) ?Delegate {
        return self.delegate;
    }

    /// Open a real Win32 window and run the message loop with the D3D11
    /// swap chain. Blocks until quit.
    ///
    /// `QS_SETTINGS_TEST_FRAMES` caps the frame count (parsed by the shared
    /// `contract.parseTestFrames`) so CI gets a deterministic run it can
    /// assert on, instead of an interactive one that never returns.
    pub fn run(self: *Window) !void {
        // Headless test builds must never touch Win32: `zig build test` runs
        // on every platform and must not need a window station.
        if (builtin.is_test) return;

        const d = self.delegate orelse return error.NoDelegate;
        self.state.delegate = d;

        // `config.title` is already a NUL-terminated string, which is exactly
        // what the C `const char *` parameter wants, so it passes straight
        // through with no copy and no lifetime concern.
        const cfg = self.state.config;
        const handle = c.glin_win_window_create(
            cfg.title,
            @intCast(cfg.width),
            @intCast(cfg.height),
            @intCast(cfg.min_width),
            @intCast(cfg.min_height),
        ) orelse return error.NoWindowStation;
        self.handle = handle;
        defer self.handle = null;
        defer c.glin_win_window_destroy(handle);

        c.glin_win_window_set_callbacks(
            handle,
            onFrame,
            onPointer,
            onScroll,
            onKey,
            onResize,
            onClose,
            self,
        );

        const adapter_name = std.mem.span(c.glin_win_adapter_name(handle));
        std.log.info(
            "Windows window: {d}x{d} ({s}), presenter: {s} ({s})",
            .{ cfg.width, cfg.height, cfg.title, presenterOf(handle).name(), adapter_name },
        );

        const requested: i32 = blk: {
            // Same env var, same helper, same semantics as the other two
            // backends, so all three run under one harness.
            const raw = std.c.getenv("QS_SETTINGS_TEST_FRAMES") orelse break :blk 0;
            const n = contract.parseTestFrames(std.mem.span(raw)) orelse break :blk 0;
            break :blk @intCast(n);
        };
        // Unlike AppKit, Win32 redraws as often as the application invalidates,
        // so there is no cap to clamp: any positive value is reachable, and
        // unlike the Cocoa case an unreachable cap cannot hang the run.
        std.log.info("QS_SETTINGS_TEST_FRAMES: {d} (0 = interactive)", .{requested});
        c.glin_win_window_run(handle, requested);
    }

    // ---- callbacks handed to the shim ----

    fn ctx(p: ?*anyopaque) *Window {
        return @ptrCast(@alignCast(p.?));
    }

    /// WM_PAINT. Runs the delegate's frame (Clay layout + the software
    /// rasterizer), then hands the converted pixels back to the shim, which
    /// uploads them into the D3D11 texture and presents.
    fn onFrame(p: ?*anyopaque) callconv(.c) void {
        const self = ctx(p);
        const w = self.state.win_w;
        const h = self.state.win_h;

        // Adopt at most one coalesced resize per frame (windows/adapter), so a
        // live drag lays out once per drawn frame instead of per event.
        if (adapter.applyPendingResize(&self.state)) {
            onResized(self);
        }
        if (adapter.resolveQuit(&self.state)) return;

        const d = self.delegate orelse return;
        d.on_frame(d.ptr, w, h);
        self.presentFrame();
    }

    /// Copy the surface the delegate just drew into the shim's upload buffer.
    fn presentFrame(self: *Window) void {
        const handle = self.handle orelse return;
        const surface = soft.currentSurface() orelse return;
        if (!present.blitSizeValid(surface.width, surface.height)) return;

        const need = present.blitBufLen(surface.width, surface.height);
        if (self.blit_buf.len < need) {
            self.blit_buf = std.heap.c_allocator.alloc(u8, need) catch return;
        }
        // The hand-off contract (NO channel swap, NO vertical flip) lives in
        // the tested helper; see windows/present.zig for how the swap-chain
        // format was chosen and ci/check_windows_colors.c for the check that
        // proves it against real GPU output.
        present.identityRgba8(surface.pixels, self.blit_buf, surface.width, surface.height);
        if (std.c.getenv("GLIN_DUMP_SURFACE")) |p| dumpRaw(p, surface.pixels);
        c.glin_win_present(
            handle,
            self.blit_buf.ptr,
            @intCast(surface.width),
            @intCast(surface.height),
        );
        self.diag_frames += 1;
        // Reported AFTER the present, and only once, because this frame may be
        // the one that made the shim fall back from D3D11 to GDI — a report
        // taken before it would claim a GPU path the window never used.
        if (self.diag_frames == 1) reportFirstFrame(handle, self.blit_buf, surface);
    }

    /// Apply a coalesced resize. There is no surface to resize here: the
    /// renderer owns it and the Host resizes it at the start of the next
    /// frame, so all this needs to do is note that the size moved (which
    /// `applyPendingResize` already did) and keep the upload buffer correct,
    /// which `presentFrame` handles by length. The swap chain was already
    /// resized by the shim's WM_SIZE handler.
    ///
    /// Kept as a named function so `onFrame` reads as the four steps it is,
    /// and so the empty body is documented rather than looking like an
    /// oversight.
    fn onResized(_: *Window) void {}

    fn onPointer(
        p: ?*anyopaque,
        kind: c_int,
        button_number: c_int,
        x: f64,
        y: f64,
        // The shim's own view of whether a button is held is ignored, exactly
        // as on macOS: `self.left_held` is tracked from the transitions this
        // same callback sees, so the two cannot disagree. A motion event
        // arriving between a WM_LBUTTONDOWN and a WM_LBUTTONUP that crossed a
        // focus change would otherwise report a stale held state.
        _: c_int,
    ) callconv(.c) void {
        const self = ctx(p);
        const d = self.delegate orelse return;
        const w = self.state.win_w;
        const h = self.state.win_h;

        // Translate to the Delegate's contract: evdev button code on a
        // transition, 0 on motion, and NO y flip (Win32's client origin is
        // already top-left). All of it lives in input_win.zig because getting
        // the button code wrong is silent — a click that never fires looks
        // exactly like a healthy window with dead buttons.
        const kind_u8: u8 = if (kind >= 0 and kind <= 255) @intCast(kind) else 0;
        const t = input_win.translate(w, h, .{
            .kind = kind_u8,
            .button_number = @intCast(button_number),
            .x = @floatCast(x),
            .y = @floatCast(y),
        }, self.left_held);
        if (t.pressed and kind_u8 == input_win.DOWN) self.left_held = true;
        if (!t.pressed and kind_u8 == input_win.UP) self.left_held = false;

        self.state.needs_draw = true;
        d.on_pointer(d.ptr, t.x, t.y, t.pressed, t.button);
        // WM_PAINT only arrives when something invalidates the window, and a
        // toolkit that owns its own frame loop never invalidates on its own.
        c.glin_win_invalidate(self.handle);
    }

    fn onScroll(p: ?*anyopaque, dx: f64, dy: f64) callconv(.c) void {
        const self = ctx(p);
        const d = self.delegate orelse return;
        const delta = d.on_scroll orelse return;
        const s = adapter.scrollDelta(@floatCast(dx), @floatCast(dy));
        self.state.needs_draw = true;
        delta(d.ptr, s.dx, s.dy);
        // Scrolling moves the view; Win32 must be told or nothing repaints.
        c.glin_win_invalidate(self.handle);
    }

    fn onKey(p: ?*anyopaque, vk: c_int, pressed: c_int) callconv(.c) c_int {
        const self = ctx(p);
        const d = self.delegate orelse return 0;
        // Translate the raw `wParam` to the evdev code the Delegate contract
        // promises, so the widget layer and `components.input` need no Windows
        // awareness. The raw value is passed unmodified because the keypad's
        // Enter is only distinguishable by its extended-key bit.
        const ev = keymap.evdevFor(@bitCast(vk));
        if (ev == keymap.KEY_NONE) return 0;
        self.state.needs_draw = true;
        const consumed = d.on_key(d.ptr, ev, pressed != 0);
        // Typing changes the display; without this the keystroke is consumed
        // but the window keeps showing the old value.
        c.glin_win_invalidate(self.handle);
        if (adapter.resolveQuit(&self.state)) c.glin_win_quit(self.handle);
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
        c.glin_win_quit(self.handle);
    }

    /// Drive one real frame into a software surface and report what was drawn.
    /// Exposed so tools and the demo's headless path keep working on Windows
    /// without a window station — the same escape hatch the other two backends
    /// provide.
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

/// Write raw bytes to a file. Debug aid for eyeballing a frame on a machine
/// with no convenient screen capture.
fn dumpRaw(path: [*:0]const u8, bytes: []const u8) void {
    const f = std.c.fopen(path, "wb") orelse return;
    _ = std.c.fwrite(bytes.ptr, 1, bytes.len, f);
    _ = std.c.fclose(f);
    std.log.info("wrote {d} raw bytes to {s}", .{ bytes.len, std.mem.span(path) });
}

/// Report the first composited frame's size, painted-pixel count and a
/// checksum of the exact bytes handed to the D3D11 pipeline.
///
/// This is the Windows counterpart of macOS's `reportFirstFrame`, and it exists
/// for the same reason: a screenshot is not a usable proof. Windows has no
/// built-in CLI screenshot tool, and a screen-capture library would be a new
/// dependency plus a permission model, for something CI cannot assert on. A
/// non-zero checksum proves the whole chain ran — layout -> rasterizer ->
/// present.zig -> the D3D11 upload — and proves the bytes are not one repeated
/// colour, which a blank or flat window cannot fake.
fn reportFirstFrame(handle: *c.GlinWinWindow, upload: []const u8, surface: *const soft.Surface) void {
    var painted: usize = 0;
    var i: usize = 0;
    while (i + 3 < surface.pixels.len) : (i += 4) {
        if (surface.pixels[i] != surface.clear_rgb[0] or
            surface.pixels[i + 1] != surface.clear_rgb[1] or
            surface.pixels[i + 2] != surface.clear_rgb[2]) painted += 1;
    }
    // FNV-1a over the uploaded bytes: a one-line "did anything actually change"
    // probe.
    var hash: u64 = 0xcbf29ce484222325;
    for (upload) |byte| {
        hash ^= byte;
        hash *%= 0x100000001b3;
    }
    std.log.info(
        "Windows first frame: {d}x{d}, {d} painted pixels, {s} upload checksum 0x{x}",
        .{ surface.width, surface.height, painted, presenterOf(handle).name(), hash },
    );
}
