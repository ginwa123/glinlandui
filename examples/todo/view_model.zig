// The ViewModel: the only place the screen's state is written.
// This is Kotlin's `TodoViewModel`, and `Store` in the engine is its `ViewModelStore`.
// Every public function here is an INTENT the view may raise: it never draws, never reads a widget, and never knows a window exists.
const std = @import("std");
const state_mod = @import("state.zig");

const TodoUiState = state_mod.TodoUiState;

pub const TodoViewModel = struct {
    // The state, as a plain value: an intent replaces it, and the next frame reads whatever it says.
    state: TodoUiState = .{},

    pub fn init() TodoViewModel {
        return .{};
    }

    // `val state by vm.state`: the value the view draws.
    pub fn uiState(self: *const TodoViewModel) TodoUiState {
        return self.state;
    }

    // `fun add()` — the draft comes IN as an argument, and the answer says whether the intent took it.
    // A blank title is not a todo, and a full list is full: either way the state is not touched and the draft stays.
    pub fn add(self: *TodoViewModel, title: []const u8) bool {
        const trimmed = std.mem.trim(u8, title, " \t\r\n");
        if (trimmed.len == 0 or self.state.count >= state_mod.max_todos) return false;
        self.state = self.state.withTodo(trimmed);
        return true;
    }

    // `fun remove(index: Int)`
    pub fn remove(self: *TodoViewModel, index: usize) void {
        self.state = self.state.withoutTodo(index);
    }

    // `fun toggle(index: Int)`
    pub fn toggle(self: *TodoViewModel, index: usize) void {
        self.state = self.state.withToggled(index);
    }

    // `onCleared()`: the store calls this when the screen goes away. This ViewModel holds no timers or buffers.
    pub fn onCleared(self: *TodoViewModel) void {
        _ = self;
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

test "add on a blank title is refused, and changes nothing" {
    var vm = TodoViewModel.init();
    try std.testing.expect(!vm.add("   "));
    try std.testing.expectEqual(@as(usize, 0), vm.uiState().count);
}

test "add on a full list is refused, so the draft stays in the field" {
    var vm = TodoViewModel.init();
    var i: usize = 0;
    while (i < state_mod.max_todos) : (i += 1) _ = vm.add("x");
    try std.testing.expect(!vm.add("one more"));
    try std.testing.expectEqual(state_mod.max_todos, vm.uiState().count);
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
