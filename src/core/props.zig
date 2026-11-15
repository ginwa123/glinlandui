// The vocabulary a widget's props are written in.

// Every field of a props struct is one of these or a plain flag: an id, a label, a length, padding, a border, a radius and a size.

// A bare u16 or f32 names no meaning, so a props field never carries one: the constructors here are the only door a number comes in through, and each one states its unit.

// Two shapes cover the layout fields: `Size` when a field is an axis of a widget (fit, grow, fixed, percent, clamp), and `Len` when it is a length the widget measures or computes with.

// A count, an index, a fraction the app owns (a slider's value) and the payload inside one of these types stay plain numbers: only the unit-less length is the sin.
const std = @import("std");
const cl = @import("zclay");
const Color = @import("color.zig").Color;
const frame = @import("frame.zig");

// How a widget is named. Clay takes either a string or a (prefix, index) pair.

// A row wants the pair, so no per-frame string is built for it; everything else wants the string.
pub const Id = union(enum) {
    text: []const u8,
    indexed: struct { prefix: []const u8, index: u32 },

    // The id of one item of a list, e.g. `Id.at("todo.row", 3)` — the pair Clay's IDI takes, without formatting.
    pub fn at(prefix: []const u8, index: usize) Id {
        return .{ .indexed = .{ .prefix = prefix, .index = @intCast(index) } };
    }

    // The Clay element id. Both shapes go through the string form, so `clay()` and `str()` always agree.

    // An element that cannot be named by a string cannot be clicked by a test, focused, or found in semantics.
    pub fn clay(self: Id) cl.ElementId {
        return cl.getElementId(self.str());
    }

    // The id as text, for the two places that need one: the semantics tag and keyboard focus.

    // An indexed id is formatted into the frame's scratch, so this is valid for the frame it is called in.
    pub fn str(self: Id) []const u8 {
        return switch (self) {
            .text => |s| s,
            .indexed => |i| frame.formatText("{s}.{d}", .{ i.prefix, i.index }),
        };
    }

    pub fn eql(a: Id, b: Id) bool {
        return switch (a) {
            .text => |s| switch (b) {
                .text => |t| std.mem.eql(u8, s, t),
                else => false,
            },
            .indexed => |i| switch (b) {
                .indexed => |j| i.index == j.index and std.mem.eql(u8, i.prefix, j.prefix),
                else => false,
            },
        };
    }
};

// A length in points: the one unit this vocabulary measures in, for a gap, a padding, a border, a radius, a glyph or a whole widget.

// Points are logical, never device pixels: a platform multiplies by the display scale at the drawing edge, so the same props are one design on every screen.

// The literal spelling is `.{ .px = 8 }`, and `.{}` (or `Len.none`) is no length at all — a gap of none, a border that draws nothing.
pub const Len = struct {
    px: f32 = 0,

    pub const none: Len = .{};

    // The same length, spelled where an expression is wanted instead of a field literal.
    pub fn of(v: f32) Len {
        return .{ .px = v };
    }

    // The length a consumer draws or measures with: points, fractional, unscaled.
    pub fn pts(self: Len) f32 {
        return self.px;
    }

    // The length Clay's spacing fields take: whole points, rounded, never negative.
    pub fn whole(self: Len) u16 {
        return @intFromFloat(@round(@max(self.px, 0)));
    }

    // This length times a factor — a hover lift, a scale factor, half of a box.
    pub fn scaled(self: Len, factor: f32) Len {
        return .{ .px = self.px * factor };
    }

    pub fn add(a: Len, b: Len) Len {
        return .{ .px = a.px + b.px };
    }

    pub fn isNone(self: Len) bool {
        return self.px == 0;
    }
};

// A click handler and the model it belongs to: Zig has no closures, so the pair travels as one field.

pub const Click = struct {
    f: ?*const fn (?*anyopaque) void = null,
    ctx: ?*anyopaque = null,
};

// The pointer shape a click target asks for: the registry and a widget's props share this one definition.
pub const Cursor = enum { default, pointer, text, ew_resize, ns_resize };

// A text handler and its model: the new text is handed back, so the model can hold the draft.

pub const Change = struct {
    f: ?*const fn (?*anyopaque, []const u8) void = null,
    ctx: ?*anyopaque = null,
};

// The same, for a handler that answers whether it took the text (a field clears itself when it did).

pub const Submit = struct {
    f: ?*const fn (?*anyopaque, []const u8) bool = null,
    ctx: ?*anyopaque = null,
};

// An app's own content inside a component's row: told which row, it declares what it likes.

pub const RowExtra = struct {
    f: ?*const fn (?*anyopaque, usize) void = null,
    ctx: ?*anyopaque = null,
};

// A right-click menu a component offers: the rows, in order, and who to tell which one was picked.

