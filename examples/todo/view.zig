// The View: pure declaration from the state.
// Nothing here writes the model. A widget raises an intent on the ViewModel and the next frame draws whatever
// the model says — the one-way flow Compose calls "state down, events up".
// Zig has no closures, so a composable receives a `*Scope` (the hidden `Composer` plus the theme and the
// `viewModel()` lookup) and a click handler is a plain `fn` plus an opaque context.
const std = @import("std");
const glinlandui = @import("glinlandui");
const box_mod = glinlandui.components.box;
const text_mod = glinlandui.components.text;
const button = glinlandui.components.button;
const checkbox_mod = glinlandui.components.checkbox;
const input_mod = glinlandui.components.input;
const scroll_mod = glinlandui.components.scroll;
const registry = glinlandui.components.click_registry;
const cl = glinlandui.zclay;
const frame = glinlandui.frame;
const table = glinlandui.table;
const text_editor = glinlandui.text_editor;

const state_mod = @import("state.zig");
const view_model = @import("view_model.zig");
const theme_mod = @import("theme.zig");

const TodoUiState = state_mod.TodoUiState;
const TodoViewModel = view_model.TodoViewModel;
const Composition = glinlandui.composition.Composition;
const Theme = glinlandui.theme.Theme;

pub const field_id = "todo.field";
const list_id = "todo.list";
// One row's height, taken from the virtualisation helper's own constant so the two cannot disagree.
const row_h: u32 = table.row_height;

// The editing buffer and the caret. This is VIEW state, not model state: the model holds the value, the
// editor holds where the caret is — the same split Compose makes between `value` and the internal selection.
pub const Field = struct {
    buf: [state_mod.max_input]u8 = undefined,
    ed: text_editor.Editor = undefined,
    ctx: input_mod.FieldCtx = undefined,
    bound: bool = false,

    // Wire the editor to its own buffer, once, after the Field is where it will stay: the editor keeps a pointer
    // to that buffer, so binding a copy would leave it editing a dead struct.
    pub fn bind(self: *Field) void {
        if (self.bound) return;
        self.ed = text_editor.Editor.init(&self.buf);
        self.ctx = .{ .input = &self.ed, .id = field_id, .measure = measure };
        self.bound = true;
    }
};

// Measure with the font that actually draws the field. A guessed cell width drifts off the glyphs, so the caret,
// the click and the drag would each land somewhere slightly different.
fn measure(bytes: []const u8, font_size: u16) f32 {
    return glinlandui.text.measureText(bytes, font_size).w;
}

// What a composable reads from the ambient tree: the composition, the theme, and the model.
pub const Scope = struct {
    comp: *Composition,
    theme: Theme,
    vm: *TodoViewModel,
    field: *Field,
};

// One frame's snapshot of the state, plus the scope. Children take this, so what the view declares is a function
// of exactly one value — which is what makes "the model changed" and "the screen changed" the same statement.
pub const Screen = struct {
    scope: *Scope,
    state: TodoUiState,
};

// A row's click context. It must outlive the frame, because clicks are dispatched AFTER the declare returns —
// so it lives in a composition slot, not on this stack.
const RowCtx = struct {
    vm: *TodoViewModel,
    index: usize,
};

// `@Composable fun TodoScreen(vm: TodoViewModel = viewModel())`
pub fn TodoScreen(scope: *Scope) void {
    // `val state by vm.state.collectAsState()`
    const state = scope.comp.collectAsState(TodoUiState, scope.vm.state.asStateFlow());

    // `LaunchedEffect(Unit) { focusRequester.requestFocus() }`: the field owns the keyboard from the first frame.
    scope.comp.effect("todo.focus", 1, scope.field, focusField);

    var screen = Screen{ .scope = scope, .state = state };
    theme_mod.Surface(scope.theme, "todo.root", &screen, surfaceChildren);
}

fn focusField(_: *Field) void {
    frame.setFocus(field_id);
}

// `Surface { Column(Modifier.padding(16.dp)) { ... } }`
fn surfaceChildren(screen: *Screen) void {
    header(screen);
    todoList(screen);
    footer(screen);
}

// ---- header: TextField + Button --------------------------------------------------------------------------------

fn header(screen: *Screen) void {
    // `Modifier.padding(16.dp).fillMaxWidth()` in Compose; here the props struct IS the modifier, so it is two fields.
    box_mod.box(.{
        .id = "todo.header",
        .direction = .row,
        .w = .grow,
        .pad = 16,
        .gap = 8,
        .child_align = .{ .y = .center },
    }, screen, headerChildren);
}

