// The headless half of the devtool: parse a command line, run an app with no window, act on it, and print the tree.
const std = @import("std");
const cl = @import("zclay");
const host_mod = @import("../host.zig");
const testing = @import("../testing/root.zig");
const finders = @import("../testing/finders.zig");
const dispatch = @import("../components/dispatch.zig");
const snapshot_mod = @import("snapshot.zig");

// How many `--do` actions one run takes, in order.
pub const max_actions = 16;

// Frames a long press holds the button down for: the app sees a press that outlasts a click.
const long_press_frames = 12;

// What the CLI can do to a component. The tag is how it names one, the same tag the tree prints.
pub const ActionKind = enum { click, longpress, press, release, move, scroll, drag, type_text, key };

pub const Action = struct {
    kind: ActionKind = .click,
    // The component's tag, or `@x,y` for a raw point.
    target: []const u8 = "",
    // Whatever the kind needs: `dx,dy` for scroll and drag, the text for type, nothing for the rest.
    args: []const u8 = "",
};

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
    // The actions to play before the tree is read, in order.
    actions: [max_actions]Action = [_]Action{.{}} ** max_actions,
    action_count: usize = 0,
    // A `--do` value the parser did not understand: reported once, rather than silently ignored.
    bad_action: bool = false,
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
        } else if (argValue(a, "--do", args, &i)) |v| {
            if (parseAction(v)) |action| {
                if (opts.action_count < max_actions) {
                    opts.actions[opts.action_count] = action;
                    opts.action_count += 1;
                }
                // An action asks for the tree afterwards, because that is where its effect shows.
                opts.dump = true;
            } else {
                opts.bad_action = true;
            }
        } else if (argValue(a, "--size", args, &i)) |v| {
            if (std.mem.indexOfScalar(u8, v, 'x')) |x| {
                opts.width = std.fmt.parseInt(u32, v[0..x], 10) catch opts.width;
                opts.height = std.fmt.parseInt(u32, v[x + 1 ..], 10) catch opts.height;
                opts.size_given = true;
            }
        } else if (argValue(a, "--pick", args, &i)) |v| {
            if (parsePoint(v)) |p| {
                opts.pick = p;
                opts.dump = true;
            }
        }
    }
    return opts;
}

