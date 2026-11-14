// The screen's state, as a VALUE: the meter, the one animation, and what the last frame declared.
// This is Kotlin's `data class LazyUiState` — a plain value a ViewModel replaces, never mutates in place.
// Nothing here imports a widget: a row is a function of its index, and the frame's text scratch is the engine's.
const std = @import("std");
const glinlandui = @import("glinlandui");

// Ten thousand rows, and none of them is stored: a row is a function of its index. That is the point — the list is free, and the drawing is what costs.
pub const row_count: usize = 10_000;

// One row's height, taken from the virtualisation helper's own constant so the two cannot disagree.
pub const row_h: f32 = @floatFromInt(glinlandui.table.row_height);

// The frame budget of a 144 Hz display, in milliseconds.
pub const budget_144_ms: f32 = 1000.0 / 144.0;

// The data source, as a pure function: no row is ever built, and the text lands in the frame's scratch so it outlives the declare.
pub fn rowName(index: usize) []const u8 {
    return glinlandui.frame.formatText("row {d: >5}", .{index});
}

// The second half of a row, also a function of its index alone.
pub fn rowMeta(index: usize) []const u8 {
    return glinlandui.frame.formatText("user{d}@example.com   {d}.{d:0>2}", .{ index, index % 977, index % 100 });
}

// The last N frame durations, in nanoseconds. `tick` is called at the top of every frame with the clock, so the meter measures what the screen actually
// got, not what the toolkit hoped for.
pub const Meter = struct {
    const cap = 120;

    durations: [cap]i64 = [_]i64{0} ** cap,
    count: usize = 0,
    next: usize = 0,
    last_ns: i64 = 0,

    fn tick(self: *Meter, now_ns: i64) void {
        if (self.last_ns != 0 and now_ns > self.last_ns) {
            self.durations[self.next] = now_ns - self.last_ns;
            self.next = (self.next + 1) % cap;
            if (self.count < cap) self.count += 1;
        }
        self.last_ns = now_ns;
    }

    pub const Stats = struct { last_ms: f32 = 0, avg_ms: f32 = 0, max_ms: f32 = 0, fps: f32 = 0 };

    pub fn stats(self: *const Meter) Stats {
        if (self.count == 0) return .{};
        const last_ms = @as(f32, @floatFromInt(self.durations[(self.next + cap - 1) % cap])) / 1_000_000.0;
        var total: i64 = 0;
        var worst: i64 = 0;
        for (self.durations[0..self.count]) |d| {
            total += d;
            if (d > worst) worst = d;
        }
        const avg_ms = @as(f32, @floatFromInt(@divTrunc(total, @as(i64, @intCast(self.count))))) / 1_000_000.0;
        return .{
            .last_ms = last_ms,
            .avg_ms = avg_ms,
            .max_ms = @as(f32, @floatFromInt(worst)) / 1_000_000.0,
            .fps = if (avg_ms > 0) 1000.0 / avg_ms else 0,
        };
    }
};

// Everything the view draws, in one value: `it.copy(...)` functions only, so a frame reads a state that cannot change under it.
pub const LazyUiState = struct {
    meter: Meter = .{},
    // Auto-scroll on or off, and the points per frame it moves the list.
    auto: bool = false,
    speed: f32 = 400,
    // Rows declared in the last frame, so the header can show the virtualisation working.
    declared: usize = 0,

    // The meter records the frame that just ended; asking for the next one is the ViewModel's decision, not this value's.
    pub fn ticked(self: LazyUiState, now_ns: i64) LazyUiState {
        var next = self;
        next.meter.tick(now_ns);
        return next;
    }

    pub fn stats(self: *const LazyUiState) Meter.Stats {
        return self.meter.stats();
    }

    pub fn withAuto(self: LazyUiState, on: bool) LazyUiState {
        var next = self;
        next.auto = on;
        return next;
    }

    pub fn withSpeed(self: LazyUiState, points_per_frame: f32) LazyUiState {
        var next = self;
        next.speed = points_per_frame;
        return next;
    }

    pub fn withDeclared(self: LazyUiState, rows: usize) LazyUiState {
        var next = self;
        next.declared = rows;
        return next;
    }
};

// ---- tests ---------------------------------------------------------------------------------------------------

test "the meter reports a frame time and a rate" {
    var m = Meter{};
    m.tick(1_000_000);
    m.tick(7_000_000); // 6 ms
    const s = m.stats();
    try std.testing.expectApproxEqAbs(@as(f32, 6.0), s.last_ms, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 6.0), s.avg_ms, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 1000.0 / 6.0), s.fps, 0.5);
}
