// Generic Clay app Host: the engine-side owner ui views plugs into.
const std = @import("std");
const contract = @import("window_contract.zig");
const render = @import("render.zig");
const frame_mod = @import("frame.zig");
const theme_mod = @import("theme.zig");
const dispatch = @import("component.zig").dispatch;

const keyboard = @import("keyboard_constant.zig");

/// The keys the Host itself acts on, from the one table: Escape, Tab, and the five a browser zooms with.
const key_escape: u32 = keyboard.KEY_ESCAPE;
const key_tab: u32 = keyboard.KEY_TAB;
const key_0: u32 = keyboard.KEY_ZERO;
const key_minus: u32 = keyboard.KEY_MINUS;
const key_equal: u32 = keyboard.KEY_EQUAL;
const key_kp_minus: u32 = keyboard.KEY_KP_MINUS;
const key_kp_plus: u32 = keyboard.KEY_KP_PLUS;
const zoom_mod = @import("zoom.zig");
const focus_mod = @import("component.zig").focus;
const registry = @import("component.zig").click_registry;
const image_widgets = @import("component.zig").image;
const cl = @import("zclay");
const scroll_mod = @import("component.zig").scroll;
const input_mod = @import("component.zig").input;
const context_menu = @import("component.zig").context_menu;
const reorder_mod = @import("component.zig").reorder;
const semantics = @import("semantics.zig");
const inspector_mod = @import("devtools/inspector.zig");
const glyphs = @import("glyphs.zig");
const text_face = @import("text_face.zig");
const clock_mod = @import("clock.zig");
const momentum = @import("momentum.zig");

/// App declare callback: builds the Clay tree for a w x h window.
pub const RootFn = *const fn (?*anyopaque, u32, u32) void;

/// The devtool service, if the app hosts one: the frame loop fires a waiting request before the app declares, and serialises its reply once the tree is resolved.
pub const ServiceHooks = struct {
    ptr: *anyopaque,
    begin: *const fn (ptr: *anyopaque, host: *Host) void,
    end: *const fn (ptr: *anyopaque, host: *Host, w: u32, h: u32) void,
};

/// A layout's own floor: the size the app needs before its panels stop fitting.
pub const MinContent = struct { w: u32 = 0, h: u32 = 0 };

