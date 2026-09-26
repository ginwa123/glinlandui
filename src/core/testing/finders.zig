//! Matchers for the semantics tree — the `onNodeWithText` / `hasClickAction`
//! half of the E2E API.
//!
//! Shape note: Compose composes matchers (`hasText("x") and hasClickAction()`)
//! over an object graph. Here a matcher is a DECLARATIVE query struct: unset
//! fields do not constrain, so the common case reads as one literal and needs
//! no allocation, no vtable and no allocator in the test path:
//!
//!     driver.onNode(.{ .label = "Save", .has_click_action = true })
//!
//! Imports: std + the sibling semantics module ONLY (layering R1-R3, R6).
const std = @import("std");
const cl = @import("zclay");
const sm = @import("../semantics.zig");

/// A declarative query. `null` means "do not constrain on this field".
pub const Query = struct {
    tag: ?[]const u8 = null,
    label: ?[]const u8 = null,
    value: ?[]const u8 = null,
    role: ?sm.Role = null,
    has_click_action: ?bool = null,
    has_scroll_action: ?bool = null,
    set_text_action: ?bool = null,
    enabled: ?bool = null,
    checked: ?bool = null,
    selected: ?bool = null,
    hidden: ?bool = null,
    /// true  -> only nodes with visible_fraction > 0
    /// false -> only nodes fully clipped out of view
    displayed: ?bool = null,
    /// Which match to select when several match. When unset, `findSole`
    /// enforces Compose's onNode() contract: exactly one match or an error.
    index: ?usize = null,

    pub fn matches(q: Query, n: *const sm.Node) bool {
        if (q.tag) |t| if (!std.mem.eql(u8, t, n.tag)) return false;
        if (q.label) |t| if (!std.mem.eql(u8, t, n.label)) return false;
        if (q.value) |t| if (!std.mem.eql(u8, t, n.value)) return false;
        if (q.role) |r| if (r != n.role) return false;
        if (q.has_click_action) |v| if (v != n.actions.click) return false;
        if (q.has_scroll_action) |v| if (v != n.actions.scroll) return false;
        if (q.set_text_action) |v| if (v != n.actions.set_text) return false;
        if (q.enabled) |v| if (v != n.flags.enabled) return false;
        if (q.checked) |v| if (v != n.flags.checked) return false;
        if (q.selected) |v| if (v != n.flags.selected) return false;
        if (q.hidden) |v| if (v != n.flags.hidden) return false;
        if (q.displayed) |v| if (v != (n.visible_fraction > 0)) return false;
        return true;
    }
};

pub const FindError = error{
    /// Nothing in the last resolved frame matched.
    NoNodeFound,
    /// `index` pointed past the last match (there WERE matches).
    NoNodeAtIndex,
    /// More than one node matched and no `index` was given. Compose raises the
    /// same way: `onNode` is a single-node handle, and silently picking the
    /// first match hides a genuine test bug.
    TooManyNodes,
};

/// The `index`-th match (default 0) in the CURRENT frame.
pub fn findOne(q: Query) FindError!sm.Node {
    const want = q.index orelse 0;
    var seen: usize = 0;
    for (sm.all()) |*n| {
        if (!q.matches(n)) continue;
        if (seen == want) return n.*;
        seen += 1;
    }
    // "Nothing matched" and "index past the last match" are different test
    // bugs (a missing widget vs. a wrong index), so they get different errors.
    return if (seen == 0) error.NoNodeFound else error.NoNodeAtIndex;
}

/// Compose's onNode() contract: exactly one match, unless `index` is set.
pub fn findSole(q: Query) FindError!sm.Node {
    if (q.index != null) return findOne(q);
    var found: ?sm.Node = null;
    for (sm.all()) |*n| {
        if (!q.matches(n)) continue;
        if (found != null) return error.TooManyNodes;
        found = n.*;
    }
    return found orelse error.NoNodeFound;
}

/// How many nodes match. Used by `onAllNodes` and count assertions.
pub fn count(q: Query) usize {
    var c: usize = 0;
    for (sm.all()) |*n| {
        if (q.matches(n)) c += 1;
    }
    return c;
}

// ---- Test doubles ----
//
// The matcher layer is pure over the registry, so its tests need no Clay
// context at all: register nodes directly and query them.

