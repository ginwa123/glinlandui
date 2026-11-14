// The screen's state, as a VALUE: everything the view draws is one of these.
// This is Kotlin's `data class TodoUiState` — copied on every change and comparable, so the flow can drop a publish that changes nothing.
// A half-typed title is NOT in here: it is an editing draft, it lives in the field, and `add` takes it as an argument.
const std = @import("std");

// Capacities. A value type is bounded by its fields, so these are what bound the state's size.
pub const max_title: usize = 96;
pub const max_todos: usize = 64;

// An owned, fixed-capacity string. Kotlin's `String` is immutable and owned by the state; this is its Zig shape.
pub const Text = struct {
    bytes: [max_title]u8 = [_]u8{0} ** max_title,
    len: usize = 0,

    pub fn from(s: []const u8) Text {
        var t = Text{};
        t.set(s);
        return t;
    }

    // Copy `s` in, truncating at capacity: a value type cannot fail to allocate, so it truncates instead.
    pub fn set(self: *Text, s: []const u8) void {
        const n = @min(s.len, self.bytes.len);
        @memcpy(self.bytes[0..n], s[0..n]);
        self.len = n;
    }

    pub fn slice(self: *const Text) []const u8 {
        return self.bytes[0..self.len];
    }

    pub fn eql(a: Text, b: Text) bool {
        return std.mem.eql(u8, a.slice(), b.slice());
    }
};

// One todo. `title` is owned by the value, so a copy of the state owns its own text.
pub const Todo = struct {
    title: Text = .{},
    done: bool = false,

    pub fn eql(a: Todo, b: Todo) bool {
        return a.done == b.done and Text.eql(a.title, b.title);
    }
};

// `data class TodoUiState(val todos: List<String> = emptyList())`.
pub const TodoUiState = struct {
    todos: [max_todos]Todo = [_]Todo{.{}} ** max_todos,
    count: usize = 0,

    // The live rows. A slice, so the view iterates what exists rather than the whole capacity.
    pub fn items(self: *const TodoUiState) []const Todo {
        return self.todos[0..self.count];
    }

    pub fn doneCount(self: *const TodoUiState) usize {
        var n: usize = 0;
        for (self.items()) |t| {
            if (t.done) n += 1;
        }
        return n;
    }

    // `it.copy(todos = it.todos + title)`
    pub fn withTodo(self: TodoUiState, title: []const u8) TodoUiState {
        var next = self;
        if (next.count >= max_todos) return next;
        next.todos[next.count] = .{ .title = Text.from(title) };
        next.count += 1;
        return next;
    }

    // `it.copy(todos = it.todos.filterIndexed { i, _ -> i != index })`
    pub fn withoutTodo(self: TodoUiState, index: usize) TodoUiState {
        var next = self;
        if (index >= next.count) return next;
        var i = index;
        while (i + 1 < next.count) : (i += 1) next.todos[i] = next.todos[i + 1];
        next.count -= 1;
        next.todos[next.count] = .{};
        return next;
    }

    // `it.copy(todos = it.todos.mapIndexed { i, t -> if (i == index) t.copy(done = !t.done) else t })`
    pub fn withToggled(self: TodoUiState, index: usize) TodoUiState {
        var next = self;
        if (index >= next.count) return next;
        next.todos[index].done = !next.todos[index].done;
        return next;
    }

    // What `data class` equality means here: every live row, and nothing in the spare capacity.
    pub fn eql(a: TodoUiState, b: TodoUiState) bool {
        if (a.count != b.count) return false;
        var i: usize = 0;
        while (i < a.count) : (i += 1) {
            if (!Todo.eql(a.todos[i], b.todos[i])) return false;
        }
        return true;
    }
};

// ---- tests ---------------------------------------------------------------------------------------------------

test "a fresh state is empty, and equals another fresh one" {
    try std.testing.expectEqual(@as(usize, 0), (TodoUiState{}).count);
    try std.testing.expect(TodoUiState.eql(.{}, .{}));
}

test "adding a todo grows the count and keeps the title" {
    const state = (TodoUiState{}).withTodo("Buy milk");
    try std.testing.expectEqual(@as(usize, 1), state.count);
    try std.testing.expectEqualStrings("Buy milk", state.items()[0].title.slice());
    try std.testing.expect(!state.items()[0].done);
}

test "removing a row closes the gap and leaves the rest in order" {
    var state = TodoUiState{};
    state = state.withTodo("one");
    state = state.withTodo("two");
    state = state.withTodo("three");
    state = state.withoutTodo(1);

    try std.testing.expectEqual(@as(usize, 2), state.count);
    try std.testing.expectEqualStrings("one", state.items()[0].title.slice());
    try std.testing.expectEqualStrings("three", state.items()[1].title.slice());
}

test "toggling flips exactly one row, and an index out of range is a no-op" {
    var state = TodoUiState{};
    state = state.withTodo("one");
    state = state.withTodo("two");

    const toggled = state.withToggled(1);
    try std.testing.expect(!toggled.items()[0].done);
    try std.testing.expect(toggled.items()[1].done);
    try std.testing.expectEqual(@as(usize, 1), toggled.doneCount());

    // A click and a state change can race by one frame, so this must not panic.
    try std.testing.expect(TodoUiState.eql(state, state.withToggled(7)));
}

test "eql sees a changed row, a removed row, and a toggle that was undone" {
    var base = TodoUiState{};
    base = base.withTodo("a");
    base = base.withTodo("b");

    try std.testing.expect(!TodoUiState.eql(base, base.withToggled(0)));
    try std.testing.expect(!TodoUiState.eql(base, base.withoutTodo(0)));
    try std.testing.expect(TodoUiState.eql(base, base.withToggled(0).withToggled(0)));
}

test "capacity is a ceiling, not a crash" {
    var state = TodoUiState{};
    var i: usize = 0;
    while (i < max_todos + 4) : (i += 1) state = state.withTodo("x");
    try std.testing.expectEqual(max_todos, state.count);
}