fn headerChildren(screen: *Screen) void {
    const t = screen.scope.theme;
    textField(screen);
    button.button(.{
        .id = "todo.add",
        .label = "Add",
        .font_size = t.type_scale.label,
        .bg = t.colors.primary,
        .fg = t.colors.on_primary,
        .hover_bg = t.colors.primary_hover,
        .radius = 6,
        .pad_tb = 8,
        .pad_lr = 16,
        .on_click = onAdd,
        // The ViewModel outlives the frame; a `*Scope` on this stack does not.
        .ctx = screen.scope.vm,
    });
}

// `TextField(value = state.input, onValueChange = vm::onInputChange, modifier = Modifier.weight(1f))`
fn textField(screen: *Screen) void {
    const t = screen.scope.theme;
    const field = screen.scope.field;
    field.bind();

    // Two writers, one source of truth. If the model published, adopt its text — that is `add()` clearing the
    // field. Otherwise the editor is authoritative and its text is reported as an intent, never written here.
    const seen = screen.scope.comp.remember(u64, "todo.field.revision", 0);
    const model_text = screen.state.input.slice();
    const edited_text = field.ed.text();
    if (seen.* != screen.scope.vm.revision()) {
        if (!std.mem.eql(u8, edited_text, model_text)) field.ed.setText(model_text);
        seen.* = screen.scope.vm.revision();
    } else if (!std.mem.eql(u8, edited_text, model_text)) {
        screen.scope.vm.onInputChange(edited_text);
        seen.* = screen.scope.vm.revision();
    }

    input_mod.liveField(.{
        .id = field_id,
        .font_size = t.type_scale.body,
        .bg = t.colors.surface,
        .fg = t.colors.text,
        .sel_bg = t.colors.surface_variant,
        .sel_fg = t.colors.text,
        .caret_fg = t.colors.primary,
        .radius = 6,
        .pad_tb = 8,
        .pad_lr = 10,
        .border_width = 1,
        .border_color = t.colors.divider,
        .min_w = 120,
        // `Modifier.weight(1f)`: take the row's spare width, and stop before it stops being a field.
        .max_w = 640,
    }, &field.ctx);
}

fn onAdd(ctx: ?*anyopaque) void {
    const vm: *TodoViewModel = @ptrCast(@alignCast(ctx.?));
    vm.add();
}

// ---- the list: `LazyColumn { itemsIndexed(todos) { i, todo -> ... } }` ----------------------------------------

fn todoList(screen: *Screen) void {
    const t = screen.scope.theme;
    scroll_mod.scroll(.{
        .id = list_id,
        .direction = .vertical,
        .w = .grow,
        .h = .grow,
        .bg = t.colors.background,
        .thumb_bg = t.colors.surface_variant,
        .thumb_hover_bg = t.colors.primary,
    }, screen, listChildren);
}

fn listChildren(screen: *Screen) void {
    const total = screen.state.count;
    if (total == 0) {
        emptyState(screen);
        return;
    }

    // What is on screen decides what is declared: the same four lines `LazyColumn` spends on its window.
    const data = cl.getScrollContainerData(cl.getElementId(list_id));
    const view_h: f32 = if (data.found) data.scroll_container_dimensions.h else 600;
    // Clay's scroll position is negative going down.
    const scroll_y: f32 = if (data.found) @max(-data.scroll_position.y, 0) else 0;
    const vis = table.visible(.{
        .total_rows = total,
        .total_cols = 1,
        .scroll_y = scroll_y,
        .height = view_h,
        .width = 0,
        .overscan = 2,
        .row_height = row_h,
    });

    if (vis.first_row > 0) spacerRow("todo.pad.top", vis.first_row);
    for (0..vis.row_count) |i| todoRow(screen, vis.first_row + i);
    const after = vis.first_row + vis.row_count;
    if (after < total) spacerRow("todo.pad.bottom", total - after);
}

// Everything outside the viewport is ONE empty rectangle of its exact height: the scrollbar still reports the
// real list length, and a list of ten thousand rows would still cost one command per frame.
fn spacerRow(id: []const u8, rows: usize) void {
    box_mod.box(.{
        .id = id,
        .w = .grow,
        .h = .{ .fixed = @as(f32, @floatFromInt(rows)) * @as(f32, @floatFromInt(row_h)) },
        .direction = .column,
    }, {}, noChildren);
}

