const std = @import("std");

const glinlandui = @import("glinlandui");

pub fn main() !void {
    // Library demo entry: reference the surface so the exe build proves
    // the re-exports resolve; no compositor touched.
    _ = glinlandui.Window;
    _ = glinlandui.WindowConfig;
    _ = glinlandui.render;
    _ = glinlandui.text;
    std.debug.print("glinlandui library ok\n", .{});
}

test "glinlandui surface resolves" {
    _ = glinlandui.Window;
    _ = glinlandui.WindowConfig;
    _ = glinlandui.render;
    _ = glinlandui.text;
}
