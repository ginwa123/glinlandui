// The headless half of the devtool: parse a command line, run an app without a window, and print its component tree.
const std = @import("std");
const cl = @import("zclay");
const host_mod = @import("../host.zig");
const testing = @import("../testing/root.zig");
const snapshot_mod = @import("snapshot.zig");

pub const Options = struct {
    // Print the tree instead of opening a window.
    dump: bool = false,
    // JSON for a program, text for a person.
    json: bool = false,
    // Frames to run before reading the tree: the first settles layout, the rest let scroll positions and hovers resolve.
    frames: usize = 3,
    width: u32 = 720,
    height: u32 = 480,
    // Whether --size was given, so an app's own default size survives when it was not.
    size_given: bool = false,
    // How many levels of children to serialise.
    depth: u16 = 16,
    // Report the node under one point instead of the whole tree.
    pick: ?cl.Vector2 = null,
    // Which app to run, by the name its spec uses.
    app: []const u8 = "demo",
    // Write the frame, devtool window up, to this TGA path instead of printing the tree.
    shot: ?[]const u8 = null,
    help: bool = false,
};

// A command line is argv including the program name; unknown flags are ignored so an app may keep its own.
pub fn parse(args: []const []const u8) Options {
    var opts = Options{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (eq(a, "--dump") or eq(a, "--inspect")) {
            opts.dump = true;
        } else if (eq(a, "--json")) {
            opts.json = true;
            opts.dump = true;
        } else if (eq(a, "--text")) {
            opts.json = false;
            opts.dump = true;
        } else if (eq(a, "--help") or eq(a, "-h")) {
            opts.help = true;
        } else if (number(u32, a, "--frames", args, &i)) |n| {
            opts.frames = @max(1, n);
        } else if (number(u16, a, "--depth", args, &i)) |n| {
            opts.depth = n;
        } else if (argValue(a, "--app", args, &i)) |v| {
            opts.app = v;
        } else if (argValue(a, "--shot", args, &i)) |v| {
            opts.shot = v;
        } else if (argValue(a, "--size", args, &i)) |v| {
            if (std.mem.indexOfScalar(u8, v, 'x')) |x| {
                opts.width = std.fmt.parseInt(u32, v[0..x], 10) catch opts.width;
                opts.height = std.fmt.parseInt(u32, v[x + 1 ..], 10) catch opts.height;
                opts.size_given = true;
            }
        } else if (argValue(a, "--pick", args, &i)) |v| {
            if (std.mem.indexOfScalar(u8, v, ',')) |comma| {
                const x = std.fmt.parseFloat(f32, v[0..comma]) catch continue;
                const y = std.fmt.parseFloat(f32, v[comma + 1 ..]) catch continue;
                opts.pick = .{ .x = x, .y = y };
                opts.dump = true;
            }
        }
    }
    return opts;
}

fn eq(a: []const u8, flag: []const u8) bool {
    return std.mem.eql(u8, a, flag);
}

// The value of `--flag=value`, or of `--flag value` which consumes the next token.
fn argValue(a: []const u8, flag: []const u8, args: []const []const u8, i: *usize) ?[]const u8 {
    if (a.len > flag.len + 1 and std.mem.startsWith(u8, a, flag) and a[flag.len] == '=') return a[flag.len + 1 ..];
    if (!std.mem.eql(u8, a, flag)) return null;
    if (i.* + 1 >= args.len) return null;
    i.* += 1;
    return args[i.*];
}

// A numeric flag in either spelling; a token that is not a number leaves the caller's default standing.
fn number(comptime T: type, a: []const u8, flag: []const u8, args: []const []const u8, i: *usize) ?T {
    const v = argValue(a, flag, args, i) orelse return null;
    return std.fmt.parseInt(T, v, 10) catch null;
}

