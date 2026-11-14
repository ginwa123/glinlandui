// `ViewModelStore` and the ViewModel convention.

// A ViewModel is not a base class here: it is any type that holds its state and offers `pub fn onCleared(self: *T) void`.

// The store owns one instance per screen, creates it on first use, and calls `onCleared` when the screen goes away.

// Compose scopes a store to a navigation graph; an app with one screen has one store, and an app with routes has one per route.
const std = @import("std");

pub fn Store(comptime T: type) type {
    return struct {
        const Self = @This();

        instance: ?T = null,

        // `viewModel()`: the same instance for the life of the screen, created once.
        pub fn getOrCreate(self: *Self, factory: *const fn () T) *T {
            if (self.instance == null) self.instance = factory();
            return &self.instance.?;
        }

        // `ViewModelStore.clear()`: drop the instance and let it release what it held.
        pub fn clear(self: *Self) void {
            if (self.instance) |*vm| vm.onCleared();
            self.instance = null;
        }
    };
}

// ---- tests ---------------------------------------------------------------------------------------------------

// Set by the spy below, so the assertion can outlive the store's own storage.
var spy_cleared: bool = false;

const Spy = struct {
    pub fn make() Spy {
        return .{};
    }

    pub fn onCleared(_: *Spy) void {
        spy_cleared = true;
    }
};

const Counter = struct {
    count: usize = 0,

    pub fn make() Counter {
        return .{};
    }

    pub fn onCleared(_: *Counter) void {}
};

test "the store hands back one instance, and clear drops it" {
    var store = Store(Counter){};
    const first = store.getOrCreate(Counter.make);
    first.count += 1;
    const again = store.getOrCreate(Counter.make);
    try std.testing.expect(first == again);
    try std.testing.expectEqual(@as(usize, 1), again.count);

    store.clear();
    const fresh = store.getOrCreate(Counter.make);
    try std.testing.expectEqual(@as(usize, 0), fresh.count);
}

test "clear calls onCleared, which is where a ViewModel releases its work" {
    var store = Store(Spy){};
    _ = store.getOrCreate(Spy.make);
    store.clear();
    try std.testing.expect(spy_cleared);
}
