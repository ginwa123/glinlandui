// The ViewModel: the only place the screen's state is written.
// This is Kotlin's `LazyScrollViewModel`, and `Store` in the engine is its `ViewModelStore`.
// Every public function here is an INTENT: it never draws, never reads a widget, and never knows a window exists.
const std = @import("std");
const glinlandui = @import("glinlandui");
const scroll_mod = glinlandui.components.scroll;
const input_mod = glinlandui.components.input;
const table = glinlandui.table;

const state_mod = @import("state.zig");
const LazyUiState = state_mod.LazyUiState;

// The one list on the screen. Its id is the screen's, so it lives with the model that scrolls it and not with the view that names it.
pub const scroll_id = "lazy.scroll";

// What the window can do for an animation: ask for another frame, and stop asking once it is over.
pub const FramePump = struct {
    ctx: ?*anyopaque,
    request: *const fn (?*anyopaque) void,
    idle: *const fn (?*anyopaque) void,
};

pub const LazyViewModel = struct {
    // The state, as a plain value: an intent replaces it, and the next frame reads whatever it says.
    ui: LazyUiState = .{},
    // Null in the headless bench, where the test driver produces the frames instead of a window.
    pump: ?FramePump = null,
    // Print the meter once a second, for a run nobody can watch (a benchmark on a build machine).
    log: bool = false,
    log_next_ns: i64 = 0,

    pub fn init() LazyViewModel {
        return .{};
    }

    // `val state by vm.ui`: the value the view draws.
    pub fn uiState(self: *const LazyViewModel) LazyUiState {
        return self.ui;
    }

    // The frame start: the clock is the Activity's, so the measurement arrives as an argument.
    pub fn tick(self: *LazyViewModel, now_ns: i64) void {
        self.ui = self.ui.ticked(now_ns);
    }

    pub fn maybeLog(self: *LazyViewModel, now_ns: i64) void {
        if (!self.log or now_ns < self.log_next_ns) return;
        self.log_next_ns = now_ns + std.time.ns_per_s;
        const s = self.ui.stats();
        std.debug.print("fps {d: >6.1}  frame {d: >5.2} ms  avg {d: >5.2}  max {d: >6.2}  declared {d}\n", .{
            s.fps, s.last_ms, s.avg_ms, s.max_ms, self.ui.declared,
        });
    }

    // The auto-scroll: one step of the animation BEFORE the frame declares, and another frame while it runs.
    pub fn advance(self: *LazyViewModel) void {
        if (!self.ui.auto) return;
        scroll_mod.scrollBy(scroll_id, 0, self.ui.speed);
        self.requestFrame();
    }

    // `onToggleAuto`: Space, or the header's button, and the pump follows the state so an idle window stays quiet.
    pub fn toggleAuto(self: *LazyViewModel) void {
        self.ui = self.ui.withAuto(!self.ui.auto);
        if (self.ui.auto) self.requestFrame() else self.stopFrames();
    }

    // `onJumpBottom`: End, or the header's button. The list clamps the offset to its own content, so no arithmetic here can overshoot.
    pub fn jumpToBottom(self: *LazyViewModel) void {
        _ = self;
        scroll_mod.scrollBy(scroll_id, 0, span());
    }

    pub fn jumpToTop(self: *LazyViewModel) void {
        _ = self;
        scroll_mod.scrollBy(scroll_id, 0, -span());
    }

    // The bench's knob: how fast the animation moves, in points per frame. Speed is state, so it is set through the model.
    pub fn setSpeed(self: *LazyViewModel, points_per_frame: f32) void {
        self.ui = self.ui.withSpeed(points_per_frame);
    }

    // Which rows this frame must declare, and the record of how many that was. The viewport is only readable once the list is declared, which is why
    // this is called from inside it — and the header, declared before it, draws the count the PREVIOUS frame left behind.
    pub fn visibleRows(self: *LazyViewModel) table.Visible {
        const v = scroll_mod.view(scroll_id);
        const view_h: f32 = if (v.found) v.height else 600;
        const vis = table.visible(.{
            .total_rows = state_mod.row_count,
            .total_cols = 1,
            .scroll_y = v.y,
            .height = view_h,
            .width = 0,
            .overscan = 2,
            .row_height = table.row_height,
        });
        self.ui = self.ui.withDeclared(vis.row_count);
        return vis;
    }

    // `onKey`: evdev codes, so the handler is the same on every host. Every case here is an intent, so nothing is scrolled behind the model's back.
    pub fn onKey(raw: ?*anyopaque, mods: input_mod.Mods, keycode: u32) bool {
        _ = mods;
        const self: *LazyViewModel = @ptrCast(@alignCast(raw.?));
        switch (keycode) {
            key_space => {
                self.toggleAuto();
                return true;
            },
            key_home => {
                self.jumpToTop();
                return true;
            },
            key_end => {
                self.jumpToBottom();
                return true;
            },
            else => return false,
        }
    }

    // `onCleared()`: the store calls this when the screen goes away. This model holds no timers and no buffers.
    pub fn onCleared(self: *LazyViewModel) void {
        _ = self;
    }

    fn requestFrame(self: *LazyViewModel) void {
        if (self.pump) |p| p.request(p.ctx);
    }

    fn stopFrames(self: *LazyViewModel) void {
        if (self.pump) |p| p.idle(p.ctx);
    }

    // The height of every row in the list, which is also the distance from the top to the bottom.
    fn span() f32 {
        return @as(f32, @floatFromInt(state_mod.row_count)) * state_mod.row_h;
    }

    const key_space: u32 = 57;
    const key_home: u32 = 102;
    const key_end: u32 = 107;
};
