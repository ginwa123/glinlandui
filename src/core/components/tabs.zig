//! A tab bar: fixed-width tabs in a strip that scrolls, an accent dot, a close box, a right-click card and drag-to-reorder.
const std = @import("std");
const cl = @import("zclay");
const headless = @import("../testing/headless.zig");
const prop = @import("../props.zig");
const Color = @import("../color.zig").Color;
const registry = @import("click_registry.zig");
const context_menu = @import("context_menu.zig");
const reorder_mod = @import("reorder.zig");
const semantics = @import("../semantics.zig");
const text_fit = @import("../text_fit.zig");
const frame_mod = @import("../frame.zig");

/// One tab.
pub const Tab = struct {
    label: []const u8,
    active: bool = false,
    closable: bool = true,
    /// A small dot before the label, for a per-tab colour. Null draws none.
    accent: ?Color = null,
    /// Whether this tab's work is unsaved: the one fact its card's Save row is enabled by.
    dirty: bool = false,
};

/// What a tab's right-click card can ask for, in the order the card lists them.
pub const Action = enum { save, close_others, close_right, close_left, close };

/// Every action, in card order.
pub const all_actions = [_]Action{ .save, .close_others, .close_right, .close_left, .close };

/// The words a card draws when an app does not name its own.
pub const default_labels = [_][]const u8{ "Save", "Close others", "Close tabs to the right", "Close tabs to the left", "Close" };

/// A tab's card. The engine knows which rows are possible; the app decides what picking one means.
pub const Menu = struct {
    f: ?*const fn (?*anyopaque, usize, Action) void = null,
    ctx: ?*anyopaque = null,
    // Five labels in `all_actions` order, so an app can speak its own language; null draws the defaults.
    labels: ?[]const []const u8 = null,
    // The card's look: the defaults are a dark card, an app passes its theme's own colours.
    style: prop.ContextMenu = .{},
};

/// Tab click: the index in the slice the bar was given.
pub const SelectFn = ?*const fn (?*anyopaque, usize) void;

pub const TabsProps = struct {
    id: prop.Id,
    // Where the app declared this widget: `@src()` at the call site, which the devtool then shows as the declaration.
    src: ?std.builtin.SourceLocation = null,
    tabs: []const Tab = &.{},
    h: prop.Size = .{ .fixed = 34 },
    // Every tab is this wide, however long its label: a bar of equal tabs reads as a bar, not as a run of words.
    tab_w: prop.Len = .{ .px = 160 },
    bg: Color = Color.rgb(0x1a, 0x1a, 0x1d),
    active_bg: Color = Color.rgb(0x14, 0x14, 0x16),
    hover_bg: Color = Color.rgb(0x22, 0x22, 0x26),
    fg: Color = Color.rgb(0x8a, 0x8a, 0x94),
    active_fg: Color = Color.rgb(0xf0, 0xf0, 0xf4),
    close_fg: Color = Color.rgb(0x5a, 0x5a, 0x64),
    close_hover: Color = Color.rgb(0x33, 0x33, 0x3c),
    // The dot an unsaved tab wears in its close slot; null draws it in the tab's own label tone.
    dirty_fg: ?Color = null,
    // A line along the bottom of the active tab: the cue that stays legible when the fill is a subtle step.
    active_line: ?Color = null,
    // A 1 pt rule under the whole strip, so a bar of tabs reads as a bar and not as floating words.
    divider: ?Color = null,
    // Tabs are rounded along their top edge: with the 1 pt gap, a hovered tab reads as a tab.
    tab_radius: prop.Radius = .{ .top_left = .{ .px = 6 }, .top_right = .{ .px = 6 } },
    label_size: prop.Len = .{ .px = 13 },
    pad_lr: prop.Len = .{ .px = 11 },
    // The bar a drop would land on, drawn across the strip.
    drop_line: Color = Color.rgb(0x7a, 0xb8, 0xff),
    on_select: prop.Select = .{},
    on_close: prop.Select = .{},
    // Drag a tab onto another to move it: the app splices its own array, `from` and `to` are indices after the move.
    on_move: ?*const fn (?*anyopaque, usize, usize) void = null,
    ctx: ?*anyopaque = null,
    menu: Menu = .{},
    click_z: i16 = 0,
};

/// The element id of tab `i`. `+1` so tab 0 never collides with the bar's own id.
fn tabId(base: []const u8, i: usize) cl.ElementId {
    return cl.ElementId.IDI(base, @as(u32, @intCast(i + 1)));
}

/// An element inside tab `i`: the dot, the close box or the label's own row.
fn innerId(base: []const u8, i: usize, slot: u32) cl.ElementId {
    return cl.ElementId.IDI(base, @as(u32, @intCast(i + 1)) + slot * 0x10000);
}

/// The strip's clip, and the row of tabs inside it: two ids no tab index can reach.
fn stripId(base: []const u8) cl.ElementId {
    return cl.ElementId.IDI(base, 0xF000);
}

fn stripRowId(base: []const u8) cl.ElementId {
    return cl.ElementId.IDI(base, 0xF001);
}

/// The rule along the bar's bottom edge, and the line under the active tab: ids no tab index can reach.
fn dividerId(base: []const u8) cl.ElementId {
    return cl.ElementId.IDI(base, 0xF002);
}

/// The copy of a picked-up tab that follows the pointer, and the gap it leaves: ids no tab index can reach.
fn ghostId(base: []const u8) cl.ElementId {
    return cl.ElementId.IDI(base, 0xF003);
}

fn holeId(base: []const u8, slot: usize) cl.ElementId {
    return cl.ElementId.IDI(base, 0xE000 + @as(u32, @intCast(slot)));
}

