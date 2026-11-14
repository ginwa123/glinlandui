// glinlandui example: the component catalog — every widget, one screen, the kit's palette.
// It is the executable form of the UI kit document: the same roles, the same metrics, and a live component for each entry.
const std = @import("std");
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

const theme = glinlandui.theme;
const c = theme.dragon.colors;
const scale = theme.dragon.type_scale;

// No metrics here on purpose: every widget below is drawn with its own defaults, which are the kit's.
const r_card: u16 = 8;

// The screen's state: what the widgets report into.
pub const App = struct {
    field: input_mod.Field = .{ .id = .{ .text = "catalog.field" } },
    dd_field: input_mod.Field = .{ .id = .{ .text = "catalog.dd.field" } },
    checked: bool = true,
    radio: usize = 1,
    toggled: bool = true,
    slider: f32 = 62,
    tab: usize = 0,
    row: ?usize = 1,
    tree_sel: usize = 2,
    dd_query: [64]u8 = undefined,
    dd_len: usize = 0,
    focus_claimed: bool = false,
    radio_ctx: [3]PickCtx = undefined,
    row_ctx: [4]PickCtx = undefined,
    last: [64]u8 = undefined,
    last_len: usize = 0,

    // `onCreate`: the field's look and its intents are set ONCE.
    pub fn start(self: *App) void {
        self.field.font_size = scale.body;
        self.field.fg = c.text;
        self.field.bg = c.background;
        self.field.sel_fg = c.text;
        self.field.sel_bg = theme.selected;
        self.field.caret_fg = c.primary;
        self.field.border = .{ .width = 1, .color = c.divider };
        self.field.on_change = .{ .f = onTyped, .ctx = self };

        self.dd_field.font_size = scale.label;
        self.dd_field.fg = c.text;
        self.dd_field.bg = c.background;
        self.dd_field.sel_bg = theme.selected;
        self.dd_field.caret_fg = c.primary;
        self.dd_field.border = .{ .width = 1, .color = c.divider };
        self.dd_field.on_change = .{ .f = onDdTyped, .ctx = self };

        for (&self.radio_ctx, 0..) |*rc, i| rc.* = .{ .app = self, .index = i };
        for (&self.row_ctx, 0..) |*rc, i| rc.* = .{ .app = self, .index = i };
    }

    // The root: one scroll container over a column of sections.
    pub fn content(ctx: ?*anyopaque, w: u32, h: u32) void {
        _ = w;
        _ = h;
        const self: *App = @ptrCast(@alignCast(ctx.?));
        // The toolkit resets focus when a host starts, so the field claims the keyboard on the first frame.
        if (!self.focus_claimed) {
            self.focus_claimed = true;
            glinlandui.frame.setFocus("catalog.field");
        }
        box_mod.box(.{
            .id = .{ .text = "catalog.root" },
            .w = .grow,
            .h = .grow,
            .direction = .column,
            .bg = c.background,
        }, self, rootChildren);
    }
};

fn rootChildren(self: *App) void {
    scroll_mod.scroll(.{
        .id = .{ .text = "catalog.scroll" },
        .direction = .vertical,
        .w = .grow,
        .h = .grow,
        .bg = c.background,
        .thumb_bg = c.divider,
        .thumb_hover_bg = c.text_done,
    }, self, page);
}

fn page(self: *App) void {
    box_mod.box(.{
        .id = .{ .text = "catalog.page" },
        .w = .grow,
        .direction = .column,
        .pad = props.Pad.all(24),
        .gap = 16,
    }, self, pageChildren);
}

fn pageChildren(self: *App) void {
    header(self);
    section(self, "catalog.buttons.section", "Buttons", "one primary per view, everything else quiet", buttonsBody);
    section(self, "catalog.field.section", "Text field", "value in, on_change out; the engine types into it", fieldBody);
    section(self, "catalog.selection.section", "Selection controls", "a checked box is primary, and never colour alone", selectionBody);
    section(self, "catalog.roles.section", "Colour roles", "theme.dragon.colors — eleven roles, no hex", rolesBody);
    section(self, "catalog.type.section", "Type scale", "title 18 / body 14 / label 13 / caption 12", typeBody);
    section(self, "catalog.badges.section", "Badges & icons", "state is a word first, a tint second", badgeBody);
    section(self, "catalog.tabs.section", "Tabs", "34px, a 2px underline on the active one", tabsBody);
    section(self, "catalog.list.section", "List", "rows with ids, hover and a click each", listBody);
    section(self, "catalog.tree.section", "Tree", "26px rows, a 17px indent, selection is a fill and a bar", treeBody);
    section(self, "catalog.dropdown.section", "Dropdown", "a field and its rows, owned by the caller", dropdownBody);
}

