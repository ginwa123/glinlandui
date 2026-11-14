// The ViewModel: the only place the screen's state is written.
// This is Kotlin's `TodoViewModel`, and `Store` in the engine is its `ViewModelStore`.
// Every public function here is an INTENT the view may raise: it never draws, never reads a widget, and never knows a window exists.
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

    // `fun add()` — the draft comes IN as an argument, and the answer says whether the intent took it.
    // A blank title is not a todo, so the state is not touched and nothing repaints.
    pub fn add(self: *TodoViewModel, title: []const u8) bool {
        const trimmed = std.mem.trim(u8, title, " \t\r\n");
        if (trimmed.len == 0) return false;
        return self.state.update(trimmed, TodoUiState.withTodo);
    }

    // `fun remove(index: Int)`
    pub fn remove(self: *TodoViewModel, index: usize) void {
        _ = self.state.update(index, TodoUiState.withoutTodo);
    }

    // `fun toggle(index: Int)`
    pub fn toggle(self: *TodoViewModel, index: usize) void {
        _ = self.state.update(index, TodoUiState.withToggled);
    }

    // `onCleared()`: the store calls this when the screen goes away, so nothing outlives its window.
    pub fn onCleared(self: *TodoViewModel) void {
        self.state.state.collector_count = 0;
    }
};

// ---- tests ---------------------------------------------------------------------------------------------------

test "add trims, appends, and says it took the draft" {
    var vm = TodoViewModel.init();
    try std.testing.expect(vm.add("  Buy milk  "));

    const state = vm.uiState();
    try std.testing.expectEqual(@as(usize, 1), state.count);
    try std.testing.expectEqualStrings("Buy milk", state.items()[0].text());
}

test "add on a blank title publishes nothing" {
    var vm = TodoViewModel.init();
    const before = vm.state.revision();
    try std.testing.expect(!vm.add("   "));
    try std.testing.expectEqual(@as(usize, 0), vm.uiState().count);
    try std.testing.expectEqual(before, vm.state.revision());
}

test "remove and toggle are intents over the index" {
    var vm = TodoViewModel.init();
    _ = vm.add("one");
    _ = vm.add("two");

    vm.toggle(1);
    try std.testing.expect(vm.uiState().items()[1].done);

    vm.remove(0);
    try std.testing.expectEqual(@as(usize, 1), vm.uiState().count);
    try std.testing.expectEqualStrings("two", vm.uiState().items()[0].text());
}