/// The most bars one app may keep a scroll position for, and the most tabs one bar may offer a card for.
const bar_cap: usize = 16;
const tab_cap: usize = 64;

/// What a bar remembers between frames: where its strip sits, and how much room it had.
const Strip = struct {
    id: cl.ElementId,
    // How far the strip has slid left; 0 shows the first tab.
    h_scroll: f32 = 0,
    // The clip's width last frame, which is the only viewport a declare can know before its own layout closes.
    inner_w: f32 = 0,
    // The active index the reveal last ran for: a strip nobody navigated must not undo a wheel scroll every frame.
    followed: ?usize = null,
    // The tab this bar is dragging, and where it was picked up inside its own box: the floating copy keeps that offset.
    drag_from: ?usize = null,
    grab_dx: f32 = 0,
    // Where this bar's cards live in `menu_slots`: one slot per tab, never shared with another bar.
    menu_base: usize = 0,
};

var strips: [bar_cap]Strip = undefined;
var strip_count: usize = 0;

// One tab's card, kept between frames: a card outlives the declare that raised it, so its rows cannot live on the stack.
const MenuSlot = struct {
    f: ?*const fn (?*anyopaque, usize, Action) void = null,
    ctx: ?*anyopaque = null,
    tab: usize = 0,
    // The card's own flags, in `all_actions` order: a row nobody can pick is drawn dim and answers nothing.
    disabled: [all_actions.len]bool = .{ false, false, false, false, false },
};

var menu_slots: [bar_cap * tab_cap]MenuSlot = undefined;

// The strip belonging to this bar, created on first use: the state survives the frame, keyed the way Clay keys the element.
fn stripFor(id: cl.ElementId) *Strip {
    for (strips[0..strip_count]) |*s| {
        if (s.id.id == id.id and s.id.offset == id.offset) return s;
    }
    // A bar that was never declared before takes the next slot; one past the cap recycles the first one's.
    const slot = if (strip_count < strips.len) strip_count else 0;
    if (strip_count < strips.len) strip_count += 1;
    strips[slot] = .{ .id = id, .menu_base = slot * tab_cap };
    return &strips[slot];
}

/// Declare a tab bar.
pub fn tabs(props: TabsProps) void {
    const name = props.id.str();
    const strip = stripFor(props.id.clay());
    const gap: f32 = 1;
    const tab_w = props.tab_w.pts();
    const count: f32 = @floatFromInt(props.tabs.len);
    const content_w = if (props.tabs.len == 0) 0 else count * tab_w + gap * (count - 1);
    // The clip's width is last frame's, because a box read mid-declare has not been laid out yet.
    if (frame_mod.bounds(stripId(name))) |b| strip.inner_w = b.width;
    followActive(props.tabs, strip, tab_w, gap);
    wheelScroll(strip, stripId(name), content_w);
    // Never past either end: a close, or a wheel past the last tab, can ask for more than the strip has to give.
    strip.h_scroll = std.math.clamp(strip.h_scroll, 0, @max(content_w - strip.inner_w, 0));

    semantics.registerAt(@src(), .{
        .declared = semantics.declaredAt(props.src),
        .id = props.id.clay(),
        .tag = name,
        .role = .list,
        .flags = .{ .enabled = true },
    });

    const preview = previewOf(props, strip);
    if (preview == null) strip.drag_from = null;

    cl.UI()(.{
        .id = props.id.clay(),
        .layout = .{
            .direction = .top_to_bottom,
            .sizing = .{ .w = .grow, .h = props.h.clay() },
            .child_gap = 0,
        },
        .background_color = props.bg.toClay(),
    })({
        // ONE horizontal clip: a tab slides under the bar's right edge instead of painting over the component beside it.
        cl.UI()(.{
            .id = stripId(name),
            .layout = .{
                .direction = .left_to_right,
                .sizing = .{ .w = .grow, .h = .grow },
                .child_alignment = .{ .x = .left, .y = .center },
                .child_gap = 0,
            },
            .clip = .{ .horizontal = true, .child_offset = .{ .x = -strip.h_scroll, .y = 0 } },
        })({
            cl.UI()(.{
                .id = stripRowId(name),
                .layout = .{
                    .direction = .left_to_right,
                    .sizing = .{ .w = .fit, .h = .grow },
                    .child_gap = gap,
                },
            })({
                // A tab scrolled out of the strip must not answer a click where it used to be.
                registry.pushClip(stripId(name));
                if (preview) |p| {
                    // The strip makes room where the tab would land, so the gap IS the answer to "where will it go".
                    for (p.order[0..p.count], 0..) |source, slot| {
                        if (source == no_slot) holeUi(props, slot) else tabUi(props, strip, props.tabs[source], source);
                    }
                } else {
                    for (props.tabs, 0..) |tab, i| tabUi(props, strip, tab, i);
                }
                registry.popClip();
            });
        });
        // The picked-up tab follows the pointer: a copy above everything, so it reads as lifted out of the strip.
        if (preview) |p| ghostUi(props, p.from, strip);
        // The seam between the bar and the pane it opens: a strip with no rule under it floats over the editor.
        if (props.divider) |d| cl.UI()(.{
            .id = dividerId(name),
            .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(1) } },
            .background_color = d.toClay(),
        })({});
    });
}

// Slide the strip just enough to show the active tab, and only when the active tab CHANGED: a wheel scroll stays put.
fn followActive(items: []const Tab, strip: *Strip, tab_w: f32, gap: f32) void {
    const active = activeIndex(items) orelse return;
    // A bar nobody has laid out yet has no room to keep a tab in, so the reveal waits for the second frame.
    if (strip.inner_w <= 0) return;
    if (strip.followed == active) return;
    const start = @as(f32, @floatFromInt(active)) * (tab_w + gap);
    const end = start + tab_w;
    if (start - strip.h_scroll < 0) strip.h_scroll = start;
    if (end - strip.h_scroll > strip.inner_w) strip.h_scroll = end - strip.inner_w;
    strip.followed = active;
}

