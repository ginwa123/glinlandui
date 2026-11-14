// The View: declaration only — the page, its sections, the rows and the widget demos read the state and raise intents.
const glinlandui = @import("glinlandui");
const props = glinlandui.props;
const components = glinlandui.components;
const box_mod = components.box;
const text_mod = components.text;
const button = components.button;
const badge_mod = components.badge;
const checkbox_mod = components.checkbox;
const radio_mod = components.radio;
const toggle_mod = components.toggle;
const slider_mod = components.slider;
const tabs_mod = components.tabs;
const list_mod = components.list;
const tree_mod = components.tree;
const scroll_mod = components.scroll;
const dropdown_mod = components.dropdown;
const icon_mod = components.icon;
const input_mod = components.input;
const frame = glinlandui.frame;

const state_mod = @import("state.zig");
const view_model = @import("view_model.zig");

const CatalogUiState = state_mod.CatalogUiState;
const CatalogViewModel = view_model.CatalogViewModel;
const Theme = glinlandui.theme.Theme;

// No metrics here on purpose: every widget below is drawn with its own defaults, which are the kit's.
const r_card: u16 = 8;

// What a composable reads: the theme, the model, and this frame's snapshot of its state. The fields and the click contexts are the model's.
pub const Scope = struct {
    theme: Theme,
    vm: *CatalogViewModel,
    // `val state by vm.state.collectAsState()`
    state: CatalogUiState,
};

// `@Composable fun CatalogScreen(vm: CatalogViewModel = viewModel())`: one scroll container over a column of sections.
pub fn CatalogScreen(scope: *Scope) void {
    box_mod.box(.{
        .id = .{ .text = "catalog.root" },
        .w = .grow,
        .h = .grow,
        .direction = .column,
        .bg = scope.theme.colors.background,
    }, scope, rootChildren);
}

fn rootChildren(scope: *Scope) void {
    const c = scope.theme.colors;
    scroll_mod.scroll(.{
        .id = .{ .text = "catalog.scroll" },
        .direction = .vertical,
        .w = .grow,
        .h = .grow,
        .bg = c.background,
        .thumb_bg = c.divider,
        .thumb_hover_bg = c.text_done,
    }, scope, page);
}

fn page(scope: *Scope) void {
    box_mod.box(.{
        .id = .{ .text = "catalog.page" },
        .w = .grow,
        .direction = .column,
        .pad = props.Pad.all(24),
        .gap = 16,
    }, scope, pageChildren);
}

fn pageChildren(scope: *Scope) void {
    header(scope);
    for (&state_mod.sections) |*s| section(scope, s);
}

fn header(scope: *Scope) void {
    box_mod.box(.{
        .id = .{ .text = "catalog.header" },
        .w = .grow,
        .direction = .column,
        .gap = 6,
    }, scope, headerChildren);
}

fn headerChildren(scope: *Scope) void {
    const t = scope.theme;
    text_mod.label(.{ .label = .{ .text = "glinlandui · catalog", .size = t.type_scale.title, .color = t.colors.text } });
    text_mod.label(.{
        .label = .{ .text = "every component the toolkit ships, drawn with the kit's eleven roles", .size = t.type_scale.caption, .color = t.colors.text_dim },
    });
    // What the widgets last reported, so a click is visible and not only felt.
    const said = if (scope.state.lastText().len == 0) "nothing yet" else scope.state.lastText();
    const shown = frame.formatText("last intent: {s}", .{said});
    text_mod.label(.{ .label = .{ .text = shown, .size = t.type_scale.caption, .color = t.colors.text_done } });
}

// A card's context may live on the frame: a box fills its children inside the same call, and no click keeps it.
const SectionCtx = struct {
    scope: *Scope,
    section: *const state_mod.Section,
};

fn section(scope: *Scope, s: *const state_mod.Section) void {
    const c = scope.theme.colors;
    box_mod.box(.{
        .id = .{ .text = s.id },
        .w = .grow,
        .direction = .column,
        .bg = c.surface,
        .pad = props.Pad.all(16),
        .gap = 12,
        .radius = props.Radius.all(r_card),
        .border = .{ .width = 1, .color = c.divider },
    }, SectionCtx{ .scope = scope, .section = s }, sectionChildren);
}

