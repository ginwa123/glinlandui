//! Assertions over a resolved semantics node — the `assertIsDisplayed` /
//! `assertHasClickAction` half of the E2E API.
//!
//! Every function here is PURE over a `semantics.Node` value, so they are
//! unit-testable without a Clay context, and `testing/root.zig`'s
//! `Interaction` methods are thin wrappers that supply the node.
//!
//! Why `Node` by value and not by id: a node is a FRAME-SCOPED SNAPSHOT
//! (bounds and visibility do not exist until `endLayout` and change every
//! frame). Taking the value makes that explicit and forces callers to
//! re-resolve — which is exactly what Compose's SemanticsNodeInteraction does.
//!
//! Imports: std + the sibling semantics module ONLY (layering R1-R3, R6).
const std = @import("std");
const sm = @import("../semantics.zig");

/// Failure reasons. Naming rule: the error names what was FOUND, so a positive
/// assertion reports the missing state (`isDisplayed` -> `NotDisplayed`) and a
/// negative one reports the state that should not have been there
/// (`isNotDisplayed` -> `Displayed`). That keeps a bare `error.Displayed` in a
/// test log unambiguous about which direction failed.
pub const Error = error{
    // Display / existence
    NotDisplayed,
    Displayed,
    Hidden,
    Visible,
    // Actions
    NoClickAction,
    HasClickAction,
    NoScrollAction,
    // State
    Disabled,
    Enabled,
    NotSelected,
    Selected,
    NotChecked,
    Checked,
    // Identity
    LabelMismatch,
    ValueMismatch,
    TagMismatch,
    RoleMismatch,
};

pub fn isDisplayed(n: sm.Node) Error!void {
    if (!n.isDisplayed()) return error.NotDisplayed;
}

pub fn isNotDisplayed(n: sm.Node) Error!void {
    if (n.isDisplayed()) return error.Displayed;
}

/// The node exists in the tree and has real geometry (independent of clipping).
pub fn exists(n: sm.Node) Error!void {
    if (!n.found) return error.NotDisplayed;
}

pub fn isHidden(n: sm.Node) Error!void {
    if (!n.flags.hidden) return error.Visible;
}

pub fn hasClickAction(n: sm.Node) Error!void {
    if (!n.actions.click) return error.NoClickAction;
}

/// The complement: a node that must NOT be clickable (a label, a container, a
/// disabled control).
pub fn hasNoClickAction(n: sm.Node) Error!void {
    if (n.actions.click) return error.HasClickAction;
}

pub fn hasScrollAction(n: sm.Node) Error!void {
    if (!n.actions.scroll) return error.NoScrollAction;
}

pub fn hasSetTextAction(n: sm.Node) Error!void {
    if (!n.actions.set_text) return error.NoClickAction;
}

pub fn isEnabled(n: sm.Node) Error!void {
    if (!n.flags.enabled) return error.Disabled;
}

pub fn isDisabled(n: sm.Node) Error!void {
    if (n.flags.enabled) return error.Enabled;
}

pub fn isSelected(n: sm.Node) Error!void {
    if (!n.flags.selected) return error.NotSelected;
}

pub fn isNotSelected(n: sm.Node) Error!void {
    if (n.flags.selected) return error.Selected;
}

pub fn isChecked(n: sm.Node) Error!void {
    if (!n.flags.checked) return error.NotChecked;
}

pub fn isNotChecked(n: sm.Node) Error!void {
    if (n.flags.checked) return error.Checked;
}

pub fn labelEquals(n: sm.Node, expected: []const u8) Error!void {
    if (!std.mem.eql(u8, n.label, expected)) return error.LabelMismatch;
}

pub fn valueEquals(n: sm.Node, expected: []const u8) Error!void {
    if (!std.mem.eql(u8, n.value, expected)) return error.ValueMismatch;
}

pub fn tagEquals(n: sm.Node, expected: []const u8) Error!void {
    if (!std.mem.eql(u8, n.tag, expected)) return error.TagMismatch;
}

pub fn roleIs(n: sm.Node, expected: sm.Role) Error!void {
    if (n.role != expected) return error.RoleMismatch;
}

