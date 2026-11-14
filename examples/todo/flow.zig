// The state holder the whole example is built on: a value that announces when it changes.
// This is kotlinx.coroutines' `MutableStateFlow`/`StateFlow` in Zig: one current value, `set` publishes a
// new one only when it differs from the last, and a collector hears about each published value once.
// The "only when it differs" rule is not an optimisation — it is the contract that lets a screen stay
// idle, because a value equal to the one already on screen is not a reason to draw anything.
const std = @import("std");

// How many collectors one flow may carry. A composition subscribes once; an app needing more says so here.
pub const max_collectors: usize = 8;

// The read-only half — `StateFlow` in Kotlin. A view is handed this shape and cannot publish.
pub fn StateFlow(comptime T: type) type {
    return struct {
        value: T,

        const Self = @This();

        // The current value. Reading is not a subscription: `collect` is what asks for notifications.
        pub fn get(self: *const Self) T {
            return self.value;
        }
    };
}

// The writable half — `MutableStateFlow` in Kotlin. A `T` with `pub fn eql(a: T, b: T) bool` decides equality;
// anything else falls back to `std.meta.eql`, which compares a struct field by field.
pub fn MutableStateFlow(comptime T: type) type {
    return struct {
        const Self = @This();

        // The distinct-value gate: `T.eql` when the type has one, `std.meta.eql` otherwise.
        fn eqlValue(a: T, b: T) bool {
            return switch (@typeInfo(T)) {
                .@"struct", .@"enum", .@"union", .@"opaque" => if (@hasDecl(T, "eql")) T.eql(a, b) else std.meta.eql(a, b),
                else => std.meta.eql(a, b),
            };
        }

        // A subscriber: an opaque context and a plain function, because Zig has no closures.
        pub const Collector = struct {
            ctx: ?*anyopaque,
            // Called once per PUBLISHED value, never for one that equals what is already there.
            on_value: *const fn (?*anyopaque) void,
        };

        state: StateFlow(T),
        // Bumped on every publish, so a consumer can tell "the model changed" from "a frame happened".
        version: u64 = 0,
        collectors: [max_collectors]Collector = undefined,
        collector_count: usize = 0,

        pub fn init(initial: T) Self {
            return .{ .state = .{ .value = initial } };
        }

        pub fn value(self: *const Self) T {
            return self.state.value;
        }

        // The read-only view a composable collects. It aliases this flow's value; it is not a copy.
        pub fn asStateFlow(self: *Self) *StateFlow(T) {
            return &self.state;
        }

        // Publish `next`, unless it equals the current value. Returns whether anything was published.
        pub fn set(self: *Self, next: T) bool {
            if (eqlValue(self.state.value, next)) return false;
            self.state.value = next;
            self.version += 1;
            for (self.collectors[0..self.collector_count]) |c| c.on_value(c.ctx);
            return true;
        }

        // `_state.update { it.copy(...) }`: the reducer reads the current value and returns the next one.
        pub fn update(self: *Self, arg: anytype, comptime reduce: fn (T, @TypeOf(arg)) T) bool {
            return self.set(reduce(self.state.value, arg));
        }

        // Idempotent by `ctx`: a composition that collects on every frame subscribes exactly once.
        pub fn collect(self: *Self, c: Collector) void {
            for (self.collectors[0..self.collector_count]) |existing| {
                if (existing.ctx == c.ctx) return;
            }
            if (self.collector_count >= max_collectors) return;
            self.collectors[self.collector_count] = c;
            self.collector_count += 1;
        }

        // Drop a collector, so a screen that leaves stops waking the app.
        pub fn removeCollector(self: *Self, ctx: ?*anyopaque) void {
            var i: usize = 0;
            while (i < self.collector_count) : (i += 1) {
                if (self.collectors[i].ctx != ctx) continue;
                self.collectors[i] = self.collectors[self.collector_count - 1];
                self.collector_count -= 1;
                return;
            }
        }
    };
}

// ---- tests ---------------------------------------------------------------------------------------------------

// A three-field value to publish, so the gate is tested on something shaped like real state.
const Pair = struct {
    a: u32 = 0,
    b: u32 = 0,

    pub fn eql(x: Pair, y: Pair) bool {
        return x.a == y.a and x.b == y.b;
    }
};

// Counts how often the flow woke it, which is the only observable a collector has.
const Counter = struct {
    calls: usize = 0,

    fn onValue(ctx: ?*anyopaque) void {
        const self: *Counter = @ptrCast(@alignCast(ctx.?));
        self.calls += 1;
    }
};

test "a value equal to the current one publishes nothing" {
    var flow = MutableStateFlow(Pair).init(.{ .a = 1 });
    var counter = Counter{};
    flow.collect(.{ .ctx = &counter, .on_value = Counter.onValue });

    try std.testing.expect(!flow.set(.{ .a = 1 }));
    try std.testing.expectEqual(@as(usize, 0), counter.calls);
    try std.testing.expectEqual(@as(u64, 0), flow.version);

    try std.testing.expect(flow.set(.{ .a = 1, .b = 1 }));
    try std.testing.expectEqual(@as(usize, 1), counter.calls);
    try std.testing.expectEqual(@as(u64, 1), flow.version);
}

test "update hands the reducer the current value, and publishes once" {
    var flow = MutableStateFlow(Pair).init(.{ .a = 1, .b = 2 });
    var counter = Counter{};
    flow.collect(.{ .ctx = &counter, .on_value = Counter.onValue });

    const Bump = struct {
        fn apply(p: Pair, by: u32) Pair {
            var next = p;
            next.a += by;
            return next;
        }
    };
    _ = flow.update(@as(u32, 10), Bump.apply);
    try std.testing.expectEqual(@as(u32, 11), flow.value().a);
    try std.testing.expectEqual(@as(usize, 1), counter.calls);

    // A reducer that lands on the same value is a no-op, exactly like a `copy()` that changes nothing.
    _ = flow.update(@as(u32, 0), Bump.apply);
    try std.testing.expectEqual(@as(usize, 1), counter.calls);
}

test "collecting twice from one context subscribes once" {
    var flow = MutableStateFlow(Pair).init(.{});
    var counter = Counter{};
    flow.collect(.{ .ctx = &counter, .on_value = Counter.onValue });
    flow.collect(.{ .ctx = &counter, .on_value = Counter.onValue });
    try std.testing.expectEqual(@as(usize, 1), flow.collector_count);

    _ = flow.set(.{ .a = 1 });
    try std.testing.expectEqual(@as(usize, 1), counter.calls);
}

test "a removed collector stops hearing about publishes" {
    var flow = MutableStateFlow(Pair).init(.{});
    var counter = Counter{};
    flow.collect(.{ .ctx = &counter, .on_value = Counter.onValue });
    flow.removeCollector(&counter);
    try std.testing.expectEqual(@as(usize, 0), flow.collector_count);

    _ = flow.set(.{ .a = 1 });
    try std.testing.expectEqual(@as(usize, 0), counter.calls);
}