fn sectionChildren(ctx: SectionCtx) void {
    box_mod.box(.{
        .id = .{ .text = frame.formatText("{s}.head", .{ctx.section.id}) },
        .w = .grow,
        .direction = .column,
        .gap = 2,
    }, ctx, sectionHeadChildren);
    sectionBody(ctx);
}

fn sectionHeadChildren(ctx: SectionCtx) void {
    const t = ctx.scope.theme;
    text_mod.label(.{ .label = .{ .text = ctx.section.title, .size = t.type_scale.body, .color = t.colors.text } });
    text_mod.label(.{ .label = .{ .text = ctx.section.note, .size = t.type_scale.caption, .color = t.colors.text_dim } });
}

// Which demo the section's card holds is the data's to say; how it is drawn is this file's.
fn sectionBody(ctx: SectionCtx) void {
    switch (ctx.section.body) {
        .buttons => buttonsBody(ctx.scope),
        .text_field => fieldBody(ctx.scope),
        .selection => selectionBody(ctx.scope),
        .roles => rolesBody(ctx.scope),
        .type_scale => typeBody(ctx.scope),
        .badges => badgeBody(ctx.scope),
        .tabs => tabsBody(ctx.scope),
        .list => listBody(ctx.scope),
        .tree => treeBody(ctx.scope),
        .dropdown => dropdownBody(ctx.scope),
    }
}

// ---- buttons -------------------------------------------------------------------------------------------------

fn buttonsBody(scope: *Scope) void {
    row(scope, "catalog.buttons.emphasis", emphasisButtons);
    row(scope, "catalog.buttons.sizes", sizeButtons);
    row(scope, "catalog.buttons.states", stateButtons);
}

const RowCtx = struct { scope: *Scope, body: *const fn (*Scope) void };

fn row(scope: *Scope, id: []const u8, body: *const fn (*Scope) void) void {
    box_mod.box(.{
        .id = .{ .text = id },
        .w = .grow,
        .direction = .row,
        .gap = 8,
        .child_align = .{ .y = .center },
    }, RowCtx{ .scope = scope, .body = body }, rowChildren);
}

fn rowChildren(ctx: RowCtx) void {
    ctx.body(ctx.scope);
}

fn emphasisButtons(scope: *Scope) void {
    const c = scope.theme.colors;
    button.button(.{
        .id = .{ .text = "catalog.btn.primary" },
        .label = .{ .text = "Run query", .color = c.on_primary },
        .bg = c.primary,
        .fg = c.on_primary,
        .hover_bg = c.primary_hover,
        .on_click = .{ .f = onPrimary, .ctx = scope.vm },
    });
    button.button(.{
        .id = .{ .text = "catalog.btn.secondary" },
        .label = .{ .text = "Explain" },
        .bg = c.surface_variant,
        .fg = c.text,
        .hover_bg = c.hover,
        .border = .{ .width = 1, .color = c.divider },
        .on_click = .{ .f = onSecondary, .ctx = scope.vm },
    });
    button.button(.{
        .id = .{ .text = "catalog.btn.quiet" },
        .label = .{ .text = "Cancel" },
        .bg = c.surface,
        .fg = c.text_dim,
        .hover_bg = c.hover,
        .on_click = .{ .f = onQuiet, .ctx = scope.vm },
    });
    button.button(.{
        .id = .{ .text = "catalog.btn.danger" },
        .label = .{ .text = "Drop table" },
        .bg = c.surface,
        .fg = state_mod.danger,
        .hover_bg = c.hover,
        .border = .{ .width = 1, .color = state_mod.danger_edge },
        .on_click = .{ .f = onDanger, .ctx = scope.vm },
    });
    button.button(.{
        .id = .{ .text = "catalog.btn.disabled" },
        .label = .{ .text = "Disabled" },
        .disabled = true,
        .disabled_bg = c.surface_variant,
        .disabled_fg = c.text_done,
    });
}

