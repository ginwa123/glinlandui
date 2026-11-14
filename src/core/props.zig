// The vocabulary a widget's props are written in.

// Every field of a props struct is one of these or a plain flag: an id, a label, padding, a border, a radius and a size.

// Each carries its own defaults and its own Clay translation, so no component re-derives them and no caller passes a bare number where a meaning belongs.
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

// A run of text: what it says, how big it is, and what colour it is drawn in.
pub const Label = struct {
    text: []const u8 = "",
    size: u16 = 14,
    color: Color = Color.rgb(0xe8, 0xe8, 0xe8),

    pub fn of(text: []const u8) Label {
        return .{ .text = text };
    }

    pub fn sized(self: Label, size: u16) Label {
        var next = self;
        next.size = size;
        return next;
    }

    pub fn colored(self: Label, color: Color) Label {
        var next = self;
        next.color = color;
        return next;
    }
};

// Padding on four sides. `all` and `axes` cover almost every call.
pub const Pad = struct {
    top: u16 = 0,
    right: u16 = 0,
    bottom: u16 = 0,
    left: u16 = 0,

    pub fn all(v: u16) Pad {
        return .{ .top = v, .right = v, .bottom = v, .left = v };
    }

    pub fn axes(tb: u16, lr: u16) Pad {
        return .{ .top = tb, .right = lr, .bottom = tb, .left = lr };
    }

    pub fn sides(top: u16, right: u16, bottom: u16, left: u16) Pad {
        return .{ .top = top, .right = right, .bottom = bottom, .left = left };
    }

    pub fn clay(self: Pad) cl.Padding {
        return .{ .top = self.top, .right = self.right, .bottom = self.bottom, .left = self.left };
    }
};

// A border: a width and the colour it is drawn in. Width 0 draws nothing.
pub const Border = struct {
    width: u16 = 0,
    color: Color = Color.rgb(0x00, 0x00, 0x00),

    pub fn all(width: u16, color: Color) Border {
        return .{ .width = width, .color = color };
    }

    pub fn clay(self: Border) cl.BorderElementConfig {
        if (self.width == 0) return .{};
        return .{ .color = self.color.toClay(), .width = .outside(self.width) };
    }
};

// A corner radius in points. `all` is the uniform case; the four fields are there for the rest.
pub const Radius = struct {
    top_left: u16 = 0,
    top_right: u16 = 0,
    bottom_left: u16 = 0,
    bottom_right: u16 = 0,

    pub fn all(v: u16) Radius {
        return .{ .top_left = v, .top_right = v, .bottom_left = v, .bottom_right = v };
    }

    pub fn clay(self: Radius) cl.CornerRadius {
        return .{
            .top_left = @floatFromInt(self.top_left),
            .top_right = @floatFromInt(self.top_right),
            .bottom_left = @floatFromInt(self.bottom_left),
            .bottom_right = @floatFromInt(self.bottom_right),
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
    try std.testing.expectEqual(@as(u16, 20), l.size);
    try std.testing.expectEqual(Color.rgb(1, 2, 3), l.color);
    // The defaults are a readable body size on a dark surface.
    try std.testing.expectEqual(@as(u16, 14), (Label{}).size);
}

test "Pad has one value per side, and the two shortcuts agree with it" {
    const a = Pad.all(4);
    try std.testing.expectEqual(@as(u16, 4), a.top);
    try std.testing.expectEqual(@as(u16, 4), a.left);
    const b = Pad.axes(2, 6);
    try std.testing.expectEqual(@as(u16, 2), b.top);
    try std.testing.expectEqual(@as(u16, 2), b.bottom);
    try std.testing.expectEqual(@as(u16, 6), b.left);
    try std.testing.expectEqual(@as(u16, 6), b.right);
    try std.testing.expectEqual(@as(u16, 0), (Pad{}).top);
}

test "Border draws nothing at width 0, and a colour at any other width" {
    try std.testing.expectEqual(cl.BorderElementConfig{}, (Border{}).clay());
    const b = Border.all(2, Color.rgb(0xff, 0, 0));
    try std.testing.expectEqual(@as(u16, 2), b.width);
    try std.testing.expectEqual(Color.rgb(0xff, 0, 0).toClay(), b.clay().color);
}

test "Radius translates to Clay's four corners" {
    const r = Radius.all(6);
    const c = r.clay();
    try std.testing.expectEqual(@as(f32, 6), c.top_left);
    try std.testing.expectEqual(@as(f32, 6), c.bottom_right);
    try std.testing.expectEqual(@as(f32, 0), (Radius{}).clay().top_left);
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
