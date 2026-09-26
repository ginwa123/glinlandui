// Generic Clay app Host: the engine-side owner ui views plugs into.
// Owns the allocator, lazy GLES3 renderer slots, Clay arena, window dims,
// pointer state, quit intent, a Views table and a KeyChain. App chrome
// (root container, close props, page routing) lives in ui and plugs in
// via `root_fn` (registered at init) — Host only owns beginFrame +
// clayFrame plumbing + delegate events. Imports: std + siblings ONLY
// (render + frame + dispatch + click_registry + window_contract for Delegate).
// Never: ui/*, theme, or a platform backend — Host is core logic and must
// compile identically on every OS. The Delegate it hands out is the neutral
// one from the window contract, which is also what every backend re-exports,
// so the type identity is shared rather than merely equivalent.
const std = @import("std");
const contract = @import("window_contract.zig");
const render = @import("render.zig");
const frame_mod = @import("frame.zig");
const dispatch = @import("components/dispatch.zig");
const registry = @import("components/click_registry.zig");
const image_widgets = @import("components/image.zig");
const cl = @import("zclay");
const scroll_mod = @import("components/scroll.zig");
const semantics = @import("semantics.zig");

/// App declare callback: builds the Clay tree for a w x h window.
/// ctx is the app owner (e.g. *Shell); Host supplies dims + plumbing.
pub const RootFn = *const fn (?*anyopaque, u32, u32) void;

