// The state holder MVVM is built on: a value that publishes only when it actually changes.

// This is kotlinx.coroutines' `MutableStateFlow` in Zig — one value, and a value equal to the current one is not a publish.

// There is no collector list: a frame is the unit of observation here, and the next frame reads whatever the value says.
const std = @import("std");

// The distinct-value gate: `T.eql` when the type has one, `std.meta.eql` otherwise.
fn eqlValue(comptime T: type, a: T, b: T) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"enum", .@"union", .@"opaque" => if (@hasDecl(T, "eql")) T.eql(a, b) else std.meta.eql(a, b),
        else => std.meta.eql(a, b),
    };
}

// A value a ViewModel owns and a view reads. `set`/`update` return whether anything was published.
pub fn MutableStateFlow(comptime T: type) type {
    return struct {
        const Self = @This();

        value: T,

        pub fn init(initial: T) Self {
            return .{ .value = initial };
        }

        pub fn get(self: *const Self) T {
            return self.value;
        }

        // Replace the value, unless it equals the current one. The answer is whether it was published.
        pub fn set(self: *Self, next: T) bool {
            if (eqlValue(T, self.value, next)) return false;
            self.value = next;
            return true;
        }

        // `_state.update { it.copy(...) }`: the reducer reads the current value and returns the next one.
        pub fn update(self: *Self, arg: anytype, comptime reduce: fn (T, @TypeOf(arg)) T) bool {
            return self.set(reduce(self.value, arg));
        }
    };
}

// ---- tests ---------------------------------------------------------------------------------------------------

// A two-field value to publish, so the gate is tested on something shaped like real state.
const Pair = struct {
    a: u32 = 0,
    b: u32 = 0,

    pub fn eql(x: Pair, y: Pair) bool {
        return x.a == y.a and x.b == y.b;
    }
};

test "a value equal to the current one is not published" {
    var flow = MutableStateFlow(Pair).init(.{ .a = 1 });
    try std.testing.expect(!flow.set(.{ .a = 1 }));
    try std.testing.expectEqual(@as(u32, 1), flow.get().a);

    try std.testing.expect(flow.set(.{ .a = 1, .b = 1 }));
    try std.testing.expectEqual(@as(u32, 1), flow.get().b);
}

test "update hands the reducer the current value, and publishes once" {
    var flow = MutableStateFlow(Pair).init(.{ .a = 1, .b = 2 });

    const Bump = struct {
        fn apply(p: Pair, by: u32) Pair {
            var next = p;
            next.a += by;
            return next;
        }
    };
    try std.testing.expect(flow.update(@as(u32, 10), Bump.apply));
    try std.testing.expectEqual(@as(u32, 11), flow.get().a);

    // A reducer that lands on the same value is a no-op, exactly like a `copy()` that changes nothing.
    try std.testing.expect(!flow.update(@as(u32, 0), Bump.apply));
}

test "a scalar value needs no eql of its own" {
    var flow = MutableStateFlow(u32).init(3);
    try std.testing.expect(!flow.set(3));
    try std.testing.expect(flow.set(4));
    try std.testing.expectEqual(@as(u32, 4), flow.get());
}
