// The screen's state and the catalog's data, as VALUES: nothing here imports a widget or holds a callback.
const std = @import("std");
const glinlandui = @import("glinlandui");

// Capacities. A value type is bounded by its fields, and the draft is sized to the field's buffer so it round-trips.
pub const max_text: usize = 256;
pub const max_filter: usize = 64;
pub const max_note: usize = 64;
// The row that draws a pick state: three radios, so three click contexts.
pub const radio_count: usize = 3;

pub const Text = [max_text:0]u8;
pub const Filter = [max_filter:0]u8;
pub const Note = [max_note:0]u8;

// Copy `s` in, truncating at capacity: a value type cannot fail to allocate, so it truncates instead of growing.
fn setText(comptime N: usize, dst: *[N:0]u8, s: []const u8) void {
    const n = @min(s.len, N);
    @memcpy(dst[0..n], s[0..n]);
    dst[n] = 0;
}

// `data class CatalogUiState(..)`: which control is on, which row is picked, and the two drafts the widgets report.
pub const CatalogUiState = struct {
    checked: bool = true,
    radio: usize = 1,
    toggled: bool = true,
    slider: f32 = 62,
    tab: usize = 0,
    row: ?usize = 1,
    tree_row: usize = 2,
    // The question card is up, so the modal demo owns the window while it is.
    modal: bool = false,
    draft: Text = .{0} ** max_text,
    filter: Filter = .{0} ** max_filter,
    last: Note = .{0} ** max_note,

    // `val text by state.draft.collectAsState()`: the field's value prop, and what the field reports back.
    pub fn draftText(self: *const CatalogUiState) []const u8 {
        return std.mem.sliceTo(&self.draft, 0);
    }

    // The dropdown's search text: the rows it shows are whatever matches it.
    pub fn filterText(self: *const CatalogUiState) []const u8 {
        return std.mem.sliceTo(&self.filter, 0);
    }

    // What the last widget said, so a click is visible and not only felt.
    pub fn lastText(self: *const CatalogUiState) []const u8 {
        return std.mem.sliceTo(&self.last, 0);
    }

    pub fn withDraft(self: CatalogUiState, text: []const u8) CatalogUiState {
        var next = self;
        setText(max_text, &next.draft, text);
        return next;
    }

    pub fn withFilter(self: CatalogUiState, text: []const u8) CatalogUiState {
        var next = self;
        setText(max_filter, &next.filter, text);
        return next;
    }

    pub fn withLast(self: CatalogUiState, text: []const u8) CatalogUiState {
        var next = self;
        setText(max_note, &next.last, text);
        return next;
    }

    pub fn withModal(self: CatalogUiState, on: bool) CatalogUiState {
        var next = self;
        next.modal = on;
        return next;
    }

    pub fn withChecked(self: CatalogUiState, on: bool) CatalogUiState {
        var next = self;
        next.checked = on;
        return next;
    }

    pub fn withRadio(self: CatalogUiState, index: usize) CatalogUiState {
        var next = self;
        next.radio = index;
        return next;
    }

    pub fn withToggled(self: CatalogUiState, on: bool) CatalogUiState {
        var next = self;
        next.toggled = on;
        return next;
    }

    pub fn withSlider(self: CatalogUiState, value: f32) CatalogUiState {
        var next = self;
        next.slider = value;
        return next;
    }

    pub fn withTab(self: CatalogUiState, index: usize) CatalogUiState {
        var next = self;
        next.tab = index;
        return next;
    }

    pub fn withRow(self: CatalogUiState, index: usize) CatalogUiState {
        var next = self;
        next.row = index;
        return next;
    }

    pub fn withTreeRow(self: CatalogUiState, index: usize) CatalogUiState {
        var next = self;
        next.tree_row = index;
        return next;
    }
};

// ---- the catalog's content, as values -------------------------------------------------------------------------