fn header(self: *App) void {
    box_mod.box(.{
        .id = .{ .text = "catalog.header" },
        .w = .grow,
        .direction = .column,
        .gap = 6,
    }, self, headerChildren);
}

fn headerChildren(self: *App) void {
    text_mod.label(.{ .label = .{ .text = "glinlandui · catalog", .size = scale.title, .color = c.text } });
    text_mod.label(.{
        .label = .{ .text = "every component the toolkit ships, drawn with the kit's eleven roles", .size = scale.caption, .color = c.text_dim },
    });
    // What the widgets last reported, so a click is visible and not only felt.
    const said = if (self.last_len == 0) "nothing yet" else self.last[0..self.last_len];
    const shown = glinlandui.frame.formatText("last intent: {s}", .{said});
    text_mod.label(.{ .label = .{ .text = shown, .size = scale.caption, .color = c.text_done } });
}

// One card: a title, a note, and whatever the section's body declares.
const SectionCtx = struct {
    app: *App,
    id: []const u8,
    title: []const u8,
    note: []const u8,
    body: *const fn (*App) void,
};

fn section(self: *App, id: []const u8, title: []const u8, note: []const u8, body: *const fn (*App) void) void {
    box_mod.box(.{
        .id = .{ .text = id },
        .w = .grow,
        .direction = .column,
        .bg = c.surface,
        .pad = props.Pad.all(16),
        .gap = 12,
        .radius = props.Radius.all(r_card),
        .border = .{ .width = 1, .color = c.divider },
    }, SectionCtx{ .app = self, .id = id, .title = title, .note = note, .body = body }, sectionChildren);
}

fn sectionChildren(ctx: SectionCtx) void {
    box_mod.box(.{
        .id = .{ .text = glinlandui.frame.formatText("{s}.head", .{ctx.id}) },
        .w = .grow,
        .direction = .column,
        .gap = 2,
    }, ctx, sectionHeadChildren);
    ctx.body(ctx.app);
}

fn sectionHeadChildren(ctx: SectionCtx) void {
    text_mod.label(.{ .label = .{ .text = ctx.title, .size = scale.body, .color = c.text } });
    text_mod.label(.{ .label = .{ .text = ctx.note, .size = scale.caption, .color = c.text_dim } });
}

// ---- buttons -------------------------------------------------------------------------------------------------

fn buttonsBody(self: *App) void {
    row(self, "catalog.buttons.emphasis", emphasisButtons);
    row(self, "catalog.buttons.sizes", sizeButtons);
    row(self, "catalog.buttons.states", stateButtons);
}

fn row(self: *App, id: []const u8, body: *const fn (*App) void) void {
    box_mod.box(.{
        .id = .{ .text = id },
        .w = .grow,
        .direction = .row,
        .gap = 8,
        .child_align = .{ .y = .center },
    }, RowCtx{ .app = self, .body = body }, rowChildren);
}

const RowCtx = struct { app: *App, body: *const fn (*App) void };

fn rowChildren(ctx: RowCtx) void {
    ctx.body(ctx.app);
}