pub const Host = struct {
    alloc: std.mem.Allocator,
    renderer: ?render.Renderer = null,
    renderer_attempted: bool = false,
    clay_mem: []u8 = &.{},
    clay_ready: bool = false,
    /// Theme-independent default (720x480 literal); caller may override
    /// win_w/h after init (same values as ui/theme.zig, the source of
    /// truth — no theme import by design).
    win_w: u32 = 720,
    win_h: u32 = 480,
    ptr: dispatch.PtrState = .{},
    /// Pending wheel scroll delta (px, accumulated by onScrollEvent,
    /// consumed once per frame by frame() into Clay's scroll containers).
    scroll_dx: f32 = 0,
    scroll_dy: f32 = 0,
    quit_requested: bool = false,
    views: dispatch.Views = .{},
    keys: dispatch.KeyChain = .{},
    root_ctx: ?*anyopaque = null,
    root_fn: RootFn,

    pub fn init(alloc: std.mem.Allocator, ctx: ?*anyopaque, root_fn: RootFn) !Host {
        var self = Host{ .alloc = alloc, .root_ctx = ctx, .root_fn = root_fn };
        self.clay_mem = try frame_mod.initClay(alloc, self.win_w, self.win_h);
        self.clay_ready = true;
        return self;
    }

    pub fn deinit(self: *Host) void {
        if (self.renderer) |*r| r.deinit();
        self.renderer = null;
        if (self.clay_mem.len > 0) self.alloc.free(self.clay_mem);
        self.clay_mem = &.{};
        self.clay_ready = false;
    }

    /// The per-frame declare phase: reset the per-frame registries, then run
    /// the app's root callback.
    ///
    /// PUBLIC on purpose. The headless test Driver must drive THIS, not
    /// `root_fn` directly: the resets are what stop click_registry entries and
    /// semantics nodes from accumulating across frames. Bypassing them makes a
    /// tag lookup ambiguous ("TooManyNodes") after the second frame, which is
    /// exactly the bug this indirection exists to prevent.
    pub fn declareFrame(self: *Host, w: u32, h: u32) void {
        // Fresh registries per frame (components self-register during
        // declare; stale boxes must never ghost-fire).
        registry.beginFrame();
        scroll_mod.beginScrollFrame();
        image_widgets.beginFrame();
        semantics.beginFrame();
        self.root_fn(self.root_ctx, w, h);
    }

    fn declareThunk(ctx: *anyopaque, w: u32, h: u32) void {
        const self: *Host = @ptrCast(@alignCast(ctx));
        self.declareFrame(w, h);
    }

    pub fn frame(self: *Host, w: u32, h: u32) void {
        _ = self.frameWithOptions(w, h, null);
    }

    /// Frame variant used by the reusable headless test driver. A null
    /// options pointer preserves the production Pango/GLES path exactly;
    /// a non-null pointer only adds measurement/probe seams for tests.
    pub fn frameWithOptions(self: *Host, w: u32, h: u32, options: ?*const frame_mod.FrameOptions) u32 {
        if (!self.clay_ready) return frame_mod.shape_default;
        self.win_w = w;
        self.win_h = h;
        // Consume the pending wheel delta exactly once per frame (Clay
        // routes it to the hovered scroll container; zero = no-op).
        const dx = self.scroll_dx;
        const dy = self.scroll_dy;
        self.scroll_dx = 0;
        self.scroll_dy = 0;
        // clayFrame resolves the cursor shape AFTER endLayout into
        // frame_mod.currentShape() (it also returns it; void here keeps
        // Delegate.on_frame and all Host.frame callers signature-stable).
        // Window.run reads frame_mod.currentShape() after on_frame
        // returns and set_shapes change-only — no ui/* churn.
        if (options) |opts| {
            return frame_mod.clayFrameWithOptions(
                self.alloc,
                &self.renderer,
                &self.renderer_attempted,
                self.ptr.x,
                self.ptr.y,
                self.ptr.down,
                dx,
                dy,
                w,
                h,
                declareThunk,
                self,
                opts,
            );
        }
        return frame_mod.clayFrame(
            self.alloc,
            &self.renderer,
            &self.renderer_attempted,
            self.ptr.x,
            self.ptr.y,
            self.ptr.down,
            dx,
            dy,
            w,
            h,
            declareThunk,
            self,
        );
    }

    pub fn onPointerEvent(self: *Host, x: f32, y: f32, pressed: bool, button: u32) void {
        const last_x = self.ptr.x;
        const last_y = self.ptr.y;
        dispatch.pointerEvent(&self.ptr, x, y, pressed, button, self.win_w, self.win_h);
        // Slider-style drag: while a press-drag is in flight, nudge the
        // scroll container under the pointer 1:1 (pointer down = scroll
        // down). dispatch only marks dragging; the scroll happens here so
        // dispatch never imports scroll (no cycle: host owns both).
        if (self.ptr.down and self.ptr.dragging and (x != last_x or y != last_y)) {
            scroll_mod.dragScroll(x, y, x - last_x, y - last_y);
        }
    }

    pub fn onScrollEvent(self: *Host, dx: f32, dy: f32) void {
        self.scroll_dx += dx;
        self.scroll_dy += dy;
    }

    pub fn onKeyEvent(self: *Host, keycode: u32, pressed: bool) bool {
        return dispatch.handleKey(&self.keys, keycode, pressed);
    }

    pub fn onResizeEvent(self: *Host, w: u32, h: u32) void {
        self.win_w = w;
        self.win_h = h;
    }

    pub fn onCloseEvent(self: *Host) void {
        self.quit_requested = true;
    }

    pub fn isQuit(self: *Host) bool {
        return self.quit_requested;
    }

    fn onFrame(ptr: *anyopaque, w: u32, h: u32) void {
        const self: *Host = @ptrCast(@alignCast(ptr));
        self.frame(w, h);
    }

    fn onPointer(ptr: *anyopaque, x: f32, y: f32, pressed: bool, button: u32) void {
        const self: *Host = @ptrCast(@alignCast(ptr));
        self.onPointerEvent(x, y, pressed, button);
    }

    fn onScroll(ptr: *anyopaque, dx: f32, dy: f32) void {
        const self: *Host = @ptrCast(@alignCast(ptr));
        self.onScrollEvent(dx, dy);
    }

    fn onKey(ptr: *anyopaque, keycode: u32, pressed: bool) bool {
        const self: *Host = @ptrCast(@alignCast(ptr));
        return self.onKeyEvent(keycode, pressed);
    }

    fn onResize(ptr: *anyopaque, w: u32, h: u32) void {
        const self: *Host = @ptrCast(@alignCast(ptr));
        self.onResizeEvent(w, h);
    }

    fn onClose(ptr: *anyopaque) void {
        const self: *Host = @ptrCast(@alignCast(ptr));
        self.onCloseEvent();
    }

    fn isQuitFn(ptr: *anyopaque) bool {
        const self: *Host = @ptrCast(@alignCast(ptr));
        return self.isQuit();
    }

    /// Same Delegate shape as ui Shell (Window accepts it directly).
    pub fn delegate(self: *Host) contract.Delegate {
        return .{
            .ptr = self,
            .on_frame = onFrame,
            .on_pointer = onPointer,
            .on_scroll = onScroll,
            .on_key = onKey,
            .on_resize = onResize,
            .on_close = onClose,
            .is_quit = isQuitFn,
        };
    }
};

