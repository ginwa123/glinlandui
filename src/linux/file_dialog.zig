//! The Linux file dialog: a D-Bus client that asks the XDG Desktop Portal for a file, a folder or a save target.
const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

const dbus = @import("dbus.zig");
const portal = @import("portal.zig");
const contract = @import("../core/file_dialog_contract.zig");

// The portable surface, re-exported so a consumer writes `glinlandui.file_dialog.Options` and never names a Linux module.
pub const Kind = contract.Kind;
pub const Rule = contract.Rule;
pub const Filter = contract.Filter;
pub const Options = contract.Options;
pub const Status = contract.Status;
pub const Selection = contract.Selection;
pub const Error = contract.Error;

/// True when this host can open a dialog at all.
pub fn available() bool {
    return true;
}

/// Ask for one existing file. See `contract.Options` for what can be asked.
pub fn openFile(alloc: std.mem.Allocator, options: Options) !Selection {
    var opts = options;
    opts.kind = .open_file;
    return choose(alloc, opts);
}

/// Ask for one existing DIRECTORY — the "select folder" case.
pub fn openFolder(alloc: std.mem.Allocator, options: Options) !Selection {
    var opts = options;
    opts.kind = .open_folder;
    return choose(alloc, opts);
}

/// Ask where to write a file. The file need not exist.
pub fn saveFile(alloc: std.mem.Allocator, options: Options) !Selection {
    var opts = options;
    opts.kind = .save_file;
    return choose(alloc, opts);
}

/// How long the CONTROL calls (Hello, AddMatch, the chooser call itself) may take before the client gives up.
const control_timeout_ms: i32 = 5_000;