fn emphasisButtons(self: *App) void {
    button.button(.{
        .id = .{ .text = "catalog.btn.primary" },
        .label = .{ .text = "Run query", .color = c.on_primary },
        .bg = c.primary,
        .fg = c.on_primary,
        .hover_bg = c.primary_hover,
        .on_click = .{ .f = onPrimary, .ctx = self },
    });
    button.button(.{
        .id = .{ .text = "catalog.btn.secondary" },
        .label = .{ .text = "Explain" },
        .bg = c.surface_variant,
        .fg = c.text,
        .hover_bg = c.hover,
        .border = .{ .width = 1, .color = c.divider },
        .on_click = .{ .f = onSecondary, .ctx = self },
    });
    button.button(.{
        .id = .{ .text = "catalog.btn.quiet" },
        .label = .{ .text = "Cancel" },
        .bg = c.surface,
        .fg = c.text_dim,
        .hover_bg = c.hover,
        .on_click = .{ .f = onQuiet, .ctx = self },
    });
    button.button(.{
        .id = .{ .text = "catalog.btn.danger" },
        .label = .{ .text = "Drop table" },
        .bg = c.surface,
        .fg = danger,
        .hover_bg = c.hover,
        .border = .{ .width = 1, .color = danger_edge },
        .on_click = .{ .f = onDanger, .ctx = self },
    });
    button.button(.{
        .id = .{ .text = "catalog.btn.disabled" },
        .label = .{ .text = "Disabled" },
        .disabled = true,
        .disabled_bg = c.surface_variant,
        .disabled_fg = c.text_done,
    });
}

// The one row that states sizes on purpose: a catalog has to show the three variants, and the component
// has no size enum yet — every other button in this screen takes the defaults.
fn sizeButtons(self: *App) void {
    button.button(.{
        .id = .{ .text = "catalog.btn.sm" },
        .label = .{ .text = "Small", .size = scale.caption, .color = c.on_primary },
        .bg = c.primary,
        .fg = c.on_primary,
        .hover_bg = c.primary_hover,
        .h = .{ .fixed = 24 },
        .pad = props.Pad.axes(0, 9),
        .on_click = .{ .f = onSmall, .ctx = self },
    });
    button.button(.{
        .id = .{ .text = "catalog.btn.md" },
        .label = .{ .text = "Medium", .size = scale.label, .color = c.on_primary },
        .bg = c.primary,
        .fg = c.on_primary,
        .hover_bg = c.primary_hover,
        .h = .{ .fixed = 28 },
        .pad = props.Pad.axes(0, 12),
        .on_click = .{ .f = onMedium, .ctx = self },
    });
    button.button(.{
        .id = .{ .text = "catalog.btn.lg" },
        .label = .{ .text = "Large", .size = scale.body, .color = c.on_primary },
        .bg = c.primary,
        .fg = c.on_primary,
        .hover_bg = c.primary_hover,
        .h = .{ .fixed = 32 },
        .pad = props.Pad.axes(0, 16),
        .on_click = .{ .f = onLarge, .ctx = self },
    });
}

fn stateButtons(self: *App) void {
    text_mod.label(.{ .label = .{ .text = "hover, pressed and disabled are 1px of fill — nothing moves.", .size = scale.caption, .color = c.text_done } });
    const shown = glinlandui.frame.formatText("slider {d:.0}", .{self.slider});
    badge_mod.badge(.{ .id = .{ .text = "catalog.btn.badge" }, .label = .{ .text = shown, .size = scale.caption, .color = c.text_dim }, .bg = c.surface_variant });
}

// ---- text field ----------------------------------------------------------------------------------------------

fn fieldBody(self: *App) void {
    box_mod.box(.{
        .id = .{ .text = "catalog.field.row" },
        .w = .grow,
        .direction = .row,
        .gap = 8,
        .child_align = .{ .y = .center },
    }, self, fieldRowChildren);
}

fn fieldRowChildren(self: *App) void {
    box_mod.box(.{
        .id = .{ .text = "catalog.field.wrap" },
        .w = .{ .clamp = .{ .min = 160, .max = 420, .grow = true } },
        .direction = .row,
    }, self, fieldChildren);
    text_mod.label(.{
        .label = .{ .text = "type, select, copy — the field owns the caret and reports every edit", .size = scale.caption, .color = c.text_done },
    });
}

fn fieldChildren(self: *App) void {
    input_mod.textField(&self.field);
}

// ---- selection controls --------------------------------------------------------------------------------------

fn selectionBody(self: *App) void {
    row(self, "catalog.sel.row", selectionRow);
}