// The index of the tab that is on screen: the first one flagged active, because a bar shows one at a time.
fn activeIndex(items: []const Tab) ?usize {
    for (items, 0..) |tab, i| {
        if (tab.active) return i;
    }
    return null;
}

// A wheel over the strip slides it: a mouse has no horizontal axis, and Clay spends a delta only on an axis a clip enables.
fn wheelScroll(strip: *Strip, clip: cl.ElementId, content_w: f32) void {
    // Nothing past the edge to reach, or no room known yet: the wheel belongs to whoever is behind the bar.
    if (content_w <= strip.inner_w) return;
    const box = frame_mod.bounds(clip) orelse return;
    if (frame_mod.ptr_x < box.x or frame_mod.ptr_x >= box.x + box.width) return;
    if (frame_mod.ptr_y < box.y or frame_mod.ptr_y >= box.y + box.height) return;
    // A trackpad sends x, a mouse wheel sends y: either one means the tabs past the edge, never both at once.
    const delta = if (@abs(frame_mod.scroll_dx) > 0.01) frame_mod.scroll_dx else frame_mod.scroll_dy;
    if (delta == 0) return;
    strip.h_scroll += delta;
}

// The slot the picked-up tab left: the strip draws a gap there instead of a tab.
const no_slot: usize = std.math.maxInt(usize);

// A drag in flight over this bar: which tab was picked up, and the slot the strip makes room at.
const Preview = struct {
    from: usize,
    hole: usize,
    // Which tab each slot shows, `no_slot` for the gap.
    order: [tab_cap]usize = @splat(no_slot),
    count: usize = 0,
};

// The preview for a drag this bar owns: the picked-up tab leaves its slot and a gap opens where it would land.
fn previewOf(props: TabsProps, strip: *Strip) ?Preview {
    const owner = reorder_mod.draggingList() orelse return null;
    if (!std.mem.eql(u8, owner, props.id.str())) return null;
    const from = reorder_mod.draggingIndex() orelse return null;
    const boundary = reorder_mod.dropIndex(props.id.str()) orelse return null;
    // A bar of more tabs than the module tracks keeps its plain order rather than a wrong preview.
    if (from >= props.tabs.len or props.tabs.len > tab_cap) return null;

    // Where the pick-up started inside the tab, so the floating copy keeps its label under the pointer.
    if (strip.drag_from == null or strip.drag_from.? != from) {
        // The press point, not the pointer: by the frame a drag is noticed the pointer has already left it.
        const grab_x = if (frame_mod.ptr_down) frame_mod.ptr_press_x else frame_mod.ptr_x;
        if (frame_mod.bounds(tabId(props.id.str(), from))) |box| strip.grab_dx = grab_x - box.x;
        strip.drag_from = from;
    }

    var out = Preview{ .from = from, .hole = 0, .count = props.tabs.len };
    // The boundary is asked in the picked-up tab's own index space: past it, the slot comes back one once it leaves.
    out.hole = @min(if (boundary > from) boundary - 1 else boundary, props.tabs.len - 1);
    var source: usize = 0;
    var slot: usize = 0;
    while (slot < out.count) : (slot += 1) {
        if (slot == out.hole) continue;
        if (source == from) source += 1;
        out.order[slot] = source;
        source += 1;
    }
    return out;
}

// The gap a picked-up tab leaves: the width it would take, tinted with the drop colour, so the landing is visible.
fn holeUi(props: TabsProps, slot: usize) void {
    cl.UI()(.{
        .id = holeId(props.id.str(), slot),
        .layout = .{ .sizing = .{ .w = .fixed(props.tab_w.pts()), .h = .grow } },
        .background_color = Color.withAlpha(props.drop_line, 28).toClay(),
        .corner_radius = props.tab_radius.clay(),
        .border = .{ .color = Color.withAlpha(props.drop_line, 120).toClay(), .width = .outside(1) },
    })({});
}

// The picked-up tab itself, floating under the pointer at the offset it was grabbed by, above everything else.
fn ghostUi(props: TabsProps, from: usize, strip: *Strip) void {
    const tab = props.tabs[from];
    const bar = frame_mod.bounds(props.id.clay()) orelse return;
    const name = props.id.str();
    const size = props.label_size.whole();
    const rule: f32 = if (props.divider == null) 0 else 1;
    cl.UI()(.{
        .id = ghostId(name),
        .layout = .{
            .direction = .left_to_right,
            .sizing = .{ .w = .fixed(props.tab_w.pts()), .h = .fixed(@max(bar.height - rule, 20)) },
            .padding = .{ .left = props.pad_lr.whole(), .right = props.pad_lr.whole() },
            .child_alignment = .{ .x = .left, .y = .center },
            .child_gap = 8,
        },
        .floating = .{
            .attach_to = .to_root,
            .offset = .{ .x = frame_mod.ptr_x - strip.grab_dx, .y = bar.y },
            .z_index = reorder_mod.z_index,
            // Nothing under the copy loses its hover or its click: the drag keeps owning the pointer.
            .pointer_capture_mode = .passthrough,
        },
        .background_color = props.active_bg.toClay(),
        .corner_radius = props.tab_radius.clay(),
        .border = .{ .color = props.drop_line.toClay(), .width = .outside(1) },
    })({
        // The copy has no close box, so its label may spend what that box would have taken.
        const budget = props.tab_w.pts() - props.pad_lr.pts() * 2;
        const fitted = text_fit.fit(tab.label, size, budget);
        cl.text(tab.label[0..fitted.keep], .{ .font_size = size, .color = props.active_fg.toClay() });
        if (fitted.dots) cl.text(text_fit.dots, .{ .font_size = size, .color = props.active_fg.toClay() });
    });
}

