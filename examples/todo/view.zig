// The View: pure declaration from the state.
// Nothing here writes the model. A widget raises an intent on the ViewModel and the next frame draws whatever the model says.
const glinlandui = @import("glinlandui");
const box_mod = glinlandui.components.box;
const text_mod = glinlandui.components.text;
const button = glinlandui.components.button;
const checkbox_mod = glinlandui.components.checkbox;
const input_mod = glinlandui.components.input;
const list_mod = glinlandui.components.list;
const scroll_mod = glinlandui.components.scroll;
const frame = glinlandui.frame;
const props = glinlandui.props;

const state_mod = @import("state.zig");
const view_model = @import("view_model.zig");

const TodoUiState = state_mod.TodoUiState;
const TodoViewModel = view_model.TodoViewModel;
const Theme = glinlandui.theme.Theme;

pub const field_id = "todo.field";
const list_id = "todo.list";
const rows_id = "todo.rows";
const row_h: u32 = 40;

// A click context must outlive the frame, because clicks are dispatched AFTER the declare returns — so these
// live in the App and are handed to the view, never built on this stack.
pub const AddCtx = struct {
    vm: *TodoViewModel,
    field: *input_mod.FieldCtx,
};

pub const RowCtx = struct {
    vm: *TodoViewModel,
    index: usize,
};

// What a composable reads: the theme, the model, the field, this frame's state, and the click contexts.
pub const Scope = struct {
    theme: Theme,
    vm: *TodoViewModel,
    // The draft: the engine's field owns the text, the caret and the selection, so the model does not hold a half-typed title.
    field: *input_mod.FieldCtx,
    state: TodoUiState,
    add: *AddCtx,
    rows: []RowCtx,
};

// `@Composable fun TodoScreen(vm: TodoViewModel = viewModel())`
pub fn TodoScreen(scope: *Scope) void {
    box_mod.box(.{
        .id = .{ .text = "todo.root" },
        .w = .grow,
        .h = .grow,
        .direction = .column,
        .bg = scope.theme.colors.background,
    }, scope, body);
}

fn body(scope: *Scope) void {
    header(scope);
    todoList(scope);
    footer(scope);
}

// `Row(Modifier.padding(16.dp)) { TextField(.., Modifier.weight(1f)); Button { Text("Add") } }`
fn header(scope: *Scope) void {
    box_mod.box(.{
        .id = .{ .text = "todo.header" },
        .direction = .row,
        .w = .grow,
        .pad = props.Pad.all(16),
        .gap = 8,
        .child_align = .{ .y = .center },
    }, scope, headerChildren);
}

fn headerChildren(scope: *Scope) void {
    const t = scope.theme;
    input_mod.liveField(.{
        .id = .{ .text = scope.field.id },
        .font_size = t.type_scale.body,
        .bg = t.colors.surface,
        .fg = t.colors.text,
        .sel_bg = t.colors.surface_variant,
        .sel_fg = t.colors.text,
        .caret_fg = t.colors.primary,
        .radius = props.Radius.all(6),
        .pad = props.Pad.axes(8, 10),
        .border = .{ .width = 1, .color = t.colors.divider },
        .w = .{ .clamp = .{ .min = 120, .max = 640, .grow = true } },
    }, scope.field);

    button.button(.{
        .id = .{ .text = "todo.add" },
        .label = .{ .text = "Add", .size = t.type_scale.label, .color = t.colors.on_primary },
        .bg = t.colors.primary,
        .hover_bg = t.colors.primary_hover,
        .radius = props.Radius.all(6),
        .pad = props.Pad.axes(8, 16),
        .on_click = onAdd,
        .ctx = scope.add,
    });
}

fn onAdd(raw: ?*anyopaque) void {
    const ctx: *AddCtx = @ptrCast(@alignCast(raw.?));
    // `add` answers whether it took the draft; a blank title leaves it in the field, which is what the user typed it for.
    if (ctx.vm.add(ctx.field.editor.text())) ctx.field.editor.setText("");
}