fn selectionRow(self: *App) void {
    checkbox_mod.checkbox(.{
        .id = .{ .text = "catalog.check" },
        .checked = self.checked,
        .box_bg = c.background,
        .checked_bg = c.primary,
        .check_color = c.on_primary,
        .border_color = c.text_done,
        .hover_bg = c.hover,
        .on_click = .{ .f = onCheck, .ctx = self },
    });
    text_mod.label(.{ .label = .{ .text = "Include views", .size = scale.label, .color = c.text } });

    var i: usize = 0;
    while (i < 3) : (i += 1) {
        radio_mod.radio(.{
            .id = props.Id.at("catalog.radio", i),
            .selected = self.radio == i,
            .outer_bg = c.background,
            .selected_border = c.primary,
            .border_color = c.text_done,
            .dot_color = c.primary,
            .on_click = .{ .f = onRadio, .ctx = &self.radio_ctx[i] },
        });
    }
    text_mod.label(.{ .label = .{ .text = "read only", .size = scale.label, .color = c.text } });

    toggle_mod.toggle(.{
        .id = .{ .text = "catalog.toggle" },
        .on = self.toggled,
        .on_bg = c.primary,
        .off_bg = c.surface_variant,
        .knob_color = c.on_primary,
        .on_click = .{ .f = onToggle, .ctx = self },
    });
    text_mod.label(.{ .label = .{ .text = "auto-run", .size = scale.label, .color = c.text } });

    slider_mod.slider(.{
        .id = .{ .text = "catalog.slider" },
        .value = self.slider,
        .min = 0,
        .max = 100,
        .track_bg = c.surface_variant,
        .fill_bg = c.primary,
        .thumb_color = c.primary,
        .on_change = .{ .f = onSlider, .ctx = self },
    });
}

// ---- colour roles --------------------------------------------------------------------------------------------

fn rolesBody(self: *App) void {
    _ = self;
    box_mod.box(.{
        .id = .{ .text = "catalog.roles.row" },
        .w = .grow,
        .direction = .row,
        .gap = 8,
    }, {}, rolesRowChildren);
}

fn rolesRowChildren(_: void) void {
    inline for (std.meta.fields(theme.Colors)) |f| {
        box_mod.box(.{
            .id = .{ .text = f.name },
            .w = .{ .fixed = 68 },
            .direction = .column,
            .gap = 4,
        }, Swatch{ .name = f.name, .color = @field(c, f.name) }, swatchChildren);
    }
}

const Swatch = struct { name: []const u8, color: glinlandui.Color };

fn swatchChildren(s: Swatch) void {
    box_mod.box(.{
        .id = .{ .text = glinlandui.frame.formatText("{s}.chip", .{s.name}) },
        .w = .grow,
        .h = .{ .fixed = 40 },
        .direction = .row,
        .bg = s.color,
        .border = .{ .width = 1, .color = c.divider },
    }, {}, noChildren);
    text_mod.label(.{ .label = .{ .text = s.name, .size = scale.caption, .color = c.text_dim } });
}

fn noChildren(_: void) void {}

// ---- type ----------------------------------------------------------------------------------------------------

fn typeBody(self: *App) void {
    _ = self;
    box_mod.box(.{
        .id = .{ .text = "catalog.type.col" },
        .w = .grow,
        .direction = .column,
        .gap = 8,
    }, {}, typeColumnChildren);
}

fn typeColumnChildren(_: void) void {
    text_mod.label(.{ .label = .{ .text = "Schema · main.db", .size = scale.title, .color = c.text } });
    text_mod.label(.{ .label = .{ .text = "Select rows from orders where total > 100.", .size = scale.body, .color = c.text } });
    text_mod.label(.{ .label = .{ .text = "Table name, column type, row count", .size = scale.label, .color = c.text_dim } });
    text_mod.label(.{ .label = .{ .text = "42 ROWS · 6 COLUMNS · 12 ms", .size = scale.caption, .color = c.text_done } });
}

// ---- badges + icons ------------------------------------------------------------------------------------------

fn badgeBody(self: *App) void {
    row(self, "catalog.badges.row", badgesRow);
}

