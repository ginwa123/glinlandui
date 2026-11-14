// The View: pure declaration from the state. Nothing here writes the model — a button raises an intent and the next frame draws what it says.
const glinlandui = @import("glinlandui");
const box_mod = glinlandui.components.box;
const button = glinlandui.components.button;
const text_mod = glinlandui.components.text;
const Color = glinlandui.Color;
const props = glinlandui.props;

const state_mod = @import("state.zig");
const view_model = @import("view_model.zig");

const dialog = glinlandui.file_dialog;
const DialogViewModel = view_model.DialogViewModel;
const Machine = state_mod.Machine;
const Theme = glinlandui.theme.Theme;

// The two tones the theme has no role for: "that answer is fine" against "that one is a problem".
const COLOR_OK = Color.hexC("#6bd968");
const COLOR_ERR = Color.hexC("#ff6b6b");
const COLOR_WARN = Color.hexC("#e8c56b");

// What a composable reads: the theme, the model, and its machine — a pointer, because `line` composes into the model's buffer.
pub const Scope = struct {
    theme: Theme,
    vm: *DialogViewModel,
    state: *Machine,
};

// `@Composable fun DialogScreen(vm: DialogViewModel = viewModel())`
pub fn DialogScreen(scope: *Scope) void {
    box_mod.box(.{
        .id = .{ .text = "dlg-root" },
        .direction = .column,
        .w = .grow,
        .h = .grow,
        .bg = scope.theme.colors.background,
        .pad = props.Pad.all(16),
        .gap = 12,
    }, scope, body);
}

fn body(scope: *Scope) void {
    const t = scope.theme;
    text_mod.label(.{
        .label = .{ .text = "glinlandui.file_dialog — the system file picker", .size = t.type_scale.body, .color = t.colors.text },
    });

    // Gated on `available()`: a button that cannot work is worse than no button, because the user finds out by clicking it.
    if (dialog.available()) {
        box_mod.row(.{
            .id = .{ .text = "dlg-actions" },
            .w = .grow,
            .h = .{ .fixed = 40 },
            .gap = 8,
        }, scope, actionRow);
    } else {
        box_mod.box(.{
            .id = .{ .text = "dlg-unavailable" },
            .w = .grow,
            .h = .{ .fixed = 40 },
            .bg = t.colors.surface,
            .radius = props.Radius.all(8),
            .pad = props.Pad.all(12),
            .child_align = .{ .x = .left, .y = .center },
        }, scope, unavailableChild);
    }

    box_mod.box(.{
        .id = .{ .text = "dlg-status" },
        .w = .grow,
        .h = .{ .fixed = 76 },
        .bg = t.colors.surface,
        .radius = props.Radius.all(8),
        .pad = props.Pad.all(12),
        .gap = 4,
    }, scope, statusChildren);
}

fn unavailableChild(scope: *Scope) void {
    const t = scope.theme;
    text_mod.label(.{
        .label = .{ .text = "No file dialog on this platform (the browser has none).", .size = t.type_scale.label, .color = COLOR_WARN },
    });
}

fn actionRow(scope: *Scope) void {
    const t = scope.theme;
    // A button's click arrives after this frame, so each one's context is written into the model rather than made here.
    const ctxs = &scope.vm.action_ctxs;
    var i: usize = 0;
    while (i < state_mod.ACTIONS.len) : (i += 1) {
        ctxs[i] = .{ .vm = scope.vm, .index = i };
        button.button(.{
            .id = .{ .text = state_mod.ACTIONS[i].id },
            .label = .{ .text = state_mod.ACTIONS[i].label, .size = t.type_scale.body, .color = t.colors.on_primary },
            .h = .{ .fixed = 40 },
            .bg = t.colors.primary,
            .hover_bg = t.colors.primary_hover,
            .on_click = .{ .f = onAction, .ctx = &ctxs[i] },
        });
    }
}

fn onAction(raw: ?*anyopaque) void {
    const ctx: *DialogViewModel.ActionCtx = @ptrCast(@alignCast(raw.?));
    ctx.vm.open(state_mod.ACTIONS[ctx.index].kind);
}

fn statusChildren(scope: *Scope) void {
    const t = scope.theme;
    const state = scope.state;
    text_mod.label(.{
        .label = .{ .text = "Last answer", .size = t.type_scale.caption, .color = t.colors.text_dim },
    });
    // Red for a problem and NOT red for a cancellation: `isProblem` is the same predicate the tests hold the line on, so the two cannot drift.
    text_mod.label(.{
        .label = .{ .text = state.line(), .size = t.type_scale.body, .color = if (state.outcome.isProblem()) COLOR_ERR else COLOR_OK },
    });
}