/// A connected, authenticated bus session.
pub const Client = struct {
    fd: i32,
    alloc: std.mem.Allocator,
    /// The well-known name the chooser call is addressed to.
    service_name: []const u8 = portal.desktop_service,
    /// The unique name the bus assigned us (`1.42`), which is what the request path is built from.
    unique: [64]u8 = undefined,
    unique_len: usize = 0,
    serial: u32 = 0,
    /// Monotonic, so two dialogs in one process never collide on a token.
    token_counter: u64 = 0,
    /// The request path the CURRENT attempt will be answered on, and the buffer it borrows.
    request_path_buf: [256]u8 = undefined,
    request_path: []const u8 = "",
    /// Receive buffer.
    in_buf: [8 * 1024]u8 = undefined,
    in_len: usize = 0,
    in_pos: usize = 0,
    /// Scratch for `errorReply`, which builds a frame by hand.
    frame_buf: [1024]u8 = undefined,
    /// Scratch space for the URIs a response carries.
    uri_scratch: [64][]const u8 = undefined,

    /// Connect, authenticate, and say Hello.
    pub fn connect(alloc: std.mem.Allocator) !Client {
        const env = if (std.c.getenv("DBUS_SESSION_BUS_ADDRESS")) |raw| std.mem.span(raw) else null;
        const address = dbus.parseBusAddress(alloc, env, @intCast(linux.getuid())) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // An address we cannot use, or none at all, means there is no session bus to talk to — which is the app-level statement a UI can act on, rather than.
            else => return error.NoSessionBus,
        };
        defer address.deinit(alloc);

        var self = Client{ .fd = -1, .alloc = alloc };
        errdefer self.deinit();
        try self.connectSocket(address);
        try self.authenticate();
        try self.sayHello();
        return self;
    }

    pub fn deinit(self: *Client) void {
        if (self.fd >= 0) {
            _ = linux.close(self.fd);
            self.fd = -1;
        }
    }

    fn connectSocket(self: *Client, address: dbus.BusAddress) !void {
        const raw = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
        switch (linux.errno(raw)) {
            .SUCCESS => {},
            else => return error.NoSessionBus,
        }
        const fd: i32 = @intCast(raw);
        self.fd = fd;

        // `std.os.linux.sockaddr` is the flat kernel struct, and `sun` is the view of it for AF_UNIX.
        var sun: linux.sockaddr.un = std.mem.zeroes(linux.sockaddr.un);
        sun.family = linux.AF.UNIX;

        // The address LENGTH matters for an abstract socket and not for a path one, and getting it wrong for the abstract case connects to a different name.
        const len: linux.socklen_t = switch (address) {
            .path => |p| blk: {
                if (p.len >= sun.path.len) return error.NoSessionBus;
                @memcpy(sun.path[0..p.len], p);
                // family + name + the NUL that terminates a path name
                break :blk @intCast(@sizeOf(linux.sa_family_t) + p.len + 1);
            },
            .abstract => |a| blk: {
                // `a[0]` IS the NUL that makes the name abstract; the name is the rest of the slice.
                if (a.len - 1 >= sun.path.len) return error.NoSessionBus;
                @memcpy(sun.path[0 .. a.len - 1], a[1..]);
                break :blk @intCast(@sizeOf(linux.sa_family_t) + 1 + (a.len - 1));
            },
        };

        const sa: *const linux.sockaddr = @ptrCast(&sun);
        // Every failure here means the same thing to a caller: there is no session bus to ask.
        if (linux.errno(linux.connect(fd, sa, len)) != .SUCCESS) return error.NoSessionBus;
    }

    /// SASL EXTERNAL, then BEGIN.
    fn authenticate(self: *Client) !void {
        var cred: [64]u8 = undefined;
        const line = try dbus.authExternal(@intCast(linux.getuid()), &cred);
        try self.writeAll(line);
        try self.writeAll(dbus.begin_line);

        const reply = try self.readLine();
        switch (dbus.parseAuthReply(reply)) {
            .ok => {},
            .rejected => return error.NoSessionBus,
            .failed => return error.NoSessionBus,
            .data, .unknown => return error.NoSessionBus,
        }
    }

    /// `org.freedesktop.DBus.Hello`, whose reply is our unique name.
    fn sayHello(self: *Client) !void {
        const reply = try self.callMethod(
            "org.freedesktop.DBus",
            "/org/freedesktop/DBus",
            "org.freedesktop.DBus",
            "Hello",
            "",
            "",
        );
        if (reply.kind == .error_reply) return error.NoSessionBus;

        var r = dbus.Reader.init(reply.body);
        const name = r.readString() catch return error.NoSessionBus;
        if (name.len == 0 or name.len > self.unique.len) return error.NoSessionBus;
        @memcpy(self.unique[0..name.len], name);
        self.unique_len = name.len;
    }

    /// The unique name, e.g. `:1.42`.
    pub fn uniqueName(self: *const Client) []const u8 {
        return self.unique[0..self.unique_len];
    }

    /// Ask the portal for something, and wait for the user to answer.
    pub fn choose(self: *Client, opts: Options) !Selection {
        self.token_counter += 1;
        var token_buf: [32]u8 = undefined;
        const token = try portal.writeToken(self.token_counter, &token_buf);

        // The filter list is a documented option, and a portal is entitled to refuse it — and this one does, in a way that takes the whole dialog with it: the.
        var handle = self.attempt(opts, token, opts.filters.len != 0) catch |first_err| blk: {
            if (opts.filters.len == 0) return first_err;
            // The connection may be gone entirely; a new one is cheap, and the old socket, if it still exists, goes with it.
            self.reconnect() catch |e| return e;
            break :blk self.attempt(opts, token, false) catch |e| return e;
        };
        if (handle.kind == .error_reply and opts.filters.len != 0) {
            // Refused in words rather than by disconnecting.
            handle = self.attempt(opts, token, false) catch |e| return e;
        }
        if (handle.kind == .error_reply) {
            const name = handle.error_name orelse "";
            // The two cases a UI must tell apart: nothing owns the name (no portal installed) versus the portal answered and refused.
            if (std.mem.indexOf(u8, name, "ServiceUnknown") != null or
                std.mem.indexOf(u8, name, "NameHasNoOwner") != null) return error.NoPortal;
            return error.PortalError;
        }

        // `self.request_path`, set by `attempt` and NOT recomputed here.
        const decoded = try self.waitForResponse(self.request_path, opts.timeout_ms);
        return self.toSelection(decoded);
    }

    /// One attempt: derive the request path from the name this connection holds NOW, listen on it, and make the call.
    fn attempt(self: *Client, opts: Options, token: []const u8, with_filters: bool) !dbus.Header {
        var folded_buf: [64]u8 = undefined;
        const folded = try portal.foldSenderName(self.uniqueName(), &folded_buf);
        self.request_path = try portal.writeRequestPath(self.uniqueName(), token, &self.request_path_buf);

        // The match rule goes before the call: the bus processes messages in order, so by the time the portal can answer, the bus is already routing that.
        try self.registerForToken(token, folded);

        var body_buf: [4096]u8 = undefined;
        var bw = dbus.Writer.init(&body_buf);
        var o = opts;
        if (!with_filters) o.filters = &.{};
        try portal.writeMethodBody(&bw, o, token);
        return self.callMethod(
            self.service_name,
            portal.desktop_path,
            portal.chooser_interface,
            portal.memberFor(o.kind),
            "ssa{sv}",
            bw.written(),
        );
    }

    /// Install the match rule that routes THIS request's Response to us.
    fn registerForToken(self: *Client, token: []const u8, folded: []const u8) !void {
        var rule_buf: [512]u8 = undefined;
        const rule = try portal.writeResponseMatchRule(folded, token, &rule_buf);
        var add: [600]u8 = undefined;
        var aw = dbus.Writer.init(&add);
        aw.writeString(rule);
        const reply = try self.callMethod(
            "org.freedesktop.DBus",
            "/org/freedesktop/DBus",
            "org.freedesktop.DBus",
            "AddMatch",
            "s",
            aw.written(),
        );
        if (reply.kind == .error_reply) return error.NoPortal;
    }

    /// Throw the current connection away and open a new one.
    fn reconnect(self: *Client) !void {
        const fresh = try Client.connect(self.alloc);
        self.deinit();
        self.* = fresh;
    }

    /// Cancel a dialog that is already open.
    pub fn close(self: *Client, request_path: []const u8) void {
        self.serial +%= 1;
        var frame: [512]u8 = undefined;
        const bytes = dbus.encode(
            &frame,
            .method_call,
            .{ .no_reply_expected = true },
            self.serial,
            &.{
                .{ .code = dbus.field_destination, .value = .{ .string = self.service_name } },
                .{ .code = dbus.field_path, .value = .{ .object_path = request_path } },
                .{ .code = dbus.field_interface, .value = .{ .string = portal.request_interface } },
                .{ .code = dbus.field_member, .value = .{ .string = "Close" } },
            },
            "",
        );
        self.writeAll(bytes) catch {};
    }

    /// Wait for the one signal this request is waiting for.
    fn waitForResponse(self: *Client, request_path: []const u8, timeout_ms: ?u32) !portal.Decoded {
        // The budget is wall-clock, not "time spent in poll": a bus can keep sending unrelated signals (NameOwnerChanged from another app) for as long as it.
        const started = nowMs();

        while (true) {
            const header = try self.nextMessage(leftOf(timeout_ms, started)) orelse return error.Timeout;
            if (header.kind != .signal) continue;
            const path = header.path orelse continue;
            if (!std.mem.eql(u8, path, request_path)) continue;
            const iface = header.interface_name orelse continue;
            if (!std.mem.eql(u8, iface, portal.response_interface)) continue;
            return portal.decodeResponse(header.body, &self.uri_scratch) catch return error.PortalError;
        }
    }

    /// Turn URIs into allocated paths, in a `Selection` the caller frees.
    fn toSelection(self: *Client, decoded: portal.Decoded) !Selection {
        const status = decoded.status();
        if (status != .selected) return .{ .status = status };
        if (decoded.uris.len == 0) return .{ .status = .other };

        const paths = self.alloc.alloc([]const u8, decoded.uris.len) catch return error.OutOfMemory;
        errdefer self.alloc.free(paths);

        var made: usize = 0;
        // Free whatever was already duplicated if a later allocation fails: a caller that gets an error has no Selection to free, so this is the only place.
        errdefer for (paths[0..made]) |p| self.alloc.free(p);

        for (decoded.uris) |uri| {
            var path_buf: [4096]u8 = undefined;
            // A URI this client cannot turn into a path (a `recent://` from an exotic portal, say) is skipped rather than fatal: the other selections are still.
            const path = portal.uriToPath(uri, &path_buf) catch continue;
            paths[made] = self.alloc.dupe(u8, path) catch return error.OutOfMemory;
            made += 1;
        }
        if (made == 0) return .{ .status = .other };
        return .{ .status = .selected, .paths = paths[0..made] };
    }

    /// Send a method call and wait for its reply, skipping any signals that arrive in the meantime (the bus sends `NameAcquired` unbidden).
    fn callMethod(
        self: *Client,
        destination: []const u8,
        path: []const u8,
        interface: []const u8,
        member: []const u8,
        signature: []const u8,
        body: []const u8,
    ) !dbus.Header {
        self.serial +%= 1;
        const serial = self.serial;

        var frame: [8192]u8 = undefined;
        var fields: [5]dbus.Field = undefined;
        var n_fields: usize = 0;
        fields[n_fields] = .{ .code = dbus.field_destination, .value = .{ .string = destination } };
        n_fields += 1;
        fields[n_fields] = .{ .code = dbus.field_path, .value = .{ .object_path = path } };
        n_fields += 1;
        fields[n_fields] = .{ .code = dbus.field_interface, .value = .{ .string = interface } };
        n_fields += 1;
        fields[n_fields] = .{ .code = dbus.field_member, .value = .{ .string = member } };
        n_fields += 1;
        if (signature.len != 0) {
            fields[n_fields] = .{ .code = dbus.field_signature, .value = .{ .signature = signature } };
            n_fields += 1;
        }

        const bytes = dbus.encode(&frame, .method_call, .{}, serial, fields[0..n_fields], body);
        try self.writeAll(bytes);

        while (true) {
            const header = try self.nextMessage(control_timeout_ms) orelse return error.Timeout;
            if (header.reply_serial == null or header.reply_serial.? != serial) continue;
            return header;
        }
    }

    fn writeAll(self: *Client, bytes: []const u8) !void {
        var sent: usize = 0;
        while (sent < bytes.len) {
            const rc = linux.sendto(
                self.fd,
                bytes.ptr + sent,
                bytes.len - sent,
                posix.MSG.NOSIGNAL,
                null,
                0,
            );
            const err = linux.errno(rc);
            switch (err) {
                .SUCCESS => {},
                .INTR => continue,
                else => return error.BusDisconnected,
            }
            if (rc == 0) return error.BusDisconnected;
            sent += rc;
        }
    }

    /// One CRLF-terminated line, for the SASL handshake.
    fn readLine(self: *Client) ![]const u8 {
        var search_from = self.in_pos;
        while (true) {
            if (std.mem.indexOfScalarPos(u8, self.in_buf[0..self.in_len], search_from, '\n')) |nl| {
                const line = self.in_buf[self.in_pos..nl];
                // Keep the bytes after the newline for the next message.
                self.in_pos = nl + 1;
                return std.mem.trimEnd(u8, line, "\r");
            }
            search_from = self.in_len;
            if (self.in_len == self.in_buf.len) return error.BusProtocol;
            const n = try posix.read(self.fd, self.in_buf[self.in_len..]);
            if (n == 0) return error.BusDisconnected;
            self.in_len += n;
        }
    }

    /// The next message, or null when `timeout_ms` (or the time left of it) expires first.
    fn nextMessage(self: *Client, timeout_ms: ?i32) !?dbus.Header {
        while (true) {
            if (self.in_pos < self.in_len) {
                if (dbus.frameLength(self.in_buf[self.in_pos..self.in_len])) |len| {
                    if (len == 0) return error.BusProtocol;
                    if (self.in_pos + len <= self.in_len) {
                        const header = try dbus.parse(self.in_buf[self.in_pos..][0..len]);
                        self.in_pos += len;
                        return header;
                    }
                    // A frame that is complete per its own header but not yet delivered: keep it and read more.
                }
            }
            if (self.in_len == self.in_buf.len) return error.BusProtocol;

            var fds = [_]posix.pollfd{.{
                .fd = self.fd,
                .events = posix.POLL.IN,
                .revents = 0,
            }};
            const ready = posix.poll(&fds, timeout_ms orelse -1) catch return error.BusDisconnected;
            if (ready == 0) return null;

            const n = try posix.read(self.fd, self.in_buf[self.in_len..]);
            if (n == 0) return error.BusDisconnected;
            self.in_len += n;
        }
    }
};