fn badgesRow(self: *App) void {
    _ = self;
    badge_mod.badge(.{ .id = .{ .text = "catalog.badge.ok" }, .label = .{ .text = "connected", .size = scale.caption, .color = c.primary }, .bg = c.surface_variant });
    badge_mod.badge(.{ .id = .{ .text = "catalog.badge.warn" }, .label = .{ .text = "read only", .size = scale.caption, .color = c.text_dim }, .bg = c.surface_variant });
    badge_mod.badge(.{ .id = .{ .text = "catalog.badge.pk" }, .label = .{ .text = "primary key", .size = scale.caption, .color = c.text_dim }, .bg = c.surface_variant });
    badge_mod.badge(.{ .id = .{ .text = "catalog.badge.null" }, .label = .{ .text = "nullable", .size = scale.caption, .color = c.text_done }, .bg = c.surface });
    inline for ([_][]const u8{ "▸", "▾", "+", "×", "⌘", "↵" }) |glyph| {
        icon_mod.icon(.{ .glyph = glyph, .font_size = scale.body, .color = c.text_dim });
    }
}

// ---- tabs ----------------------------------------------------------------------------------------------------

fn tabsBody(self: *App) void {
    // Built per frame from the state: a tab bar is a view of which tab is open, not a constant.
    var demo_tabs = [_]tabs_mod.Tab{
        .{ .label = "Query 1", .active = self.tab == 0, .closable = false },
        .{ .label = "Query 2", .active = self.tab == 1 },
        .{ .label = "Query 3", .active = self.tab == 2 },
    };
    tabs_mod.tabs(.{
        .id = .{ .text = "catalog.tabs" },
        .tabs = &demo_tabs,
        .bg = c.surface,
        .active_bg = c.background,
        .fg = c.text_dim,
        .active_fg = c.text,
        .close_fg = c.text_done,
        .on_select = .{ .f = onTab, .ctx = self },
    });
}

// ---- list ----------------------------------------------------------------------------------------------------

const demo_rows = [_][]const u8{ "orders", "customers", "products", "invoices" };
// `list` takes the items as `anytype`, so the slice has to be named: `demo_rows[0..]` would be a pointer to the array.
const demo_row_slice: []const []const u8 = &demo_rows;

fn listBody(self: *App) void {
    list_mod.list(.{
        .id = .{ .text = "catalog.list" },
        .row_bg = c.surface,
        .selected_bg = theme.selected,
        .row_fg = c.text,
        .selected_fg = c.text,
        .hover_bg = c.hover,
        .border_width = 1,
        .border_color = c.divider,
        .selected = self.row,
        .on_select = .{ .f = onRow, .ctx = self },
    }, demo_row_slice, self, listRow);
}

fn listRow(self: *App, item: []const u8, index: usize) void {
    _ = self;
    text_mod.label(.{ .label = .{ .text = item, .size = scale.label, .color = c.text } });
    badge_mod.badge(.{
        .id = props.Id.at("catalog.list.meta", index),
        .label = .{ .text = "table", .size = scale.caption, .color = c.text_done },
        .bg = c.surface,
    });
}

// ---- tree ----------------------------------------------------------------------------------------------------

const demo_tree = [_]tree_mod.Row{
    .{ .label = "main.db", .has_children = true, .expanded = true, .kind = .group, .meta = "12" },
    .{ .label = "orders", .depth = 1, .meta = "1 284" },
    .{ .label = "customers", .depth = 1, .selected = true, .meta = "412" },
    .{ .label = "id", .depth = 2, .meta = "pk" },
    .{ .label = "email", .depth = 2, .meta = "text" },
    .{ .label = "products", .depth = 1, .meta = "96" },
};

fn treeBody(self: *App) void {
    tree_mod.tree(.{
        .id = .{ .text = "catalog.tree" },
        .rows = &demo_tree,
        .row_bg = c.surface,
        .selected_bg = theme.selected,
        .hover_bg = c.hover,
        .fg = c.text,
        .selected_fg = c.text,
        .group_fg = c.text,
        .meta_fg = c.text_dim,
        .caret_fg = c.text_done,
        .selected_bar = c.primary,
        .on_select = .{ .f = onTree, .ctx = self },
    });
}

// ---- dropdown ------------------------------------------------------------------------------------------------