fn tabUi(props: TabsProps, strip: *Strip, tab: Tab, i: usize) void {
    const name = props.id.str();
    // The pointer over THIS tab, asked by id: `cl.hovered()` would answer for the strip row, and light up every tab at once.
    const hovered = cl.pointerOver(tabId(name, i));
    const fg = if (tab.active or hovered) props.active_fg else props.fg;
    const bg = if (tab.active) props.active_bg else if (hovered) props.hover_bg else props.bg;
    const size = props.label_size.whole();

    cl.UI()(.{
        .id = tabId(name, i),
        .layout = .{
            .direction = .top_to_bottom,
            .sizing = .{ .w = .fixed(props.tab_w.pts()), .h = .grow },
            .child_gap = 0,
        },
        .background_color = bg.toClay(),
        .corner_radius = props.tab_radius.clay(),
    })({
        cl.UI()(.{
            .id = innerId(name, i, 5),
            .layout = .{
                .direction = .left_to_right,
                .sizing = .{ .w = .grow, .h = .grow },
                .padding = .{ .left = props.pad_lr.whole(), .right = props.pad_lr.whole() },
                .child_alignment = .{ .x = .left, .y = .center },
                .child_gap = 8,
            },
        })({
            if (tab.accent) |accent| {
                cl.UI()(.{
                    .id = innerId(name, i, 1),
                    .layout = .{ .sizing = .{ .w = .fixed(5), .h = .fixed(5) } },
                    .background_color = accent.toClay(),
                    .corner_radius = .all(3),
                })({});
            }
            // The label takes whatever the dot and the close leave, and is cut to it: a tab never grows a second line.
            cl.UI()(.{
                .id = innerId(name, i, 3),
                .layout = .{
                    .direction = .left_to_right,
                    .sizing = .{ .w = .grow, .h = .grow },
                    .child_alignment = .{ .x = .left, .y = .center },
                    .child_gap = 0,
                },
            })({
                const fitted = text_fit.fit(tab.label, size, labelBudget(props, tab));
                cl.text(tab.label[0..fitted.keep], .{ .font_size = size, .color = fg.toClay() });
                // Three dots rather than U+2026: the bundled face has Latin-1, and a missing glyph reads worse than a short name.
                if (fitted.dots) cl.text(text_fit.dots, .{ .font_size = size, .color = fg.toClay() });
            });
            // Where the close box would be: a clean tab offers "x", a tab with unsaved work offers the dot until it is hovered.
            if (tab.closable) closeSlot(props, tab, hovered, fg, i);
        });
        // The active tab's own line, under its label: the fill is a subtle step, so one bright edge is what a glance finds.
        if (tab.active) if (props.active_line) |line| cl.UI()(.{
            .id = innerId(name, i, 4),
            .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(2) } },
            .background_color = line.toClay(),
        })({});
    });

    semantics.registerAt(@src(), .{
        .declared = semantics.declaredAt(props.src),
        .id = tabId(name, i),
        .role = .list_item,
        .flags = .{ .enabled = true, .selected = tab.active },
    });
    if (props.on_select.f) |cb| {
        registry.registerZCursor(tabId(name, i), cb, props.on_select.ctx, i, props.click_z, .pointer);
    }
    if (tab.closable) {
        if (props.on_close.f) |cb| {
            registry.registerZCursor(innerId(name, i, 2), cb, props.on_close.ctx, i, props.click_z, .pointer);
        }
    }
    // The Host already routes press/move/release to `reorder`, so a registered tab is draggable with no pointer code here.
    if (props.on_move) |move_fn| {
        reorder_mod.register(name, tabId(name, i), i, .{
            .on_move = move_fn,
            .ctx = props.ctx,
            .axis = .horizontal,
            .line = props.drop_line,
        });
    }
    if (strip.menu_base + i < menu_slots.len) registerCard(props, strip.menu_base + i, tab, i);
}

// The 16 pt slot at a tab's right edge: the dot while the tab has edits and nobody points at it, "x" otherwise.
fn closeSlot(props: TabsProps, tab: Tab, hovered: bool, fg: Color, i: usize) void {
    const name = props.id.str();
    // A box with nothing drawn in it must paint nothing at all: a transparent fill emits no rectangle in Clay.
    const background = if (cl.hovered()) props.close_hover else Color.rgba(0, 0, 0, 0);
    cl.UI()(.{
        .id = innerId(name, i, 2),
        .layout = .{
            .sizing = .{ .w = .fixed(16), .h = .fixed(16) },
            .child_alignment = .{ .x = .center, .y = .center },
        },
        .background_color = background.toClay(),
        .corner_radius = .all(4),
    })({
        if (tab.dirty and !hovered) {
            cl.UI()(.{
                .id = innerId(name, i, 6),
                .layout = .{ .sizing = .{ .w = .fixed(6), .h = .fixed(6) } },
                .background_color = (props.dirty_fg orelse fg).toClay(),
                .corner_radius = .all(3),
            })({});
        } else {
            cl.text("x", .{ .font_size = 11, .color = props.close_fg.toClay() });
        }
    });
}

// What a tab's label may spend: its own width less the dot, the close box, the two paddings and the gaps between them.
fn labelBudget(props: TabsProps, tab: Tab) f32 {
    const gap: f32 = 8;
    var chrome = props.pad_lr.pts() * 2;
    if (tab.accent != null) chrome += 5 + gap;
    if (tab.closable) chrome += 16 + gap;
    return props.tab_w.pts() - chrome;
}