pub const Host = struct {
    /// True while a drag that BEGAN over a text target is in flight: selecting text must not also scroll the pane.
    drag_selecting_text: bool = false,
    alloc: std.mem.Allocator,
    renderer: ?render.Renderer = null,
    renderer_attempted: bool = false,
    clay_mem: []u8 = &.{},
    clay_ready: bool = false,
    /// The smallest content box this app can lay out in: the Host caps the zoom there, so a window cannot squeeze the layout past it.
    min_content: MinContent = .{},
    /// The window's theme: the Activity hands its own here once, and every component that left a prop to the theme follows it.
    theme: theme_mod.Theme = theme_mod.dark,

    /// The window's own size, before the zoom divided it: what the cap above is computed from.
    window_w: u32 = 720,
    window_h: u32 = 480,

    /// Theme-independent default (720x480 literal); caller may override win_w/h after init (same values as ui/theme.zig, the source of truth — no theme.
    win_w: u32 = 720,
    win_h: u32 = 480,
    ptr: dispatch.PtrState = .{},
    /// Millisecond clock for double-click timing and the caret blink. Defaults to the platform's monotonic clock; null means no double clicks and a fixed frame step.
    clock: ?*const fn (?*anyopaque) i64 = null,
    clock_ctx: ?*anyopaque = null,
    /// A monotonic frame clock in seconds. The host advances it; a component only reads it.
    clock_s: f32 = 0,
    /// The wall clock reading of the last frame, in milliseconds, so `delta_s` is real time rather than one frame's worth.
    last_clock_ms: i64 = 0,
    /// Pending wheel scroll delta (px, accumulated by onScrollEvent, consumed once per frame by frame() into Clay's scroll containers).
    scroll_dx: f32 = 0,
    scroll_dy: f32 = 0,
    /// The same wheel delta again, kept for the glide's measurement: the pending scroll is spent in whole pixels, this one stays whole.
    gesture_dx: f32 = 0,
    gesture_dy: f32 = 0,
    /// A wheel event arrived since the last frame, so the glide measures this frame's gesture instead of taking over.
    gesture_open: bool = false,
    /// The glide a flick leaves behind, so a trackpad that reports no momentum of its own still coasts to a stop.
    glide: momentum.Glide = .{},
    quit_requested: bool = false,
    /// An app that must ask before the window closes (unsaved work): return true to HANDLE the close yourself.
    close_hook: ?*const fn (?*anyopaque) bool = null,
    close_ctx: ?*anyopaque = null,
    views: dispatch.Views = .{},
    keys: dispatch.KeyChain = .{},
    root_ctx: ?*anyopaque = null,
    root_fn: RootFn,
    /// The devtool. Non-null turns the app into one that answers a right click with its own component tree; the app's own code is untouched.
    inspect: ?*inspector_mod.Inspector = null,
    /// The allocator `devtools.attach` made the inspector with, so the shutdown frees it with the same one.
    inspect_alloc: ?std.mem.Allocator = null,
    /// The devtool service. Non-null means a client may be waiting on this frame, so the loop fires its request before declaring and answers after resolving.
    service: ?ServiceHooks = null,

    pub fn init(alloc: std.mem.Allocator, ctx: ?*anyopaque, root_fn: RootFn) !Host {
        // The platform's monotonic clock by default: a double click and a 1 Hz caret need real time, and an app that never wires one has neither.
        var self = Host{ .alloc = alloc, .root_ctx = ctx, .root_fn = root_fn, .clock = clock_mod.monoMs };
        // The glyph cache and the measured face spend the app's allocator, not a page-per-glyph one of their own.
        glyphs.initCache(alloc);
        text_face.setAllocator(alloc);
        // Text fields grow past their inline buffer with the same allocator, so no field has a length limit.
        input_mod.setTextAllocator(alloc);
        self.clay_mem = try frame_mod.initClay(alloc, self.win_w, self.win_h);
        self.clay_ready = true;
        // Nothing is on screen yet, so the first frame of this host is never "the same as the last", and no field owns the keyboard.
        frame_mod.resetCommandsDigest();
        frame_mod.resetFocus();
        return self;
    }

    pub fn deinit(self: *Host) void {
        if (self.renderer) |*r| r.deinit();
        self.renderer = null;
        if (self.clay_mem.len > 0) self.alloc.free(self.clay_mem);
        self.clay_mem = &.{};
        // The duplicate-id set `initClay` sized from Clay's ceiling shares the arena's lifetime and the arena's allocator.
        frame_mod.deinitIdSet();
        self.clay_ready = false;
        // The devtool is heap memory made with `attach`'s allocator: free it, or a debug allocator reports it as a leak.
        if (self.inspect) |dev| {
            dev.search.deinit();
            (self.inspect_alloc orelse self.alloc).destroy(dev);
        }
        self.inspect = null;
        // The glyph cache and the measured face are process-lifetime singletons that spent THIS host's allocator, so a shutdown gives them back.
        glyphs.deinitCache();
        text_face.deinitFace();
    }

    /// The per-frame declare phase: reset the per-frame registries, then run the app's root callback.
    pub fn declareFrame(self: *Host, w: u32, h: u32) void {
        // A devtool client is waiting: fire its action BEFORE the registries are cleared, so it lands in the targets the last frame declared.
        if (self.service) |svc| svc.begin(svc.ptr, self);
        // Fresh registries per frame (components self-register during declare; stale boxes must never ghost-fire).
        frame_mod.beginDragFrame();
        registry.beginFrame();
        context_menu.beginFrame();
        reorder_mod.beginFrame();
        scroll_mod.beginScrollFrame();
        input_mod.beginFrame();
        image_widgets.beginFrame();
        semantics.beginFrame();
        self.root_fn(self.root_ctx, w, h);
        // The context menu is the engine's, so it needs no declaration from the app: it floats over the tree it was raised from.
        context_menu.declare();
        // The devtool declares last, so its overlay paints over the app; it registers no semantics node, so it never shows up in its own tree.
        if (self.inspect) |dev| dev.declare(w, h);
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
        // A window too small for the zoom it was left on steps back to a rung that fits.
        self.window_w = w;
        self.window_h = h;
        if (frame_mod.zoom() > self.zoomCeiling()) self.setZoom(frame_mod.zoom());
        // Everything the app and its components touch is content points: a zoomed window simply holds fewer of them.
        self.win_w = frame_mod.contentWidth(w);
        self.win_h = frame_mod.contentHeight(h);
        // The pointer and the clock are frame state, so a component can place a caret from a click and blink it.
        frame_mod.setPointer(self.ptr.x, self.ptr.y);
        // The press origin too, so a field can refuse a drag that began outside it.
        frame_mod.setPointerButton(self.ptr.down, self.ptr.down_x, self.ptr.down_y);
        // Real elapsed time when the host has a clock (a caret must blink once a second at 60 fps and at 144 fps); a fixed step otherwise, so tests stay deterministic.
        const now_ms: i64 = if (self.clock) |f| f(self.clock_ctx) else 0;
        const delta: f32 = if (self.clock != null and self.last_clock_ms != 0 and now_ms > self.last_clock_ms)
            @min(@as(f32, @floatFromInt(now_ms - self.last_clock_ms)) / 1000.0, 0.25)
        else
            0.016;
        self.last_clock_ms = now_ms;
        self.clock_s += delta;
        frame_mod.setTime(self.clock_s, delta);
        // The wheel's own motion is the gesture's; a flick that stopped arriving is the glide's to finish, so the two are stepped in order and never at once.
        if (self.gesture_open) {
            self.glide.feed(self.gesture_dx, self.gesture_dy, delta);
            self.gesture_dx = 0;
            self.gesture_dy = 0;
            self.gesture_open = false;
        }
        const glided = if (self.glide.advance(delta)) |d| blk: {
            self.scroll_dx += d.dx;
            self.scroll_dy += d.dy;
            break :blk true;
        } else false;
        // Consume the wheel delta once per frame, in WHOLE pixels with the remainder carried: a sub-pixel offset re-rasterises every glyph.
        const dx = @trunc(self.scroll_dx);
        const dy = @trunc(self.scroll_dy);
        self.scroll_dx -= dx;
        self.scroll_dy -= dy;
        // clayFrame resolves the cursor shape AFTER endLayout into frame_mod.currentShape() (it also returns it; void here keeps Delegate.on_frame and all.
        var effective: frame_mod.FrameOptions = if (options) |opts| opts.* else .{};
        // A devtool reads the resolved tree, so attaching one turns the resolve on: the app never has to know its frames are being watched.
        if (self.inspect != null or self.service != null) effective.resolve_semantics = true;
        // The theme in force for this frame: a component resolves the props its app left unset against it.
        theme_mod.setCurrent(self.theme);
        const shape = frame_mod.clayFrameWithOptions(
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
            &effective,
        );
        // A glide whose whole pixels moved nothing — the list is at its end, or no list is under the pointer — ends here rather than asking for a second of frames that draw the same pixels; a glide that did move asks for the next frame itself, the way an animation does.
        if (glided) {
            if (dx == 0 and dy == 0) frame_mod.requestFrame() else if (frame_mod.wheelMoved()) frame_mod.requestFrame() else self.glide.end();
        } else if (self.glide.pending()) {
            // The quiet gap before a takeover is measured in frames, and no event will arrive to supply them.
            frame_mod.requestFrame();
        }
        // Every box is real now, so a component that asked to stay in view is scrolled before the next frame draws.
        scroll_mod.applyReveals();
        // The tree is resolved now, so a waiting client can be answered from this frame rather than the last one.
        if (self.service) |svc| svc.end(svc.ptr, self, w, h);
        return shape;
    }

    pub fn onPointerEvent(self: *Host, window_x: f32, window_y: f32, pressed: bool, button: u32) void {
        // The app declares in content points and the window reports window points: one division, so both spaces agree.
        const x = window_x / frame_mod.zoom();
        const y = window_y / frame_mod.zoom();
        // A click carries the keyboard modifiers it was made with, which is what makes a shift-click extend a run.
        frame_mod.setPointerShift(self.keys.mods.shift);
        // A right press asks the app's components first: a widget offering a menu owns the click it was right-clicked in.
        if (button == dispatch.BTN_RIGHT) {
            if (pressed) {
                const offered = context_menu.secondaryClick(x, y, @floatFromInt(self.win_w), @floatFromInt(self.win_h));
                // With no menu under the pointer the click is the devtool's, which is how both can live in one window.
                if (!offered) if (self.inspect) |dev| dev.onSecondaryClick(x, y);
            }
            return;
        }
        // A left press belongs to an open card: inside it a row answers on release, outside it dismisses and goes no further.
        if (button == dispatch.BTN_LEFT and pressed and context_menu.leftPress(x, y)) return;
        // Remember where a drag STARTED: over text it is a selection, and a selection must not drag the pane with it.
        if (button == dispatch.BTN_LEFT) {
            if (pressed) self.drag_selecting_text = registry.hoverCursorAt(x, y) == .text else self.drag_selecting_text = false;
        }
        // A drag-to-reorder starts on a press over a draggable row, and reports on the release.
        if (button == dispatch.BTN_LEFT) {
            if (pressed) reorder_mod.press(x, y) else _ = reorder_mod.release(x, y);
        }
        // The picker follows the pointer between frames, so the outline is under the cursor before the click lands.
        if (self.inspect) |dev| dev.onPointerMove(x, y);
        const last_x = self.ptr.x;
        const last_y = self.ptr.y;
        // Keep the frame-visible pointer current, so a click handler dispatched below places the caret where the release happened.
        frame_mod.setPointer(x, y);
        // Stamp the event so a double click can be told from two clicks; with no clock every click is a single.
        self.ptr.now_ms = if (self.clock) |f| f(self.clock_ctx) else 0;
        dispatch.pointerEvent(&self.ptr, x, y, pressed, button, self.win_w, self.win_h);
        // The scrollbar pill owns the pointer from the press that grabs it to the release: its travel is shorter than the content's, so it maps its own ratio.
        if (pressed and button == dispatch.BTN_LEFT) {
            // The pill first: a press on it is a grab. A press on the TRACK jumps the content to the pointer and then slides the pill with it.
            if (!scroll_mod.beginThumbGrab(x, y)) _ = scroll_mod.beginBarPress(x, y);
        }
        const thumb_moved = scroll_mod.moveThumb(x, y);
        if (button == dispatch.BTN_LEFT and !pressed) scroll_mod.endThumbGrab();
        if (thumb_moved) return;
        // Slider-style drag: a press that is HELD and moved nudges the pane 1:1 — a move is button 0, whatever `pressed` the backend calls it.
        if (button == 0 and self.ptr.down and self.ptr.dragging and (x != last_x or y != last_y)) {
            if (!self.drag_selecting_text and !frame_mod.dragClaimed()) scroll_mod.dragScroll(x, y, x - last_x, y - last_y);
            reorder_mod.move(x, y);
        }
    }

    pub fn onScrollEvent(self: *Host, dx: f32, dy: f32) void {
        // A delta this small moves nothing on screen, so it must not make the next frame count as dirty.
        if (@abs(dx) < 0.01 and @abs(dy) < 0.01) return;
        // Window points to content points: a wheel notch moves the same amount of layout at any zoom.
        const content_dx = dx / frame_mod.zoom();
        const content_dy = dy / frame_mod.zoom();
        self.scroll_dx += content_dx;
        self.scroll_dy += content_dy;
        self.gesture_dx += content_dx;
        self.gesture_dy += content_dy;
        self.gesture_open = true;
    }

    /// The return value is CLOSE INTENT, which the window acts on: a key the focused field typed is never one.
    pub fn onKeyEvent(self: *Host, keycode: u32, pressed: bool) bool {
        // `Ctrl/Cmd +` / `-` / `0` zoom the content, and the engine owns the gesture: an app routes none of it.
        if (pressed and self.keys.mods.shortcut()) {
            switch (keycode) {
                key_equal, key_kp_plus => {
                    self.setZoom(zoom_mod.next(frame_mod.zoom(), 1));
                    return false;
                },
                key_minus, key_kp_minus => {
                    self.setZoom(zoom_mod.next(frame_mod.zoom(), -1));
                    return false;
                },
                key_0 => {
                    self.setZoom(zoom_mod.reset);
                    return false;
                },
                else => {},
            }
        }
        // Escape dismisses an open context menu, and stops there: it is not the app's close intent either.
        if (pressed and keycode == key_escape and context_menu.isOpen()) {
            context_menu.close();
            return false;
        }
        // Escape also abandons a drag, so a row picked up by mistake lands back where it was.
        if (pressed and keycode == key_escape) reorder_mod.cancel();
        // Escape closes the devtool while it is up, and is never read as the app's close intent.
        if (self.inspect) |dev| {
            if (dev.onKey(keycode)) return false;
        }
        // Tab walks the focusable components and Escape hands the keyboard back: every control is reachable, and none of them is a trap (WCAG 2.1.1, 2.1.2).
        if (pressed and keycode == key_tab) {
            _ = focus_mod.advance(self.keys.mods.shift);
            return false;
        }
        if (pressed and keycode == key_escape and frame_mod.focusedId() != null) {
            frame_mod.setFocus(null);
            return false;
        }
        if (dispatch.handleKey(&self.keys, keycode, pressed)) return true;
        // No app handler asked to close: the focused field takes the key, so typing needs no routing code in the app.
        if (pressed) _ = input_mod.dispatchKey(self.keys.mods, keycode);
        return false;
    }

    /// Composed text from a backend that has a keyboard layout; typing never goes through the key chain.
    pub fn onTextEvent(self: *Host, text: []const u8) bool {
        if (dispatch.handleText(&self.keys, text)) return true;
        return input_mod.dispatchText(text);
    }

    pub fn onResizeEvent(self: *Host, w: u32, h: u32) void {
        self.window_w = w;
        self.window_h = h;
        if (frame_mod.zoom() > self.zoomCeiling()) self.setZoom(frame_mod.zoom());
        self.win_w = frame_mod.contentWidth(w);
        self.win_h = frame_mod.contentHeight(h);
    }

    pub fn onCloseEvent(self: *Host) void {
        // An app with unsaved work holds the window open and asks its own question; it calls `requestQuit` when answered.
        if (self.close_hook) |hook| {
            if (hook(self.close_ctx)) return;
        }
        self.quit_requested = true;
    }

    /// The content zoom in force: 1.0 until `Ctrl/Cmd +` / `-` or an app's own control moves it.
    pub fn zoomFactor(self: *Host) f32 {
        _ = self;
        return frame_mod.zoom();
    }

    /// Set the content zoom, as `Ctrl/Cmd +` / `-` / `0` do; a menu or a settings row calls this instead.
    pub fn setZoom(self: *Host, factor: f32) void {
        const ceiling = self.zoomCeiling();
        if (zoom_mod.clamp(factor) > ceiling) {
            frame_mod.setZoom(zoom_mod.largestAtMost(ceiling));
            return;
        }
        frame_mod.setZoom(factor);
    }

    /// The zoom this window can show without squeezing the layout below `min_content`; the ladder's top when no floor is set.
    fn zoomCeiling(self: *const Host) f32 {
        if (self.min_content.w == 0 or self.min_content.h == 0) return zoom_mod.steps[zoom_mod.steps.len - 1];
        const fw: f32 = @floatFromInt(self.window_w);
        const fh: f32 = @floatFromInt(self.window_h);
        const cw: f32 = @floatFromInt(self.min_content.w);
        const ch: f32 = @floatFromInt(self.min_content.h);
        return @max(1.0, @min(fw / cw, fh / ch));
    }

    /// Close the window: what an app calls once its own question is answered.
    pub fn requestQuit(self: *Host) void {
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

test "host: deinit hands back the glyph cache, the face and the devtool it latched" {
    var d = Host{ .alloc = std.testing.allocator, .root_fn = noopRoot };
    glyphs.initCache(std.testing.allocator);
    text_face.setAllocator(std.testing.allocator);
    defer text_face.setAllocator(std.heap.page_allocator);
    // One cached mask and one devtool, so the shutdown has something that would leak if it were skipped.
    if (text_face.font()) |f| _ = glyphs.cachedGlyph(f, 'K', 14);
    d.inspect = std.testing.allocator.create(inspector_mod.Inspector) catch return error.OutOfMemory;
    d.inspect.?.* = .{};
    d.inspect_alloc = std.testing.allocator;
    d.deinit();
    try std.testing.expect(d.inspect == null);
    try std.testing.expectEqual(@as(usize, 0), glyphs.cachedGlyphCount());
    // testing.allocator fails this test if the arena, the map, the face's bytes or the devtool are still live.
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

// An app that must ask before closing: the hook holds the window open, and `requestQuit` is the answer.
const CloseHolder = struct {
    var calls: usize = 0;

    fn hook(_: ?*anyopaque) bool {
        calls += 1;
        return true;
    }
};

test "host: a close hook can hold the window open, and requestQuit closes it" {
    var h: Host = undefined;
    try testHost(&h, null, noopRoot);
    CloseHolder.calls = 0;
    h.close_hook = CloseHolder.hook;
    h.onCloseEvent();
    try std.testing.expect(!h.isQuit());
    try std.testing.expectEqual(@as(usize, 1), CloseHolder.calls);
    h.requestQuit();
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

fn hostNestedProbeChildren(_: void) void {
    cl.UI()(.{
        .id = .ID("host-outer-probe"),
        .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(40) } },
    })({});
    scroll_mod.scroll(.{ .id = .{ .text = "host-inner" }, .w = .{ .fixed = 100 }, .h = .{ .fixed = 50 } }, {}, hostNestedInnerChildren);
    var i: usize = 0;
    while (i < 2) : (i += 1) {
        cl.UI()(.{ .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(40) } } })({});
    }
}

