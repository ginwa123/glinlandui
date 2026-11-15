// glinlanduidp — the glinlandui debug process. An independent client: it imports nothing from the framework and drives a running app over its socket.
const std = @import("std");

// The names an app can serve under, which is what `devices` probes and what `-s` names.
const app_names = [_][]const u8{ "demo", "calculator", "todo", "catalog", "file-dialog", "lazy-scroll" };

const usage =
    \\glinlanduidp — the glinlandui debug process.
    \\
    \\Point it at a running glinlandui app and read or drive its components, the
    \\way adb does for a phone. The app serves itself when it is started with
    \\GLIN_DEVTOOLS=1; nothing else is needed, and this binary knows no app.
    \\
    \\USAGE
    \\  glinlanduidp <verb> [operands] [flags]
    \\
    \\VERBS
    \\  devices                list the apps that are serving right now
    \\  tree | json            the component tree, as indented lines or as JSON
    \\  pick X,Y               the node under one point
    \\  tap TAG | tap @X,Y     press and release it
    \\  longpress TAG          hold the press, then release
    \\  press | release TAG    one half of a click
    \\  move TAG               move the pointer onto it
    \\  scroll TAG DX,DY       wheel over it, in points
    \\  swipe TAG DX,DY        press on it and drag by DX,DY
    \\  text TAG TEXT          focus it, then type TEXT
    \\  key CODE               press and release an evdev key code (28 Enter, 1 Escape)
    \\  quit                   ask the app to close
    \\
    \\FLAGS
    \\  -s, --device=NAME      which app to talk to (default: the only one serving)
    \\  -h, --help             this text
    \\
    \\EXAMPLES
    \\  glinlanduidp devices
    \\  glinlanduidp tree
    \\  glinlanduidp tap todo.add
    \\  glinlanduidp text todo.field "buy milk"
    \\  glinlanduidp key 28
    \\
;

const Options = struct {
    verb: ?[]const u8 = null,
    a0: []const u8 = "",
    a1: []const u8 = "",
    device: ?[]const u8 = null,
    help: bool = false,
};

// A verb first, then its operands, then flags — the shape adb's own commands have.
fn parse(args: []const []const u8) Options {
    var opts = Options{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            opts.help = true;
        } else if (std.mem.eql(u8, a, "-s") or std.mem.eql(u8, a, "--device")) {
            if (i + 1 < args.len) {
                i += 1;
                opts.device = args[i];
            }
        } else if (std.mem.startsWith(u8, a, "--device=")) {
            opts.device = a["--device=".len..];
        } else if (std.mem.startsWith(u8, a, "-")) {
            // An unknown flag is the caller's mistake, and worth saying rather than ignoring.
            opts.verb = null;
            opts.help = true;
            return opts;
        } else if (opts.verb == null) {
            opts.verb = a;
        } else if (opts.a0.len == 0) {
            opts.a0 = a;
        } else if (opts.a1.len == 0) {
            opts.a1 = a;
        }
    }
    return opts;
}

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.page_allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const opts = parse(args);
    if (opts.help or opts.verb == null) {
        return print(io, usage);
    }
    const verb = opts.verb.?;
    if (std.mem.eql(u8, verb, "devices")) return devices(io);
    if (std.mem.eql(u8, verb, "help")) return print(io, usage);

    var line_buf: [192]u8 = undefined;
    const line = request(verb, opts, &line_buf) orelse {
        std.debug.print("glinlanduidp: {s} needs an operand (see --help)\n", .{verb});
        std.process.exit(2);
    };
    const name = opts.device orelse onlyDevice(io) orelse {
        std.debug.print("glinlanduidp: nothing is serving, or several are: name one with -s (see `glinlanduidp devices`)\n", .{});
        std.process.exit(2);
    };
    var out_buf: [8192]u8 = undefined;
    var out = std.Io.File.stdout().writer(io, &out_buf);
    talk(io, name, line, &out.interface) catch |err| {
        std.debug.print("glinlanduidp: {s}: {s}\n", .{ name, @errorName(err) });
        std.process.exit(2);
    };
    try out.interface.flush();
}