// The one row that states sizes on purpose: a catalog shows the three variants, and the button has no size enum.
fn sizeButtons(scope: *Scope) void {
    const t = scope.theme;
    const c = t.colors;
    button.button(.{
        .id = .{ .text = "catalog.btn.sm" },
        .label = .{ .text = "Small", .size = t.type_scale.caption, .color = c.on_primary },
        .bg = c.primary,
        .fg = c.on_primary,
        .hover_bg = c.primary_hover,
        .h = .{ .fixed = 24 },
        .pad = props.Pad.axes(0, 9),
        .on_click = .{ .f = onSmall, .ctx = scope.vm },
    });
    button.button(.{
        .id = .{ .text = "catalog.btn.md" },
        .label = .{ .text = "Medium", .size = t.type_scale.label, .color = c.on_primary },
        .bg = c.primary,
        .fg = c.on_primary,
        .hover_bg = c.primary_hover,
        .h = .{ .fixed = 28 },
        .pad = props.Pad.axes(0, 12),
        .on_click = .{ .f = onMedium, .ctx = scope.vm },
    });
    button.button(.{
        .id = .{ .text = "catalog.btn.lg" },
        .label = .{ .text = "Large", .size = t.type_scale.body, .color = c.on_primary },
        .bg = c.primary,
        .fg = c.on_primary,
        .hover_bg = c.primary_hover,
        .h = .{ .fixed = 32 },
        .pad = props.Pad.axes(0, 16),
        .on_click = .{ .f = onLarge, .ctx = scope.vm },
    });
}

fn stateButtons(scope: *Scope) void {
    const t = scope.theme;
    const c = t.colors;
    text_mod.label(.{ .label = .{ .text = "hover, pressed and disabled are 1px of fill — nothing moves.", .size = t.type_scale.caption, .color = c.text_done } });
    const shown = frame.formatText("slider {d:.0}", .{scope.state.slider});
    badge_mod.badge(.{ .id = .{ .text = "catalog.btn.badge" }, .label = .{ .text = shown, .size = t.type_scale.caption, .color = c.text_dim }, .bg = c.surface_variant });
}

// ---- text field ----------------------------------------------------------------------------------------------

fn fieldBody(scope: *Scope) void {
    box_mod.box(.{
        .id = .{ .text = "catalog.field.row" },
        .w = .grow,
        .direction = .row,
        .gap = 8,
        .child_align = .{ .y = .center },
    }, scope, fieldRowChildren);
}

fn fieldRowChildren(scope: *Scope) void {
    const t = scope.theme;
    box_mod.box(.{
        .id = .{ .text = "catalog.field.wrap" },
        .w = .{ .clamp = .{ .min = 160, .max = 420, .grow = true } },
        .direction = .row,
    }, scope, fieldChildren);
    text_mod.label(.{
        .label = .{ .text = "type, select, copy — the field owns the caret and reports every edit", .size = t.type_scale.caption, .color = t.colors.text_done },
    });
}

fn fieldChildren(scope: *Scope) void {
    const field = &scope.vm.field;
    // `TextField(value = state.draft)`: one line of state in, and the field reports every edit back through `on_change`.
    field.value = scope.state.draftText();
    input_mod.textField(field);
}

// ---- selection controls --------------------------------------------------------------------------------------

fn selectionBody(scope: *Scope) void {
    row(scope, "catalog.sel.row", selectionRow);
}

fn selectionRow(scope: *Scope) void {
    const t = scope.theme;
    const c = t.colors;
    const state = &scope.state;
    checkbox_mod.checkbox(.{
        .id = .{ .text = "catalog.check" },
        .checked = state.checked,
        .box_bg = c.background,
        .checked_bg = c.primary,
        .check_color = c.on_primary,
        .border_color = c.text_done,
        .hover_bg = c.hover,
        .on_click = .{ .f = onCheck, .ctx = scope.vm },
    });
    text_mod.label(.{ .label = .{ .text = "Include views", .size = t.type_scale.label, .color = c.text } });

    // A radio's click carries only a context, so each one points at the model's own row of them.
    var i: usize = 0;
    while (i < state_mod.radio_count) : (i += 1) {
        radio_mod.radio(.{
            .id = props.Id.at("catalog.radio", i),
            .selected = state.radio == i,
            .outer_bg = c.background,
            .selected_border = c.primary,
            .border_color = c.text_done,
            .dot_color = c.primary,
            .on_click = .{ .f = onRadio, .ctx = &scope.vm.radio_ctxs[i] },
        });
    }
    text_mod.label(.{ .label = .{ .text = "read only", .size = t.type_scale.label, .color = c.text } });

    toggle_mod.toggle(.{
        .id = .{ .text = "catalog.toggle" },
        .on = state.toggled,
        .on_bg = c.primary,
        .off_bg = c.surface_variant,
        .knob_color = c.on_primary,
        .on_click = .{ .f = onToggle, .ctx = scope.vm },
    });
    text_mod.label(.{ .label = .{ .text = "auto-run", .size = t.type_scale.label, .color = c.text } });

    slider_mod.slider(.{
        .id = .{ .text = view_model.slider_id },
        .value = state.slider,
        .min = 0,
        .max = 100,
        .track_bg = c.surface_variant,
        .fill_bg = c.primary,
        .thumb_color = c.primary,
        .on_change = .{ .f = onSlider, .ctx = scope.vm },
    });
}

