// The View: pure declaration from the state.
// Nothing here writes the model. A widget raises an intent on the ViewModel and the next frame draws whatever the model says.
const glinlandui = @import("glinlandui");
const box_mod = glinlandui.components.box;
const text_mod = glinlandui.components.text;
const button = glinlandui.components.button;
const scroll_mod = glinlandui.components.scroll;
const frame = glinlandui.frame;
const props = glinlandui.props;
const Color = glinlandui.Color;

const state_mod = @import("state.zig");
const view_model = @import("view_model.zig");

const Theme = glinlandui.theme.Theme;
const LazyUiState = state_mod.LazyUiState;
const LazyViewModel = view_model.LazyViewModel;

// The meter has two states and the theme has no role for either: missing the frame budget must LOOK wrong, so these two are the app's own.
const over_budget = Color.hexC("#c86a6a");
const within_budget = Color.hexC("#7fae8a");

// What a composable reads: the theme, the model, and this frame's snapshot of its state.
pub const Scope = struct {
    theme: Theme,
    vm: *LazyViewModel,
    // `val ui by vm.ui.collectAsState()`
    ui: LazyUiState,
};

// `@Composable fun LazyScrollScreen(vm: LazyScrollViewModel = viewModel())`
pub fn Screen(scope: *Scope) void {
    box_mod.box(.{
        .id = .{ .text = "root" },
        .w = .grow,
        .h = .grow,
        .direction = .column,
        .bg = scope.theme.colors.background,
        .gap = 0,
    }, scope, body);
}

fn body(scope: *Scope) void {
    header(scope);
    list(scope);
    footer(scope);
}

fn header(scope: *Scope) void {
    box_mod.box(.{
        .id = .{ .text = "header" },
        .w = .grow,
        .h = .{ .fixed = 44 },
        .direction = .row,
        .bg = scope.theme.colors.surface,
        .pad = props.Pad.all(10),
        .gap = 12,
    }, scope, headerChildren);
}

fn headerChildren(scope: *Scope) void {
    const t = scope.theme;
    const s = scope.ui.stats();
    text_mod.label(.{ .label = .{ .text = "10,000 rows", .size = t.type_scale.body, .color = t.colors.text } });
    text_mod.label(.{
        .label = .{
            .text = frame.formatText("fps {d: >6.1}   frame {d: >5.2} ms   avg {d: >5.2}   max {d: >6.2}", .{
                s.fps, s.last_ms, s.avg_ms, s.max_ms,
            }),
            .size = t.type_scale.body,
            // Red the moment the last frame misses a 144 Hz budget, so a regression is visible at a glance.
            .color = if (s.last_ms > state_mod.budget_144_ms) over_budget else within_budget,
        },
    });
    text_mod.label(.{
        .label = .{
            .text = frame.formatText("declared {d} of {d}", .{ scope.ui.declared, state_mod.row_count }),
            .size = t.type_scale.body,
            .color = t.colors.text_dim,
        },
    });
    box_mod.spacer(.{ .text = "header.spacer" });
    button.button(.{
        .id = .{ .text = "header.auto" },
        .label = .{ .text = if (scope.ui.auto) "Stop" else "Scroll", .size = t.type_scale.body },
        .bg = if (scope.ui.auto) t.colors.primary else t.colors.surface_variant,
        .fg = if (scope.ui.auto) t.colors.on_primary else t.colors.text,
        .hover_bg = if (scope.ui.auto) t.colors.primary_hover else t.colors.divider,
        .pad = props.Pad.axes(4, 14),
        .on_click = .{ .f = onToggleAuto, .ctx = scope.vm },
    });
    button.button(.{
        .id = .{ .text = "header.bottom" },
        .label = .{ .text = "End", .size = t.type_scale.body },
        .bg = t.colors.surface_variant,
        .fg = t.colors.text,
        .hover_bg = t.colors.divider,
        .pad = props.Pad.axes(4, 14),
        .on_click = .{ .f = onJumpBottom, .ctx = scope.vm },
    });
}