// Run the app headless and write its tree. This is the whole CLI: an agent gets the same nodes the inspector draws.
pub fn dump(
    alloc: std.mem.Allocator,
    opts: Options,
    ctx: ?*anyopaque,
    root_fn: host_mod.RootFn,
    out: *std.Io.Writer,
) !void {
    var driver = try testing.Driver.initOwned(alloc, ctx, root_fn);
    defer driver.deinit();
    driver.headless = true;
    try driver.start(.{ .width = opts.width, .height = opts.height });
    var i: usize = 1;
    while (i < opts.frames) : (i += 1) driver.frame();

    const snap = snapshot_mod.Snapshot.build(opts.width, opts.height);
    if (opts.pick) |p| {
        if (opts.json) {
            try snap.writeJsonPick(out, p.x, p.y, .{ .depth = opts.depth, .pretty = true });
        } else {
            try snap.writeTextPick(out, p.x, p.y);
        }
        return;
    }
    if (opts.json) {
        try snap.writeJson(out, .{ .depth = opts.depth, .pretty = true });
    } else {
        try snap.writeText(out, opts.depth);
    }
}

pub const usage =
    \\glinlandui-inspect: read a running app's component tree without a window.
    \\
    \\  --app=NAME          which example app to run: demo, calculator, todo, catalog,
    \\                      file-dialog, lazy-scroll (default demo)
    \\  --dump, --inspect   print the tree
    \\  --json              JSON, for a program
    \\  --text              indented lines, for a person
    \\  --shot=PATH.tga     write the frame with the devtool window open, instead of the tree
    \\  --size=WxH          layout size (default: the app's own window size)
    \\  --frames=N          frames to run before reading (default 3)
    \\  --depth=N           levels of children to print (default 16)
    \\  --pick=X,Y          the node under one point, not the whole tree
    \\  -h, --help          this text
    \\
    \\In a running app the same tree is one right-click away: the examples attach
    \\the inspector, so "Inspect element" opens it over the app.
    \\
;

test "a bare command line names the demo and dumps nothing" {
    const opts = parse(&.{"glinlandui-inspect"});
    try std.testing.expect(!opts.dump);
    try std.testing.expect(!opts.json);
    try std.testing.expectEqualStrings("demo", opts.app);
    try std.testing.expectEqual(@as(?cl.Vector2, null), opts.pick);
    try std.testing.expectEqual(@as(?[]const u8, null), opts.shot);
}

test "--json implies a dump, because asking for JSON is asking for output" {
    const opts = parse(&.{ "glinlandui-inspect", "--json" });
    try std.testing.expect(opts.dump);
    try std.testing.expect(opts.json);
}

test "sizes, frame counts, depth and the app name are read in both flag spellings" {
    const opts = parse(&.{ "app", "--size=1024x768", "--frames", "9", "--depth=2", "--app", "catalog" });
    try std.testing.expectEqual(@as(u32, 1024), opts.width);
    try std.testing.expectEqual(@as(u32, 768), opts.height);
    try std.testing.expect(opts.size_given);
    try std.testing.expectEqual(@as(usize, 9), opts.frames);
    try std.testing.expectEqual(@as(u16, 2), opts.depth);
    try std.testing.expectEqualStrings("catalog", opts.app);
}

test "a pick point is parsed into coordinates, and asks for the tree" {
    const opts = parse(&.{ "app", "--pick", "120.5,80" });
    try std.testing.expect(opts.dump);
    try std.testing.expectApproxEqAbs(@as(f32, 120.5), opts.pick.?.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 80), opts.pick.?.y, 0.001);
}

test "a shot path is kept, and does not by itself ask for a dump" {
    const opts = parse(&.{ "app", "--shot=/tmp/frame.tga" });
    try std.testing.expectEqualStrings("/tmp/frame.tga", opts.shot.?);
    try std.testing.expect(!opts.dump);
}

test "flags an app owns are left alone, and a broken number keeps the default" {
    const opts = parse(&.{ "app", "--verbose", "--frames=soon", "--size=wide" });
    try std.testing.expectEqual(@as(usize, 3), opts.frames);
    try std.testing.expectEqual(@as(u32, 720), opts.width);
    try std.testing.expect(!opts.size_given);
    try std.testing.expect(!opts.dump);
}

test "the last spelling of a flag wins" {
    const opts = parse(&.{ "app", "--json", "--text" });
    try std.testing.expect(!opts.json);
    try std.testing.expect(opts.dump);
}
