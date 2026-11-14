// The screen's state, as a VALUE: everything the view draws is one of these.
// This is Kotlin's `data class TodoUiState` — a plain value a ViewModel replaces, never mutates in place.
// The half-typed title IS in here: the field is driven by `value`, so the state holds the draft, exactly as Compose's does.
const std = @import("std");

// Capacities. A value type is bounded by its fields, so these are what bound the state's size.
pub const max_title: usize = 96;
pub const max_input: usize = 256;
pub const max_todos: usize = 64;

// A title is a zero-terminated array — Zig's own way to carry a length with the bytes, read back with `std.mem.sliceTo`.
pub const Title = [max_title:0]u8;

// An empty title, so a `Todo` needs no initialiser.
pub const empty_title: Title = .{0} ** max_title;

// The draft's storage: the same shape as a title, sized to the field's buffer.
pub const Draft = [max_input:0]u8;
pub const empty_draft: Draft = .{0} ** max_input;

// Copy `s` in, truncating at capacity: a value type cannot fail to allocate, so it truncates instead.
fn setText(comptime N: usize, dst: *[N:0]u8, s: []const u8) void {
    const n = @min(s.len, N);
    @memcpy(dst[0..n], s[0..n]);
    dst[n] = 0;
}

fn setTitle(dst: *Title, s: []const u8) void {
    setText(max_title, dst, s);
}

// One todo. The title is owned by the value, so a copy of the state owns its own text.
pub const Todo = struct {
    title: Title = empty_title,
    done: bool = false,

    pub fn text(self: *const Todo) []const u8 {
        return std.mem.sliceTo(&self.title, 0);
    }
};

// `data class TodoUiState(val input: String = "", val todos: List<String> = emptyList())`.
pub const TodoUiState = struct {
    input: Draft = empty_draft,
    todos: [max_todos]Todo = [_]Todo{.{}} ** max_todos,
    count: usize = 0,

    // The draft the field shows, and the title `add` takes.
    pub fn draft(self: *const TodoUiState) []const u8 {
        return std.mem.sliceTo(&self.input, 0);
    }

    // `it.copy(input = text)`
    pub fn withInput(self: TodoUiState, text: []const u8) TodoUiState {
        var next = self;
        setText(max_input, &next.input, text);
        return next;
    }

    // The live rows. A slice, so the view iterates what exists rather than the whole capacity.
    pub fn items(self: *const TodoUiState) []const Todo {
        return self.todos[0..self.count];
    }

    pub fn doneCount(self: *const TodoUiState) usize {
        var n: usize = 0;
        for (self.todos[0..self.count]) |t| {
            if (t.done) n += 1;
        }
        return n;
    }

    // `it.copy(todos = it.todos + title)`
    pub fn withTodo(self: TodoUiState, title: []const u8) TodoUiState {
        var next = self;
        if (next.count >= max_todos) return next;
        setTitle(&next.todos[next.count].title, title);
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
};

// ---- tests ---------------------------------------------------------------------------------------------------

test "a fresh state is empty" {
    try std.testing.expectEqual(@as(usize, 0), (TodoUiState{}).count);
    try std.testing.expectEqual(@as(usize, 0), (TodoUiState{}).items().len);
}

test "adding a todo grows the count and keeps the title" {
    const state = (TodoUiState{}).withTodo("Buy milk");
    try std.testing.expectEqual(@as(usize, 1), state.count);
    try std.testing.expectEqualStrings("Buy milk", state.items()[0].text());
    try std.testing.expect(!state.items()[0].done);
}

test "a title is truncated at capacity, and stays terminated" {
    const long = "x" ** (max_title + 8);
    const state = (TodoUiState{}).withTodo(long);
    try std.testing.expectEqual(max_title, state.items()[0].text().len);
    try std.testing.expectEqual(@as(u8, 0), state.items()[0].title[max_title]);
}

test "removing a row closes the gap and leaves the rest in order" {
    var state = TodoUiState{};
    state = state.withTodo("one");
    state = state.withTodo("two");
    state = state.withTodo("three");
    state = state.withoutTodo(1);

    try std.testing.expectEqual(@as(usize, 2), state.count);
    try std.testing.expectEqualStrings("one", state.items()[0].text());
    try std.testing.expectEqualStrings("three", state.items()[1].text());
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
    try std.testing.expectEqual(@as(usize, 0), state.withToggled(7).doneCount());
}

test "capacity is a ceiling, not a crash" {
    var state = TodoUiState{};
    var i: usize = 0;
    while (i < max_todos + 4) : (i += 1) state = state.withTodo("x");
    try std.testing.expectEqual(max_todos, state.count);
}