// Empty (the default) means the component has NO menu and never reacts to a right click.
pub const ContextMenu = struct {
    items: []const []const u8 = &.{},
    on_select: Select = .{},
    // The card's look. The defaults are a dark card; an app passes its theme's own colours.
    bg: Color = Color.rgb(0x22, 0x22, 0x22),
    fg: Color = Color.rgb(0xe8, 0xe8, 0xe8),
    hover_bg: Color = Color.rgb(0x33, 0x33, 0x33),
    border: Color = Color.rgb(0x3a, 0x3a, 0x3a),
    font_size: Len = .{ .px = 13 },
    row_h: Len = .{ .px = 28 },
    pad: Len = .{ .px = 4 },
    row_pad: Len = .{ .px = 10 },
    radius: Len = .{ .px = 6 },

    pub fn isNone(self: ContextMenu) bool {
        return self.items.len == 0;
    }
};

// The same, for a handler that is told WHICH row, tab or option was hit.

pub const Select = struct {
    f: ?*const fn (?*anyopaque, usize) void = null,
    ctx: ?*anyopaque = null,
};

// A run of text: what it says, how big it is, and what colour it is drawn in.

// `size` is a length like any other, so a label and the box around it are measured in the same unit.
pub const Label = struct {
    text: []const u8 = "",
    size: Len = .{ .px = 14 },
    color: Color = Color.rgb(0xe8, 0xe8, 0xe8),

    pub fn of(text: []const u8) Label {
        return .{ .text = text };
    }

    pub fn sized(self: Label, size: f32) Label {
        var next = self;
        next.size = Len.of(size);
        return next;
    }

    pub fn colored(self: Label, color: Color) Label {
        var next = self;
        next.color = color;
        return next;
    }
};

// Padding on four sides. `all` and `axes` cover almost every call, and their name supplies the unit.
pub const Pad = struct {
    top: Len = .{},
    right: Len = .{},
    bottom: Len = .{},
    left: Len = .{},

    pub fn all(v: f32) Pad {
        const l = Len.of(v);
        return .{ .top = l, .right = l, .bottom = l, .left = l };
    }

    pub fn axes(tb: f32, lr: f32) Pad {
        return .{ .top = Len.of(tb), .right = Len.of(lr), .bottom = Len.of(tb), .left = Len.of(lr) };
    }

    pub fn sides(top: f32, right: f32, bottom: f32, left: f32) Pad {
        return .{ .top = Len.of(top), .right = Len.of(right), .bottom = Len.of(bottom), .left = Len.of(left) };
    }

    pub fn clay(self: Pad) cl.Padding {
        return .{ .top = self.top.whole(), .right = self.right.whole(), .bottom = self.bottom.whole(), .left = self.left.whole() };
    }
};

// A border: a width and the colour it is drawn in. Width 0 draws nothing.
pub const Border = struct {
    width: Len = .{},
    color: Color = Color.rgb(0x00, 0x00, 0x00),

    pub fn all(width: f32, color: Color) Border {
        return .{ .width = Len.of(width), .color = color };
    }

    pub fn clay(self: Border) cl.BorderElementConfig {
        if (self.width.isNone()) return .{};
        return .{ .color = self.color.toClay(), .width = .outside(self.width.whole()) };
    }
};

// A corner radius in points. `all` is the uniform case; the four fields are there for the rest.
pub const Radius = struct {
    top_left: Len = .{},
    top_right: Len = .{},
    bottom_left: Len = .{},
    bottom_right: Len = .{},

    pub fn all(v: f32) Radius {
        const l = Len.of(v);
        return .{ .top_left = l, .top_right = l, .bottom_left = l, .bottom_right = l };
    }

    pub fn clay(self: Radius) cl.CornerRadius {
        return .{
            .top_left = self.top_left.pts(),
            .top_right = self.top_right.pts(),
            .bottom_left = self.bottom_left.pts(),
            .bottom_right = self.bottom_right.pts(),
        };
    }
};

// How a widget takes space on one axis.
pub const Size = union(enum) {
    // As small as the content allows.
    fit,
    // Fill the parent.
    grow,
    // Exactly this many points.
    fixed: f32,
    // This fraction of the parent.
    percent: f32,
    // Fit or grow, clamped; 0 means unbounded on that side.
    clamp: struct { min: f32 = 0, max: f32 = 0, grow: bool = false },

    pub fn px(v: f32) Size {
        return .{ .fixed = v };
    }

    pub fn pct(v: f32) Size {
        return .{ .percent = v };
    }

    pub fn between(min: f32, max: f32) Size {
        return .{ .clamp = .{ .min = min, .max = max } };
    }

    pub fn growing(min: f32, max: f32) Size {
        return .{ .clamp = .{ .min = min, .max = max, .grow = true } };
    }

    pub fn clay(self: Size) cl.SizingAxis {
        return switch (self) {
            .fit => .fit,
            .grow => .grow,
            .fixed => |v| .fixed(v),
            .percent => |v| .percent(v),
            .clamp => |c| if (c.grow)
                .growMinMax(.{ .min = c.min, .max = c.max })
            else
                .fitMinMax(.{ .min = c.min, .max = c.max }),
        };
    }
};

// ---- tests ---------------------------------------------------------------------------------------------------