/// The node must be at least partially visible AND, when a minimum fraction is
/// given, at least that much of it. Useful for "the row is scrolled into view"
/// without demanding pixel-exact geometry.
pub fn visibleAtLeast(n: sm.Node, min_fraction: f32) Error!void {
    if (!n.isDisplayed() or n.visible_fraction < min_fraction) return error.NotDisplayed;
}

// ---- Test doubles ----

fn sample() sm.Node {
    return .{
        .id = @import("zclay").getElementId("a"),
        .tag = "a",
        .role = .button,
        .label = "Save",
        .value = "v",
        .found = true,
        .bounds = .{ .x = 0, .y = 0, .width = 10, .height = 10 },
        .clip = .{ .x = 0, .y = 0, .width = 10, .height = 10 },
        .visible_fraction = 1,
        .actions = .{ .click = true },
    };
}

test "a fully visible, enabled, clickable node passes the positive checks" {
    const n = sample();
    try isDisplayed(n);
    try exists(n);
    try hasClickAction(n);
    try isEnabled(n);
    try labelEquals(n, "Save");
    try valueEquals(n, "v");
    try tagEquals(n, "a");
    try roleIs(n, .button);
    try visibleAtLeast(n, 1.0);
    // ...and fails the negative complements, each naming what was found.
    try std.testing.expectError(error.Displayed, isNotDisplayed(n));
    // isDisabled on an ENABLED node reports error.Enabled (the state found),
    // not error.Disabled (the state required).
    try std.testing.expectError(error.Enabled, isDisabled(n));
    try std.testing.expectError(error.HasClickAction, hasNoClickAction(n));
}

test "a clipped-out node is not displayed and fails the positive check" {
    var n = sample();
    n.visible_fraction = 0;
    try std.testing.expectError(error.NotDisplayed, isDisplayed(n));
    try std.testing.expectError(error.NotDisplayed, visibleAtLeast(n, 0.01));
    try isNotDisplayed(n);
    // It still EXISTS: "not displayed" and "not in the tree" are different.
    try exists(n);
}

test "a node Clay never laid out is neither found nor displayed" {
    var n = sample();
    n.found = false;
    n.visible_fraction = 0;
    try std.testing.expectError(error.NotDisplayed, isDisplayed(n));
    try std.testing.expectError(error.NotDisplayed, exists(n));
}

test "hidden intent beats full geometry" {
    var n = sample();
    n.flags.hidden = true;
    try std.testing.expect(!n.isDisplayed());
    try std.testing.expectError(error.NotDisplayed, isDisplayed(n));
    try isHidden(n);
}

test "visibleAtLeast enforces a partial-visibility threshold" {
    var n = sample();
    n.visible_fraction = 0.25;
    try visibleAtLeast(n, 0.2);
    try std.testing.expectError(error.NotDisplayed, visibleAtLeast(n, 0.5));
    try isDisplayed(n);
}

test "checked / selected / enabled assertions are symmetric" {
    var n = sample();
    n.flags.checked = true;
    n.flags.selected = true;
    try isChecked(n);
    try isSelected(n);
    try std.testing.expectError(error.Checked, isNotChecked(n));
    try std.testing.expectError(error.Selected, isNotSelected(n));

    n.flags.checked = false;
    n.flags.selected = false;
    try isNotChecked(n);
    try isNotSelected(n);
    try std.testing.expectError(error.NotChecked, isChecked(n));
    try std.testing.expectError(error.NotSelected, isSelected(n));
}

test "label, value, tag and role mismatches are distinguishable" {
    const n = sample();
    try std.testing.expectError(error.LabelMismatch, labelEquals(n, "Cancel"));
    try std.testing.expectError(error.ValueMismatch, valueEquals(n, "other"));
    try std.testing.expectError(error.TagMismatch, tagEquals(n, "b"));
    try std.testing.expectError(error.RoleMismatch, roleIs(n, .checkbox));
}

test "scroll and set-text actions are asserted independently of click" {
    var n = sample();
    n.actions = .{ .scroll = true, .set_text = true };
    try hasScrollAction(n);
    try hasSetTextAction(n);
    try std.testing.expectError(error.NoClickAction, hasClickAction(n));
    n.actions = .{};
    try std.testing.expectError(error.NoScrollAction, hasScrollAction(n));
    try std.testing.expectError(error.NoClickAction, hasSetTextAction(n));
}