// ---- colour roles --------------------------------------------------------------------------------------------

fn rolesBody(scope: *Scope) void {
    box_mod.box(.{
        .id = .{ .text = "catalog.roles.row" },
        .w = .grow,
        .direction = .row,
        .gap = 8,
    }, scope.theme, rolesRowChildren);
}

fn rolesRowChildren(t: Theme) void {
    for (state_mod.swatches) |s| {
        box_mod.box(.{
            .id = .{ .text = s.name },
            .w = .{ .fixed = 68 },
            .direction = .column,
            .gap = 4,
        }, SwatchCtx{ .swatch = s, .theme = t }, swatchChildren);
    }
}

const SwatchCtx = struct { swatch: state_mod.Swatch, theme: Theme };

fn swatchChildren(ctx: SwatchCtx) void {
    box_mod.box(.{
        .id = .{ .text = frame.formatText("{s}.chip", .{ctx.swatch.name}) },
        .w = .grow,
        .h = .{ .fixed = 40 },
        .direction = .row,
        .bg = ctx.swatch.color,
        .border = .{ .width = 1, .color = ctx.theme.colors.divider },
    }, {}, noChildren);
    text_mod.label(.{ .label = .{ .text = ctx.swatch.name, .size = ctx.theme.type_scale.caption, .color = ctx.theme.colors.text_dim } });
}

fn noChildren(_: void) void {}

// ---- type ----------------------------------------------------------------------------------------------------

fn typeBody(scope: *Scope) void {
    box_mod.box(.{
        .id = .{ .text = "catalog.type.col" },
        .w = .grow,
        .direction = .column,
        .gap = 8,
    }, scope.theme, typeColumnChildren);
}

fn typeColumnChildren(t: Theme) void {
    const c = t.colors;
    text_mod.label(.{ .label = .{ .text = "Schema · main.db", .size = t.type_scale.title, .color = c.text } });
    text_mod.label(.{ .label = .{ .text = "Select rows from orders where total > 100.", .size = t.type_scale.body, .color = c.text } });
    text_mod.label(.{ .label = .{ .text = "Table name, column type, row count", .size = t.type_scale.label, .color = c.text_dim } });
    text_mod.label(.{ .label = .{ .text = "42 ROWS · 6 COLUMNS · 12 ms", .size = t.type_scale.caption, .color = c.text_done } });
}

// ---- badges + icons ------------------------------------------------------------------------------------------

fn badgeBody(scope: *Scope) void {
    row(scope, "catalog.badges.row", badgesRow);
}

fn badgesRow(scope: *Scope) void {
    const t = scope.theme;
    const c = t.colors;
    badge_mod.badge(.{ .id = .{ .text = "catalog.badge.ok" }, .label = .{ .text = "connected", .size = t.type_scale.caption, .color = c.primary }, .bg = c.surface_variant });
    badge_mod.badge(.{ .id = .{ .text = "catalog.badge.warn" }, .label = .{ .text = "read only", .size = t.type_scale.caption, .color = c.text_dim }, .bg = c.surface_variant });
    badge_mod.badge(.{ .id = .{ .text = "catalog.badge.pk" }, .label = .{ .text = "primary key", .size = t.type_scale.caption, .color = c.text_dim }, .bg = c.surface_variant });
    badge_mod.badge(.{ .id = .{ .text = "catalog.badge.null" }, .label = .{ .text = "nullable", .size = t.type_scale.caption, .color = c.text_done }, .bg = c.surface });
    inline for ([_][]const u8{ "▸", "▾", "+", "×", "⌘", "↵" }) |glyph| {
        icon_mod.icon(.{ .glyph = glyph, .font_size = t.type_scale.body, .color = c.text_dim });
    }
}

