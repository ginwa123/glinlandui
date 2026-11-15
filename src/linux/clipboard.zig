//! The Linux clipboard: the session's helper program, run with a pipe. Wayland speaks `wl-copy`/`wl-paste`, X11 `xclip` or `xsel`.
const std = @import("std");
const contract = @import("../core/clipboard_contract.zig");
const model = @import("clipboard_model.zig");

/// The same ceiling every backend declares; see `core/clipboard_contract.zig`.
pub const max_bytes: usize = contract.max_bytes;

// The longest path `resolve` will build: a PATH entry, a slash, and a tool name.
const max_path: usize = 4096;

// How long a helper may run before SIGALRM ends it: long enough for a big paste, short enough that a stuck one is a hiccup rather than a frozen window.
const helper_deadline_s: c_uint = 5;

// One helper's argv: the program, at most four arguments, and the terminator `execve` needs.
const max_args: usize = 5;

// Read the selection into `buf`; empty when this session has no helper or the selection holds no text.
pub fn read(buf: []u8) []const u8 {
    if (buf.len == 0) return buf[0..0];
    const plan = model.choose(probe(), .paste) orelse return buf[0..0];
    var exe_buffer: [max_path]u8 = undefined;
    const exe = resolve(plan.exe, &exe_buffer) orelse return buf[0..0];
    const cap = @min(buf.len, max_bytes);
    const got = capture(exe, plan.args, buf[0..cap]);
    return buf[0..contract.trim(got, cap)];
}

// Put `text` on the selection. A shell with no helper drops it, which is what the portable stub does too.
pub fn write(text: []const u8) void {
    if (text.len == 0) return;
    const plan = model.choose(probe(), .copy) orelse return;
    var exe_buffer: [max_path]u8 = undefined;
    const exe = resolve(plan.exe, &exe_buffer) orelse return;
    feed(exe, plan.args, text[0..@min(text.len, max_bytes)]);
}

// What this session offers: the display variables, and which helpers are actually installed.
fn probe() model.Session {
    var session = model.sessionFrom(getenv("WAYLAND_DISPLAY"), getenv("DISPLAY"));
    // `wl-copy` writes and `wl-paste` reads, so a session needs both of them to be useful.
    session.wl_clipboard = onPath("wl-copy") and onPath("wl-paste");
    session.xclip = onPath("xclip");
    session.xsel = onPath("xsel");
    return session;
}

fn getenv(name: [*:0]const u8) ?[]const u8 {
    const raw = std.c.getenv(name) orelse return null;
    return std.mem.span(raw);
}

fn onPath(name: []const u8) bool {
    var buffer: [max_path]u8 = undefined;
    return resolve(name, &buffer) != null;
}

// The helper's full path: `execve` does not search PATH, and a bare name would fail with ENOENT.
fn resolve(name: []const u8, buffer: []u8) ?[:0]const u8 {
    const path = getenv("PATH") orelse return null;
    var segments = std.mem.splitScalar(u8, path, ':');
    while (segments.next()) |dir| {
        if (dir.len == 0) continue;
        const joined = std.fmt.bufPrintZ(buffer, "{s}/{s}", .{ dir, name }) catch continue;
        if (std.c.access(joined.ptr, std.c.X_OK) == 0) return joined;
    }
    return null;
}

// Fork the helper with one standard stream on a pipe, and reap it. Returns the raw byte count, or -1.
fn capture(exe: [:0]const u8, args: []const [:0]const u8, dst: []u8) isize {
    var fds: [2]std.c.fd_t = undefined;
    if (std.c.pipe(&fds) != 0) return -1;

    const pid = std.c.fork();
    if (pid < 0) {
        _ = std.c.close(fds[0]);
        _ = std.c.close(fds[1]);
        return -1;
    }
    // The child writes into the pipe and must not hold its read end open, or the parent never sees EOF.
    if (pid == 0) childExec(exe, args, fds[1], 1, fds[0]);

    _ = std.c.close(fds[1]);
    const got = drain(fds[0], dst);
    _ = std.c.close(fds[0]);
    _ = std.c.waitpid(@intCast(pid), null, 0);
    return got;
}

// Fork the helper with one standard stream on a pipe, hand it `text`, and reap it.
fn feed(exe: [:0]const u8, args: []const [:0]const u8, text: []const u8) void {
    var fds: [2]std.c.fd_t = undefined;
    if (std.c.pipe(&fds) != 0) return;

    const pid = std.c.fork();
    if (pid < 0) {
        _ = std.c.close(fds[0]);
        _ = std.c.close(fds[1]);
        return;
    }
    // The child reads from the pipe and must not hold its write end open, or it waits for a writer that is us.
    if (pid == 0) childExec(exe, args, fds[0], 0, fds[1]);

    _ = std.c.close(fds[0]);
    // A helper that exits early closes the pipe, and the default SIGPIPE would then kill THIS process: ignore it for the write, then put the app's disposition back.
    const previous = ignoreSigPipe();
    var off: usize = 0;
    while (off < text.len) {
        const written = std.c.write(fds[1], text.ptr + off, text.len - off);
        if (written <= 0) break;
        off += @intCast(written);
    }
    restoreSigPipe(previous);
    _ = std.c.close(fds[1]);
    _ = std.c.waitpid(@intCast(pid), null, 0);
}

// The child half: point one standard stream at the pipe, run the helper, and never return — between fork and exec only async-signal-safe calls may run.
fn childExec(exe: [:0]const u8, args: []const [:0]const u8, pipe_end: std.c.fd_t, target: std.c.fd_t, drop: std.c.fd_t) noreturn {
    if (pipe_end != target) {
        _ = std.c.dup2(pipe_end, target);
        _ = std.c.close(pipe_end);
    }
    _ = std.c.close(drop);

    // A hung helper must not freeze the frame: SIGALRM ends it, and a fork clears the alarm, so a daemonised helper survives.
    _ = std.c.alarm(helper_deadline_s);

    var argv: [max_args + 1]?[*:0]const u8 = undefined;
    argv[0] = exe.ptr;
    for (args[0..@min(args.len, max_args)], 0..) |arg, i| argv[i + 1] = arg.ptr;
    argv[@min(args.len, max_args) + 1] = null;
    const envp: [*:null]const ?[*:0]const u8 = @ptrCast(std.c.environ);
    _ = std.c.execve(exe.ptr, @ptrCast(&argv), envp);
    // Nothing ran: the parent sees an empty read and the plan simply produced nothing.
    std.c._exit(127);
}

// Ignore SIGPIPE for the write, handing back the disposition to put back afterwards.
fn ignoreSigPipe() std.posix.Sigaction {
    const action: std.posix.Sigaction = .{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    var previous: std.posix.Sigaction = undefined;
    std.posix.sigaction(std.posix.SIG.PIPE, &action, &previous);
    return previous;
}

fn restoreSigPipe(previous: std.posix.Sigaction) void {
    std.posix.sigaction(std.posix.SIG.PIPE, &previous, null);
}

// Read until the helper closes its end, keeping the first `dst.len` bytes and discarding the rest so it never blocks on a full pipe.
fn drain(fd: std.c.fd_t, dst: []u8) isize {
    var total: usize = 0;
    var sink: [4096]u8 = undefined;
    while (true) {
        const target: []u8 = if (total < dst.len) dst[total..] else sink[0..];
        const got = std.c.read(fd, target.ptr, target.len);
        if (got <= 0) break;
        if (total < dst.len) total += @intCast(got);
    }
    return @intCast(total);
}