const demo_options = [_][]const u8{ "orders", "customers", "products" };

fn dropdownBody(self: *App) void {
    box_mod.box(.{
        .id = .{ .text = "catalog.dd.wrap" },
        .w = .{ .fixed = 260 },
        .direction = .column,
    }, self, dropdownWrapChildren);
}

fn dropdownWrapChildren(self: *App) void {
    // The field is the filter: the rows are whatever matches what has been typed into it.
    var shown: [demo_options.len][]const u8 = undefined;
    var n: usize = 0;
    for (demo_options) |option| {
        if (dropdown_mod.matches(self.dd_query[0..self.dd_len], option)) {
            shown[n] = option;
            n += 1;
        }
    }
    dropdown_mod.dropdown(.{
        .field_id = "catalog.dd.field",
        .list_id = "catalog.dd.list",
        .field = &self.dd_field,
        .row_bg = c.surface,
        .selected_bg = theme.selected,
        .row_fg = c.text,
        .hover_bg = c.hover,
        .field_bg = c.background,
        .border_width = 1,
        .border_color = c.divider,
        .on_select = .{ .f = onOption, .ctx = self },
    }, shown[0..n], self, optionRow);
}

fn optionRow(self: *App, item: []const u8, index: usize) void {
    _ = self;
    text_mod.label(.{ .label = .{ .text = item, .size = scale.label, .color = c.text } });
    badge_mod.badge(.{
        .id = props.Id.at("catalog.dd.kind", index),
        .label = .{ .text = "table", .size = scale.caption, .color = c.text_done },
        .bg = c.surface,
    });
}

// ---- intents -------------------------------------------------------------------------------------------------

const PickCtx = struct { app: *App, index: usize };

// The kit's two app-level tones: the destructive red and its edge.
const danger = glinlandui.Color.hexC("#c4746e");
const danger_edge = glinlandui.Color.hexC("#4a3330");

fn report(self: *App, text: []const u8) void {
    self.last_len = @min(text.len, self.last.len);
    @memcpy(self.last[0..self.last_len], text[0..self.last_len]);
}

fn onPrimary(ctx: ?*anyopaque) void {
    const self: *App = @ptrCast(@alignCast(ctx.?));
    report(self, "primary button");
}

fn onSecondary(ctx: ?*anyopaque) void {
    const self: *App = @ptrCast(@alignCast(ctx.?));
    report(self, "secondary button");
}

fn onQuiet(ctx: ?*anyopaque) void {
    const self: *App = @ptrCast(@alignCast(ctx.?));
    report(self, "quiet button");
}

fn onDanger(ctx: ?*anyopaque) void {
    const self: *App = @ptrCast(@alignCast(ctx.?));
    report(self, "danger button");
}

fn onSmall(ctx: ?*anyopaque) void {
    const self: *App = @ptrCast(@alignCast(ctx.?));
    report(self, "small button");
}

fn onMedium(ctx: ?*anyopaque) void {
    const self: *App = @ptrCast(@alignCast(ctx.?));
    report(self, "medium button");
}

fn onLarge(ctx: ?*anyopaque) void {
    const self: *App = @ptrCast(@alignCast(ctx.?));
    report(self, "large button");
}

fn onTyped(ctx: ?*anyopaque, text: []const u8) void {
    const self: *App = @ptrCast(@alignCast(ctx.?));
    report(self, text);
}

fn onDdTyped(ctx: ?*anyopaque, text: []const u8) void {
    const self: *App = @ptrCast(@alignCast(ctx.?));
    self.dd_len = @min(text.len, self.dd_query.len);
    @memcpy(self.dd_query[0..self.dd_len], text[0..self.dd_len]);
}

fn onCheck(ctx: ?*anyopaque) void {
    const self: *App = @ptrCast(@alignCast(ctx.?));
    self.checked = !self.checked;
    report(self, if (self.checked) "checked" else "unchecked");
}

fn onRadio(ctx: ?*anyopaque) void {
    const pick: *PickCtx = @ptrCast(@alignCast(ctx.?));
    pick.app.radio = pick.index;
    report(pick.app, "radio picked");
}