// ---- Test doubles ----

fn noopRoot(_: ?*anyopaque, _: u32, _: u32) void {}

const FrameRec = struct {
    calls: usize = 0,
    w: u32 = 0,
    h: u32 = 0,
};

fn recRoot(ctx: ?*anyopaque, w: u32, h: u32) void {
    const r: *FrameRec = @ptrCast(@alignCast(ctx.?));
    r.calls += 1;
    r.w = w;
    r.h = h;
}

// ARENA DISCIPLINE (mirrors ui views_test.zig): testHost() intentionally
// never deinits — Clay keeps a global currentContext pointer inside the
// init arena, so freeing it would dangle the NEXT test's
// minMemorySize/initialize (ABRT in clay.h Clay_MinMemorySize). Arenas
// come from page_allocator (no leak detector). deinit's flag/free
// transitions are covered separately on a stack Host with no Clay arena
// involved (see the init/deinit test).
fn testHost(h: *Host, ctx: ?*anyopaque, root_fn: RootFn) !void {
    h.* = try Host.init(std.heap.page_allocator, ctx, root_fn);
}

test "host: init defaults headless (Clay only, renderer stays null)" {
    var h: Host = undefined;
    try testHost(&h, null, noopRoot);
    try std.testing.expect(h.clay_ready);
    try std.testing.expect(h.renderer == null);
    try std.testing.expectEqual(@as(u32, 720), h.win_w);
    try std.testing.expectEqual(@as(u32, 480), h.win_h);
    // deinit flag/free transitions on a stack Host (no Clay arena — safe;
    // testing.allocator fails on leak, so a live free is proven).
    var d = Host{ .alloc = std.testing.allocator, .root_fn = noopRoot, .clay_ready = true };
    d.clay_mem = try std.testing.allocator.alloc(u8, 8);
    d.deinit();
    try std.testing.expect(!d.clay_ready);
    try std.testing.expect(d.renderer == null);
    try std.testing.expectEqual(@as(usize, 0), d.clay_mem.len);
}

test "host: delegate drives every event (shape + wiring)" {
    var h: Host = undefined;
    try testHost(&h, null, noopRoot);
    var d = h.delegate();
    d.on_resize(d.ptr, 800, 600);
    try std.testing.expectEqual(@as(u32, 800), h.win_w);
    try std.testing.expectEqual(@as(u32, 600), h.win_h);
    d.on_pointer(d.ptr, 10, 20, true, 272);
    try std.testing.expectEqual(@as(f32, 10), h.ptr.x);
    try std.testing.expectEqual(@as(f32, 20), h.ptr.y);
    try std.testing.expect(h.ptr.down);
    try std.testing.expect(!d.on_key(d.ptr, 30, true));
    try std.testing.expect(!d.is_quit(d.ptr));
    d.on_close(d.ptr);
    try std.testing.expect(d.is_quit(d.ptr));
}

test "host: onClose requests quit" {
    var h: Host = undefined;
    try testHost(&h, null, noopRoot);
    try std.testing.expect(!h.isQuit());
    h.onCloseEvent();
    try std.testing.expect(h.isQuit());
}

test "host: pointer press latches down, release clears" {
    var h: Host = undefined;
    try testHost(&h, null, noopRoot);
    h.onPointerEvent(10, 20, true, 272);
    try std.testing.expectEqual(@as(f32, 10), h.ptr.x);
    try std.testing.expectEqual(@as(f32, 20), h.ptr.y);
    try std.testing.expect(h.ptr.down);
    h.onPointerEvent(10, 20, false, 272);
    try std.testing.expect(!h.ptr.down);
}

