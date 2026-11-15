//! Which clipboard helper a Linux session should run. Pure: the facts come in, the plan comes out, and every OS can test it.
const std = @import("std");

// What the session offers: a compositor that speaks Wayland, an X server, and which helpers are on PATH.
pub const Session = struct {
    wayland: bool = false,
    x11: bool = false,
    wl_clipboard: bool = false,
    xclip: bool = false,
    xsel: bool = false,
};

// Which way the text moves: `copy` puts it on the selection, `paste` takes it off.
pub const Verb = enum { copy, paste };

// What to run: a program name, and the arguments it needs, each NUL-terminated so `execve` takes them unchanged.
pub const Plan = struct {
    exe: [:0]const u8,
    args: []const [:0]const u8,
};

// The session a pair of environment values describes: Wayland when WAYLAND_DISPLAY is set, X11 when DISPLAY is too.
pub fn sessionFrom(wayland_display: ?[]const u8, display: ?[]const u8) Session {
    return .{
        .wayland = present(wayland_display),
        .x11 = present(display),
    };
}

// An environment variable is set when it is set AND non-empty: `WAYLAND_DISPLAY=` is how a wrapper unsets it.
fn present(value: ?[]const u8) bool {
    const text = value orelse return false;
    return text.len > 0;
}

// The first helper that fits this session, or null when none is installed — a paste then reads nothing.
pub fn choose(session: Session, verb: Verb) ?Plan {
    // Wayland first when the compositor is there: on Wayland an X client still works, but only through XWayland.
    if (session.wayland and session.wl_clipboard) {
        return switch (verb) {
            .copy => .{ .exe = "wl-copy", .args = &.{} },
            .paste => .{ .exe = "wl-paste", .args = &.{"--no-newline"} },
        };
    }
    if (session.x11 and session.xclip) {
        return switch (verb) {
            .copy => .{ .exe = "xclip", .args = &.{ "-selection", "clipboard", "-in" } },
            .paste => .{ .exe = "xclip", .args = &.{ "-selection", "clipboard", "-out" } },
        };
    }
    if (session.x11 and session.xsel) {
        return switch (verb) {
            .copy => .{ .exe = "xsel", .args = &.{ "--clipboard", "--input" } },
            .paste => .{ .exe = "xsel", .args = &.{ "--clipboard", "--output" } },
        };
    }
    return null;
}

// ---- tests ---------------------------------------------------------------------------------------------------

fn exeOf(plan: ?Plan) []const u8 {
    const p = plan orelse return "";
    return p.exe;
}

fn argsOf(plan: ?Plan) []const []const u8 {
    const p = plan orelse return &.{};
    return p.args;
}

test "a Wayland session with wl-clipboard uses wl-copy and wl-paste" {
    const session = Session{ .wayland = true, .wl_clipboard = true };
    const copy = choose(session, .copy).?;
    try std.testing.expectEqualStrings("wl-copy", copy.exe);
    try std.testing.expectEqual(@as(usize, 0), copy.args.len);

    const paste = choose(session, .paste).?;
    try std.testing.expectEqualStrings("wl-paste", paste.exe);
    try std.testing.expectEqual(@as(usize, 1), paste.args.len);
    // Without `--no-newline` every paste would end with an extra newline.
    try std.testing.expectEqualStrings("--no-newline", paste.args[0]);
}

test "Wayland without wl-clipboard falls back to the X server through XWayland" {
    const session = Session{ .wayland = true, .x11 = true, .xclip = true };
    try std.testing.expectEqualStrings("xclip", exeOf(choose(session, .paste)));
}

test "xclip is preferred over xsel, and both address the clipboard selection" {
    const both = Session{ .x11 = true, .xclip = true, .xsel = true };
    try std.testing.expectEqualStrings("xclip", exeOf(choose(both, .copy)));
    try std.testing.expectEqualStrings("xclip", exeOf(choose(both, .paste)));

    const only_sel = Session{ .x11 = true, .xsel = true };
    try std.testing.expectEqualStrings("xsel", exeOf(choose(only_sel, .copy)));
    const copy = choose(only_sel, .copy).?;
    try std.testing.expectEqualStrings("--clipboard", copy.args[0]);
    try std.testing.expectEqualStrings("--input", copy.args[1]);
    const paste = choose(only_sel, .paste).?;
    try std.testing.expectEqualStrings("--output", paste.args[1]);
}

test "a helper installed for a display that is not there is not used" {
    // xclip on PATH with no DISPLAY: nothing can reach the X server, so there is no plan.
    try std.testing.expect(choose(.{ .xclip = true }, .copy) == null);
    // The same for wl-clipboard with no compositor.
    try std.testing.expect(choose(.{ .wl_clipboard = true }, .paste) == null);
    try std.testing.expect(choose(.{}, .paste) == null);
}

test "the session is read from the two display variables, and an empty one means absent" {
    const wayland = sessionFrom("wayland-0", null);
    try std.testing.expect(wayland.wayland);
    try std.testing.expect(!wayland.x11);

    const x11 = sessionFrom(null, ":0");
    try std.testing.expect(!x11.wayland);
    try std.testing.expect(x11.x11);

    const both = sessionFrom("wayland-1", ":1");
    try std.testing.expect(both.wayland and both.x11);

    // `WAYLAND_DISPLAY=` is how a wrapper unsets it; it is not a display.
    const unset = sessionFrom("", "");
    try std.testing.expect(!unset.wayland);
    try std.testing.expect(!unset.x11);
}

test "the plan carries the exact argv each helper documents" {
    const clip = Session{ .x11 = true, .xclip = true };
    const out = argsOf(choose(clip, .paste));
    try std.testing.expectEqual(@as(usize, 3), out.len);
    try std.testing.expectEqualStrings("-selection", out[0]);
    try std.testing.expectEqualStrings("clipboard", out[1]);
    try std.testing.expectEqualStrings("-out", out[2]);
}