fn hostNestedInnerChildren(_: void) void {
    var i: usize = 0;
    while (i < 6) : (i += 1) {
        cl.UI()(.{ .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(40) } } })({});
    }
}

fn hostNestedRoot(_: ?*anyopaque, _: u32, _: u32) void {
    scroll_mod.scroll(.{ .id = .{ .text = "host-outer" }, .w = .{ .fixed = 200 }, .h = .{ .fixed = 100 } }, {}, hostNestedProbeChildren);
}

test "host: a nested scroll at its end hands the wheel to the page behind it" {
    var h: Host = undefined;
    try testHost(&h, null, hostNestedRoot);
    h.frame(720, 480);
    const outer_probe = cl.getElementId("host-outer-probe");
    const y0 = cl.getElementData(outer_probe).bounding_box.y;
    // Hover the inner container: 50 of 240 points are showing, so 19 notches of 10 exhaust it.
    const inner = cl.getElementData(cl.getElementId("host-inner")).bounding_box;
    h.onPointerEvent(inner.x + inner.width * 0.5, inner.y + inner.height * 0.5, false, 0);
    var i: usize = 0;
    while (i < 19) : (i += 1) {
        h.onScrollEvent(0, 10);
        h.frame(720, 480);
    }
    // Every notch goes to the inner list first, and the first notch it cannot use goes to the page behind it.
    var notches: usize = 0;
    while (notches < 80 and cl.getElementData(outer_probe).bounding_box.y >= y0) : (notches += 1) {
        h.onScrollEvent(0, 10);
        h.frame(720, 480);
    }
    try std.testing.expect(cl.getElementData(outer_probe).bounding_box.y < y0);
    try std.testing.expectApproxEqAbs(@as(f32, 190), scroll_mod.view("host-inner").y, 0.5);
}

