// The part of Compose's `Modifier` this toolkit maps onto: padding, fill, and weight.
// glinlandui lays out in logical points, which are the `dp` a Compose app would write, so a number here is the
// value inside `16.dp`. A Modifier is a value you chain and then fold into a widget's props — it never draws.
const std = @import("std");
const glinlandui = @import("glinlandui");
const box_mod = glinlandui.components.box;

pub const Modifier = struct {
    pad: f32 = 0,
    fill_width: bool = false,
    fill_height: bool = false,
    // `Modifier.weight(1f)`: grow along the PARENT's main axis, which is why `apply` is told the parent.
    weight_factor: f32 = 0,

    // `Modifier.padding(16.dp)`
    pub fn padding(self: Modifier, v: f32) Modifier {
        var next = self;
        next.pad = v;
        return next;
    }

    // `Modifier.fillMaxWidth()`
    pub fn fillMaxWidth(self: Modifier) Modifier {
        var next = self;
        next.fill_width = true;
        return next;
    }

    // `Modifier.fillMaxSize()`
    pub fn fillMaxSize(self: Modifier) Modifier {
        var next = self;
        next.fill_width = true;
        next.fill_height = true;
        return next;
    }

    // `Modifier.weight(1f)`
    pub fn weight(self: Modifier, v: f32) Modifier {
        var next = self;
        next.weight_factor = v;
        return next;
    }

    // Fold the chain into a box's props. `parent` is the direction of the container this box sits in.
    pub fn apply(self: Modifier, props: box_mod.BoxProps, parent: box_mod.Direction) box_mod.BoxProps {
        var next = props;
        if (self.pad > 0) next.pad = @intFromFloat(self.pad);
        if (self.fill_width) next.w = .grow;
        if (self.fill_height) next.h = .grow;
        if (self.weight_factor > 0) {
            switch (parent) {
                .row => next.w = .grow,
                .column => next.h = .grow,
            }
        }
        return next;
    }
};

// A union has no `==`; its tag is what a test can assert on.
fn sizeIs(s: box_mod.Size, tag: std.meta.Tag(box_mod.Size)) bool {
    return std.meta.activeTag(s) == tag;
}

// ---- tests ---------------------------------------------------------------------------------------------------

test "an empty modifier changes nothing" {
    const props = box_mod.BoxProps{ .id = "x", .pad = 3 };
    const out = (Modifier{}).apply(props, .row);
    try std.testing.expectEqual(@as(u16, 3), out.pad);
    try std.testing.expect(sizeIs(out.w, .fit));
}

test "padding, fillMaxSize and weight land on the axes they name" {
    const padded = (Modifier{}).padding(16).apply(.{ .id = "x" }, .column);
    try std.testing.expectEqual(@as(u16, 16), padded.pad);

    const full = (Modifier{}).fillMaxSize().apply(.{ .id = "x" }, .column);
    try std.testing.expect(sizeIs(full.w, .grow));
    try std.testing.expect(sizeIs(full.h, .grow));

    // weight grows along the parent's main axis, and only that axis.
    const in_row = (Modifier{}).weight(1).apply(.{ .id = "x" }, .row);
    try std.testing.expect(sizeIs(in_row.w, .grow));
    try std.testing.expect(sizeIs(in_row.h, .fit));

    const in_column = (Modifier{}).weight(1).apply(.{ .id = "x" }, .column);
    try std.testing.expect(sizeIs(in_column.h, .grow));
    try std.testing.expect(sizeIs(in_column.w, .fit));
}