// `kind:TAG` or `kind:TAG:ARGS` — the tag is the one the tree prints, so a value the tree showed is a value this accepts.
pub fn parseAction(value: []const u8) ?Action {
    const first = std.mem.indexOfScalar(u8, value, ':') orelse value.len;
    const kind_text = value[0..first];
    const rest = if (first < value.len) value[first + 1 ..] else "";
    const kind = std.meta.stringToEnum(ActionKind, kind_text) orelse
        (if (eq(kind_text, "type")) ActionKind.type_text else return null);
    // The args run to the end, so text may contain a colon but not a bare `:` separator of its own.
    const second = std.mem.indexOfScalar(u8, rest, ':') orelse rest.len;
    return .{
        .kind = kind,
        .target = rest[0..second],
        .args = if (second < rest.len) rest[second + 1 ..] else "",
    };
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

// `X,Y`, the point a `@x,y` target names and the delta a drag or a scroll takes.
pub fn parsePoint(text: []const u8) ?cl.Vector2 {
    const comma = std.mem.indexOfScalar(u8, text, ',') orelse return null;
    const x = std.fmt.parseFloat(f32, text[0..comma]) catch return null;
    const y = std.fmt.parseFloat(f32, text[comma + 1 ..]) catch return null;
    return .{ .x = x, .y = y };
}

// Run the app headless, play the actions in order, then write its tree. This is the whole CLI: an agent reads the same nodes the window draws.
pub fn run(
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

    // Settle first: one frame lays out, the rest let scroll offsets and hovers resolve.
    var i: usize = 1;
    while (i < opts.frames) : (i += 1) driver.frame();

    if (opts.bad_action) {
        std.debug.print("glinlandui-inspect: a --do value was not understood (see --help)\n", .{});
        std.process.exit(2);
    }
    for (opts.actions[0..opts.action_count]) |action| {
        perform(&driver, action) catch |err| {
            std.debug.print("glinlandui-inspect: {s} {s}: {s}\n", .{ @tagName(action.kind), action.target, @errorName(err) });
            std.process.exit(2);
        };
    }

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

// Where an action's target is: a tag resolved to the node's VISIBLE centre, so a clipped row is hit where it shows, or `@x,y` as-is.
pub fn targetOf(action: Action) !cl.Vector2 {
    if (std.mem.startsWith(u8, action.target, "@")) return parsePoint(action.target[1..]) orelse error.BadPoint;
    return (try finders.findSole(.{ .tag = action.target })).visibleCenter();
}

// The instant half of an action, through the app's own pointer and key path: nothing is faked, the app's handlers run. The caller runs the frame that shows it.
pub fn performOn(host: *host_mod.Host, action: Action, at: cl.Vector2) !void {
    switch (action.kind) {
        .click => {
            host.onPointerEvent(at.x, at.y, true, dispatch.BTN_LEFT);
            host.onPointerEvent(at.x, at.y, false, dispatch.BTN_LEFT);
        },
        .press => host.onPointerEvent(at.x, at.y, true, dispatch.BTN_LEFT),
        .release => host.onPointerEvent(at.x, at.y, false, dispatch.BTN_LEFT),
        .move => host.onPointerEvent(at.x, at.y, false, 0),
        .scroll => {
            const d = parsePoint(action.args) orelse return error.BadDelta;
            host.onPointerEvent(at.x, at.y, false, 0);
            host.onScrollEvent(d.x, d.y);
        },
        .drag => {
            const d = parsePoint(action.args) orelse return error.BadDelta;
            host.onPointerEvent(at.x, at.y, true, dispatch.BTN_LEFT);
            host.onPointerEvent(at.x + d.x, at.y + d.y, false, 0);
            host.onPointerEvent(at.x + d.x, at.y + d.y, false, dispatch.BTN_LEFT);
        },
        .type_text => {
            // Focus first: typing goes to the focused field, exactly as a user's caret does.
            host.onPointerEvent(at.x, at.y, true, dispatch.BTN_LEFT);
            host.onPointerEvent(at.x, at.y, false, dispatch.BTN_LEFT);
            for (action.args) |byte| {
                const k = testing.keyForAscii(byte) orelse return error.UnsupportedCharacter;
                if (k.shift) _ = host.onKeyEvent(testing.key_shift, true);
                _ = host.onKeyEvent(k.code, true);
                _ = host.onKeyEvent(k.code, false);
                if (k.shift) _ = host.onKeyEvent(testing.key_shift, false);
            }
        },
        // The two kinds the callers own: a key needs no point, and a hold spans frames.
        .key, .longpress => unreachable,
    }
}

// One action for the headless run: resolve, fire, and run the frame that shows the result.
fn perform(driver: *testing.Driver, action: Action) !void {
    if (action.kind == .key) {
        const code = std.fmt.parseInt(u32, action.target, 10) catch return error.BadKeyCode;
        _ = try driver.key(code);
        return;
    }
    // The service keeps a press down across frames; here the driver can simply run them.
    const at = try targetOf(action);
    if (action.kind == .longpress) {
        driver.pressAt(at.x, at.y);
        var i: usize = 0;
        while (i < long_press_frames) : (i += 1) driver.frame();
        driver.releaseAt(at.x, at.y);
        return;
    }
    try performOn(driver.host, action, at);
    driver.frame();
}

pub const usage =
    \\glinlandui-inspect: read and drive an app's component tree without a window.
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
    \\  --do=ACTION         act on a component before the tree is printed; repeatable, in order
    \\  -h, --help          this text
    \\
    \\ACTIONS, each `kind:TAG` or `kind:TAG:ARGS` (TAG is the id the tree prints, or @x,y):
    \\
    \\  click:TAG           press and release it
    \\  longpress:TAG       hold the press, then release
    \\  press:TAG           press only
    \\  release:TAG         release only
    \\  move:TAG            move the pointer onto it
    \\  scroll:TAG:DX,DY    wheel over it, in points
    \\  drag:TAG:DX,DY      press on it and drag by DX,DY
    \\  type:TAG:TEXT       focus it, then type TEXT
    \\  key:CODE            press and release an evdev key code (1 is Escape)
    \\
    \\The actions run in one process, and the tree is printed after the last of them, so their effect is visible:
    \\
    \\  zig build inspect -- --app=todo --do=type:todo.field:buy milk --do=key:36
    \\
;

test "a bare command line names the demo and dumps nothing" {
    const opts = parse(&.{"glinlandui-inspect"});
    try std.testing.expect(!opts.dump);
    try std.testing.expect(!opts.json);
    try std.testing.expectEqualStrings("demo", opts.app);
    try std.testing.expectEqual(@as(?cl.Vector2, null), opts.pick);
    try std.testing.expectEqual(@as(?[]const u8, null), opts.shot);
    try std.testing.expectEqual(@as(usize, 0), opts.action_count);
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

test "actions are collected in order, each with the arguments its kind needs" {
    const opts = parse(&.{
        "app",
        "--do=click:demo.btn",
        "--do=scroll:demo.list:0,-120.5",
        "--do=type:todo.field:buy milk",
        "--do=key:36",
    });
    try std.testing.expect(opts.dump);
    try std.testing.expectEqual(@as(usize, 4), opts.action_count);
    try std.testing.expectEqual(ActionKind.click, opts.actions[0].kind);
    try std.testing.expectEqualStrings("demo.btn", opts.actions[0].target);
    try std.testing.expectEqual(ActionKind.scroll, opts.actions[1].kind);
    try std.testing.expectEqualStrings("0,-120.5", opts.actions[1].args);
    try std.testing.expectEqual(ActionKind.type_text, opts.actions[2].kind);
    try std.testing.expectEqualStrings("buy milk", opts.actions[2].args);
    try std.testing.expectEqual(ActionKind.key, opts.actions[3].kind);
    try std.testing.expectEqualStrings("36", opts.actions[3].target);
}

test "an action with no tag, or one the parser does not know, is reported instead of ignored" {
    const bare = parse(&.{ "app", "--do=click" });
    try std.testing.expectEqual(@as(usize, 1), bare.action_count);
    try std.testing.expectEqualStrings("", bare.actions[0].target);

    const wrong = parse(&.{ "app", "--do=explode:demo.btn" });
    try std.testing.expect(wrong.bad_action);
    try std.testing.expectEqual(@as(usize, 0), wrong.action_count);
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

// ---- An app to act on ----

const components = struct {
    const box_mod = @import("../components/box.zig");
    const button_mod = @import("../components/button.zig");
    const toggle_mod = @import("../components/toggle.zig");
};

const ActApp = struct {
    on: bool = false,
    clicks: u32 = 0,

    fn root(ctx: ?*anyopaque, _: u32, _: u32) void {
        components.box_mod.box(.{
            .id = .{ .text = "act.root" },
            .direction = .column,
            .w = .grow,
            .h = .grow,
        }, ctx, children);
    }

    fn children(ctx: ?*anyopaque) void {
        const self: *ActApp = @ptrCast(@alignCast(ctx.?));
        components.toggle_mod.toggle(.{
            .id = .{ .text = "act.toggle" },
            .on = self.on,
            .on_click = .{ .f = onToggle, .ctx = self },
        });
        components.button_mod.button(.{
            .id = .{ .text = "act.button" },
            .label = .{ .text = "Go" },
            .w = .{ .fixed = 80 },
            .h = .{ .fixed = 30 },
            .on_click = .{ .f = onButton, .ctx = self },
        });
    }

    fn onToggle(ctx: ?*anyopaque) void {
        const self: *ActApp = @ptrCast(@alignCast(ctx.?));
        self.on = !self.on;
    }

    fn onButton(ctx: ?*anyopaque) void {
        const self: *ActApp = @ptrCast(@alignCast(ctx.?));
        self.clicks += 1;
    }
};

fn runInto(alloc: std.mem.Allocator, argv: []const []const u8, app: *ActApp, out: []u8) ![]const u8 {
    const opts = parse(argv);
    var w = std.Io.Writer.fixed(out);
    try run(alloc, opts, app, ActApp.root, &w);
    return w.buffered();
}

test "an action reaches the app's own handler, and the tree shows the result" {
    var app = ActApp{};
    var buf: [8192]u8 = undefined;
    const out = try runInto(std.heap.page_allocator, &.{ "app", "--do=click:act.toggle" }, &app, &buf);

    try std.testing.expect(app.on);
    // The toggle reports its checked state, so the dump is the evidence and not only the struct.
    try std.testing.expect(std.mem.indexOf(u8, out, "act.toggle") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "checked") != null);
}

test "a button click through the CLI is a real click, once per action" {
    var app = ActApp{};
    var buf: [8192]u8 = undefined;
    _ = try runInto(std.heap.page_allocator, &.{ "app", "--do=click:act.button", "--do=click:act.button" }, &app, &buf);
    try std.testing.expectEqual(@as(u32, 2), app.clicks);
}

test "a point target needs no tag, and a long press holds the button down across frames" {
    var app = ActApp{};
    var buf: [8192]u8 = undefined;
    _ = try runInto(std.heap.page_allocator, &.{ "app", "--do=press:@10,10" }, &app, &buf);
    // A press alone fires nothing: the release is what a click is.
    try std.testing.expectEqual(@as(u32, 0), app.clicks);
    try std.testing.expect(app.on == false);

    var held = ActApp{};
    _ = try runInto(std.heap.page_allocator, &.{ "app", "--do=longpress:act.button" }, &held, &buf);
    try std.testing.expectEqual(@as(u32, 1), held.clicks);
}
