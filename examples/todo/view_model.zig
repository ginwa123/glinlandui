// The ViewModel: the only place the screen's state is written.
// This is Kotlin's `TodoViewModel`. It holds the state flow, and every public function is an INTENT the view
// may raise. It never draws, never reads a widget, and never knows a window exists — which is what makes it
// testable without a frame, and what stops the view and the model from disagreeing.
const std = @import("std");
const state_mod = @import("state.zig");
const flow_mod = @import("flow.zig");

const TodoUiState = state_mod.TodoUiState;

pub const TodoViewModel = struct {
    state: flow_mod.MutableStateFlow(TodoUiState),

    pub fn init() TodoViewModel {
        return .{ .state = .init(.{}) };
    }

    pub fn uiState(self: *const TodoViewModel) TodoUiState {
        return self.state.value();
    }

    // Bumped on every publish. The view compares it to tell a model change from its own edit.
    pub fn revision(self: *const TodoViewModel) u64 {
        return self.state.version;
    }

    // `fun onInputChange(text: String)`
    pub fn onInputChange(self: *TodoViewModel, text: []const u8) void {
        _ = self.state.update(text, TodoUiState.withInput);
    }

    // `fun add()` — a blank input is not a todo, so the state is not touched and nothing repaints.
    pub fn add(self: *TodoViewModel) void {
        const current = self.state.value();
        const trimmed = std.mem.trim(u8, current.input.slice(), " \t\r\n");
        if (trimmed.len == 0) return;
        _ = self.state.update(trimmed, TodoUiState.withTodo);
    }

    // `fun remove(index: Int)`
    pub fn remove(self: *TodoViewModel, index: usize) void {
        _ = self.state.update(index, TodoUiState.withoutTodo);
    }

    // Not in the Compose sample, but a todo list without it is a list of claims: one intent, one reducer.
    pub fn toggle(self: *TodoViewModel, index: usize) void {
        _ = self.state.update(index, TodoUiState.withToggled);
    }

    // `onCleared()`: the store calls this when the screen goes away, so nothing outlives its window.
    pub fn onCleared(self: *TodoViewModel) void {
        self.state.collector_count = 0;
    }
};

// `ViewModelStore`: one instance per screen, created on first use and cleared when the screen leaves.
// Compose scopes a store to a navigation graph; this example has one screen, so one store is the whole graph.
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

test "add trims, appends, and clears the input" {
    var vm = TodoViewModel.init();
    vm.onInputChange("  Buy milk  ");
    vm.add();

    const state = vm.uiState();
    try std.testing.expectEqual(@as(usize, 1), state.count);
    try std.testing.expectEqualStrings("Buy milk", state.items()[0].title.slice());
    try std.testing.expectEqual(@as(usize, 0), state.input.len);
}

test "add on a blank input publishes nothing" {
    var vm = TodoViewModel.init();
    const before = vm.revision();
    vm.onInputChange("   ");
    vm.add();
    try std.testing.expectEqual(@as(usize, 0), vm.uiState().count);
    // Only the input change published; `add` itself was a no-op.
    try std.testing.expectEqual(before + 1, vm.revision());
}

test "remove and toggle are intents over the index" {
    var vm = TodoViewModel.init();
    vm.onInputChange("one");
    vm.add();
    vm.onInputChange("two");
    vm.add();

    vm.toggle(1);
    try std.testing.expect(vm.uiState().items()[1].done);

    vm.remove(0);
    try std.testing.expectEqual(@as(usize, 1), vm.uiState().count);
    try std.testing.expectEqualStrings("two", vm.uiState().items()[0].title.slice());
}

test "the store hands back one instance for the life of the screen" {
    var store = Store(TodoViewModel){};
    const first = store.getOrCreate(TodoViewModel.init);
    first.onInputChange("x");
    const again = store.getOrCreate(TodoViewModel.init);
    try std.testing.expect(first == again);
    try std.testing.expectEqualStrings("x", again.uiState().input.slice());

    store.clear();
    const fresh = store.getOrCreate(TodoViewModel.init);
    try std.testing.expectEqual(@as(usize, 0), fresh.uiState().input.len);
}

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

test "clear calls onCleared, which is where a ViewModel releases its work" {
    var store = Store(Spy){};
    _ = store.getOrCreate(Spy.make);
    store.clear();
    try std.testing.expect(spy_cleared);
}
