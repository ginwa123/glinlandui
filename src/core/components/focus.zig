// Keyboard focus: the order Tab walks, so every control is reachable without a pointer and none of them is a trap (WCAG 2.2, SC 2.1.1 and 2.1.2).
const std = @import("std");
const frame = @import("../frame.zig");

// How many focusable elements one frame may declare: past this the extra ones are unreachable by Tab, which beats a crash.
pub const capacity: usize = 256;

// One focusable id, copied: a Tab press arrives between frames, so the order has to outlive the declare that filled it.
const Entry = struct {
    buf: [96]u8 = undefined,
    len: usize = 0,

    fn set(self: *Entry, id: []const u8) void {
        self.len = id.len;
        @memcpy(self.buf[0..self.len], id);
    }

    fn text(self: *const Entry) []const u8 {
        return self.buf[0..self.len];
    }

    fn is(self: *const Entry, id: []const u8) bool {
        return std.mem.eql(u8, self.text(), id);
    }
};

// This frame's order, in declaration order: rebuilt by `beginDeclare`, read by `advance` after the frame.
var order: [capacity]Entry = [_]Entry{.{}} ** capacity;
var count: usize = 0;

// Start a frame: the components that declare below rebuild the order from scratch, so a screen that went away takes its order with it.
pub fn beginDeclare() void {
    count = 0;
}

// Put an element in the tab order. A repeat (one field declared twice in a frame) keeps its first position, and a detached id is not in the order.
pub fn declare(id: []const u8) void {
    if (id.len == 0 or id.len > order[0].buf.len or count >= capacity) return;
    for (order[0..count]) |*e| if (e.is(id)) return;
    order[count].set(id);
    count += 1;
}

// How many elements Tab can reach this frame.
pub fn focusable() usize {
    return count;
}

// The element at `index` in this frame's order, so a test can prove what Tab is about to do.
pub fn at(index: usize) []const u8 {
    return order[index].text();
}

// Where `id` sits in the order, or null when it is not focusable any more (its screen was popped, say).
fn indexOf(id: []const u8) ?usize {
    for (order[0..count], 0..) |*e, i| if (e.is(id)) return i;
    return null;
}

// The next element (or the previous one with Shift), wrapping at both ends: this is the whole keyboard route through a screen.
pub fn advance(back: bool) bool {
    if (count == 0) return false;
    const to = if (frame.focusedId()) |current|
        if (indexOf(current)) |i| step(i, back) else start(back)
    else
        start(back);
    frame.setFocus(order[to].text());
    return true;
}

// Where Tab starts when the keyboard is not already on something focusable.
fn start(back: bool) usize {
    return if (back) count - 1 else 0;
}

fn step(index: usize, back: bool) usize {
    if (back) return if (index == 0) count - 1 else index - 1;
    return (index + 1) % count;
}

// ===================== tests =====================

test "Tab walks the order the frame declared, and wraps at both ends" {
    frame.resetFocus();
    beginDeclare();
    declare("one");
    declare("two");
    declare("three");
    try std.testing.expectEqual(@as(usize, 3), focusable());
    try std.testing.expectEqualStrings("one", at(0));

    try std.testing.expect(advance(false));
    try std.testing.expectEqualStrings("one", frame.focusedId().?);
    _ = advance(false);
    try std.testing.expectEqualStrings("two", frame.focusedId().?);
    _ = advance(false);
    _ = advance(false);
    try std.testing.expectEqualStrings("one", frame.focusedId().?);
    _ = advance(true);
    try std.testing.expectEqualStrings("three", frame.focusedId().?);
}

test "Shift+Tab with nothing focused starts at the end, Tab at the beginning" {
    frame.resetFocus();
    beginDeclare();
    declare("first");
    declare("last");
    _ = advance(true);
    try std.testing.expectEqualStrings("last", frame.focusedId().?);
    frame.resetFocus();
    _ = advance(false);
    try std.testing.expectEqualStrings("first", frame.focusedId().?);
}

test "a focus that is not in this frame's order starts the order again, instead of stalling" {
    frame.resetFocus();
    beginDeclare();
    declare("a");
    declare("b");
    frame.setFocus("closed-page-field");
    _ = advance(false);
    try std.testing.expectEqualStrings("a", frame.focusedId().?);
}

test "an element declared twice is in the order once" {
    frame.resetFocus();
    beginDeclare();
    declare("a");
    declare("a");
    declare("b");
    try std.testing.expectEqual(@as(usize, 2), focusable());
}

test "a frame with nothing focusable moves nothing, so a dead end is not a trap" {
    frame.resetFocus();
    beginDeclare();
    try std.testing.expect(!advance(false));
    try std.testing.expect(frame.focusedId() == null);
}

test "an empty or oversized id is left out of the order, never cut into another element's name" {
    frame.resetFocus();
    beginDeclare();
    declare("");
    declare("x" ** 120);
    declare("ok");
    try std.testing.expectEqual(@as(usize, 1), focusable());
    try std.testing.expectEqualStrings("ok", at(0));
}
