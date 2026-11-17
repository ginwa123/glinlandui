//! The component façade: every widget the toolkit can draw, re-exported in one file (the rules are I6 in src/README.md).

const std = @import("std");

// Containers and primitives.
pub const box = @import("components/box.zig");
pub const text = @import("components/text.zig");
pub const caret = @import("components/caret.zig");
pub const icon = @import("components/icon.zig");
pub const image = @import("components/image.zig");
pub const badge = @import("components/badge.zig");

// Input.
pub const button = @import("components/button.zig");
pub const input = @import("components/input.zig");
pub const checkbox = @import("components/checkbox.zig");
pub const radio = @import("components/radio.zig");
pub const toggle = @import("components/toggle.zig");
pub const slider = @import("components/slider.zig");
pub const dropdown = @import("components/dropdown.zig");

// Collections.
pub const list = @import("components/list.zig");
pub const tree = @import("components/tree.zig");
pub const tabs = @import("components/tabs.zig");
pub const scroll = @import("components/scroll.zig");

// Layout: the surfaces an app frames its own content with.
pub const sidebar = @import("components/sidebar.zig");
pub const split = @import("components/split.zig");
pub const modal = @import("components/modal.zig");
pub const context_menu = @import("components/context_menu.zig");

// The single-line draft layer under `input`: a caller's bytes, a caret, a selection, and what each key does.
pub const input_draft = @import("components/input_draft.zig");

// The per-frame plumbing a pointer event travels through.
pub const click_registry = @import("components/click_registry.zig");
pub const dispatch = @import("components/dispatch.zig");
pub const focus = @import("components/focus.zig");
pub const reorder = @import("components/reorder.zig");

test {
    // Naming each one forces its file into this suite: a `pub const` alone is lazily analysed, so its tests would not run.
    _ = box;
    _ = text;
    _ = caret;
    _ = icon;
    _ = image;
    _ = badge;
    _ = button;
    _ = input;
    _ = input_draft;
    _ = checkbox;
    _ = radio;
    _ = toggle;
    _ = slider;
    _ = dropdown;
    _ = list;
    _ = tree;
    _ = tabs;
    _ = scroll;
    _ = sidebar;
    _ = split;
    _ = modal;
    _ = context_menu;
    _ = click_registry;
    _ = dispatch;
    _ = focus;
    _ = reorder;
    // Comptime names, so this is the façade's own inventory: a component that goes missing from it fails here.
    const decls = @typeInfo(@This()).@"struct".decls;
    try std.testing.expect(decls.len >= 25);
    try std.testing.expect(@hasDecl(box, "box"));
    try std.testing.expect(@hasDecl(button, "button"));
    try std.testing.expect(@hasDecl(input, "textField"));
}