// A tab's card: the engine fills the five rows and their enablement, and reports which tab and which action were picked.
fn registerCard(props: TabsProps, slot_index: usize, tab: Tab, i: usize) void {
    const spec = props.menu;
    if (spec.f == null) return;
    const slot = &menu_slots[slot_index];
    slot.f = spec.f;
    slot.ctx = spec.ctx;
    slot.tab = i;
    slot.disabled = disabledRows(props.tabs, tab, i);
    var card = spec.style;
    const labels = spec.labels orelse &default_labels;
    // The engine's five actions are the whole vocabulary, so a longer list is cut rather than indexed past its end.
    card.items = labels[0..@min(labels.len, all_actions.len)];
    // The flags outlive this declare: a card is picked on a later frame, so they ride in the slot, never on the stack.
    card.disabled = slot.disabled[0..];
    card.on_select = .{ .f = onCardRow, .ctx = slot };
    context_menu.register(tabId(props.id.str(), i), card, props.click_z);
}

// Which of the five rows this tab cannot use: a dim row, from what the engine itself knows and nothing more.
fn disabledRows(items: []const Tab, tab: Tab, i: usize) [all_actions.len]bool {
    return .{
        // Save belongs to a tab with unsaved work; what saving it writes is the app's business.
        !tab.dirty,
        items.len < 2,
        i + 1 >= items.len,
        i == 0,
        !tab.closable,
    };
}

// A card row was picked: the action and the tab it belongs to go to the app.
fn onCardRow(ctx: ?*anyopaque, row: usize) void {
    const slot: *MenuSlot = @ptrCast(@alignCast(ctx.?));
    if (row >= all_actions.len) return;
    const f = slot.f orelse return;
    f(slot.ctx, slot.tab, all_actions[row]);
}

const sample_tabs = [_]Tab{
    .{ .label = "users", .active = true, .accent = Color.rgb(0x7a, 0xa2, 0xc4) },
    .{ .label = "orders", .accent = Color.rgb(0x7f, 0xae, 0x8a) },
    .{ .label = "Query 1", .closable = false },
};

fn declareSample() void {
    tabs(.{ .id = .{ .text = "tabs" }, .tabs = &sample_tabs });
}

test "a tab bar draws a box per tab plus the container" {
    var rects: usize = 0;
    var texts: usize = 0;
    try headless.countCommands(declareSample, &rects, &texts);
    // Container + one box per tab + a dot on two. The strip and the label's row draw nothing, and an idle close box is transparent.
    try std.testing.expectEqual(@as(usize, 1 + 3 + 2), rects);
    // A label per tab, plus an "x" on the two closable ones.
    try std.testing.expectEqual(@as(usize, 3 + 2), texts);
}

test "an empty bar still declares its container" {
    var rects: usize = 0;
    var texts: usize = 0;
    try headless.countCommands(declareEmpty, &rects, &texts);
    try std.testing.expectEqual(@as(usize, 1), rects);
    try std.testing.expectEqual(@as(usize, 0), texts);
}

fn declareEmpty() void {
    tabs(.{ .id = .{ .text = "tabs-empty" }, .tabs = &.{} });
}

test "TabsProps needs only an id" {
    const p = TabsProps{ .id = .{ .text = "x" } };
    try std.testing.expectEqual(@as(usize, 0), p.tabs.len);
}

// ---- the fixture every frame test declares, so one module can hold several bars --------------------------------------

var fx: TabsProps = .{ .id = .{ .text = "tabs-fx" } };

// One frame on the canvas `headless.begin` set up, with the pointer where a test asked for it.
fn frame(pointer_x: f32, pointer_y: f32) []cl.RenderCommand {
    frame_mod.setPointer(pointer_x, pointer_y);
    cl.setPointerState(.{ .x = pointer_x, .y = pointer_y }, false);
    cl.beginLayout();
    tabs(fx);
    return cl.endLayout();
}

fn boxOf(id: cl.ElementId) cl.BoundingBox {
    return cl.getElementData(id).bounding_box;
}

const long_tabs = [_]Tab{.{ .label = "a request name far too long for any tab", .closable = false }};

