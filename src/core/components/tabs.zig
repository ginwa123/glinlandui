//! A tab bar: one clickable tab per entry, with an optional accent dot and a close button.

const std = @import("std");
const cl = @import("zclay");
const Color = @import("../color.zig").Color;
const registry = @import("click_registry.zig");
const semantics = @import("../semantics.zig");

/// One tab.
pub const Tab = struct {
    label: []const u8,
    active: bool = false,
    closable: bool = true,
    /// A small dot before the label, for a per-tab colour. Null draws none.
    accent: ?Color = null,
};

/// Tab click: the index in the slice the bar was given.
pub const SelectFn = ?*const fn (?*anyopaque, usize) void;

pub const TabsProps = struct {
    id: []const u8,
    tabs: []const Tab,
    h: u32 = 34,
    bg: Color = Color.rgb(0x1a, 0x1a, 0x1d),
    active_bg: Color = Color.rgb(0x14, 0x14, 0x16),
    fg: Color = Color.rgb(0x8a, 0x8a, 0x94),
    active_fg: Color = Color.rgb(0xf0, 0xf0, 0xf4),
    close_fg: Color = Color.rgb(0x5a, 0x5a, 0x64),
    pad_lr: u16 = 12,
    on_select: SelectFn = null,
    on_close: SelectFn = null,
    ctx: ?*anyopaque = null,
    click_z: i16 = 0,
};

fn tabId(base: []const u8, i: usize) cl.ElementId {
    return cl.ElementId.IDI(base, @as(u32, @intCast(i + 1)));
}

fn innerId(base: []const u8, i: usize, slot: u32) cl.ElementId {
    return cl.ElementId.IDI(base, @as(u32, @intCast(i + 1)) + slot * 0x10000);
}

/// Declare a tab bar.
pub fn tabs(props: TabsProps) void {
    semantics.register(.{
        .id = cl.getElementId(props.id),
        .tag = props.id,
        .role = .list,
        .flags = .{ .enabled = true },
    });

    cl.UI()(.{
        .id = .ID(props.id),
        .layout = .{
            .direction = .left_to_right,
            .sizing = .{ .w = .grow, .h = .fixed(@floatFromInt(props.h)) },
            .child_gap = 1,
        },
        .background_color = props.bg.toClay(),
    })({
        for (props.tabs, 0..) |tab, i| tabUi(props, tab, i);
    });
}

fn tabUi(props: TabsProps, tab: Tab, i: usize) void {
    const fg = if (tab.active) props.active_fg else props.fg;
    const bg = if (tab.active) props.active_bg else props.bg;

    cl.UI()(.{
        .id = .IDI(props.id, @as(u32, @intCast(i + 1))),
        .layout = .{
            .direction = .left_to_right,
            .sizing = .{ .w = .fit, .h = .grow },
            .padding = .{ .left = props.pad_lr, .right = props.pad_lr },
            .child_alignment = .{ .x = .left, .y = .center },
            .child_gap = 8,
        },
        .background_color = (if (!tab.active and cl.hovered()) props.bg else bg).toClay(),
    })({
        if (tab.accent) |accent| {
            cl.UI()(.{
                .id = innerId(props.id, i, 1),
                .layout = .{ .sizing = .{ .w = .fixed(5), .h = .fixed(5) } },
                .background_color = accent.toClay(),
                .corner_radius = .all(3),
            })({});
        }
        cl.text(tab.label, .{ .font_size = 13, .color = fg.toClay() });
        if (tab.closable) {
            cl.UI()(.{
                .id = innerId(props.id, i, 2),
                .layout = .{
                    .sizing = .{ .w = .fixed(16), .h = .fixed(16) },
                    .child_alignment = .{ .x = .center, .y = .center },
                },
                .background_color = (if (cl.hovered()) Color.rgb(0x33, 0x33, 0x3c) else Color.rgb(0, 0, 0)).toClay(),
                .corner_radius = .all(4),
            })({
                cl.text("x", .{ .font_size = 11, .color = props.close_fg.toClay() });
            });
        }
    });

    semantics.register(.{
        .id = tabId(props.id, i),
        .role = .list_item,
        .flags = .{ .enabled = true, .selected = tab.active },
    });
    if (props.on_select) |cb| {
        registry.registerZCursor(tabId(props.id, i), cb, props.ctx, i, props.click_z, .pointer);
    }
    if (tab.closable) {
        if (props.on_close) |cb| {
            registry.registerZCursor(innerId(props.id, i, 2), cb, props.ctx, i, props.click_z, .pointer);
        }
    }
}

// ---- tests ----

fn stubMeasure(s: []const u8, cfg: *cl.TextElementConfig, _: void) cl.Dimensions {
    return .{
        .w = @as(f32, @floatFromInt(s.len)) * @as(f32, @floatFromInt(cfg.font_size)) * 0.6,
        .h = @as(f32, @floatFromInt(cfg.font_size)),
    };
}

fn countCommands(declare_fn: *const fn () void, rects: *usize, texts: *usize) !void {
    const mem_size = cl.minMemorySize();
    const buf = try std.heap.page_allocator.alloc(u8, mem_size);
    const arena = cl.Arena.init(buf);
    _ = cl.initialize(arena, .{ .w = 720, .h = 480 }, .{});
    cl.setMeasureTextFunction(void, {}, stubMeasure);
    cl.setPointerState(.{ .x = 99999, .y = 99999 }, false);
    cl.beginLayout();
    declare_fn();
    const cmds = cl.endLayout();
    var r: usize = 0;
    var t: usize = 0;
    for (cmds) |c| switch (c.command_type) {
        .rectangle => r += 1,
        .text => t += 1,
        else => {},
    };
    rects.* = r;
    texts.* = t;
}

const sample_tabs = [_]Tab{
    .{ .label = "users", .active = true, .accent = Color.rgb(0x7a, 0xa2, 0xc4) },
    .{ .label = "orders", .accent = Color.rgb(0x7f, 0xae, 0x8a) },
    .{ .label = "Query 1", .closable = false },
};

fn declareSample() void {
    tabs(.{ .id = "tabs", .tabs = &sample_tabs });
}

test "a tab bar draws a box per tab plus the container" {
    var rects: usize = 0;
    var texts: usize = 0;
    try countCommands(declareSample, &rects, &texts);
    // Container + one box per tab + a dot on two + a close box on two.
    try std.testing.expectEqual(@as(usize, 1 + 3 + 2 + 2), rects);
    // A label per tab, plus an "x" on the two closable ones.
    try std.testing.expectEqual(@as(usize, 3 + 2), texts);
}

test "an empty bar still declares its container" {
    var rects: usize = 0;
    var texts: usize = 0;
    try countCommands(declareEmpty, &rects, &texts);
    try std.testing.expectEqual(@as(usize, 1), rects);
    try std.testing.expectEqual(@as(usize, 0), texts);
}

fn declareEmpty() void {
    tabs(.{ .id = "tabs-empty", .tabs = &.{} });
}
