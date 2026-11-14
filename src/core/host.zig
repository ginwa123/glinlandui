// Generic Clay app Host: the engine-side owner ui views plugs into.
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
pub const RootFn = *const fn (?*anyopaque, u32, u32) void;

pub const Host = struct {
    alloc: std.mem.Allocator,
    renderer: ?render.Renderer = null,
    renderer_attempted: bool = false,
    clay_mem: []u8 = &.{},
    clay_ready: bool = false,
    /// Theme-independent default (720x480 literal); caller may override win_w/h after init (same values as ui/theme.zig, the source of truth — no theme.
    win_w: u32 = 720,
    win_h: u32 = 480,
    ptr: dispatch.PtrState = .{},
    /// Millisecond clock for double-click timing. The app supplies one (its own Io); null means no double clicks.
    clock: ?*const fn (?*anyopaque) i64 = null,
    clock_ctx: ?*anyopaque = null,
    /// A monotonic frame clock in seconds. The host advances it; a component only reads it.
    clock_s: f32 = 0,
    /// Pending wheel scroll delta (px, accumulated by onScrollEvent, consumed once per frame by frame() into Clay's scroll containers).
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
        // Nothing is on screen yet, so the first frame of this host is never "the same as the last".
        frame_mod.resetCommandsDigest();
        return self;
    }

    pub fn deinit(self: *Host) void {
        if (self.renderer) |*r| r.deinit();
        self.renderer = null;
        if (self.clay_mem.len > 0) self.alloc.free(self.clay_mem);
        self.clay_mem = &.{};
        self.clay_ready = false;
    }

    /// The per-frame declare phase: reset the per-frame registries, then run the app's root callback.
    pub fn declareFrame(self: *Host, w: u32, h: u32) void {
        // Fresh registries per frame (components self-register during declare; stale boxes must never ghost-fire).
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

    /// Frame variant used by the reusable headless test driver.
    pub fn frameWithOptions(self: *Host, w: u32, h: u32, options: ?*const frame_mod.FrameOptions) u32 {
        if (!self.clay_ready) return frame_mod.shape_default;
        self.win_w = w;
        self.win_h = h;
        // The pointer and the clock are frame state, so a component can place a caret from a click and blink it.
        frame_mod.setPointer(self.ptr.x, self.ptr.y);
        // The press origin too, so a field can refuse a drag that began outside it.
        frame_mod.setPointerButton(self.ptr.down, self.ptr.down_x, self.ptr.down_y);
        self.clock_s += 0.016;
        frame_mod.setTime(self.clock_s, 0.016);
        // Consume the wheel delta once per frame, in WHOLE pixels with the remainder carried: a sub-pixel offset re-rasterises every glyph.
        const dx = @trunc(self.scroll_dx);
        const dy = @trunc(self.scroll_dy);
        self.scroll_dx -= dx;
        self.scroll_dy -= dy;
        // clayFrame resolves the cursor shape AFTER endLayout into frame_mod.currentShape() (it also returns it; void here keeps Delegate.on_frame and all.
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
        // Keep the frame-visible pointer current, so a click handler dispatched below places the caret where the release happened.
        frame_mod.setPointer(x, y);
        // Stamp the event so a double click can be told from two clicks; with no clock every click is a single.
        self.ptr.now_ms = if (self.clock) |f| f(self.clock_ctx) else 0;
        dispatch.pointerEvent(&self.ptr, x, y, pressed, button, self.win_w, self.win_h);
        // Slider-style drag: while a press-drag is in flight, nudge the scroll container under the pointer 1:1 (pointer down = scroll down).
        if (self.ptr.down and self.ptr.dragging and (x != last_x or y != last_y)) {
            scroll_mod.dragScroll(x, y, x - last_x, y - last_y);
        }
    }

    pub fn onScrollEvent(self: *Host, dx: f32, dy: f32) void {
        // A delta this small moves nothing on screen, so it must not make the next frame count as dirty.
        if (@abs(dx) < 0.01 and @abs(dy) < 0.01) return;
        self.scroll_dx += dx;
        self.scroll_dy += dy;
    }

    pub fn onKeyEvent(self: *Host, keycode: u32, pressed: bool) bool {
        return dispatch.handleKey(&self.keys, keycode, pressed);
    }

    /// Composed text from a backend that has a keyboard layout; typing never goes through the key chain.
    pub fn onTextEvent(self: *Host, text: []const u8) bool {
        return dispatch.handleText(&self.keys, text);
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

    fn onText(ptr: *anyopaque, text: []const u8) void {
        const self: *Host = @ptrCast(@alignCast(ptr));
        _ = self.onTextEvent(text);
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
            .on_text = onText,
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

// ARENA DISCIPLINE (mirrors ui views_test.zig): testHost() intentionally never deinits — Clay keeps a global currentContext pointer inside the init.
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
    // deinit flag/free transitions on a stack Host (no Clay arena — safe; testing.allocator fails on leak, so a live free is proven).
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

test "host: a frame applies whole pixels of scroll and keeps the remainder" {
    var h: Host = undefined;
    try testHost(&h, null, noopRoot);
    // Three small deltas add up to one pixel plus a remainder; the pixel moves now, the remainder waits.
    h.onScrollEvent(0, -0.4);
    h.onScrollEvent(0, -0.4);
    h.onScrollEvent(0, -0.4);
    h.frame(800, 600);
    try std.testing.expectApproxEqAbs(@as(f32, -0.2), h.scroll_dy, 0.001);
}

test "host: a no-op scroll does not make the frame dirty" {
    var h: Host = undefined;
    try testHost(&h, null, noopRoot);
    // A zero delta, or jitter below a hundredth of a point, must not cost a repaint: that kept an idle window at 60 fps.
    h.onScrollEvent(0, 0);
    h.onScrollEvent(0.001, -0.004);
    try std.testing.expectEqual(@as(f32, 0), h.scroll_dy);
    h.onScrollEvent(0, -40);
    try std.testing.expectEqual(@as(f32, -40), h.scroll_dy);
}

test "host: empty keychain returns false (press + release)" {
    var h: Host = undefined;
    try testHost(&h, null, noopRoot);
    try std.testing.expect(!h.onKeyEvent(30, true));
    try std.testing.expect(!h.onKeyEvent(30, false));
}

test "host: delegate on_text reaches the registered text handler" {
    var h: Host = undefined;
    try testHost(&h, null, noopRoot);
    var r = dispatch.TextRec{ .ret = true };
    h.keys.registerText(dispatch.textRec, &r);
    const d = h.delegate();
    d.on_text.?(d.ptr, "A");
    try std.testing.expectEqual(@as(usize, 1), r.calls);
    try std.testing.expectEqualStrings("A", r.last[0..r.last_len]);
    try std.testing.expect(h.onTextEvent("*"));
    try std.testing.expectEqual(@as(usize, 2), r.calls);
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