fn onToggle(ctx: ?*anyopaque) void {
    const self: *App = @ptrCast(@alignCast(ctx.?));
    self.toggled = !self.toggled;
    report(self, if (self.toggled) "toggle on" else "toggle off");
}

// The slider reports a click, not a value: the app reads the pointer against the track it declared.
fn onSlider(ctx: ?*anyopaque) void {
    const self: *App = @ptrCast(@alignCast(ctx.?));
    const track = glinlandui.frame.bounds(glinlandui.frame.clayId("catalog.slider")) orelse return;
    if (track.width <= 0) return;
    const frac = std.math.clamp((glinlandui.frame.ptr_x - track.x) / track.width, 0, 1);
    self.slider = frac * 100;
    report(self, "slider moved");
}

fn onTab(ctx: ?*anyopaque, index: usize) void {
    const self: *App = @ptrCast(@alignCast(ctx.?));
    self.tab = index;
    report(self, "tab selected");
}

fn onRow(ctx: ?*anyopaque, index: usize) void {
    const self: *App = @ptrCast(@alignCast(ctx.?));
    self.row = index;
    report(self, "row selected");
}

fn onTree(ctx: ?*anyopaque, index: usize) void {
    const self: *App = @ptrCast(@alignCast(ctx.?));
    self.tree_sel = index;
    report(self, "tree row selected");
}

fn onOption(ctx: ?*anyopaque, index: usize) void {
    const self: *App = @ptrCast(@alignCast(ctx.?));
    _ = index;
    report(self, "option selected");
}

// ---- main ----------------------------------------------------------------------------------------------------

pub fn main(init: std.process.Init) !void {
    _ = init;
    const gpa = std.heap.page_allocator;

    var app = App{};
    app.start();

    var window = glinlandui.Window.init(gpa, .{
        .app_id = "glinlandui-catalog",
        .title = "glinlandui · catalog",
        .width = 960,
        .height = 760,
        .min_width = 520,
        .min_height = 400,
    });

    var host = try glinlandui.host.Host.init(gpa, &app, App.content);
    defer host.deinit();
    window.delegate = host.delegate();
    try window.run();
}

// ---- tests ---------------------------------------------------------------------------------------------------

const testing = std.testing;
const Driver = glinlandui.testing.Driver;

fn boot(app: *App) !Driver {
    app.start();
    var driver = try Driver.initOwned(std.heap.page_allocator, app, App.content);
    errdefer driver.deinit();
    try driver.start(.{ .width = 960, .height = 760 });
    // The first frame has no layout yet, so a scroll container's clip is 0x0 until it has painted once.
    driver.frame();
    return driver;
}

test "every section is declared and drawn" {
    var app = App{};
    var driver = try boot(&app);
    defer driver.deinit();

    for ([_][]const u8{
        "catalog.buttons.section", "catalog.field.section",    "catalog.selection.section", "catalog.roles.section",
        "catalog.type.section",    "catalog.badges.section",   "catalog.tabs.section",      "catalog.list.section",
        "catalog.tree.section",    "catalog.dropdown.section",
    }) |id| {
        try testing.expect(driver.exists(id));
    }
    try testing.expect(driver.hasText("glinlandui · catalog"));
    try testing.expect(driver.hasText("Colour roles"));
    try testing.expect(driver.hasText("one primary per view, everything else quiet"));
}

test "a click reaches the widget and the frame shows the result" {
    var app = App{};
    var driver = try boot(&app);
    defer driver.deinit();

    try testing.expect(app.checked);
    try driver.click("catalog.check");
    try testing.expect(!app.checked);
    try testing.expect(driver.hasText("last intent: unchecked"));
}

test "typing reaches the field with no key handler registered" {
    var app = App{};
    var driver = try boot(&app);
    defer driver.deinit();

    try driver.typeText("abc");
    try testing.expectEqualStrings("abc", app.field.text());
    try testing.expect(driver.hasText("last intent: abc"));
}

test "the palette is the kit's, role by role" {
    var app = App{};
    var driver = try boot(&app);
    defer driver.deinit();

    // The swatch row names every role, so a missing one is a missing component.
    inline for (std.meta.fields(theme.Colors)) |f| {
        try testing.expect(driver.exists(f.name));
    }
}
