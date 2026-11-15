// The devtool service on Linux: a unix socket a client connects to, a thread that serves one request per connection, and a pipe that wakes an idle window.
const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const service_mod = @import("../core/devtools/service.zig");

// The socket lives in the runtime dir when there is one, so it is per-user and the session cleans it up.
pub fn socketPath(name: []const u8, buf: []u8) ?[]const u8 {
    // The runtime dir when there is one, then the per-user temp dir, then /tmp: both sides of the socket must agree on this rule.
    const dir = if (std.c.getenv("XDG_RUNTIME_DIR")) |d| std.mem.span(d) else if (std.c.getenv("TMPDIR")) |d| std.mem.span(d) else "/tmp";
    return std.fmt.bufPrint(buf, "{s}/glinlandui-{s}.sock", .{ dir, name }) catch null;
}

pub const Handle = struct {
    server: *Server,

    // The read end of the wake pipe: what the window's event loop polls to notice a request while it is idle.
    pub fn wakeFd(self: Handle) ?i32 {
        return self.server.wake_read;
    }
};

// Start serving `name`, or null when this host cannot: no thread, no socket, nothing for an app that is not being inspected.
pub fn open(alloc: std.mem.Allocator, io: std.Io, name: []const u8, service: *service_mod.Service) ?Handle {
    var path_buf: [108]u8 = undefined;
    const path = socketPath(name, &path_buf) orelse return null;
    const server = alloc.create(Server) catch return null;
    server.* = .{ .alloc = alloc, .io = io, .service = service };
    @memcpy(server.path[0..path.len], path);
    server.path_len = path.len;
    // A socket a killed app left behind would refuse the bind, and it can only be ours: the path carries the name.
    server.path[server.path_len] = 0;
    _ = linux.unlink(@ptrCast(server.path[0..server.path_len :0]));

    var addr = std.Io.net.UnixAddress.init(server.path[0..server.path_len]) catch return null;
    server.listener = addr.listen(io, .{}) catch return null;
    const wake = makePipe() catch return null;
    server.wake_read = wake[0];
    server.wake_write = wake[1];
    service.wake = onWake;
    service.wake_ctx = server;
    server.thread = std.Thread.spawn(.{}, Server.run, .{server}) catch return null;
    server.thread.detach();
    return .{ .server = server };
}

// Ask a running app one question: connect, send one line, and write back what it answered.
pub fn request(io: std.Io, name: []const u8, line: []const u8, out: *std.Io.Writer) !void {
    var path_buf: [108]u8 = undefined;
    const path = socketPath(name, &path_buf) orelse return error.NameTooLong;
    const addr = try std.Io.net.UnixAddress.init(path);
    const stream = try addr.connect(io);
    defer stream.close(io);
    try writeAll(stream.socket.handle, line);
    try writeAll(stream.socket.handle, "\n");
    var buf: [4096]u8 = undefined;
    // The app closes the connection when the answer is complete, so end of stream is end of reply.
    while (true) {
        const n = posix.read(stream.socket.handle, &buf) catch break;
        if (n == 0) break;
        try out.writeAll(buf[0..n]);
    }
}

const Server = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    service: *service_mod.Service,
    listener: std.Io.net.Server = undefined,
    path: [108]u8 = undefined,
    path_len: usize = 0,
    wake_read: posix.fd_t = -1,
    wake_write: posix.fd_t = -1,
    thread: std.Thread = undefined,
    stopping: std.atomic.Value(bool) = .init(false),

    fn run(self: *Server) void {
        while (!self.stopping.load(.acquire)) {
            const stream = self.listener.accept(self.io) catch continue;
            self.answer(stream) catch {};
            stream.close(self.io);
        }
    }

    // One request per connection: read a line, hand it to the frame loop, write what it answered, close.
    fn answer(self: *Server, stream: std.Io.net.Stream) !void {
        var line: [service_mod.request_cap]u8 = undefined;
        const len = try readLine(stream.socket.handle, &line);
        self.service.submit(line[0..len]);
        const body = self.service.takeReply();
        writeAll(stream.socket.handle, body) catch {};
        self.service.releaseReply();
    }
};

// The wake hook: the socket thread pokes the pipe, and the window's poll sees it.
fn onWake(ptr: ?*anyopaque) void {
    const self: *Server = @ptrCast(@alignCast(ptr.?));
    _ = linux.write(self.wake_write, "x", 1);
}

fn makePipe() ![2]posix.fd_t {
    var fds: [2]i32 = undefined;
    const rc: isize = @bitCast(linux.pipe2(&fds, .{}));
    if (rc < 0) return error.PipeFailed;
    return .{ fds[0], fds[1] };
}

// One line without its newline; a client that sends none still gets an answer, which says why.
fn readLine(fd: posix.fd_t, buf: []u8) !usize {
    var len: usize = 0;
    while (len < buf.len) {
        const n = try posix.read(fd, buf[len..]);
        if (n == 0) break;
        const start = len;
        len += n;
        if (std.mem.indexOfScalar(u8, buf[start..len], '\n')) |at| return start + at;
    }
    return len;
}

fn writeAll(fd: posix.fd_t, bytes: []const u8) !void {
    var off: usize = 0;
    while (off < bytes.len) {
        const rc: isize = @bitCast(linux.write(fd, bytes[off..].ptr, bytes.len - off));
        if (rc <= 0) return error.WriteFailed;
        off += @intCast(rc);
    }
}