fn seed() void {
    sm.beginFrame();
    sm.register(.{
        .id = cl_str("save"),
        .tag = "save",
        .role = .button,
        .label = "Save",
        .actions = .{ .click = true },
    });
    sm.register(.{
        .id = cl_str("cancel"),
        .tag = "cancel",
        .role = .button,
        .label = "Cancel",
        .flags = .{ .enabled = false },
    });
    sm.register(.{
        .id = cl_str("field"),
        .tag = "field",
        .role = .text_field,
        .value = "12",
        .actions = .{ .set_text = true },
    });
    sm.register(.{
        .id = cl_str("check"),
        .tag = "check",
        .role = .checkbox,
        .flags = .{ .checked = true },
    });
    // Two nodes sharing a label, to exercise ambiguity.
    sm.register(.{ .id = cl_str("dup-a"), .tag = "dup-a", .label = "Same" });
    sm.register(.{ .id = cl_str("dup-b"), .tag = "dup-b", .label = "Same" });
}

fn cl_str(s: []const u8) cl.ElementId {
    return cl.getElementId(s);
}

test "findOne matches on tag, label, role and action" {
    seed();
    try std.testing.expectEqualStrings("Save", (try findOne(.{ .tag = "save" })).label);
    try std.testing.expectEqualStrings("save", (try findOne(.{ .label = "Save" })).tag);
    try std.testing.expectEqual(sm.Role.text_field, (try findOne(.{ .role = .text_field })).role);
    try std.testing.expectEqualStrings("field", (try findOne(.{ .set_text_action = true })).tag);
    try std.testing.expectEqualStrings("save", (try findOne(.{ .has_click_action = true })).tag);
    try std.testing.expectEqualStrings("field", (try findOne(.{ .value = "12" })).tag);
    try std.testing.expectEqualStrings("check", (try findOne(.{ .checked = true })).tag);
}

test "an unset query matches everything (no constraints)" {
    seed();
    try std.testing.expectEqual(@as(usize, 6), count(.{}));
}

test "findOne reports NoNodeFound when nothing matches" {
    seed();
    try std.testing.expectError(error.NoNodeFound, findOne(.{ .tag = "nope" }));
    // A field that is set on some node but never in this combination.
    try std.testing.expectError(error.NoNodeFound, findOne(.{ .role = .button, .checked = true }));
}

test "findOne reports NoNodeAtIndex past the last match" {
    seed();
    // One node is a text_field, so index 1 must fail with the DISTINCT error.
    try std.testing.expectError(error.NoNodeAtIndex, findOne(.{ .role = .text_field, .index = 1 }));
    _ = try findOne(.{ .role = .text_field, .index = 0 });
}

test "findSole refuses an ambiguous match" {
    seed();
    try std.testing.expectError(error.TooManyNodes, findSole(.{ .label = "Same" }));
}

test "findSole resolves ambiguity once an index is given" {
    seed();
    const a = try findSole(.{ .label = "Same", .index = 0 });
    const b = try findSole(.{ .label = "Same", .index = 1 });
    try std.testing.expectEqualStrings("dup-a", a.tag);
    try std.testing.expectEqualStrings("dup-b", b.tag);
    try std.testing.expect(a.id.id != b.id.id);
}

test "findSole succeeds for exactly one match" {
    seed();
    const n = try findSole(.{ .tag = "save" });
    try std.testing.expectEqual(sm.Role.button, n.role);
    try std.testing.expectError(error.NoNodeFound, findSole(.{ .tag = "nope" }));
}

test "a disabled node is still found but reports enabled = false" {
    seed();
    const n = try findSole(.{ .tag = "cancel" });
    try std.testing.expect(!n.flags.enabled);
    // And it carries no click action, because it never registered one.
    try std.testing.expect(!n.actions.click);
    try std.testing.expectEqual(@as(usize, 1), count(.{ .enabled = false }));
}

test "displayed filters on resolved visibility" {
    sm.beginFrame();
    // Bypass resolve (which needs a Clay layout): seed the derived field.
    var hidden = sm.Node{ .id = cl_str("d1"), .tag = "d1" };
    hidden.visible_fraction = 0;
    sm.register(hidden);
    var shown = sm.Node{ .id = cl_str("d2"), .tag = "d2" };
    shown.visible_fraction = 0.5;
    sm.register(shown);

    try std.testing.expectEqual(@as(usize, 1), count(.{ .displayed = true }));
    try std.testing.expectEqual(@as(usize, 1), count(.{ .displayed = false }));
    try std.testing.expectEqualStrings("d2", (try findSole(.{ .displayed = true })).tag);
    try std.testing.expectEqualStrings("d1", (try findSole(.{ .displayed = false })).tag);
}