// ---- tabs ----------------------------------------------------------------------------------------------------

fn tabsBody(scope: *Scope) void {
    const c = scope.theme.colors;
    // Built per frame from the state: a tab bar is a view of which tab is open, not a constant.
    var demo_tabs: [state_mod.tab_items.len]tabs_mod.Tab = undefined;
    for (state_mod.tab_items, 0..) |item, i| {
        demo_tabs[i] = .{ .label = item.label, .closable = item.closable, .active = scope.state.tab == i };
    }
    tabs_mod.tabs(.{
        .id = .{ .text = "catalog.tabs" },
        .tabs = demo_tabs[0..],
        .bg = c.surface,
        .active_bg = c.background,
        .fg = c.text_dim,
        .active_fg = c.text,
        .close_fg = c.text_done,
        .on_select = .{ .f = onTab, .ctx = scope.vm },
    });
}

// ---- list ----------------------------------------------------------------------------------------------------

fn listBody(scope: *Scope) void {
    const c = scope.theme.colors;
    list_mod.list(.{
        .id = .{ .text = "catalog.list" },
        .row_bg = c.surface,
        .selected_bg = glinlandui.theme.selected,
        .row_fg = c.text,
        .selected_fg = c.text,
        .hover_bg = c.hover,
        .border_width = 1,
        .border_color = c.divider,
        .selected = scope.state.row,
        .on_select = .{ .f = onRow, .ctx = scope.vm },
    }, state_mod.table_row_slice, scope, listRow);
}

fn listRow(scope: *Scope, item: []const u8, index: usize) void {
    const t = scope.theme;
    const c = t.colors;
    text_mod.label(.{ .label = .{ .text = item, .size = t.type_scale.label, .color = c.text } });
    badge_mod.badge(.{
        .id = props.Id.at("catalog.list.meta", index),
        .label = .{ .text = "table", .size = t.type_scale.caption, .color = c.text_done },
        .bg = c.surface,
    });
}

// ---- tree ----------------------------------------------------------------------------------------------------

fn treeBody(scope: *Scope) void {
    const c = scope.theme.colors;
    // The rows are the data's values; they are translated here, in the frame the tree reads them in.
    var rows: [state_mod.tree_rows.len]tree_mod.Row = undefined;
    for (state_mod.tree_rows, 0..) |r, i| {
        rows[i] = .{
            .label = r.label,
            .depth = r.depth,
            .has_children = r.has_children,
            .expanded = r.expanded,
            .selected = r.selected,
            .meta = r.meta,
            .kind = switch (r.kind) {
                .group => .group,
                .item => .item,
                .leaf => .leaf,
            },
        };
    }
    tree_mod.tree(.{
        .id = .{ .text = "catalog.tree" },
        .rows = rows[0..],
        .row_bg = c.surface,
        .selected_bg = glinlandui.theme.selected,
        .hover_bg = c.hover,
        .fg = c.text,
        .selected_fg = c.text,
        .group_fg = c.text,
        .meta_fg = c.text_dim,
        .caret_fg = c.text_done,
        .selected_bar = c.primary,
        .on_select = .{ .f = onTree, .ctx = scope.vm },
    });
}

// ---- dropdown ------------------------------------------------------------------------------------------------

fn dropdownBody(scope: *Scope) void {
    box_mod.box(.{
        .id = .{ .text = "catalog.dd.wrap" },
        .w = .{ .fixed = 260 },
        .direction = .column,
    }, scope, dropdownWrapChildren);
}