// Which demo a section draws. A tag, not a function pointer: the data stays a value and the view owns the drawing.
pub const Body = enum { buttons, text_field, selection, roles, type_scale, spacing, badges, tabs, list, tree, dropdown, scroll, split, sidebar_panel, modal, images };

// The nav's sections, in the order the docs page draws them: a group is a heading in the contents.
pub const Group = enum {
    foundations,
    inputs,
    data,
    layout,
    overlays,

    // The nav's heading for this group, as the page spells it.
    pub fn title(self: Group) []const u8 {
        return switch (self) {
            .foundations => "Foundations",
            .inputs => "Inputs",
            .data => "Data display",
            .layout => "Layout",
            .overlays => "Overlays",
        };
    }

    // The same heading as the sidebar draws it: the small caps a docs nav uses for its categories.
    pub fn label(self: Group) []const u8 {
        return switch (self) {
            .foundations => "FOUNDATIONS",
            .inputs => "INPUTS",
            .data => "DATA DISPLAY",
            .layout => "LAYOUT",
            .overlays => "OVERLAYS",
        };
    }
};

// One section of the page: its element id, its address, its heading, the lead line, the demo, and the call that produces it.
pub const Section = struct {
    id: []const u8,
    // The route segment this section answers to: `#text-field` addresses the text-field section.
    slug: []const u8,
    title: []const u8,
    group: Group,
    note: []const u8,
    snippet: []const u8,
    body: Body,
};