fn hostTallProbeChildren(_: void) void {
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        cl.UI()(.{
            .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(40) } },
            .background_color = .{ 100, 100, 100, 255 },
        })({});
    }
}

fn hostTallRoot(_: ?*anyopaque, _: u32, _: u32) void {
    scroll_mod.scroll(.{ .id = .{ .text = "host-tall" }, .h = .{ .fixed = 100 }, .w = .{ .fixed = 200 } }, {}, hostTallProbeChildren);
}

test "host: one wheel notch moves the list by the notch and no further" {
    var h: Host = undefined;
    try testHost(&h, null, hostTallRoot);
    // A fixed frame step: the glide is counted in frames, so where it ends does not depend on how fast this machine ran the test.
    h.clock = null;
    h.frame(720, 480);
    const box = cl.getElementData(cl.getElementId("host-tall")).bounding_box;
    h.onPointerEvent(box.x + box.width * 0.5, box.y + box.height * 0.5, false, 0);
    // A mouse wheel is a detent: Windows delivers one whole notch (60 pt) in ONE message, and the next one only when the hand turns the wheel again.
    h.onScrollEvent(0, 60);
    h.frame(720, 480);
    try std.testing.expectApproxEqAbs(@as(f32, 60), scroll_mod.view("host-tall").y, 0.5);
    // Nothing follows a notch, and nothing may: it carries no velocity to hand over, so the list stops where the notch put it.
    var i: usize = 0;
    while (i < 120) : (i += 1) h.frame(720, 480);
    try std.testing.expectApproxEqAbs(@as(f32, 60), scroll_mod.view("host-tall").y, 0.5);
}