test "host: empty keychain returns false (press + release)" {
    var h: Host = undefined;
    try testHost(&h, null, noopRoot);
    try std.testing.expect(!h.onKeyEvent(30, true));
    try std.testing.expect(!h.onKeyEvent(30, false));
}

test "host: frame runs the declare thunk with current dims" {
    var rec = FrameRec{};
    var h: Host = undefined;
    try testHost(&h, &rec, recRoot);
    h.frame(800, 600);
    try std.testing.expectEqual(@as(usize, 1), rec.calls);
    try std.testing.expectEqual(@as(u32, 800), rec.w);
    try std.testing.expectEqual(@as(u32, 600), rec.h);
    try std.testing.expectEqual(@as(u32, 800), h.win_w);
    try std.testing.expectEqual(@as(u32, 600), h.win_h);
}

test "host: wheel scroll accumulates and frame consumes it" {
    var h: Host = undefined;
    try testHost(&h, null, noopRoot);
    const d = h.delegate();
    try std.testing.expect(d.on_scroll != null);
    d.on_scroll.?(d.ptr, 0, 120);
    d.on_scroll.?(d.ptr, 5, 30);
    try std.testing.expectApproxEqAbs(@as(f32, 5), h.scroll_dx, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 150), h.scroll_dy, 1e-5);
    // Frame consumes exactly once (delta resets to zero).
    var rec = FrameRec{};
    h.root_fn = recRoot;
    h.root_ctx = &rec;
    h.frame(800, 600);
    try std.testing.expectEqual(@as(usize, 1), rec.calls);
    try std.testing.expectApproxEqAbs(@as(f32, 0), h.scroll_dx, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0), h.scroll_dy, 1e-6);
}

fn hostScrollProbeChildren(_: void) void {
    cl.UI()(.{
        .id = .ID("host-scroll-probe"),
        .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(40) } },
        .background_color = .{ 200, 50, 50, 255 },
    })({});
    var i: usize = 0;
    while (i < 9) : (i += 1) {
        cl.UI()(.{
            .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(40) } },
            .background_color = .{ 100, 100, 100, 255 },
        })({});
    }
}

fn hostScrollProbeRoot(_: ?*anyopaque, _: u32, _: u32) void {
    scroll_mod.scroll(.{ .id = "host-scroll", .h = .{ .fixed = 100 }, .w = .{ .fixed = 200 } }, {}, hostScrollProbeChildren);
}

test "host: wheel-down (Wayland positive dy) scrolls content down" {
    var h: Host = undefined;
    try testHost(&h, null, hostScrollProbeRoot);
    h.frame(720, 480);
    const y0 = cl.getElementData(cl.getElementId("host-scroll-probe")).bounding_box.y;
    // Hover the container center, then wheel down in Wayland coords.
    const box = cl.getElementData(cl.getElementId("host-scroll")).bounding_box;
    h.onPointerEvent(box.x + box.width * 0.5, box.y + box.height * 0.5, false, 0);
    h.onScrollEvent(0, 5);
    h.frame(720, 480);
    const y1 = cl.getElementData(cl.getElementId("host-scroll-probe")).bounding_box.y;
    // +5 Wayland dy negates to Clay -50px: content moves up 50.
    try std.testing.expectApproxEqAbs(y0 - 50, y1, 0.5);
}

test "host: press-drag down scrolls down slider-style (no click)" {
    var h: Host = undefined;
    try testHost(&h, null, hostScrollProbeRoot);
    h.frame(720, 480);
    const y0 = cl.getElementData(cl.getElementId("host-scroll-probe")).bounding_box.y;
    const box = cl.getElementData(cl.getElementId("host-scroll")).bounding_box;
    const cx = box.x + box.width * 0.5;
    const cy = box.y + box.height * 0.5;
    // Press, then drag down 40px through motion events (button 0).
    h.onPointerEvent(cx, cy, true, 272);
    h.onPointerEvent(cx, cy + 40, false, 0);
    try std.testing.expect(h.ptr.dragging);
    h.frame(720, 480);
    const y1 = cl.getElementData(cl.getElementId("host-scroll-probe")).bounding_box.y;
    // Slider-style 1:1: pointer down 40 = content up 40.
    try std.testing.expectApproxEqAbs(y0 - 40, y1, 0.5);
}
