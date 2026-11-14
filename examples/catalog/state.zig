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
pub const Body = enum { buttons, text_field, selection, roles, type_scale, badges, tabs, list, tree, dropdown };

// One card on the page: its element id, its heading, and the note that says what to look at.
pub const Section = struct {
    id: []const u8,
    title: []const u8,
    note: []const u8,
    body: Body,
};

// The page, in the order it draws: the executable form of the UI kit document.
pub const sections = [_]Section{
    .{ .id = "catalog.buttons.section", .title = "Buttons", .note = "one primary per view, everything else quiet", .body = .buttons },
    .{ .id = "catalog.field.section", .title = "Text field", .note = "value in, on_change out; the engine types into it", .body = .text_field },
    .{ .id = "catalog.selection.section", .title = "Selection controls", .note = "a checked box is primary, and never colour alone", .body = .selection },
    .{ .id = "catalog.roles.section", .title = "Colour roles", .note = "theme.dragon.colors — eleven roles, no hex", .body = .roles },
    .{ .id = "catalog.type.section", .title = "Type scale", .note = "title 18 / body 14 / label 13 / caption 12", .body = .type_scale },
    .{ .id = "catalog.badges.section", .title = "Badges & icons", .note = "state is a word first, a tint second", .body = .badges },
    .{ .id = "catalog.tabs.section", .title = "Tabs", .note = "34px, a 2px underline on the active one", .body = .tabs },
    .{ .id = "catalog.list.section", .title = "List", .note = "rows with ids, hover and a click each", .body = .list },
    .{ .id = "catalog.tree.section", .title = "Tree", .note = "26px rows, a 17px indent, selection is a fill and a bar", .body = .tree },
    .{ .id = "catalog.dropdown.section", .title = "Dropdown", .note = "a field and its rows, owned by the caller", .body = .dropdown },
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
