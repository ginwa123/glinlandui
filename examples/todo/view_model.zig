// The ViewModel: the only place the screen's state is written.
// This is Kotlin's `TodoViewModel`, and `Store` in the engine is its `ViewModelStore`.
// Every public function here is an INTENT the view may raise: it never draws, never reads a widget, and never knows a window exists.
const std = @import("std");
const glinlandui = @import("glinlandui");
const input_mod = glinlandui.components.input;
const state_mod = @import("state.zig");

const TodoUiState = state_mod.TodoUiState;

// The field the keyboard types into. It is the screen's, so its id lives with the screen's state.
pub const field_id = "todo.field";

pub const TodoViewModel = struct {
    // The state, as a plain value: an intent replaces it, and the next frame reads whatever it says.
    state: TodoUiState = .{},

    // Compose keeps this in `remember`: the field's look, its draft and its caret. It is here because this engine has no composition runtime, and it is not the Activity's business.
    field: input_mod.Field = .{ .id = .{ .text = field_id } },

    // A row's click context: a callback runs AFTER the frame that declared it, so the context is owned, never stacked.
    row_ctxs: [state_mod.max_todos]RowCtx = undefined,

    pub const RowCtx = struct {
        vm: *TodoViewModel,
        index: usize,
    };

    pub fn init() TodoViewModel {
        return .{};
    }

    // `onCreate`: the field takes the keyboard, and its callbacks are this model's own intents.
    pub fn start(self: *TodoViewModel, t: glinlandui.theme.Theme) void {
        // The look and the intents are set ONCE: a frame only hands the field the model's value.
        self.field = .{
            .id = .{ .text = field_id },
            .font_size = t.type_scale.body,
            .bg = t.colors.surface,
            .fg = t.colors.text,
            .sel_bg = t.colors.surface_variant,
            .sel_fg = t.colors.text,
            .caret_fg = t.colors.primary,
            .radius = glinlandui.props.Radius.all(6),
            .pad = glinlandui.props.Pad.axes(8, 10),
            .border = .{ .width = 1, .color = t.colors.divider },
            .w = .{ .clamp = .{ .min = 120, .max = 640, .grow = true } },
            .on_change = .{ .f = onDraft, .ctx = self },
            .on_submit = .{ .f = onSubmit, .ctx = self },
        };
        // The editor points at this field's own buffer, which is stable now that the field is where it will stay.
        self.field.bind();
    }

    // `val state by vm.state`: the value the view draws.
    pub fn uiState(self: *const TodoViewModel) TodoUiState {
        return self.state;
    }

    // `onValueChange = vm::onInputChange`, in the shape the widget calls it.
    fn onDraft(raw: ?*anyopaque, text: []const u8) void {
        const self: *TodoViewModel = @ptrCast(@alignCast(raw.?));
        self.onInputChange(text);
    }

    // `KeyboardActions(onDone = { vm.add(field.text()) })`: true = the intent took the draft, so the field clears itself.
    fn onSubmit(raw: ?*anyopaque, text: []const u8) bool {
        const self: *TodoViewModel = @ptrCast(@alignCast(raw.?));
        return self.add(text);
    }

    // `fun onInputChange(text: String) = _state.update { it.copy(input = text) }`
    pub fn onInputChange(self: *TodoViewModel, text: []const u8) void {
        self.state = self.state.withInput(text);
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

test "onInputChange keeps the draft in the state" {
    var vm = TodoViewModel.init();
    vm.onInputChange("buy milk");
    try std.testing.expectEqualStrings("buy milk", vm.uiState().draft());
    try std.testing.expectEqual(@as(usize, 0), vm.uiState().count);
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

test "start points the field at this model, so a submit is an intent" {
    var vm = TodoViewModel.init();
    vm.start(glinlandui.theme.dark);

    vm.field.setText("buy milk");
    try std.testing.expect(vm.field.submit());
    try std.testing.expectEqualStrings("buy milk", vm.uiState().items()[0].text());
    // The intent took the draft, so the field cleared itself and reported the empty text back to the model.
    try std.testing.expectEqualStrings("", vm.field.text());
    try std.testing.expectEqualStrings("", vm.uiState().draft());
}