test "a tab is exactly tab_w wide, and a label too long for it is cut with dots instead of wrapping" {
    headless.begin(.{ .x = 99999, .y = 99999 }, false);
    fx = .{ .id = .{ .text = "tabs-long" }, .tabs = &long_tabs, .tab_w = .{ .px = 100 }, .h = .{ .fixed = 30 } };
    const cmds = frame(99999, 99999);
    try std.testing.expectEqual(@as(f32, 100), boxOf(tabId("tabs-long", 0)).width);
    // One label, cut once: the prefix and then the dots, and nothing else in the strip.
    var runs: [4][]const u8 = undefined;
    var n: usize = 0;
    for (cmds) |c| {
        if (c.command_type != .text) continue;
        const run = c.render_data.text.string_contents;
        if (n < runs.len) runs[n] = run.chars[0..@intCast(run.length)];
        n += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings(text_fit.dots, runs[1]);
    // The kept part is a real prefix of the label and shorter than it: that is what "cut" means.
    try std.testing.expect(runs[0].len > 0 and runs[0].len < long_tabs[0].label.len);
    try std.testing.expectEqualStrings(long_tabs[0].label[0..runs[0].len], runs[0]);
}

const four_tabs = [_]Tab{
    .{ .label = "one", .closable = false },
    .{ .label = "two", .closable = false },
    .{ .label = "three", .closable = false },
    .{ .label = "four", .closable = false, .active = true },
};

test "a bar narrower than its tabs clips the strip and slides the active tab into view" {
    headless.begin(.{ .x = 99999, .y = 99999 }, false);
    cl.setLayoutDimensions(.{ .w = 240, .h = 200 });
    fx = .{ .id = .{ .text = "tabs-narrow" }, .tabs = &four_tabs, .tab_w = .{ .px = 100 }, .h = .{ .fixed = 30 } };
    // The first frame lays the clip out; the second one knows its width, which is what the reveal needs.
    _ = frame(99999, 99999);
    _ = frame(99999, 99999);
    const bar = boxOf(cl.getElementId("tabs-narrow"));
    const active = boxOf(tabId("tabs-narrow", 3));
    try std.testing.expect(active.width > 0);
    try std.testing.expect(active.x >= bar.x - 0.5);
    try std.testing.expect(active.x + active.width <= bar.x + bar.width + 0.5);
    // And the first tab is the one that went off the left edge.
    const first_tab = boxOf(tabId("tabs-narrow", 0));
    try std.testing.expect(first_tab.x + first_tab.width <= bar.x + 0.5);
    // The bar itself is the window's width: the strip scrolling never widened it.
    try std.testing.expectEqual(@as(f32, 240), bar.width);
}

const wheel_tabs = [_]Tab{
    .{ .label = "one", .closable = false, .active = true },
    .{ .label = "two", .closable = false },
    .{ .label = "three", .closable = false },
    .{ .label = "four", .closable = false },
};

test "the wheel over the strip slides it, and a frame without a wheel leaves it there" {
    headless.begin(.{ .x = 99999, .y = 99999 }, false);
    cl.setLayoutDimensions(.{ .w = 240, .h = 200 });
    fx = .{ .id = .{ .text = "tabs-wheel" }, .tabs = &wheel_tabs, .tab_w = .{ .px = 100 }, .h = .{ .fixed = 30 } };
    // The active tab is the first one, so the reveal leaves the strip at its start and the wheel has room to move it.
    _ = frame(99999, 99999);
    const before = boxOf(tabId("tabs-wheel", 3));
    frame_mod.scroll_dy = 40;
    _ = frame(50, 15);
    frame_mod.scroll_dy = 0;
    const after = boxOf(tabId("tabs-wheel", 3));
    try std.testing.expectApproxEqAbs(before.x - 40, after.x, 0.5);
    // A second frame with no wheel keeps it: a strip nobody navigated must not be yanked back every frame.
    _ = frame(50, 15);
    try std.testing.expectApproxEqAbs(after.x, boxOf(tabId("tabs-wheel", 3)).x, 0.01);
}

var card_ctx: struct { calls: usize = 0, tab: usize = 0, action: Action = .save } = .{};

fn onCard(ctx: ?*anyopaque, index: usize, action: Action) void {
    const c: *@TypeOf(card_ctx) = @ptrCast(@alignCast(ctx.?));
    c.calls += 1;
    c.tab = index;
    c.action = action;
}

const menu_tabs = [_]Tab{
    .{ .label = "clean" },
    .{ .label = "edited", .dirty = true },
};

test "a right click on a tab offers the five rows and reports the one it picked" {
    headless.begin(.{ .x = 99999, .y = 99999 }, false);
    cl.setLayoutDimensions(.{ .w = 480, .h = 200 });
    card_ctx = .{};
    fx = .{
        .id = .{ .text = "tabs-menu" },
        .tabs = &menu_tabs,
        .tab_w = .{ .px = 120 },
        .h = .{ .fixed = 30 },
        .menu = .{ .f = onCard, .ctx = &card_ctx },
    };
    registry.beginFrame();
    context_menu.beginFrame();
    _ = frame(99999, 99999);
    // The second tab is the last one and has unsaved work, so Save, Close others and Close to the left are live.
    const second = boxOf(tabId("tabs-menu", 1));
    try std.testing.expect(context_menu.secondaryClick(second.x + 20, second.y + 10, 480, 200));
    try std.testing.expect(context_menu.isOpen());
    // The card is drawn on the frame after the click, which is when its rows get boxes.
    registry.beginFrame();
    context_menu.beginFrame();
    frame_mod.setPointer(99999, 99999);
    cl.setPointerState(.{ .x = 99999, .y = 99999 }, false);
    cl.beginLayout();
    tabs(fx);
    context_menu.declare();
    _ = cl.endLayout();
    for (0..all_actions.len) |i| try std.testing.expect(cl.getElementData(context_menu.rowId(i)).found);
    // Picking "Close others" reports that action with the tab it belongs to.
    const row = boxOf(context_menu.rowId(1));
    try std.testing.expect(registry.dispatchClick(row.x + row.width * 0.5, row.y + row.height * 0.5));
    try std.testing.expectEqual(@as(usize, 1), card_ctx.calls);
    try std.testing.expectEqual(@as(usize, 1), card_ctx.tab);
    try std.testing.expectEqual(Action.close_others, card_ctx.action);
    try std.testing.expect(!context_menu.isOpen());
}

var move_ctx: struct { calls: usize = 0, from: usize = 0, to: usize = 0 } = .{};

fn onMove(ctx: ?*anyopaque, from: usize, to: usize) void {
    const c: *@TypeOf(move_ctx) = @ptrCast(@alignCast(ctx.?));
    c.calls += 1;
    c.from = from;
    c.to = to;
}

test "dragging a tab across the strip reports the index it lands on" {
    headless.begin(.{ .x = 99999, .y = 99999 }, false);
    cl.setLayoutDimensions(.{ .w = 480, .h = 200 });
    move_ctx = .{};
    reorder_mod.cancel();
    fx = .{
        .id = .{ .text = "tabs-drag" },
        .tabs = &four_tabs,
        .tab_w = .{ .px = 100 },
        .h = .{ .fixed = 30 },
        .on_move = onMove,
        .ctx = &move_ctx,
    };
    _ = frame(99999, 99999);

    const first = boxOf(tabId("tabs-drag", 0));
    reorder_mod.press(first.x + first.width * 0.5, first.y + first.height * 0.5);
    // A press that never moves is still a click, not a move.
    try std.testing.expect(!reorder_mod.isDragging());
    const third = boxOf(tabId("tabs-drag", 2));
    reorder_mod.move(third.x + third.width * 0.5, third.y + third.height * 0.5);
    try std.testing.expect(reorder_mod.isDragging());
    _ = reorder_mod.release(third.x + third.width * 0.5, third.y + third.height * 0.5);
    try std.testing.expectEqual(@as(usize, 1), move_ctx.calls);
    try std.testing.expectEqual(@as(usize, 0), move_ctx.from);
    try std.testing.expectEqual(@as(usize, 2), move_ctx.to);
}

// ---- the look: which tab lights up, what an unsaved tab offers, and the two rules ------------------------------

fn rectColorOf(cmds: []cl.RenderCommand, id: u32) ?cl.Color {
    for (cmds) |c| {
        if (c.command_type != .rectangle) continue;
        if (c.id != id) continue;
        return c.render_data.rectangle.background_color;
    }
    return null;
}

fn countTextOf(cmds: []cl.RenderCommand, needle: []const u8) usize {
    var n: usize = 0;
    for (cmds) |c| {
        if (c.command_type != .text) continue;
        const run = c.render_data.text.string_contents;
        if (std.mem.eql(u8, run.chars[0..@intCast(run.length)], needle)) n += 1;
    }
    return n;
}

const bar_bg = Color.rgb(0x10, 0x10, 0x12);
const hover_tone = Color.rgb(0x30, 0x30, 0x34);
const active_tone = Color.rgb(0x20, 0x20, 0x24);

const hover_tabs = [_]Tab{
    .{ .label = "one", .closable = false },
    .{ .label = "two", .closable = false },
    .{ .label = "three", .closable = false },
};

test "the hover tone belongs to the tab under the pointer, not to the whole strip" {
    headless.begin(.{ .x = 99999, .y = 99999 }, false);
    cl.setLayoutDimensions(.{ .w = 480, .h = 200 });
    fx = .{
        .id = .{ .text = "tabs-hover" },
        .tabs = &hover_tabs,
        .tab_w = .{ .px = 100 },
        .h = .{ .fixed = 30 },
        .bg = bar_bg,
        .hover_bg = hover_tone,
        .active_bg = active_tone,
    };
    // The first frame lays the tabs out; the second one can ask where they are.
    _ = frame(99999, 99999);
    const second = boxOf(tabId("tabs-hover", 1));
    const cmds = frame(second.x + 20, second.y + 10);
    // One tab lights up, and the two beside it keep the bar's own tone.
    try std.testing.expectEqual(hover_tone.toClay(), rectColorOf(cmds, tabId("tabs-hover", 1).id).?);
    try std.testing.expectEqual(bar_bg.toClay(), rectColorOf(cmds, tabId("tabs-hover", 0).id).?);
    try std.testing.expectEqual(bar_bg.toClay(), rectColorOf(cmds, tabId("tabs-hover", 2).id).?);
}

const dirty_tabs = [_]Tab{
    .{ .label = "clean" },
    .{ .label = "edited", .dirty = true },
};

test "an unsaved tab offers a dot where its close box sits, and the x comes back under the pointer" {
    headless.begin(.{ .x = 99999, .y = 99999 }, false);
    cl.setLayoutDimensions(.{ .w = 480, .h = 200 });
    const dot_tone = Color.rgb(0x87, 0xa9, 0x87);
    fx = .{
        .id = .{ .text = "tabs-dirty" },
        .tabs = &dirty_tabs,
        .tab_w = .{ .px = 120 },
        .h = .{ .fixed = 30 },
        .dirty_fg = dot_tone,
    };
    _ = frame(99999, 99999);
    const idle = frame(99999, 99999);
    // Two labels, and one x: the tab with edits keeps its close box until the pointer arrives.
    try std.testing.expectEqual(@as(usize, 1), countTextOf(idle, "x"));
    // The dot sits in the close slot, and it is the app's own tone.
    const slot = innerId("tabs-dirty", 1, 2);
    const dot = innerId("tabs-dirty", 1, 6);
    const dot_box = boxOf(dot);
    const slot_box = boxOf(slot);
    try std.testing.expect(dot_box.width > 0);
    try std.testing.expect(dot_box.x >= slot_box.x and dot_box.x + dot_box.width <= slot_box.x + slot_box.width);
    try std.testing.expectEqual(dot_tone.toClay(), rectColorOf(idle, dot.id).?);

    // The pointer over that tab swaps the dot for its close box.
    const edited = boxOf(tabId("tabs-dirty", 1));
    const over = frame(edited.x + 20, edited.y + 10);
    try std.testing.expectEqual(@as(usize, 2), countTextOf(over, "x"));
    try std.testing.expect(rectColorOf(over, dot.id) == null);
}

test "an idle close box paints nothing, and the hovered one paints its own tone" {
    headless.begin(.{ .x = 99999, .y = 99999 }, false);
    cl.setLayoutDimensions(.{ .w = 480, .h = 200 });
    const close_tone = Color.rgb(0x3a, 0x3a, 0x42);
    fx = .{
        .id = .{ .text = "tabs-close" },
        .tabs = &dirty_tabs,
        .tab_w = .{ .px = 120 },
        .h = .{ .fixed = 30 },
        .close_hover = close_tone,
    };
    _ = frame(99999, 99999);
    const idle = frame(99999, 99999);
    // Not hovered: the slot is transparent, so Clay emits no rectangle for it at all.
    try std.testing.expect(rectColorOf(idle, innerId("tabs-close", 0, 2).id) == null);
    // Over the close box: the box shows itself, while the other tab keeps the dot it was showing.
    const slot = boxOf(innerId("tabs-close", 0, 2));
    const over = frame(slot.x + slot.width * 0.5, slot.y + slot.height * 0.5);
    try std.testing.expectEqual(close_tone.toClay(), rectColorOf(over, innerId("tabs-close", 0, 2).id).?);
    try std.testing.expectEqual(@as(usize, 1), countTextOf(over, "x"));
    try std.testing.expect(rectColorOf(over, innerId("tabs-close", 1, 6).id) != null);
}

const line_tabs = [_]Tab{
    .{ .label = "one" },
    .{ .label = "two", .active = true },
};

test "the active tab wears its line, and the bar its rule along the bottom" {
    headless.begin(.{ .x = 99999, .y = 99999 }, false);
    cl.setLayoutDimensions(.{ .w = 480, .h = 200 });
    const line_tone = Color.rgb(0x8b, 0xa4, 0xb0);
    const divider_tone = Color.rgb(0x39, 0x38, 0x36);
    fx = .{
        .id = .{ .text = "tabs-line" },
        .tabs = &line_tabs,
        .tab_w = .{ .px = 120 },
        .h = .{ .fixed = 32 },
        .active_line = line_tone,
        .divider = divider_tone,
    };
    const cmds = frame(99999, 99999);
    const line = rectColorOf(cmds, innerId("tabs-line", 1, 4).id).?;
    try std.testing.expectEqual(line_tone.toClay(), line);
    // The inactive tab has no line, so nothing is drawn in its slot.
    try std.testing.expect(rectColorOf(cmds, innerId("tabs-line", 0, 4).id) == null);
    // The rule spans the bar's bottom edge, and the strip above it ends where the rule starts.
    const divider = boxOf(dividerId("tabs-line"));
    const bar = boxOf(cl.getElementId("tabs-line"));
    try std.testing.expectEqual(@as(f32, 1), divider.height);
    try std.testing.expectApproxEqAbs(bar.y + bar.height, divider.y + divider.height, 0.5);
    try std.testing.expectApproxEqAbs(bar.width, divider.width, 0.5);
    try std.testing.expectApproxEqAbs(divider.y, boxOf(tabId("tabs-line", 1)).y + boxOf(tabId("tabs-line", 1)).height, 0.5);
}

test "a dragged tab leaves its gap where it would land, and a copy floats at the pointer" {
    headless.begin(.{ .x = 99999, .y = 99999 }, false);
    cl.setLayoutDimensions(.{ .w = 480, .h = 200 });
    reorder_mod.cancel();
    move_ctx = .{};
    fx = .{
        .id = .{ .text = "tabs-preview" },
        .tabs = &four_tabs,
        .tab_w = .{ .px = 100 },
        .h = .{ .fixed = 30 },
        .on_move = onMove,
        .ctx = &move_ctx,
    };
    _ = frame(99999, 99999);
    const first = boxOf(tabId("tabs-preview", 0));
    const last = boxOf(tabId("tabs-preview", 3));
    // Pick up the first tab and carry it past the end of the strip, a little at a time as a hand would.
    reorder_mod.press(first.x + 20, first.y + 10);
    frame_mod.setPointerButton(true, first.x + 20, first.y + 10);
    const end = last.x + last.width - 4;
    var x = first.x + 20;
    while (x < end) : (x += 12) {
        const at = @min(x, end);
        frame_mod.setPointer(at, first.y + 10);
        reorder_mod.move(at, first.y + 10);
    }
    try std.testing.expect(reorder_mod.isDragging());
    // One frame lays the preview out; the next one has boxes to read.
    _ = frame(end, first.y + 10);
    _ = frame(end, first.y + 10);

    // The strip closed ranks and left the gap at the end: it is where the release would put the tab.
    try std.testing.expectApproxEqAbs(first.x, boxOf(tabId("tabs-preview", 1)).x, 0.5);
    try std.testing.expectApproxEqAbs(first.x + 101, boxOf(tabId("tabs-preview", 2)).x, 0.5);
    try std.testing.expectApproxEqAbs(first.x + 202, boxOf(tabId("tabs-preview", 3)).x, 0.5);
    const hole = boxOf(holeId("tabs-preview", 3));
    try std.testing.expectEqual(@as(f32, 100), hole.width);
    try std.testing.expectApproxEqAbs(first.x + 303, hole.x, 0.5);

    // The picked-up tab floats over the bar at the pointer, wearing the drop colour.
    const ghost = boxOf(ghostId("tabs-preview"));
    try std.testing.expectEqual(@as(f32, 100), ghost.width);
    try std.testing.expect(ghost.x > first.x + 100);

    // Releasing reports the move the preview promised, and the bar goes back to plain order.
    _ = reorder_mod.release(end, first.y + 10);
    try std.testing.expectEqual(@as(usize, 1), move_ctx.calls);
    try std.testing.expectEqual(@as(usize, 0), move_ctx.from);
    try std.testing.expectEqual(@as(usize, 3), move_ctx.to);
    _ = frame(99999, 99999);
    try std.testing.expect(rectColorOf(frame(99999, 99999), ghostId("tabs-preview").id) == null);
}