test "host: a flick spread over several frames keeps the list scrolling after the wheel events stop" {
    var h: Host = undefined;
    try testHost(&h, null, hostTallRoot);
    h.clock = null;
    h.frame(720, 480);
    const box = cl.getElementData(cl.getElementId("host-tall")).bounding_box;
    h.onPointerEvent(box.x + box.width * 0.5, box.y + box.height * 0.5, false, 0);
    // A trackpad reports the fingers on frame after frame; the gesture is the run of frames, not one event in it.
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        h.onScrollEvent(0, 40);
        h.frame(720, 480);
    }
    const released = scroll_mod.view("host-tall").y;
    try std.testing.expectApproxEqAbs(@as(f32, 160), released, 0.5);
    // No event arrives, and the list goes on moving: this is the whole defect the glide exists for.
    i = 0;
    while (i < 60) : (i += 1) h.frame(720, 480);
    try std.testing.expect(scroll_mod.view("host-tall").y > released + 20);
}

fn hostScrollProbeRoot(_: ?*anyopaque, _: u32, _: u32) void {
    scroll_mod.scroll(.{ .id = .{ .text = "host-scroll" }, .h = .{ .fixed = 100 }, .w = .{ .fixed = 200 } }, {}, hostScrollProbeChildren);
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
    // +5 Wayland dy is 5 px of content: one point of gesture, one point of movement.
    try std.testing.expectApproxEqAbs(y0 - 5, y1, 0.5);
}