test "a Len is points, and rounds to the whole points Clay's spacing takes" {
    try std.testing.expectEqual(@as(f32, 0), Len.none.pts());
    try std.testing.expectEqual(@as(f32, 8), Len.of(8).pts());
    try std.testing.expectEqual(@as(u16, 8), Len.of(8).whole());
    try std.testing.expectEqual(@as(u16, 9), Len.of(8.6).whole());
    try std.testing.expectEqual(@as(f32, 8.6), Len.of(8.6).pts());
    // A negative length is not a direction: Clay's spacing fields hold a count of points.
    try std.testing.expectEqual(@as(u16, 0), Len.of(-4).whole());
}

test "a Len combines without a consumer reaching for its payload" {
    try std.testing.expectEqual(@as(f32, 12), Len.of(8).add(Len.of(4)).pts());
    try std.testing.expectEqual(@as(f32, 5), Len.of(10).scaled(0.5).pts());
    try std.testing.expect(Len.none.isNone());
    try std.testing.expect(!Len.of(1).isNone());
}

test "an Id is either a string or a prefix and an index, and both name one Clay element" {
    try std.testing.expect(Id.eql(.{ .text = "a" }, .{ .text = "a" }));
    try std.testing.expect(!Id.eql(.{ .text = "a" }, .{ .text = "b" }));
    try std.testing.expect(Id.eql(Id.at("row", 3), Id.at("row", 3)));
    try std.testing.expect(!Id.eql(Id.at("row", 3), Id.at("row", 4)));
    // A string id and an indexed id never collide, even with the same prefix.
    try std.testing.expect(!Id.eql(.{ .text = "row.3" }, Id.at("row", 3)));
    // An indexed id formats to `prefix.index`, and its Clay id is that string's hash.

    // So a test that clicks "row.3" hits the element `Id.at("row", 3)` declared.
    try std.testing.expectEqualStrings("row.3", Id.at("row", 3).str());
    try std.testing.expectEqual(cl.getElementId("row.3").id, Id.at("row", 3).clay().id);
}

test "a Label carries its own size and colour" {
    const l = Label.of("hi").sized(20).colored(Color.rgb(1, 2, 3));
    try std.testing.expectEqualStrings("hi", l.text);
    try std.testing.expectEqual(@as(f32, 20), l.size.pts());
    try std.testing.expectEqual(Color.rgb(1, 2, 3), l.color);
    // The defaults are a readable body size on a dark surface.
    try std.testing.expectEqual(@as(f32, 14), (Label{}).size.pts());
}

test "Pad has one value per side, and the two shortcuts agree with it" {
    const a = Pad.all(4);
    try std.testing.expectEqual(@as(f32, 4), a.top.pts());
    try std.testing.expectEqual(@as(f32, 4), a.left.pts());
    const b = Pad.axes(2, 6);
    try std.testing.expectEqual(@as(f32, 2), b.top.pts());
    try std.testing.expectEqual(@as(f32, 2), b.bottom.pts());
    try std.testing.expectEqual(@as(f32, 6), b.left.pts());
    try std.testing.expectEqual(@as(f32, 6), b.right.pts());
    try std.testing.expectEqual(@as(f32, 0), (Pad{}).top.pts());
    // Clay's own four u16 sides, rounded from the points the caller wrote.
    try std.testing.expectEqual(@as(u16, 6), Pad.axes(2, 6).clay().left);
    try std.testing.expectEqual(@as(u16, 2), Pad.axes(2, 6).clay().top);
}

test "Border draws nothing at width 0, and a colour at any other width" {
    try std.testing.expectEqual(cl.BorderElementConfig{}, (Border{}).clay());
    const b = Border.all(2, Color.rgb(0xff, 0, 0));
    try std.testing.expectEqual(@as(f32, 2), b.width.pts());
    try std.testing.expectEqual(Color.rgb(0xff, 0, 0).toClay(), b.clay().color);
    try std.testing.expectEqual(@as(u16, 2), b.clay().width.left);
}

test "Radius translates to Clay's four corners" {
    const r = Radius.all(6);
    const c = r.clay();
    try std.testing.expectEqual(@as(f32, 6), c.top_left);
    try std.testing.expectEqual(@as(f32, 6), c.bottom_right);
    try std.testing.expectEqual(@as(f32, 0), (Radius{}).clay().top_left);
    // A corner is a length, so it keeps its fraction instead of being rounded.
    try std.testing.expectEqual(@as(f32, 2.5), (Radius{ .top_left = .{ .px = 2.5 } }).clay().top_left);
}

test "Size covers fit, grow, fixed, percent and a clamp on either axis" {
    const fit: Size = .fit;
    const grow: Size = .grow;
    try std.testing.expectEqual(cl.SizingType.fit, fit.clay().type);
    try std.testing.expectEqual(cl.SizingType.grow, grow.clay().type);
    try std.testing.expectEqual(@as(f32, 40), Size.px(40).clay().size.minmax.min);
    try std.testing.expectEqual(@as(f32, 0.5), Size.pct(0.5).clay().size.minmax.min);
    // A clamp keeps the min/max the old props carried, on either the fit or the grow path.
    try std.testing.expectEqual(@as(f32, 24), Size.between(24, 40).clay().size.minmax.min);
    try std.testing.expectEqual(cl.SizingType.grow, Size.growing(100, 400).clay().type);
}