// The page, in the order it draws: the executable form of the UI kit document.
pub const sections = [_]Section{
    .{
        .id = "catalog.roles.section",
        .title = "Colour roles",
        .slug = "colour-roles",
        .group = .foundations,
        .note = "theme.dragon.colors — eleven roles, no hex",
        .snippet =
        \\const c = glinlandui.theme.dragon.colors;
        \\
        \\text_mod.label(.{ .label = .{
        \\    .text = "Schema · main.db",
        \\    .size = t.type_scale.title,
        \\    .color = c.text,
        \\} });
        ,
        .body = .roles,
    },
    .{
        .id = "catalog.type.section",
        .title = "Type scale",
        .slug = "type-scale",
        .group = .foundations,
        .note = "title 18 / body 14 / label 13 / caption 12",
        .snippet =
        \\text_mod.label(.{ .label = .{
        \\    .text = "Table name, column type, row count",
        \\    .size = t.type_scale.label,
        \\    .color = c.text_dim,
        \\} });
        ,
        .body = .type_scale,
    },
    .{
        .id = "catalog.spacing.section",
        .title = "Theme metrics",
        .slug = "theme-metrics",
        .group = .foundations,
        .note = "padding, gaps and corners: a prop left unset takes the theme's",
        .snippet =
        \\// an unset padding is the theme's, so one switch retunes every control
        \\button.button(.{
        \\    .id = .{ .text = "save" },
        \\    .label = .{ .text = "Save" },
        \\    .on_click = .{ .f = onSave, .ctx = vm },
        \\});
        ,
        .body = .spacing,
    },
    .{
        .id = "catalog.buttons.section",
        .title = "Buttons",
        .slug = "buttons",
        .group = .inputs,
        .note = "one primary per view, everything else quiet",
        .snippet =
        \\button.button(.{
        \\    .id = .{ .text = "run" },
        \\    .label = .{ .text = "Run query", .color = c.on_primary },
        \\    .bg = c.primary,
        \\    .hover_bg = c.primary_hover,
        \\    .on_click = .{ .f = onRun, .ctx = vm },
        \\});
        ,
        .body = .buttons,
    },
    .{
        .id = "catalog.field.section",
        .title = "Text field",
        .slug = "text-field",
        .group = .inputs,
        .note = "value in, on_change out; Cmd/Ctrl+Z takes an edit back, and a right click offers Undo and Redo",
        .snippet =
        \\field.value = state.draftText();
        \\input_mod.textField(&vm.field);
        ,
        .body = .text_field,
    },
    .{
        .id = "catalog.selection.section",
        .title = "Selection controls",
        .slug = "selection-controls",
        .group = .inputs,
        .note = "a checked box is primary, and never colour alone",
        .snippet =
        \\checkbox_mod.checkbox(.{
        \\    .id = .{ .text = "include" },
        \\    .checked = state.checked,
        \\    .on_click = .{ .f = onCheck, .ctx = vm },
        \\});
        ,
        .body = .selection,
    },
    .{
        .id = "catalog.dropdown.section",
        .title = "Dropdown",
        .slug = "dropdown",
        .group = .inputs,
        .note = "a field and its rows, owned by the caller",
        .snippet =
        \\dropdown_mod.dropdown(.{
        \\    .field_id = "catalog.dd.field",
        \\    .list_id = "catalog.dd.list",
        \\    .field = &vm.dd_field,
        \\    .on_select = .{ .f = onOption, .ctx = vm },
        \\}, shown[0..n], scope, optionRow);
        ,
        .body = .dropdown,
    },
    .{
        .id = "catalog.badges.section",
        .title = "Badges & icons",
        .slug = "badges",
        .group = .data,
        .note = "state is a word first, a tint second",
        .snippet =
        \\badge_mod.badge(.{
        \\    .id = .{ .text = "state" },
        \\    .label = .{ .text = "connected", .color = c.primary },
        \\    .bg = c.surface_variant,
        \\});
        ,
        .body = .badges,
    },
    .{
        .id = "catalog.tabs.section",
        .title = "Tabs",
        .slug = "tabs",
        .group = .data,
        .note = "34px, a 2px underline on the active one",
        .snippet =
        \\tabs_mod.tabs(.{
        \\    .id = .{ .text = "tabs" },
        \\    .tabs = demo_tabs[0..],
        \\    .on_select = .{ .f = onTab, .ctx = vm },
        \\});
        ,
        .body = .tabs,
    },
    .{
        .id = "catalog.list.section",
        .title = "List",
        .slug = "list",
        .group = .data,
        .note = "rows with ids, hover and a click each",
        .snippet =
        \\list_mod.list(.{
        \\    .id = .{ .text = "tables" },
        \\    .selected = state.row,
        \\    .on_select = .{ .f = onRow, .ctx = vm },
        \\}, table_row_slice, scope, listRow);
        ,
        .body = .list,
    },
    .{
        .id = "catalog.tree.section",
        .title = "Tree",
        .slug = "tree",
        .group = .data,
        .note = "26px rows, a 17px indent, selection is a fill and a bar",
        .snippet =
        \\tree_mod.tree(.{
        \\    .id = .{ .text = "tree" },
        \\    .rows = rows[0..],
        \\    .on_select = .{ .f = onTree, .ctx = vm },
        \\});
        ,
        .body = .tree,
    },
    .{
        .id = "catalog.images.section",
        .title = "Images",
        .slug = "images",
        .group = .data,
        .note = "cover, contain and stretch — decoded once, drawn on the GPU",
        .snippet =
        \\image_mod.image(.{
        \\    .id = .{ .text = "cover" },
        \\    .path = "assets/gradient.png",
        \\    .w = props.Size.px(220),
        \\    .h = props.Size.px(130),
        \\    .fit = .cover,
        \\});
        ,
        .body = .images,
    },
    .{
        .id = "catalog.scroll.section",
        .title = "Scroll",
        .slug = "scroll",
        .group = .layout,
        .note = "a clip, a thumb, and a wheel that reaches the deepest box that can move",
        .snippet =
        \\scroll_mod.scroll(.{
        \\    .id = .{ .text = "rows" },
        \\    .direction = .vertical,
        \\    .h = .{ .fixed = 130 },
        \\}, scope, scrollRows);
        ,
        .body = .scroll,
    },
    .{
        .id = "catalog.split.section",
        .title = "Split",
        .slug = "split",
        .group = .layout,
        .note = "two panes and a line the pointer drags; the app owns the size",
        .snippet =
        \\split_mod.grip(vm.splitProps(t));
        \\
        \\box_mod.box(.{
        \\    .id = .{ .text = "pane" },
        \\    .h = .{ .fixed = split_mod.size(vm.splitProps(t)) },
        \\}, scope, paneChildren);
        ,
        .body = .split,
    },
    .{
        .id = "catalog.sidebar.section",
        .title = "Sidebar",
        .slug = "sidebar",
        .group = .layout,
        .note = "a panel whose width the pointer owns, collapsible past its floor",
        .snippet =
        \\sidebar_mod.sidebar(vm.sidebarProps(t), scope, panelChildren);
        ,
        .body = .sidebar_panel,
    },
    .{
        .id = "catalog.modal.section",
        .title = "Modal",
        .slug = "modal",
        .group = .overlays,
        .note = "a scrim over the window and a card that centres itself",
        .snippet =
        \\modal_mod.modal(.{
        \\    .id = .{ .text = "confirm" },
        \\    .title = "Unsaved changes",
        \\    .message = "This query has edits that were never saved.",
        \\    .actions = &answers,
        \\    .on_action = .{ .f = onAnswer, .ctx = vm },
        \\});
        ,
        .body = .modal,
    },
};

