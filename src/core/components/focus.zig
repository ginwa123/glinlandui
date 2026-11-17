// Keyboard focus: the order Tab walks, and the ring that says where it went (WCAG 2.2, SC 2.1.1, 2.1.2, 2.4.7).
const std = @import("std");
const cl = @import("zclay");
const frame = @import("../frame.zig");
const Color = @import("../color.zig").Color;

// How many focusable elements one frame may declare: past this the extra ones are unreachable by Tab, which beats a crash.
pub const capacity: usize = 256;

// Who draws an element's ring: the component (a text field colours it from its own props) or the Host, once, for everyone else.
pub const Ring = enum { host, component };

// One focusable element: its Clay id — a row's or a tab's id never had a string form — a label for a test to read, and its ring.
const Entry = struct {
    id: cl.ElementId = undefined,
    label: [48]u8 = undefined,
    label_len: usize = 0,
    ring: Ring = .host,
};

// This frame's order, in declaration order: rebuilt by `beginDeclare`, read by `advance` after the frame.
var order: [capacity]Entry = [_]Entry{.{}} ** capacity;
var count: usize = 0;

// The ring's Clay id offset under an element: 4 is free in every component that reserves indices (1 selection, 2 caret, 3 clip).
pub const ring_index: u32 = 4;

// The ring a focused element draws when nothing says otherwise: bright enough to read on any surface in the theme.
pub const ring_color: Color = Color.rgb(0x7a, 0xb8, 0xff);
pub const ring_width: u16 = 1;

// Start a frame: the components that declare below rebuild the order from scratch, so a screen that went away takes its order with it.
pub fn beginDeclare() void {
    count = 0;
}

// Put an element in the tab order. The Host draws its ring, so every focusable looks the same without per-component code.
pub fn declare(id: cl.ElementId, label: []const u8) void {
    put(id, label, .host);
}

// Put an element in the tab order when its COMPONENT draws the ring, so the Host does not draw a second one on top.
pub fn declareWithRing(id: cl.ElementId, label: []const u8) void {
    put(id, label, .component);
}

fn put(id: cl.ElementId, label: []const u8, ring: Ring) void {
    if (id.id == 0 or count >= capacity) return;
    for (order[0..count]) |*e| if (e.id.id == id.id) return;
    const e = &order[count];
    e.id = id;
    e.ring = ring;
    e.label_len = @min(label.len, e.label.len);
    @memcpy(e.label[0..e.label_len], label[0..e.label_len]);
    count += 1;
}

// How many elements Tab can reach this frame.
pub fn focusable() usize {
    return count;
}

// The label of the element at `index`, so a test can prove what Tab is about to do.
pub fn at(index: usize) []const u8 {
    return order[index].label[0..order[index].label_len];
}

// Where `id` sits in the order, or null when it is not focusable any more (its screen was popped, say).
fn indexOf(id: cl.ElementId) ?usize {
    for (order[0..count], 0..) |*e, i| if (e.id.id == id.id) return i;
    return null;
}

// The next element (or the previous one with Shift), wrapping at both ends: this is the whole keyboard route through a screen.
pub fn advance(back: bool) bool {
    if (count == 0) return false;
    const to = if (frame.focusedElement()) |current|
        if (indexOf(current)) |i| step(i, back) else start(back)
    else
        start(back);
    frame.setFocusElement(order[to].id);
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

// The element the Host owes a ring to: the focused one, when its component asked the Host to draw it.
pub fn hostRingElement() ?cl.ElementId {
    const current = frame.focusedElement() orelse return null;
    const i = indexOf(current) orelse return null;
    if (order[i].ring != .host) return null;
    return order[i].id;
}

// One floating box around an element's own rect. OUTSIDE it, so taking the keyboard moves no content, and floating, so a scroll clip cannot cut it.
pub fn drawRing(id: cl.ElementId, box: frame.Bounds, color: Color, width: u16, z: i16) void {
    if (box.width < 1 or box.height < 1 or width == 0) return;
    cl.UI()(.{
        .id = .{ .id = id.id, .offset = ring_index, .base_id = id.base_id, .string_id = id.string_id },
        .floating = .{
            .attach_to = .to_root,
            .offset = .{ .x = box.x, .y = box.y },
            // Above the element, and passthrough: a ring is a sign of where the keyboard is, never a target of its own.
            .z_index = z,
            .pointer_capture_mode = .passthrough,
        },
        .layout = .{ .sizing = .{ .w = .fixed(box.width), .h = .fixed(box.height) } },
        .border = .{ .color = color.toClay(), .width = .outside(width) },
    })({});
}

// ===================== tests =====================

test "Tab walks the order the frame declared, and wraps at both ends" {
    frame.resetFocus();
    beginDeclare();
    declare(cl.getElementId("one"), "one");
    declare(cl.getElementId("two"), "two");
    declare(cl.getElementId("three"), "three");
    try std.testing.expectEqual(@as(usize, 3), focusable());
    try std.testing.expectEqualStrings("one", at(0));

    try std.testing.expect(advance(false));
    try std.testing.expect(frame.isFocused("one"));
    _ = advance(false);
    try std.testing.expect(frame.isFocused("two"));
    _ = advance(false);
    _ = advance(false);
    try std.testing.expect(frame.isFocused("one"));
    _ = advance(true);
    try std.testing.expect(frame.isFocused("three"));
}

test "Shift+Tab with nothing focused starts at the end, Tab at the beginning" {
    frame.resetFocus();
    beginDeclare();
    declare(cl.getElementId("first"), "first");
    declare(cl.getElementId("last"), "last");
    _ = advance(true);
    try std.testing.expect(frame.isFocused("last"));
    frame.resetFocus();
    _ = advance(false);
    try std.testing.expect(frame.isFocused("first"));
}

test "a focus that is not in this frame's order starts the order again, instead of stalling" {
    frame.resetFocus();
    beginDeclare();
    declare(cl.getElementId("a"), "a");
    declare(cl.getElementId("b"), "b");
    frame.setFocus("closed-page-field");
    _ = advance(false);
    try std.testing.expect(frame.isFocused("a"));
}

test "an element declared twice is in the order once" {
    frame.resetFocus();
    beginDeclare();
    declare(cl.getElementId("a"), "a");
    declare(cl.getElementId("a"), "a");
    declare(cl.getElementId("b"), "b");
    try std.testing.expectEqual(@as(usize, 2), focusable());
}

test "a frame with nothing focusable moves nothing, so a dead end is not a trap" {
    frame.resetFocus();
    beginDeclare();
    try std.testing.expect(!advance(false));
    try std.testing.expect(frame.focusedElement() == null);
}

test "the Host owes a ring to a plain element and not to one that draws its own" {
    frame.resetFocus();
    beginDeclare();
    declareWithRing(cl.getElementId("field"), "field");
    declare(cl.getElementId("button"), "button");
    _ = advance(false);
    try std.testing.expect(hostRingElement() == null);
    _ = advance(false);
    try std.testing.expect(hostRingElement() != null);
}

test "a row id with no string form is focusable, and the ring lands on it" {
    frame.resetFocus();
    beginDeclare();
    const row = cl.ElementId.IDI("kurir.tree", 7);
    declare(row, "row");
    try std.testing.expect(advance(false));
    try std.testing.expect(frame.isFocusedElement(row));
    try std.testing.expectEqual(row.id, hostRingElement().?.id);
}