fn onToggleAuto(raw: ?*anyopaque) void {
    const vm: *LazyViewModel = @ptrCast(@alignCast(raw.?));
    vm.toggleAuto();
}

fn onJumpBottom(raw: ?*anyopaque) void {
    const vm: *LazyViewModel = @ptrCast(@alignCast(raw.?));
    vm.jumpToBottom();
}

fn list(scope: *Scope) void {
    const t = scope.theme;
    scroll_mod.scroll(.{
        .id = .{ .text = view_model.scroll_id },
        .direction = .vertical,
        .w = .grow,
        .h = .grow,
        .bg = t.colors.background,
        .thumb_bg = t.colors.surface_variant,
        .thumb_hover_bg = t.colors.primary,
    }, scope, listChildren);
}

fn listChildren(scope: *Scope) void {
    // What is on screen decides what is declared. This is the whole trick, and the model already answered it.
    const vis = scope.vm.visibleRows();

    // Everything above the viewport is ONE empty rectangle of its exact height: scrolling past ten thousand rows costs a single draw command, and the
    // scrollbar still knows how long the list is.
    if (vis.first_row > 0) {
        box_mod.box(.{
            .id = .{ .text = "lazy.pad.top" },
            .w = .grow,
            .h = .{ .fixed = @as(f32, @floatFromInt(vis.first_row)) * state_mod.row_h },
            .direction = .column,
        }, scope, noChildren);
    }

    for (0..vis.row_count) |i| {
        row(scope, vis.first_row + i);
    }

    const after = vis.first_row + vis.row_count;
    if (after < state_mod.row_count) {
        box_mod.box(.{
            .id = .{ .text = "lazy.pad.bottom" },
            .w = .grow,
            .h = .{ .fixed = @as(f32, @floatFromInt(state_mod.row_count - after)) * state_mod.row_h },
            .direction = .column,
        }, scope, noChildren);
    }
}

// A row is a function of its index, and so is the context its children draw from: nothing per row outlives the frame.
const RowCtx = struct {
    scope: *Scope,
    index: usize,
};

// One row: the row box with its hover colour, and the two labels inside it. Only the visible rows are declared.
fn row(scope: *Scope, index: usize) void {
    const t = scope.theme;
    box_mod.box(.{
        .id = props.Id.at("lazy.row", index),
        .direction = .row,
        .w = .grow,
        .h = .{ .fixed = state_mod.row_h },
        .pad = props.Pad.axes(6, 8),
        .gap = 16,
        .child_align = .{ .x = .left, .y = .center },
        .bg = if (index % 2 == 0) t.colors.background else t.colors.surface,
        .hover_bg = t.colors.hover,
    }, RowCtx{ .scope = scope, .index = index }, rowChildren);
}

fn rowChildren(ctx: RowCtx) void {
    const t = ctx.scope.theme;
    text_mod.label(.{ .label = .{ .text = state_mod.rowName(ctx.index), .size = t.type_scale.label, .color = t.colors.text } });
    text_mod.label(.{ .label = .{ .text = state_mod.rowMeta(ctx.index), .size = t.type_scale.label, .color = t.colors.text_dim } });
}

fn noChildren(_: *Scope) void {}

fn footer(scope: *Scope) void {
    box_mod.box(.{
        .id = .{ .text = "footer" },
        .w = .grow,
        .h = .{ .fixed = 26 },
        .direction = .row,
        .bg = scope.theme.colors.surface,
        .pad = props.Pad.all(8),
        .gap = 12,
    }, scope, footerChildren);
}

fn footerChildren(scope: *Scope) void {
    const t = scope.theme;
    text_mod.label(.{
        .label = .{ .text = "Space scrolls  ·  End jumps  ·  only the visible rows are declared", .size = t.type_scale.caption, .color = t.colors.text_dim },
    });
}