// One colour role as a value the view can paint.
pub const Swatch = struct {
    name: []const u8,
    color: glinlandui.Color,
};

// The palette is the kit's, so this table is generated from the theme's own role list — a renamed role cannot drift.
pub const swatches = makeSwatches();

const role_count = std.meta.fields(glinlandui.theme.Colors).len;

fn makeSwatches() [role_count]Swatch {
    const roles = std.meta.fields(glinlandui.theme.Colors);
    const colors = glinlandui.theme.dragon.colors;
    var out: [role_count]Swatch = undefined;
    for (roles, 0..) |f, i| out[i] = .{ .name = f.name, .color = @field(colors, f.name) };
    return out;
}

// The two app-level tones the kit's roles do not cover: the destructive red and its edge.
pub const danger = glinlandui.Color.hexC("#c4746e");
pub const danger_edge = glinlandui.Color.hexC("#4a3330");

// A tab as data: `active` is the state's, so only the label and the close button are content.
pub const TabItem = struct {
    label: []const u8,
    closable: bool = true,
};

pub const tab_items = [_]TabItem{
    .{ .label = "Query 1", .closable = false },
    .{ .label = "Query 2" },
    .{ .label = "Query 3" },
};

// One table row of the list demo.
pub const table_rows = [_][]const u8{ "orders", "customers", "products", "invoices" };

// `list` takes the items as `anytype`, so the slice has to be named: `table_rows[0..]` would be a pointer to the array.
pub const table_row_slice: []const []const u8 = &table_rows;

// The rows of the tree demo, as values: `kind` decides the colour, `depth` the indent.
pub const TreeRowKind = enum { group, item, leaf };

pub const TreeRow = struct {
    label: []const u8,
    depth: u16 = 0,
    has_children: bool = false,
    expanded: bool = false,
    selected: bool = false,
    meta: []const u8 = "",
    kind: TreeRowKind = .item,
};

pub const tree_rows = [_]TreeRow{
    .{ .label = "main.db", .has_children = true, .expanded = true, .kind = .group, .meta = "12" },
    .{ .label = "orders", .depth = 1, .meta = "1 284" },
    .{ .label = "customers", .depth = 1, .selected = true, .meta = "412" },
    .{ .label = "id", .depth = 2, .meta = "pk" },
    .{ .label = "email", .depth = 2, .meta = "text" },
    .{ .label = "products", .depth = 1, .meta = "96" },
};

// The dropdown's options, unfiltered: the view keeps whatever matches the state's filter text.
pub const options = [_][]const u8{ "orders", "customers", "products" };

pub const max_options: usize = options.len;