fn dropdownWrapChildren(scope: *Scope) void {
    const c = scope.theme.colors;
    // The field is the filter: the rows are whatever matches what has been typed into it.
    var shown: [state_mod.max_options][]const u8 = undefined;
    var n: usize = 0;
    for (state_mod.options) |option| {
        if (dropdown_mod.matches(scope.state.filterText(), option)) {
            shown[n] = option;
            n += 1;
        }
    }
    const field = &scope.vm.dd_field;
    // `TextField(value = state.filter)`: the dropdown paints the field, and the state holds what it filters on.
    field.value = scope.state.filterText();
    dropdown_mod.dropdown(.{
        .field_id = view_model.dd_field_id,
        .list_id = "catalog.dd.list",
        .field = field,
        .row_bg = c.surface,
        .selected_bg = glinlandui.theme.selected,
        .row_fg = c.text,
        .hover_bg = c.hover,
        .field_bg = c.background,
        .border_width = 1,
        .border_color = c.divider,
        .on_select = .{ .f = onOption, .ctx = scope.vm },
    }, shown[0..n], scope, optionRow);
}

fn optionRow(scope: *Scope, item: []const u8, index: usize) void {
    const t = scope.theme;
    const c = t.colors;
    text_mod.label(.{ .label = .{ .text = item, .size = t.type_scale.label, .color = c.text } });
    badge_mod.badge(.{
        .id = props.Id.at("catalog.dd.kind", index),
        .label = .{ .text = "table", .size = t.type_scale.caption, .color = c.text_done },
        .bg = c.surface,
    });
}

// ---- intents -------------------------------------------------------------------------------------------------
// A click runs after the frame that declared it, so every context here is the ViewModel's, never a frame's value.

fn onPrimary(raw: ?*anyopaque) void {
    const vm: *CatalogViewModel = @ptrCast(@alignCast(raw.?));
    vm.pressPrimary();
}

fn onSecondary(raw: ?*anyopaque) void {
    const vm: *CatalogViewModel = @ptrCast(@alignCast(raw.?));
    vm.pressSecondary();
}

fn onQuiet(raw: ?*anyopaque) void {
    const vm: *CatalogViewModel = @ptrCast(@alignCast(raw.?));
    vm.pressQuiet();
}

fn onDanger(raw: ?*anyopaque) void {
    const vm: *CatalogViewModel = @ptrCast(@alignCast(raw.?));
    vm.pressDanger();
}

fn onSmall(raw: ?*anyopaque) void {
    const vm: *CatalogViewModel = @ptrCast(@alignCast(raw.?));
    vm.pressSmall();
}

fn onMedium(raw: ?*anyopaque) void {
    const vm: *CatalogViewModel = @ptrCast(@alignCast(raw.?));
    vm.pressMedium();
}

fn onLarge(raw: ?*anyopaque) void {
    const vm: *CatalogViewModel = @ptrCast(@alignCast(raw.?));
    vm.pressLarge();
}

fn onCheck(raw: ?*anyopaque) void {
    const vm: *CatalogViewModel = @ptrCast(@alignCast(raw.?));
    vm.toggleChecked();
}

fn onRadio(raw: ?*anyopaque) void {
    const radio: *CatalogViewModel.RadioCtx = @ptrCast(@alignCast(raw.?));
    radio.vm.pickRadio(radio.index);
}

fn onToggle(raw: ?*anyopaque) void {
    const vm: *CatalogViewModel = @ptrCast(@alignCast(raw.?));
    vm.toggleSwitch();
}

fn onSlider(raw: ?*anyopaque) void {
    const vm: *CatalogViewModel = @ptrCast(@alignCast(raw.?));
    vm.slide();
}

fn onTab(raw: ?*anyopaque, index: usize) void {
    const vm: *CatalogViewModel = @ptrCast(@alignCast(raw.?));
    vm.selectTab(index);
}

fn onRow(raw: ?*anyopaque, index: usize) void {
    const vm: *CatalogViewModel = @ptrCast(@alignCast(raw.?));
    vm.selectListRow(index);
}

fn onTree(raw: ?*anyopaque, index: usize) void {
    const vm: *CatalogViewModel = @ptrCast(@alignCast(raw.?));
    vm.selectTreeRow(index);
}

fn onOption(raw: ?*anyopaque, index: usize) void {
    const vm: *CatalogViewModel = @ptrCast(@alignCast(raw.?));
    vm.selectOption(index);
}