// The one line a verb becomes; the app's service parses the same spellings it prints.
fn request(verb: []const u8, opts: Options, buf: []u8) ?[]const u8 {
    if (std.mem.eql(u8, verb, "tree")) return "tree";
    if (std.mem.eql(u8, verb, "json")) return "json";
    if (std.mem.eql(u8, verb, "quit")) return "quit";
    if (std.mem.eql(u8, verb, "pick")) return std.fmt.bufPrint(buf, "pick {s}", .{opts.a0}) catch null;
    if (std.mem.eql(u8, verb, "tap") or std.mem.eql(u8, verb, "click")) return std.fmt.bufPrint(buf, "do click:{s}", .{opts.a0}) catch null;
    if (std.mem.eql(u8, verb, "longpress")) return std.fmt.bufPrint(buf, "do longpress:{s}", .{opts.a0}) catch null;
    if (std.mem.eql(u8, verb, "press")) return std.fmt.bufPrint(buf, "do press:{s}", .{opts.a0}) catch null;
    if (std.mem.eql(u8, verb, "release")) return std.fmt.bufPrint(buf, "do release:{s}", .{opts.a0}) catch null;
    if (std.mem.eql(u8, verb, "move")) return std.fmt.bufPrint(buf, "do move:{s}", .{opts.a0}) catch null;
    if (std.mem.eql(u8, verb, "scroll")) return std.fmt.bufPrint(buf, "do scroll:{s}:{s}", .{ opts.a0, opts.a1 }) catch null;
    if (std.mem.eql(u8, verb, "swipe") or std.mem.eql(u8, verb, "drag")) return std.fmt.bufPrint(buf, "do drag:{s}:{s}", .{ opts.a0, opts.a1 }) catch null;
    if (std.mem.eql(u8, verb, "text") or std.mem.eql(u8, verb, "type")) return std.fmt.bufPrint(buf, "do type:{s}:{s}", .{ opts.a0, opts.a1 }) catch null;
    if (std.mem.eql(u8, verb, "key")) return std.fmt.bufPrint(buf, "do key:{s}", .{opts.a0}) catch null;
    return null;
}

// One request per connection, and the app closes it when the answer is complete.
fn talk(io: std.Io, name: []const u8, line: []const u8, out: *std.Io.Writer) !void {
    var path_buf: [108]u8 = undefined;
    const path = socketPath(name, &path_buf) orelse return error.NameTooLong;
    const addr = try std.Io.net.UnixAddress.init(path);
    const stream = try addr.connect(io);
    defer stream.close(io);
    // The request is one line, and the app closes the connection when its answer is complete.
    var write_buf: [256]u8 = undefined;
    var w = stream.writer(io, &write_buf);
    try w.interface.writeAll(line);
    try w.interface.writeAll("\n");
    try w.interface.flush();
    var read_buf: [256]u8 = undefined;
    var r = stream.reader(io, &read_buf);
    _ = try r.interface.stream(out, .unlimited);
}

fn devices(io: std.Io) !void {
    var buf: [1024]u8 = undefined;
    var out = std.Io.File.stdout().writer(io, &buf);
    for (app_names) |name| {
        if (!alive(io, name)) continue;
        try out.interface.print("{s}\n", .{name});
    }
    try out.interface.flush();
}

// An app is alive when it answers: there is no registry to read, so each name is asked one small question.
fn alive(io: std.Io, name: []const u8) bool {
    var sink_buf: [256]u8 = undefined;
    var sink = std.Io.Writer.fixed(&sink_buf);
    talk(io, name, "pick 0,0", &sink) catch return false;
    return true;
}

// The only app that answers, or null when none or several do.
fn onlyDevice(io: std.Io) ?[]const u8 {
    var found: ?[]const u8 = null;
    for (app_names) |name| {
        if (!alive(io, name)) continue;
        if (found != null) return null;
        found = name;
    }
    return found;
}

// Where an app puts its socket: the runtime dir when there is one, so it is per-user and the session cleans it up.
fn socketPath(name: []const u8, buf: []u8) ?[]const u8 {
    const dir = if (std.c.getenv("XDG_RUNTIME_DIR")) |d| std.mem.span(d) else "/tmp";
    return std.fmt.bufPrint(buf, "{s}/glinlandui-{s}.sock", .{ dir, name }) catch null;
}

fn print(io: std.Io, text: []const u8) !void {
    var buf: [1024]u8 = undefined;
    var out = std.Io.File.stdout().writer(io, &buf);
    try out.interface.writeAll(text);
    try out.interface.flush();
}

test "a verb and its operands keep their order, and -s names the device" {
    const opts = parse(&.{ "dp", "text", "todo.field", "buy milk", "-s", "todo" });
    try std.testing.expectEqualStrings("text", opts.verb.?);
    try std.testing.expectEqualStrings("todo.field", opts.a0);
    try std.testing.expectEqualStrings("buy milk", opts.a1);
    try std.testing.expectEqualStrings("todo", opts.device.?);
}

test "the verbs spell the same protocol the app's service parses" {
    var buf: [192]u8 = undefined;
    try std.testing.expectEqualStrings("tree", request("tree", .{}, &buf).?);
    try std.testing.expectEqualStrings("do click:todo.add", request("tap", .{ .a0 = "todo.add" }, &buf).?);
    try std.testing.expectEqualStrings("do type:todo.field:buy milk", request("text", .{ .a0 = "todo.field", .a1 = "buy milk" }, &buf).?);
    try std.testing.expectEqualStrings("do scroll:todo.list:0,-120", request("scroll", .{ .a0 = "todo.list", .a1 = "0,-120" }, &buf).?);
    // A verb that is not a request says so rather than sending something the app will not understand.
    try std.testing.expect(request("teleport", .{}, &buf) == null);
}