test "host: a flick keeps the list scrolling after the wheel events stop" {
    var h: Host = undefined;
    try testHost(&h, null, hostScrollProbeRoot);
    // A fixed frame step: the glide is counted in frames, so where it ends does not depend on how fast this machine ran the test.
    h.clock = null;
    h.frame(720, 480);
    const box = cl.getElementData(cl.getElementId("host-scroll")).bounding_box;
    h.onPointerEvent(box.x + box.width * 0.5, box.y + box.height * 0.5, false, 0);
    // A trackpad flick: a delta on each of several frames, then silence — the moment the fingers leave the pad.
    var gesture: usize = 0;
    while (gesture < 4) : (gesture += 1) {
        h.onScrollEvent(0, 10);
        h.frame(720, 480);
    }
    const released = scroll_mod.view("host-scroll").y;
    try std.testing.expectApproxEqAbs(@as(f32, 40), released, 0.5);
    // No event arrives, and the list goes on moving: this is the whole defect the glide exists for.
    var previous = released;
    var frames: usize = 0;
    var coasted: usize = 0;
    while (frames < 200) : (frames += 1) {
        h.frame(720, 480);
        const y = scroll_mod.view("host-scroll").y;
        if (y > previous) coasted += 1;
        // The quiet gap before the glide starts is not the end of it: the coast is over when it has begun and then stopped.
        if (coasted > 0 and y <= previous) break;
        previous = y;
    }
    try std.testing.expect(coasted > 1);
    try std.testing.expect(previous > released + 20);
    // 400 points of content in a 100-point viewport: a flick can only ever reach the end, never run past it.
    try std.testing.expect(previous <= 300.5);
}

