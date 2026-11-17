// The View: declaration only — the page, its sections, the rows and the widget demos read the state and raise intents.
const glinlandui = @import("glinlandui");
const props = glinlandui.props;
const components = glinlandui.components;
const box_mod = components.box;
const text_mod = components.text;
const image_mod = components.image;
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
const split_mod = components.split;
const sidebar_mod = components.sidebar;
const modal_mod = components.modal;
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
        .gap = .{ .px = 16 },
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
        .direction = .row,
        .gap = .{ .px = 12 },
        .child_align = .{ .y = .top },
    }, scope, headerChildren);
}

fn headerChildren(scope: *Scope) void {
    const t = scope.theme;
    box_mod.box(.{
        .id = .{ .text = "catalog.header.text" },
        .w = .grow,
        .direction = .column,
        .gap = .{ .px = 6 },
    }, scope, headerText);
    // The one switch: the same palette and type, the kit's denser spacing. Nothing else in this file changes.
    button.button(.{
        .id = .{ .text = "catalog.dense" },
        .label = .{ .text = if (scope.vm.dense) "Spacing: compact" else "Spacing: roomy", .size = t.type_scale.caption, .color = t.colors.text },
        .bg = t.colors.surface_variant,
        .fg = t.colors.text,
        .hover_bg = t.colors.hover,
        .border = .{ .width = .{ .px = 1 }, .color = t.colors.divider },
        .on_click = .{ .f = onDense, .ctx = scope.vm },
    });
}

fn headerText(scope: *Scope) void {
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
        // The inspector's "declared" line: Zig has no caller location, so the app says where it built this card.
        .src = @src(),
        .w = .grow,
        .direction = .column,
        .bg = c.surface,
        .pad = props.Pad.all(16),
        .gap = .{ .px = 12 },
        .radius = props.Radius.all(r_card),
        .border = .{ .width = .{ .px = 1 }, .color = c.divider },
    }, SectionCtx{ .scope = scope, .section = s }, sectionChildren);
}

fn sectionChildren(ctx: SectionCtx) void {
    box_mod.box(.{
        .id = .{ .text = frame.formatText("{s}.head", .{ctx.section.id}) },
        .src = @src(),
        .w = .grow,
        .direction = .column,
        .gap = .{ .px = 2 },
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
        .spacing => spacingBody(ctx.scope),
        .badges => badgeBody(ctx.scope),
        .tabs => tabsBody(ctx.scope),
        .list => listBody(ctx.scope),
        .tree => treeBody(ctx.scope),
        .dropdown => dropdownBody(ctx.scope),
        .scroll => scrollBody(ctx.scope),
        .split => splitBody(ctx.scope),
        .sidebar_panel => sidebarBody(ctx.scope),
        .modal => modalBody(ctx.scope),
        .images => imagesBody(ctx.scope),
    }
}

// ---- images --------------------------------------------------------------------------------------------------

fn imagesBody(scope: *Scope) void {
    row(scope, "catalog.images.fits", imageFits);
}

fn imageFits(scope: *Scope) void {
    imageCard(scope, .{ .id = "catalog.img.cover", .path = "examples/catalog/assets/gradient.png", .caption = "cover — fills the box, crops the overhang", .fit = .cover });
    imageCard(scope, .{ .id = "catalog.img.contain", .path = "examples/catalog/assets/disc.png", .caption = "contain — whole image, letterboxed", .fit = .contain });
    imageCard(scope, .{ .id = "catalog.img.stretch", .path = "examples/catalog/assets/checker.png", .caption = "stretch — aspect ignored, alpha kept", .fit = .stretch });
}

const ImageCardCtx = struct {
    // Filled in by imageCard, so a call site states only what the card shows.
    scope: *Scope = undefined,
    id: []const u8,
    path: []const u8,
    caption: []const u8,
    fit: image_mod.Fit,
};

fn imageCard(scope: *Scope, card: ImageCardCtx) void {
    var ctx = card;
    ctx.scope = scope;
    box_mod.box(.{
        .id = .{ .text = ctx.id },
        .direction = .column,
        .gap = .{ .px = 6 },
        .pad = props.Pad.all(8),
        .bg = scope.theme.colors.surface_variant,
        .radius = props.Radius.all(r_card),
    }, ctx, imageCardChildren);
}

fn imageCardChildren(ctx: ImageCardCtx) void {
    image_mod.image(.{
        .id = .{ .text = frame.formatText("{s}.img", .{ctx.id}) },
        .path = ctx.path,
        .w = props.Size.px(220),
        .h = props.Size.px(130),
        .fit = ctx.fit,
        .radius = .{ .px = 6 },
    });
    text_mod.label(.{ .label = .{
        .text = ctx.caption,
        .size = ctx.scope.theme.type_scale.caption,
        .color = ctx.scope.theme.colors.text_dim,
    } });
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
        .gap = .{ .px = 8 },
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
        .border = .{ .width = .{ .px = 1 }, .color = c.divider },
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
        .border = .{ .width = .{ .px = 1 }, .color = state_mod.danger_edge },
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
        .gap = .{ .px = 8 },
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
        .gap = .{ .px = 4 },
    }, scope.theme, rolesRowChildren);
}