fn noChildren(_: void) void {}

fn emptyState(screen: *Screen) void {
    box_mod.box(.{
        .id = "todo.empty",
        .w = .grow,
        .h = .fit,
        .pad = 24,
        .direction = .column,
    }, screen, emptyStateChildren);
}

fn emptyStateChildren(screen: *Screen) void {
    text_mod.label(.{
        .str = "No todos yet — type one and press Enter.",
        .font_size = screen.scope.theme.type_scale.body,
        .color = screen.scope.theme.colors.text_dim,
    });
}

// `Row(verticalAlignment = Alignment.CenterVertically) { Checkbox(..); Text(.., Modifier.weight(1f)); TextButton(..) }`
fn todoRow(screen: *Screen, index: usize) void {
    const t = screen.scope.theme;
    const todo = screen.state.todos[index];
    const ctxs = screen.scope.comp.remember([state_mod.max_todos]RowCtx, "todo.rows", undefined);
    ctxs[index] = .{ .vm = screen.scope.vm, .index = index };

    const row_id = frame.elementId("todo.row", index);
    // Registered BEFORE the box is declared: the Delete button inside registers later, and a later entry wins
    // the hit test — which is what keeps a click on Delete from also toggling the row underneath it.
    registry.registerClickCursor(cl.getElementId(row_id), onToggleRow, &ctxs[index], .pointer);
    cl.UI()(.{
        .id = .ID(row_id),
        .layout = .{
            .direction = .left_to_right,
            .sizing = .{ .w = .grow, .h = .fixed(@floatFromInt(row_h)) },
            .padding = .axes(0, 16),
            .child_alignment = .{ .x = .left, .y = .center },
            .child_gap = 12,
        },
        .background_color = (if (cl.hovered()) t.colors.hover else t.colors.background).toClay(),
    })({
        checkbox_mod.checkbox(.{
            .id = frame.elementId("todo.row.check", index),
            .checked = todo.done,
            .size = 18,
            .box_bg = t.colors.surface,
            .checked_bg = t.colors.primary,
            .check_color = t.colors.on_primary,
            .border_color = t.colors.divider,
            .on_click = onToggleRow,
            .ctx = &ctxs[index],
        });
        // The state is a stack value and `todoRow` returns before Clay draws, so the run has to be copied into the
        // frame's scratch. A literal, or the App's own field buffer, needs no copy.
        text_mod.label(.{
            .str = frame.formatText("{s}", .{todo.title.slice()}),
            .font_size = t.type_scale.body,
            .color = if (todo.done) t.colors.text_done else t.colors.text,
        });
        box_mod.spacer(frame.elementId("todo.row.spacer", index));
        button.button(.{
            .id = frame.elementId("todo.row.delete", index),
            .label = "Delete",
            .font_size = t.type_scale.label,
            .bg = t.colors.background,
            .fg = t.colors.text_dim,
            .hover_bg = t.colors.surface_variant,
            .radius = 6,
            .pad_tb = 4,
            .pad_lr = 10,
            .on_click = onDeleteRow,
            .ctx = &ctxs[index],
        });
    });
}

fn onToggleRow(ctx: ?*anyopaque) void {
    const row: *RowCtx = @ptrCast(@alignCast(ctx.?));
    row.vm.toggle(row.index);
}

fn onDeleteRow(ctx: ?*anyopaque) void {
    const row: *RowCtx = @ptrCast(@alignCast(ctx.?));
    row.vm.remove(row.index);
}

// ---- footer ---------------------------------------------------------------------------------------------------

fn footer(screen: *Screen) void {
    const t = screen.scope.theme;
    box_mod.box(.{
        .id = "todo.footer",
        .w = .grow,
        .h = .{ .fixed = 26 },
        .direction = .row,
        .bg = t.colors.background,
        .pad = 8,
        .gap = 12,
        .child_align = .{ .y = .center },
    }, screen, footerChildren);
}

fn footerChildren(screen: *Screen) void {
    const t = screen.scope.theme;
    const state = &screen.state;
    text_mod.label(.{
        .str = frame.formatText("{d} of {d} done", .{ state.doneCount(), state.count }),
        .font_size = t.type_scale.caption,
        .color = t.colors.text_dim,
    });
    box_mod.spacer("todo.footer.spacer");
    text_mod.label(.{
        .str = "Enter adds  ·  click a row to toggle",
        .font_size = t.type_scale.caption,
        .color = t.colors.text_done,
    });
}