test "host: a coasting list asks for the frames it needs, and stops asking once it has no room left" {
    var h: Host = undefined;
    try testHost(&h, null, hostScrollProbeRoot);
    h.clock = null;
    h.frame(720, 480);
    const box = cl.getElementData(cl.getElementId("host-scroll")).bounding_box;
    h.onPointerEvent(box.x + box.width * 0.5, box.y + box.height * 0.5, false, 0);
    var gesture: usize = 0;
    while (gesture < 4) : (gesture += 1) {
        h.onScrollEvent(0, 10);
        h.frame(720, 480);
    }
    _ = frame_mod.takeRepaintRequest();
    // No event will carry the next frame of a coast, so the coast asks for it, exactly as an animation does.
    var asked: usize = 0;
    var i: usize = 0;
    while (i < 12) : (i += 1) {
        h.frame(720, 480);
        if (frame_mod.takeRepaintRequest()) asked += 1;
    }
    try std.testing.expect(asked >= 3);
    // The list reaches its end, and the frames end with it: a coast that moves nothing must not draw a second of the same pixels.
    i = 0;
    while (i < 60) : (i += 1) {
        h.frame(720, 480);
        _ = frame_mod.takeRepaintRequest();
    }
    h.frame(720, 480);
    try std.testing.expect(!frame_mod.takeRepaintRequest());
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

test "host: a drag move counts as a move whatever `pressed` the backend calls it" {
    var h: Host = undefined;
    try testHost(&h, null, hostScrollProbeRoot);
    h.frame(720, 480);
    const y0 = cl.getElementData(cl.getElementId("host-scroll-probe")).bounding_box.y;
    const box = cl.getElementData(cl.getElementId("host-scroll")).bounding_box;
    const cx = box.x + box.width * 0.5;
    const cy = box.y + box.height * 0.5;
    // macOS and Wayland send a motion with the button still down as pressed=true, button 0: the drag used to test `!pressed` and dropped every one of them.
    h.onPointerEvent(cx, cy, true, 272);
    h.onPointerEvent(cx, cy + 20, true, 0);
    h.onPointerEvent(cx, cy + 40, true, 0);
    try std.testing.expect(h.ptr.dragging);
    h.frame(720, 480);
    const y1 = cl.getElementData(cl.getElementId("host-scroll-probe")).bounding_box.y;
    try std.testing.expectApproxEqAbs(y0 - 40, y1, 0.5);
}

test "host: Ctrl/Cmd +/-/0 zoom the content, and the next frame declares the smaller box" {
    frame_mod.setZoom(1);
    defer frame_mod.setZoom(1);
    var rec = FrameRec{};
    var h: Host = undefined;
    try testHost(&h, &rec, recRoot);
    h.frame(720, 480);
    try std.testing.expectEqual(@as(u32, 720), rec.w);
    try std.testing.expectEqual(@as(u32, 480), rec.h);

    // Ctrl goes down first, as every backend sends it, so the chain latches it before `=`.
    _ = h.onKeyEvent(29, true);
    _ = h.onKeyEvent(key_equal, true);
    try std.testing.expectApproxEqAbs(@as(f32, 1.1), frame_mod.zoom(), 0.001);
    h.frame(720, 480);
    // The app declares in a 655x436 box and the window paints it at 110%.
    try std.testing.expectEqual(@as(u32, 655), rec.w);
    try std.testing.expectEqual(@as(u32, 436), rec.h);
    try std.testing.expectEqual(@as(u32, 655), h.win_w);

    // `0` puts it back; the app never sees any of it.
    _ = h.onKeyEvent(key_0, true);
    try std.testing.expectEqual(@as(f32, 1.0), frame_mod.zoom());
    // And a bare `=` is just a key: an editor types it.
    _ = h.onKeyEvent(29, false);
    _ = h.onKeyEvent(key_equal, true);
    try std.testing.expectEqual(@as(f32, 1.0), frame_mod.zoom());
}

test "host: a zoom the window cannot show stops at the rung that fits" {
    frame_mod.setZoom(1);
    defer frame_mod.setZoom(1);
    var h: Host = undefined;
    try testHost(&h, null, noopRoot);
    h.frame(1280, 840);
    // The app's own floor: 900x560. At 1280x840 that is 1.42 across and 1.5 down, so 125% fits and 150% does not.
    h.min_content = .{ .w = 900, .h = 560 };
    h.setZoom(1.5);
    try std.testing.expectEqual(@as(f32, 1.25), frame_mod.zoom());
    h.setZoom(2.0);
    try std.testing.expectEqual(@as(f32, 1.25), frame_mod.zoom());
    h.setZoom(1.1);
    try std.testing.expectEqual(@as(f32, 1.1), frame_mod.zoom());
    // A window too small for the zoom in force steps it back to a rung that fits.
    h.onResizeEvent(1000, 560);
    try std.testing.expectEqual(@as(f32, 1.0), frame_mod.zoom());
}

test "host: a host starts with a clock, so two clicks can be told from a double click" {
    var h: Host = undefined;
    try testHost(&h, null, noopRoot);
    // Without a clock the pointer state stays at 0 ms forever, and `fireClick` can only ever report a single click.
    try std.testing.expect(h.clock != null);
    if (h.clock) |read| {
        // A test build resolves to the portable clock, which reports "no clock" rather than a guessed time.
        try std.testing.expectEqual(@as(i64, 0), read(h.clock_ctx));
    }
}

fn testClockMs(ctx: ?*anyopaque) i64 {
    const now_ms: *i64 = @ptrCast(@alignCast(ctx.?));
    return now_ms.*;
}

var contract_field: input_mod.Field = .{ .id = .{ .text = "contract-double-field" } };

fn contractFieldRoot(_: ?*anyopaque, _: u32, _: u32) void {
    input_mod.textField(&contract_field);
}

test "host: two clicks on one spot select the word, so every backend must deliver both presses" {
    var h: Host = undefined;
    try testHost(&h, null, contractFieldRoot);
    var now_ms: i64 = 1000;
    h.clock = testClockMs;
    h.clock_ctx = &now_ms;
    contract_field = .{ .id = .{ .text = "contract-double-field" }, .value = "hello world" };
    h.frame(720, 480);
    const bb = cl.getElementData(cl.getElementId("contract-double-field")).bounding_box;
    // Two points into the run: past the field's own left padding, so the pointer lands inside "hello".
    const x = bb.x + contract_field.pad_lr.pts() + 2;
    const y = bb.y + bb.height * 0.5;
    // What EVERY backend hands the Host for one click: a press and a release. This is that pair, twice, 60 ms apart.
    h.onPointerEvent(x, y, true, 272);
    h.onPointerEvent(x, y, false, 272);
    now_ms += 60;
    h.onPointerEvent(x, y, true, 272);
    h.onPointerEvent(x, y, false, 272);
    const span = contract_field.editor.caret.selection() orelse return error.NoSelection;
    try std.testing.expectEqual(@as(usize, 0), span.start);
    try std.testing.expectEqual(@as(usize, 5), span.end);
}

test "host: a press on the scrollbar track jumps the pane to the pointer and keeps the pill grabbed" {
    var h: Host = undefined;
    try testHost(&h, null, hostScrollProbeRoot);
    h.frame(720, 480);
    // The thumb is declared from the previous frame's scroll data, so the second frame is the one that has a box.
    h.frame(720, 480);
    const thumb = cl.getElementData(cl.ElementId.IDI("host-scroll", scroll_mod.vthumb_index)).bounding_box;
    const cx = thumb.x + thumb.width * 0.5;
    const content_y0 = cl.getElementData(cl.getElementId("host-scroll-probe")).bounding_box.y;
    // Forty points down the TRACK, well below the pill: the pane jumps there, which is the gesture the pill never answered.
    h.onPointerEvent(cx, thumb.y + 40, true, 272);
    try std.testing.expect(scroll_mod.thumbGrabbed());
    h.frame(720, 480);
    const content_y1 = cl.getElementData(cl.getElementId("host-scroll-probe")).bounding_box.y;
    try std.testing.expect(content_y0 - content_y1 > 40);
    h.onPointerEvent(cx, thumb.y + 40, false, 272);
    try std.testing.expect(!scroll_mod.thumbGrabbed());
}

test "host: a press on the scrollbar pill drags its content instead of nudging it 1:1" {
    var h: Host = undefined;
    try testHost(&h, null, hostScrollProbeRoot);
    h.frame(720, 480);
    // The thumb is declared from the previous frame's scroll data, so the second frame is the one that has a box.
    h.frame(720, 480);
    const thumb = cl.getElementData(cl.ElementId.IDI("host-scroll", scroll_mod.vthumb_index)).bounding_box;
    const cx = thumb.x + thumb.width * 0.5;
    const cy = thumb.y + thumb.height * 0.5;
    const content_y0 = cl.getElementData(cl.getElementId("host-scroll-probe")).bounding_box.y;
    h.onPointerEvent(cx, cy, true, 272);
    try std.testing.expect(scroll_mod.thumbGrabbed());
    h.onPointerEvent(cx, cy + 10, false, 0);
    h.frame(720, 480);
    const content_y1 = cl.getElementData(cl.getElementId("host-scroll-probe")).bounding_box.y;
    // Ten points of pill is more than ten points of content: the content moved further than the pointer did.
    try std.testing.expect(content_y0 - content_y1 > 10.5);
    h.onPointerEvent(cx, cy + 10, false, 272);
    try std.testing.expect(!scroll_mod.thumbGrabbed());
}
