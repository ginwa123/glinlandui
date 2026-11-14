// The ViewModel: the only place the screen's state is written.
// This is Kotlin's `TodoViewModel`, and `Store` in the engine is its `ViewModelStore`. Every public function
// here is an INTENT the view may raise: it never draws, never reads a widget, and never knows a window exists.
const std = @import("std");
const glinlandui = @import("glinlandui");
const state_mod = @import("state.zig");

const TodoUiState = state_mod.TodoUiState;

pub const TodoViewModel = struct {
    state: glinlandui.state_flow.MutableStateFlow(TodoUiState),

    pub fn init() TodoViewModel {
        return .{ .state = .init(.{}) };
    }

    pub fn uiState(self: *const TodoViewModel) TodoUiState {
        return self.state.value();
    }

    // Bumped on every publish. The view compares it to tell a model change from its own edit.
    pub fn revision(self: *const TodoViewModel) u64 {
        return self.state.revision();
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