// `LazyColumn { itemsIndexed(todos) { i, todo -> Row { Checkbox; Text; TextButton } } }`
fn todoList(scope: *Scope) void {
    const t = scope.theme;
    scroll_mod.scroll(.{
        .id = .{ .text = list_id },
        .direction = .vertical,
        .w = .grow,
        .h = .grow,
        .bg = t.colors.background,
        .thumb_bg = t.colors.surface_variant,
        .thumb_hover_bg = t.colors.primary,
    }, scope, listChildren);
}

fn listChildren(scope: *Scope) void {
    const t = scope.theme;
    if (scope.state.count == 0) {
        text_mod.label(.{ .label = .{ .text = "No todos yet — type one and press Enter.", .size = t.type_scale.body, .color = t.colors.text_dim } });
        return;
    }
    // The engine's list owns the rows: their ids, their hover, and the click that selects one.
    list_mod.list(.{
        .id = .{ .text = rows_id },
        .row_h = row_h,
        .row_bg = t.colors.background,
        .hover_bg = t.colors.hover,
        .radius = 0,
        .on_select = onRow,
        .ctx = scope.vm,
    }, scope.state.items(), scope, renderRow);
}

fn onRow(raw: ?*anyopaque, index: usize) void {
    const vm: *TodoViewModel = @ptrCast(@alignCast(raw.?));
    vm.toggle(index);
}

// `Row(verticalAlignment = Alignment.CenterVertically) { Checkbox(..); Text(.., Modifier.weight(1f)); TextButton(..) }`
fn renderRow(scope: *Scope, todo: state_mod.Todo, index: usize) void {
    const t = scope.theme;
    const ctxs = scope.rows;
    ctxs[index] = .{ .vm = scope.vm, .index = index };

    checkbox_mod.checkbox(.{
        .id = .{ .text = frame.elementId("todo.row.check", index) },
        .checked = todo.done,
        .size = 18,
        .box_bg = t.colors.surface,
        .checked_bg = t.colors.primary,
        .check_color = t.colors.on_primary,
        .border_color = t.colors.divider,
        .on_click = onToggle,
        .ctx = &ctxs[index],
    });
    // The state is a value and this returns before Clay draws, so the run is copied into the frame's scratch.
    text_mod.label(.{
        .label = .{ .text = frame.formatText("{s}", .{todo.text()}), .size = t.type_scale.body, .color = if (todo.done) t.colors.text_done else t.colors.text },
    });
    box_mod.spacer(props.Id.at("todo.row.spacer", index));
    button.button(.{
        .id = props.Id.at("todo.row.delete", index),
        .label = .{ .text = "Delete", .size = t.type_scale.label },
        .bg = t.colors.background,
        .fg = t.colors.text_dim,
        .hover_bg = t.colors.surface_variant,
        .radius = props.Radius.all(6),
        .pad = props.Pad.axes(4, 10),
        .on_click = onDelete,
        .ctx = &ctxs[index],
    });
}

fn onToggle(raw: ?*anyopaque) void {
    const row: *RowCtx = @ptrCast(@alignCast(raw.?));
    row.vm.toggle(row.index);
}

fn onDelete(raw: ?*anyopaque) void {
    const row: *RowCtx = @ptrCast(@alignCast(raw.?));
    row.vm.remove(row.index);
}

fn footer(scope: *Scope) void {
    box_mod.box(.{
        .id = .{ .text = "todo.footer" },
        .w = .grow,
        .h = .{ .fixed = 26 },
        .direction = .row,
        .pad = props.Pad.all(8),
        .gap = 12,
        .child_align = .{ .y = .center },
    }, scope, footerChildren);
}

fn footerChildren(scope: *Scope) void {
    const t = scope.theme;
    const state = &scope.state;
    text_mod.label(.{
        .label = .{ .text = frame.formatText("{d} of {d} done", .{ state.doneCount(), state.count }), .size = t.type_scale.caption, .color = t.colors.text_dim },
    });
    box_mod.spacer(.{ .text = "todo.footer.spacer" });
    text_mod.label(.{
        .label = .{ .text = "Enter adds  ·  click a row to toggle", .size = t.type_scale.caption, .color = t.colors.text_done },
    });
}