fn rolesRowChildren(t: Theme) void {
    for (state_mod.swatches) |s| {
        box_mod.box(.{
            .id = .{ .text = s.name },
            // As wide as its own name, and never wider than the column it shares: eleven roles fit one row.
            .w = .{ .clamp = .{ .min = 64, .max = 92 } },
            .direction = .column,
            .gap = .{ .px = 4 },
            // A role name is longer than a swatch: the cell cuts it and wraps it, instead of painting over the next one.
            .clip = .{ .horizontal = true },
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
        .border = .{ .width = .{ .px = 1 }, .color = ctx.theme.colors.divider },
    }, {}, noChildren);
    text_mod.label(.{ .label = .{ .text = ctx.swatch.name, .size = ctx.theme.type_scale.caption, .color = ctx.theme.colors.text_dim }, .wrap = true });
}

fn noChildren(_: void) void {}

// ---- type ----------------------------------------------------------------------------------------------------

fn typeBody(scope: *Scope) void {
    box_mod.box(.{
        .id = .{ .text = "catalog.type.col" },
        .w = .grow,
        .direction = .column,
        .gap = .{ .px = 8 },
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
        .border_width = .{ .px = 1 },
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
        .border_width = .{ .px = 1 },
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

// ---- theme metrics ----------------------------------------------------------------------------------------------

// Every row is a metric, drawn with the theme's own numbers: a widget that leaves a prop unset gets exactly this.
fn spacingBody(scope: *Scope) void {
    const t = scope.theme;
    const m = t.metrics;
    spacingLine(scope, "control pad", m.control_pad.top.pts(), m.control_pad.left.pts(), "button");
    spacingLine(scope, "field pad", m.field_pad.top.pts(), m.field_pad.left.pts(), "text field");
    spacingLine(scope, "chip pad", m.chip_pad.top.pts(), m.chip_pad.left.pts(), "badge");
    spacingLine(scope, "card pad", m.card_pad.top.pts(), m.card_pad.left.pts(), "modal card");
    spacingLine(scope, "control gap", m.control_gap.pts(), m.control_gap.pts(), "dropdown rows");
    spacingLine(scope, "row gap", m.row_gap.pts(), m.row_gap.pts(), "modal actions");
    spacingLine(scope, "corner sm/md/lg/pill", m.radius_sm.pts(), m.radius_pill.pts(), "chip / control / card / toggle");
}

// One metric, as its own row: the values ride in the row's context, so nothing is shared between rows.
fn spacingLine(scope: *Scope, name: []const u8, a: f32, b: f32, owner: []const u8) void {
    box_mod.box(.{
        .id = .{ .text = frame.formatText("catalog.spacing.{s}", .{name}) },
        .w = .grow,
        .direction = .row,
        .gap = .{ .px = 8 },
        .child_align = .{ .y = .center },
    }, SpacingCtx{ .theme = scope.theme, .name = name, .a = a, .b = b, .owner = owner }, spacingLineChildren);
}

const SpacingCtx = struct {
    theme: Theme,
    name: []const u8,
    a: f32,
    b: f32,
    owner: []const u8,
};

fn spacingLineChildren(ctx: SpacingCtx) void {
    const t = ctx.theme;
    text_mod.label(.{ .label = .{ .text = ctx.name, .size = t.type_scale.caption, .color = t.colors.text } });
    const value = if (ctx.a == ctx.b)
        frame.formatText("{d:.0} pt · {s}", .{ ctx.b, ctx.owner })
    else
        frame.formatText("{d:.0} / {d:.0} pt · {s}", .{ ctx.a, ctx.b, ctx.owner });
    text_mod.label(.{ .label = .{ .text = value, .size = t.type_scale.caption, .color = t.colors.text_dim } });
}

// ---- scroll -----------------------------------------------------------------------------------------------------

fn scrollBody(scope: *Scope) void {
    const c = scope.theme.colors;
    scroll_mod.scroll(.{
        .id = .{ .text = "catalog.demo.scroll" },
        .direction = .vertical,
        .w = .grow,
        .h = .{ .fixed = 130 },
        .bg = c.background,
        .border_width = .{ .px = 1 },
        .border_color = c.divider,
        .thumb_bg = c.surface_variant,
        .thumb_hover_bg = c.text_done,
    }, scope, scrollRows);
}

fn scrollRows(scope: *Scope) void {
    const t = scope.theme;
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        const line = frame.formatText("row {d} — the wheel moves the whole list, and the thumb shows where it is", .{i + 1});
        text_mod.label(.{ .label = .{ .text = line, .size = t.type_scale.caption, .color = if (i == 0) t.colors.text else t.colors.text_dim } });
    }
}

// ---- split ------------------------------------------------------------------------------------------------------

// Two panes and the line between them: the model owns the size, the widget owns the drag.
fn splitBody(scope: *Scope) void {
    const t = scope.theme;
    box_mod.box(.{
        .id = .{ .text = "catalog.split.frame" },
        .w = .grow,
        .h = .{ .fixed = 220 },
        .direction = .column,
        .bg = t.colors.background,
    }, scope, splitPaneTop);
}

fn splitPaneTop(scope: *Scope) void {
    const t = scope.theme;
    box_mod.box(.{
        .id = .{ .text = "catalog.split.top" },
        .w = .grow,
        .h = .grow,
        .pad = props.Pad.all(10),
        .bg = t.colors.surface,
    }, scope, splitTopChildren);
    split_mod.grip(scope.vm.splitProps(t));
    box_mod.box(.{
        .id = .{ .text = "catalog.split.bottom" },
        .w = .grow,
        .h = .{ .fixed = split_mod.size(scope.vm.splitProps(t)) },
        .pad = props.Pad.all(10),
        .bg = t.colors.surface_variant,
    }, scope, splitBottomChildren);
}

fn splitTopChildren(scope: *Scope) void {
    const t = scope.theme;
    text_mod.label(.{ .label = .{ .text = "the pane that grows", .size = t.type_scale.caption, .color = t.colors.text_dim } });
}

fn splitBottomChildren(scope: *Scope) void {
    const t = scope.theme;
    const shown = frame.formatText("the pane the line sizes: {d:.0} pt", .{split_mod.size(scope.vm.splitProps(t))});
    text_mod.label(.{ .label = .{ .text = shown, .size = t.type_scale.caption, .color = t.colors.text } });
}

// ---- sidebar ----------------------------------------------------------------------------------------------------

fn sidebarBody(scope: *Scope) void {
    const t = scope.theme;
    box_mod.box(.{
        .id = .{ .text = "catalog.sidebar.frame" },
        .w = .grow,
        .h = .{ .fixed = 190 },
        .direction = .row,
        .bg = t.colors.background,
    }, scope, sidebarFrameChildren);
}

fn sidebarFrameChildren(scope: *Scope) void {
    const t = scope.theme;
    sidebar_mod.sidebar(scope.vm.sidebarProps(t), scope, sidebarDemoChildren);
    box_mod.box(.{
        .id = .{ .text = "catalog.sidebar.fill" },
        .w = .grow,
        .h = .grow,
        .pad = props.Pad.all(10),
        .bg = t.colors.background,
    }, scope, sidebarFillChildren);
}

fn sidebarDemoChildren(scope: *Scope) void {
    const t = scope.theme;
    var i: usize = 0;
    while (i < 6) : (i += 1) {
        const line = frame.formatText("panel row {d}", .{i + 1});
        box_mod.box(.{
            .id = .{ .text = frame.elementId("catalog.sidebar.row", i) },
            .w = .grow,
            .pad = props.Pad.axes(4, 8),
            .bg = if (i == 1) t.colors.hover else t.colors.surface,
            .radius = t.metrics.corner(.sm),
        }, SidebarRowCtx{ .theme = t, .text = line }, sidebarRowChildren);
    }
}

const SidebarRowCtx = struct { theme: Theme, text: []const u8 };

fn sidebarRowChildren(ctx: SidebarRowCtx) void {
    text_mod.label(.{ .label = .{ .text = ctx.text, .size = ctx.theme.type_scale.caption, .color = ctx.theme.colors.text } });
}

fn sidebarFillChildren(scope: *Scope) void {
    const t = scope.theme;
    text_mod.label(.{ .label = .{
        .text = "drag the line to resize the panel; drag past its floor and it shuts, and a click on the edge brings it back",
        .size = t.type_scale.caption,
        .color = t.colors.text_dim,
    }, .wrap = true });
}

// ---- modal ------------------------------------------------------------------------------------------------------

fn modalBody(scope: *Scope) void {
    const t = scope.theme;
    row(scope, "catalog.modal.trigger", modalTrigger);
    if (scope.state.modal) {
        const answers = [_]modal_mod.Action{
            .{ .label = "Cancel" },
            .{ .label = "Discard" },
            .{ .label = "Save and close", .primary = true },
        };
        modal_mod.modal(.{
            .id = .{ .text = "catalog.modal.card" },
            .title = "Unsaved changes",
            .message = "This query has edits that were never saved. Save it before the window closes?",
            .actions = &answers,
            .on_action = .{ .f = onModalAnswer, .ctx = scope.vm },
            .bg = t.colors.surface,
            .border = t.colors.divider,
            .title_fg = t.colors.text,
            .fg = t.colors.text_dim,
            .action_bg = t.colors.surface_variant,
            .action_hover = t.colors.hover,
            .action_fg = t.colors.text,
            .primary = t.colors.primary,
            .primary_hover = t.colors.primary_hover,
            .primary_fg = t.colors.on_primary,
        });
    }
}

fn modalTrigger(scope: *Scope) void {
    const c = scope.theme.colors;
    button.button(.{
        .id = .{ .text = "catalog.modal.open" },
        .label = .{ .text = "Ask a question", .color = c.on_primary },
        .bg = c.primary,
        .fg = c.on_primary,
        .hover_bg = c.primary_hover,
        .on_click = .{ .f = onOpenModal, .ctx = scope.vm },
    });
}

fn onOpenModal(raw: ?*anyopaque) void {
    const vm: *CatalogViewModel = @ptrCast(@alignCast(raw.?));
    vm.openModal();
}

fn onModalAnswer(raw: ?*anyopaque, index: usize) void {
    const vm: *CatalogViewModel = @ptrCast(@alignCast(raw.?));
    vm.answerModal(index);
}

fn onDense(raw: ?*anyopaque) void {
    const vm: *CatalogViewModel = @ptrCast(@alignCast(raw.?));
    vm.toggleDense();
}