/// Milliseconds on a MONOTONIC clock.
fn nowMs() i64 {
    var ts: linux.timespec = undefined;
    if (linux.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(i64, @intCast(ts.sec)) * std.time.ms_per_s +
        @divTrunc(@as(i64, @intCast(ts.nsec)), std.time.ns_per_ms);
}

/// Milliseconds left of a budget that started at `started`, or null when there is no budget.
fn leftOf(timeout_ms: ?u32, started: i64) ?i32 {
    const budget = timeout_ms orelse return null;
    const left = @as(i64, budget) - (nowMs() - started);
    if (left <= 0) return 0;
    return @intCast(left);
}

/// Ask the portal and return what the user chose.
fn choose(alloc: std.mem.Allocator, opts: Options) !Selection {
    // No `builtin.is_test` gate here: `platform.zig` already selects `core/file_dialog_portable.zig` for a test build, so this module is not even in the.
    var client = try Client.connect(alloc);
    defer client.deinit();
    return client.choose(opts);
}

// The live round trip.

/// A second, minimal D-Bus client — enough to be a service on the bus.
const FakeService = struct {
    fd: i32,
    serial: u32 = 0,
    unique: [64]u8 = undefined,
    unique_len: usize = 0,
    in_buf: [8 * 1024]u8 = undefined,
    in_len: usize = 0,
    in_pos: usize = 0,
    /// Scratch for `errorReply`, which builds a frame by hand.
    frame_buf: [1024]u8 = undefined,

    fn connect(alloc: std.mem.Allocator) !FakeService {
        const env = if (std.c.getenv("DBUS_SESSION_BUS_ADDRESS")) |raw| std.mem.span(raw) else null;
        const address = try dbus.parseBusAddress(alloc, env, @intCast(linux.getuid()));
        defer address.deinit(alloc);

        var self = FakeService{ .fd = -1 };
        errdefer self.deinit();

        const raw = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
        if (linux.errno(raw) != .SUCCESS) return error.NoBus;
        self.fd = @intCast(raw);

        var sun: linux.sockaddr.un = std.mem.zeroes(linux.sockaddr.un);
        sun.family = linux.AF.UNIX;
        const p = address.socketPath();
        if (p.len == 0) return error.NoBus;
        // For an abstract address `p[0]` IS the NUL and the name is the rest; for a path address the whole slice is the name and `connect` gets the terminating.
        const abstract = p[0] == 0;
        const name = if (abstract) p[1..] else p;
        if (name.len >= sun.path.len) return error.NoBus;
        @memcpy(sun.path[0..name.len], name);
        const len: linux.socklen_t = @intCast(@sizeOf(linux.sa_family_t) + 1 + name.len);
        const sa: *const linux.sockaddr = @ptrCast(&sun);
        if (linux.errno(linux.connect(self.fd, sa, len)) != .SUCCESS) return error.NoBus;

        var cred: [64]u8 = undefined;
        try self.writeAll(try dbus.authExternal(@intCast(linux.getuid()), &cred));
        try self.writeAll(dbus.begin_line);

        // The bus answers the whole credential phase with one line.
        var sink: [256]u8 = undefined;
        _ = try posix.read(self.fd, &sink);

        // Hello, and read the reply.
        var hello_body: [64]u8 = undefined;
        var hb = dbus.Writer.init(&hello_body);
        _ = hb.written();
        const hello = try self.call(
            "org.freedesktop.DBus",
            "/org/freedesktop/DBus",
            "org.freedesktop.DBus",
            "Hello",
            "",
            "",
        );
        var r = dbus.Reader.init(hello.body);
        const unique_name = r.readString() catch return error.NoBus;
        if (unique_name.len >= self.unique.len) return error.NoBus;
        @memcpy(self.unique[0..unique_name.len], unique_name);
        self.unique_len = unique_name.len;
        return self;
    }

    fn deinit(self: *FakeService) void {
        if (self.fd >= 0) {
            _ = linux.close(self.fd);
            self.fd = -1;
        }
    }

    fn writeAll(self: *FakeService, bytes: []const u8) !void {
        var sent: usize = 0;
        while (sent < bytes.len) {
            const rc = linux.sendto(self.fd, bytes.ptr + sent, bytes.len - sent, posix.MSG.NOSIGNAL, null, 0);
            if (linux.errno(rc) != .SUCCESS or rc == 0) return error.NoBus;
            sent += rc;
        }
    }

    fn call(self: *FakeService, dest: []const u8, path: []const u8, iface: []const u8, member: []const u8, sig: []const u8, body: []const u8) !dbus.Header {
        self.serial +%= 1;
        const serial = self.serial;
        var frame: [1024]u8 = undefined;
        const fields = [_]dbus.Field{
            .{ .code = dbus.field_destination, .value = .{ .string = dest } },
            .{ .code = dbus.field_path, .value = .{ .object_path = path } },
            .{ .code = dbus.field_interface, .value = .{ .string = iface } },
            .{ .code = dbus.field_member, .value = .{ .string = member } },
            .{ .code = dbus.field_signature, .value = .{ .signature = sig } },
        };
        try self.writeAll(dbus.encode(&frame, .method_call, .{}, serial, &fields, body));
        while (true) {
            const header = try self.next() orelse return error.Timeout;
            if (header.reply_serial != null and header.reply_serial.? == serial) return header;
        }
    }

    /// The method return for `msg`, carrying one object path — the request path, which is how a real portal tells the client where the answer will arrive.
    fn replyHandle(self: *FakeService, msg: dbus.Header, handle: []const u8) !void {
        self.serial +%= 1;
        var body: [512]u8 = undefined;
        var w = dbus.Writer.init(&body);
        // An object path marshals like a string; the SIGNATURE is what says so, and a reply whose signature field is missing makes the bus answer the caller.
        w.writeString(handle);

        var frame: [1024]u8 = undefined;
        const fields = [_]dbus.Field{
            .{ .code = dbus.field_reply_serial, .value = .{ .u32 = msg.serial } },
            .{ .code = dbus.field_destination, .value = .{ .string = msg.sender orelse "" } },
            .{ .code = dbus.field_signature, .value = .{ .signature = "o" } },
        };
        try self.writeAll(dbus.encode(&frame, .method_return, .{}, self.serial, &fields, w.written()));
    }

    /// The `org.freedesktop.portal.Response` signal: `ua{sv}` with `uris`.
    fn emitResponse(self: *FakeService, request_path: []const u8, code: u32, uris: []const []const u8) !void {
        self.serial +%= 1;

        var body: [2048]u8 = undefined;
        var w = dbus.Writer.init(&body);
        w.writeU32(code);
        const dict_at = w.reserveU32();
        w.alignTo(8);
        const first = w.count();
        w.writeString("uris");
        w.writeSignature("as");
        const arr_at = w.reserveU32();
        const arr_first = w.count();
        for (uris) |u| w.writeString(u);
        w.patchU32(arr_at, @intCast(w.count() - arr_first));
        w.patchU32(dict_at, @intCast(w.count() - first));

        var frame: [4096]u8 = undefined;
        const fields = [_]dbus.Field{
            .{ .code = dbus.field_path, .value = .{ .object_path = request_path } },
            .{ .code = dbus.field_interface, .value = .{ .string = portal.response_interface } },
            .{ .code = dbus.field_member, .value = .{ .string = "Response" } },
            .{ .code = dbus.field_signature, .value = .{ .signature = "ua{sv}" } },
        };
        try self.writeAll(dbus.encode(&frame, .signal, .{}, self.serial, &fields, w.written()));
    }

    /// An ERROR message: how a portal refuses a call.
    fn errorReply(self: *FakeService, request: dbus.Header, name: []const u8) []const u8 {
        self.serial +%= 1;
        var w = dbus.Writer.init(&self.frame_buf);
        w.writeU8('l'); // endianness marker; every message starts with it
        w.writeU8(3); // message type: ERROR
        w.writeU8(0); // flags
        w.writeU8(1); // protocol version
        w.writeU32(0); // body length
        w.writeU32(self.serial);

        const array_at = w.reserveU32();
        w.alignTo(8);
        w.writeU8(4); // ERROR_NAME
        w.writeSignature("s");
        w.writeString(name);
        w.alignTo(8);
        w.writeU8(5); // REPLY_SERIAL
        w.writeSignature("u");
        w.writeU32(request.serial);
        w.alignTo(8);
        w.writeU8(6); // DESTINATION
        w.writeSignature("s");
        w.writeString(request.sender orelse "");
        w.patchU32(array_at, @intCast(w.count() - (array_at + 4)));
        // The frame ends on an 8-byte boundary, and `dbus.encode` ends with `w.alignTo(8)` for exactly this reason.
        w.alignTo(8);
        return w.written();
    }

    fn write(self: *FakeService, bytes: []const u8) !void {
        var sent: usize = 0;
        while (sent < bytes.len) {
            const rc = linux.sendto(self.fd, bytes.ptr + sent, bytes.len - sent, posix.MSG.NOSIGNAL, null, 0);
            if (linux.errno(rc) != .SUCCESS or rc == 0) return error.NoBus;
            sent += rc;
        }
    }

    fn next(self: *FakeService) !?dbus.Header {
        while (true) {
            if (self.in_pos < self.in_len) {
                if (dbus.frameLength(self.in_buf[self.in_pos..self.in_len])) |len| {
                    if (len > 0 and self.in_pos + len <= self.in_len) {
                        const header = try dbus.parse(self.in_buf[self.in_pos..][0..len]);
                        self.in_pos += len;
                        return header;
                    }
                }
            }
            if (self.in_len == self.in_buf.len) return error.NoBus;
            var fds = [_]posix.pollfd{.{ .fd = self.fd, .events = posix.POLL.IN, .revents = 0 }};
            if (try posix.poll(&fds, 10_000) == 0) return null;
            const n = try posix.read(self.fd, self.in_buf[self.in_len..]);
            if (n == 0) return error.NoBus;
            self.in_len += n;
        }
    }
};

/// Whether the well-known name is free, ours, or somebody else's.
const NameClaim = enum {
    /// We are the primary owner.
    claimed,
    /// Another connection already owns it — on a desktop, that is the real portal, and the fake one must not take it away.
    taken,
    /// The bus would not say.
    unknown,
};

/// Ask the bus for a well-known name.
fn claimName(service: *FakeService, name: []const u8) !NameClaim {
    var body: [256]u8 = undefined;
    var w = dbus.Writer.init(&body);
    w.writeString(name);
    // 4 = DO_NOT_QUEUE: fail now rather than waiting for the current owner to go away, which is what makes this safe to run on a real desktop.
    w.writeU32(4);
    const reply = try service.call(
        "org.freedesktop.DBus",
        "/org/freedesktop/DBus",
        "org.freedesktop.DBus",
        "RequestName",
        "su",
        w.written(),
    );
    if (reply.kind == .error_reply) return .unknown;
    var r = dbus.Reader.init(reply.body);
    return switch (r.readU32() catch return .unknown) {
        1 => .claimed, // PRIMARY_OWNER
        2 => .unknown, // IN_QUEUE: DO_NOT_QUEUE, so this should not happen
        3 => .taken, // EXISTS
        4 => .taken, // ALREADY_OWNER
        else => .unknown,
    };
}

fn addMatch(service: *FakeService, rule: []const u8) !void {
    var body: [512]u8 = undefined;
    var w = dbus.Writer.init(&body);
    w.writeString(rule);
    _ = try service.call(
        "org.freedesktop.DBus",
        "/org/freedesktop/DBus",
        "org.freedesktop.DBus",
        "AddMatch",
        "s",
        w.written(),
    );
}

/// The fake portal's side of one conversation, run on its own thread.
const Responder = struct {
    service: *FakeService,
    /// Refuse this many calls before answering one.
    refuse_first: usize = 0,
    code: u32 = 1,
    uris: []const []const u8 = &.{},
    /// What the client actually asked for, captured so the test can assert it.
    member_buf: [32]u8 = undefined,
    member_len: usize = 0,
    title_buf: [64]u8 = undefined,
    title_len: usize = 0,
    err: ?anyerror = null,

    fn threadMain(self: *Responder) void {
        self.run() catch |e| {
            self.err = e;
        };
    }

    fn run(self: *Responder) !void {
        // Until it has actually answered one.
        while (true) {
            const msg = (try self.service.next()) orelse return error.NoPortalTimeout;

            // The handshake is not part of the chooser conversation, and answering it is actively harmful.
            if (msg.kind != .method_call) continue;
            if (msg.interface_name == null or
                !std.mem.eql(u8, msg.interface_name.?, portal.chooser_interface)) return error.NotAChooserCall;
            if (msg.path == null or !std.mem.eql(u8, msg.path.?, portal.desktop_path)) return error.NotAChooserCall;

            // The refusal applies to the CHOOSER call, after those checks rather than before them.
            if (self.refuse_first > 0) {
                self.refuse_first -= 1;
                // A refusal in words, which is how a portal complains about an option it will not take.
                try self.service.write(self.service.errorReply(msg, "org.freedesktop.portal.Error.InvalidArgument"));
                continue;
            }

            const member = msg.member orelse return error.NoMember;
            self.member_len = @min(member.len, self.member_buf.len);
            @memcpy(self.member_buf[0..self.member_len], member[0..self.member_len]);

            // The body is (s parent_window, s title, a{sv} options).
            var r = dbus.Reader.init(msg.body);
            _ = try r.readString(); // parent window
            const title = try r.readString();
            self.title_len = @min(title.len, self.title_buf.len);
            @memcpy(self.title_buf[0..self.title_len], title[0..self.title_len]);

            // The request path the portal will answer on is derived from the token the CLIENT sent and from the sender it saw.
            const token = findOptionToken(msg.body) orelse return error.NoToken;
            var path_buf: [256]u8 = undefined;
            const request_path = try portal.writeRequestPath(msg.sender orelse return error.NoSender, token, &path_buf);
            try self.service.replyHandle(msg, request_path);
            try self.service.emitResponse(request_path, self.code, self.uris);
            return;
        }
    }

    /// Find `handle_token`'s value by scanning for the key rather than by using the client's own options decoder.
    fn findOptionToken(body: []const u8) ?[]const u8 {
        const key = "handle_token";
        const idx = std.mem.indexOf(u8, body, key) orelse return null;
        // The reader spans the WHOLE body with `pos` moved to the value, not a slice starting there: D-Bus alignment is measured from the start of the body.
        var r = dbus.Reader{ .buf = body, .pos = idx + key.len + 1 };
        const sig = r.readSignature() catch return null;
        if (!std.mem.eql(u8, sig, "s")) return null;
        return r.readString() catch null;
    }
};

/// The name the fake portal owns.
const fake_portal_name = "org.glinlandui.TestPortal";

/// Serializes the live tests against each other.
var live_test_held = std.atomic.Value(bool).init(false);

fn liveLock() void {
    while (live_test_held.cmpxchgStrong(false, true, .acquire, .monotonic) != null) {
        std.Thread.yield() catch {};
    }
}

fn liveUnlock() void {
    live_test_held.store(false, .release);
}

/// Set the fake portal up, or skip the test.
fn startFakePortal() !FakeService {
    // A failed connect is the test for "is there a bus here", which is more honest than probing for a socket file: a socket can exist and still refuse, and.
    var service = FakeService.connect(std.testing.allocator) catch return error.SkipZigTest;
    errdefer service.deinit();
    if (try claimName(&service, fake_portal_name) != .claimed) return error.SkipZigTest;
    // The match names the fake portal, because that is where the client is pointed.
    var rule_buf: [256]u8 = undefined;
    const rule = try std.fmt.bufPrint(
        &rule_buf,
        "type='method_call',destination='{s}'",
        .{fake_portal_name},
    );
    try addMatch(&service, rule);
    return service;
}

test "a folder selection survives a real session bus, end to end" {
    liveLock();
    defer liveUnlock();
    var service = try startFakePortal();
    defer service.deinit();

    var responder = Responder{
        .service = &service,
        .uris = &.{ "file:///home/u/Projects/My%20Folder", "file:///home/u/Notes%2Fdraft.md" },
    };
    const thread = try std.Thread.spawn(.{}, Responder.threadMain, .{&responder});

    var client = Client.connect(std.testing.allocator) catch |err| switch (err) {
        error.NoSessionBus => return error.SkipZigTest,
        else => return err,
    };
    defer client.deinit();
    client.service_name = fake_portal_name;

    const selection = client.choose(.{
        .kind = .open_folder,
        .title = "Choose a workspace",
        .timeout_ms = 15_000,
    }) catch |err| switch (err) {
        // The bus went away between the fake portal claiming the name and the client connecting.
        error.BusDisconnected, error.BusProtocol => return error.SkipZigTest,
        else => return err,
    };
    thread.join();
    if (responder.err) |e| return e;

    // A folder is OpenDirectory — not OpenFile with a flag.
    try std.testing.expectEqualStrings("OpenDirectory", responder.member_buf[0..responder.member_len]);
    try std.testing.expectEqualStrings("Choose a workspace", responder.title_buf[0..responder.title_len]);

    try std.testing.expectEqual(contract.Status.selected, selection.status);
    try std.testing.expectEqual(@as(usize, 2), selection.paths.len);
    try std.testing.expectEqualStrings("/home/u/Projects/My Folder", selection.paths[0]);
    try std.testing.expectEqualStrings("/home/u/Notes/draft.md", selection.paths[1]);
    selection.deinit(std.testing.allocator);
}

test "a portal that refuses the first call still gets answered" {
    // The regression this file needed and did not have.
    liveLock();
    defer liveUnlock();
    var service = try startFakePortal();
    defer service.deinit();

    // `code = 0` is the portal's "dismissed" answer, and it is the one this test wants: the subject is that the client is ANSWERED at all after a refusal.
    var responder = Responder{ .service = &service, .refuse_first = 1, .code = 0 };
    const thread = try std.Thread.spawn(.{}, Responder.threadMain, .{&responder});

    var client = Client.connect(std.testing.allocator) catch return error.SkipZigTest;
    defer client.deinit();
    client.service_name = fake_portal_name;

    const selection = try client.choose(.{
        .kind = .open_file,
        .title = "test",
        .filters = &.{
            .{ .name = "All files", .rules = &.{.{ .pattern = "*" }} },
        },
        .timeout_ms = 5_000,
    });
    thread.join();
    if (responder.err) |e| return e;

    try std.testing.expectEqual(contract.Status.cancelled, selection.status);
    selection.deinit(std.testing.allocator);
}

test "a dismissed dialog is a status, not an error" {
    liveLock();
    defer liveUnlock();
    var service = try startFakePortal();
    defer service.deinit();

    var responder = Responder{ .service = &service, .code = 0 };
    const thread = try std.Thread.spawn(.{}, Responder.threadMain, .{&responder});

    var client = Client.connect(std.testing.allocator) catch return error.SkipZigTest;
    defer client.deinit();
    client.service_name = fake_portal_name;

    const selection = try client.choose(.{ .kind = .open_file, .timeout_ms = 15_000 });
    thread.join();
    if (responder.err) |e| return e;

    // The user closed the window on purpose.
    try std.testing.expectEqual(contract.Status.cancelled, selection.status);
    try std.testing.expectEqual(@as(usize, 0), selection.paths.len);
    try std.testing.expectEqual(@as(?[]const u8, null), selection.first());
    selection.deinit(std.testing.allocator);
}

test "with no portal on the bus the client says so, rather than waiting forever" {
    liveLock();
    defer liveUnlock();

    // This test needs the name to be FREE, which it is not on a desktop that has a real portal.
    {
        var probe = FakeService.connect(std.testing.allocator) catch return error.SkipZigTest;
        defer probe.deinit();
        if (try claimName(&probe, portal.desktop_service) != .claimed) return error.SkipZigTest;
    }

    // With no portal owning the name, the bus answers the chooser call with ServiceUnknown — which is exactly what an app on a bare Wayland session with no.
    var client = Client.connect(std.testing.allocator) catch return error.SkipZigTest;
    defer client.deinit();

    try std.testing.expectError(
        error.NoPortal,
        client.choose(.{ .kind = .open_file, .timeout_ms = 5_000 }),
    );
}

test "a request that is never answered times out instead of hanging" {
    liveLock();
    defer liveUnlock();
    var service = try startFakePortal();
    defer service.deinit();

    // A portal that takes the call, answers it, and then says nothing — the user leaving the dialog open forever.
    var responder = Responder{ .service = &service, .code = 0, .uris = &.{} };
    var silent = true;
    responder.uris = &.{};
    const thread = try std.Thread.spawn(.{}, struct {
        fn go(r: *Responder, s: *bool) void {
            // Reply with the handle, then never emit the Response.
            const msg = (r.service.next() catch return) orelse return;
            var path_buf: [256]u8 = undefined;
            const token = Responder.findOptionToken(msg.body) orelse return;
            const request_path = portal.writeRequestPath(msg.sender orelse return, token, &path_buf) catch return;
            r.service.replyHandle(msg, request_path) catch return;
            s.* = false;
        }
    }.go, .{ &responder, &silent });

    var client = Client.connect(std.testing.allocator) catch return error.SkipZigTest;
    defer client.deinit();
    client.service_name = fake_portal_name;

    // 300 ms is long enough for a local bus round trip and short enough to keep the suite quick.
    try std.testing.expectError(
        error.Timeout,
        client.choose(.{ .kind = .open_file, .timeout_ms = 300 }),
    );
    thread.join();
}
