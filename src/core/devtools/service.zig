// The devtool service: the state machine a running app runs inside its frame loop, so a client can read the tree and act on it.
const std = @import("std");
const cl = @import("zclay");
const host_mod = @import("../host.zig");
const snapshot_mod = @import("snapshot.zig");
const cli = @import("cli.zig");

// The longest request line a client may send, and the largest reply one request can produce.
pub const request_cap = 512;
pub const reply_cap = 128 * 1024;

// A long press holds for this many frames after the press, which is far past a click's release.
const long_press_frames = 10;

// What a request is owed. The choice is made before the app declares and the answer is built once the tree is resolved.
const Owed = union(enum) {
    // Nothing to answer: no request arrived this frame.
    none,
    // The tree as text, or as JSON.
    tree,
    json,
    // One node, by point.
    pick: cl.Vector2,
    // The request was not understood; the body is the complaint.
    refuse,
};

pub const Service = struct {
    // One slot each way, handshaked by these flags: the transport releases its bytes before setting the flag, and the frame loop acquires it before reading them.
    request: [request_cap]u8 = undefined,
    request_len: usize = 0,
    request_ready: std.atomic.Value(bool) = .init(false),
    reply: [reply_cap]u8 = undefined,
    reply_len: usize = 0,
    reply_ready: std.atomic.Value(bool) = .init(false),
    // What this frame owes, decided in beginFrame and settled in endFrame.
    owed: Owed = .none,
    // A long press releases this many frames from now.
    release_in: u8 = 0,
    // How a transport wakes an idle app: a pipe write, a posted event, whatever that host needs.
    wake: ?*const fn (?*anyopaque) void = null,
    wake_ctx: ?*anyopaque = null,

    // The hooks the Host calls each frame.
    pub fn hooks(self: *Service) host_mod.ServiceHooks {
        return .{ .ptr = self, .begin = onBegin, .end = onEnd };
    }

    fn onBegin(ptr: *anyopaque, host: *host_mod.Host) void {
        const self: *Service = @ptrCast(@alignCast(ptr));
        self.beginFrame(host);
    }

    fn onEnd(ptr: *anyopaque, host: *host_mod.Host, w: u32, h: u32) void {
        const self: *Service = @ptrCast(@alignCast(ptr));
        self.endFrame(host, w, h);
    }

    // ---- the frame loop ----

    fn beginFrame(self: *Service, host: *host_mod.Host) void {
        // A press held from an earlier frame ends here, before the app declares, so the release looks like a user's.
        if (self.release_in > 0) {
            self.release_in -= 1;
            if (self.release_in == 0) host.onPointerEvent(host.ptr.down_x, host.ptr.down_y, false, left_button);
        }
        // Take the request, then run app code knowing the slot is free for the next one.
        var line: [request_cap]u8 = undefined;
        var len: usize = 0;
        if (self.request_ready.load(.acquire)) {
            len = self.request_len;
            @memcpy(line[0..len], self.request[0..len]);
            self.request_ready.store(false, .release);
        }
        if (len == 0) return;
        self.handle(host, line[0..len]);
    }

    // One request line, answered on this frame. An action fires here and the reply is built after the app has laid out again.
    fn handle(self: *Service, host: *host_mod.Host, line: []const u8) void {
        const text = std.mem.trim(u8, line, " \t\r\n");
        if (text.len == 0) {
            self.owed = .none;
            return;
        }
        if (std.mem.eql(u8, text, "tree")) {
            self.owed = .tree;
            return;
        }
        if (std.mem.eql(u8, text, "json")) {
            self.owed = .json;
            return;
        }
        if (std.mem.eql(u8, text, "quit")) {
            host.quit_requested = true;
            self.owed = .tree;
            return;
        }
        if (std.mem.startsWith(u8, text, "pick ")) {
            const point = cli.parsePoint(std.mem.trim(u8, text["pick ".len..], " ")) orelse {
                self.refuse("pick needs X,Y");
                return;
            };
            self.owed = .{ .pick = point };
            return;
        }
        if (std.mem.startsWith(u8, text, "do ")) {
            const spec = std.mem.trim(u8, text["do ".len..], " ");
            const action = cli.parseAction(spec) orelse {
                self.refuse("unknown action");
                return;
            };
            if (action.kind == .key) {
                const code = std.fmt.parseInt(u32, action.target, 10) catch {
                    self.refuse("key needs a code");
                    return;
                };
                _ = host.onKeyEvent(code, true);
                _ = host.onKeyEvent(code, false);
                self.owed = .tree;
                return;
            }
            const at = cli.targetOf(action) catch {
                self.refuse("no component with that tag");
                return;
            };
            if (action.kind == .longpress) {
                // The press now, the release after a few frames: what a finger held down looks like to the app.
                cli.performOn(host, .{ .kind = .press, .target = action.target }, at) catch {};
                self.release_in = long_press_frames;
                self.owed = .tree;
                return;
            }
            cli.performOn(host, action, at) catch {
                self.refuse("action failed");
                return;
            };
            self.owed = .tree;
            return;
        }
        self.refuse("unknown request");
    }

    fn refuse(self: *Service, why: []const u8) void {
        const n = @min(why.len, self.reply.len);
        @memcpy(self.reply[0..n], why[0..n]);
        self.reply_len = n;
        self.reply_ready.store(true, .release);
        self.owed = .none;
    }

    // The tree is resolved by now, so the answer describes the frame the action produced.
    fn endFrame(self: *Service, host: *host_mod.Host, w: u32, h: u32) void {
        _ = host;
        const owed = self.owed;
        if (owed == .none) return;
        self.owed = .none;

        var out = std.Io.Writer.fixed(&self.reply);
        const snap = snapshot_mod.Snapshot.build(w, h);
        const result: std.Io.Writer.Error!void = switch (owed) {
            // `refuse` already answered; reaching here means an empty answer is the honest one.
            .none, .refuse => {},
            .tree => snap.writeText(&out, 32),
            .json => snap.writeJson(&out, .{ .depth = 32, .pretty = true }),
            .pick => |p| snap.writeTextPick(&out, p.x, p.y),
        };
        result catch |err| {
            const text = @errorName(err);
            const n = @min(text.len, self.reply.len);
            @memcpy(self.reply[0..n], text[0..n]);
            self.reply_len = n;
            self.reply_ready.store(true, .release);
            return;
        };
        self.reply_len = out.buffered().len;
        self.reply_ready.store(true, .release);
    }

    // ---- the transport side ----

    // Hand a request to the frame loop and wake the app; returns once the loop has taken the previous one.
    pub fn submit(self: *Service, line: []const u8) void {
        while (self.request_ready.load(.acquire)) std.Thread.yield() catch {};
        const n = @min(line.len, self.request.len);
        @memcpy(self.request[0..n], line[0..n]);
        self.request_len = n;
        self.request_ready.store(true, .release);
        if (self.wake) |wake| wake(self.wake_ctx);
    }

    // Wait for the frame loop's answer; the caller sends it and then calls releaseReply.
    pub fn takeReply(self: *Service) []const u8 {
        while (!self.reply_ready.load(.acquire)) std.Thread.yield() catch {};
        return self.reply[0..self.reply_len];
    }

    pub fn releaseReply(self: *Service) void {
        self.reply_ready.store(false, .release);
    }
};

const left_button = @import("../component.zig").dispatch.BTN_LEFT;

test "a tree request answers with the app's own nodes" {
    var service = Service{};
    var rig = Rig{};
    try rig.init(&service);
    defer rig.deinit();

    service.submit("tree");
    rig.frame();
    const body = service.takeReply();
    defer service.releaseReply();
    try std.testing.expect(std.mem.indexOf(u8, body, "svc.root") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "svc.toggle") != null);
}

test "an action runs through the app's own handler, and the reply is the tree after it" {
    var service = Service{};
    var rig = Rig{};
    try rig.init(&service);
    defer rig.deinit();

    service.submit("do click:svc.toggle");
    rig.frame();
    const body = service.takeReply();
    defer service.releaseReply();
    // The toggle's checked state comes from the app's state, so the reply is the evidence the click landed.
    try std.testing.expect(rig.app.on);
    try std.testing.expect(std.mem.indexOf(u8, body, "flags=[enabled,checked]") != null);
}

test "a long press holds the button down for later frames, and the release arrives" {
    var service = Service{};
    var rig = Rig{};
    try rig.init(&service);
    defer rig.deinit();

    service.submit("do longpress:svc.button");
    rig.frame();
    service.releaseReply();
    // Still held: the press is down and nothing has fired yet.
    try std.testing.expect(rig.host.ptr.down);
    var i: usize = 0;
    while (i < long_press_frames + 1) : (i += 1) rig.frame();
    try std.testing.expect(!rig.host.ptr.down);
    try std.testing.expectEqual(@as(u32, 1), rig.app.clicks);
}

test "pick answers with one node, and a bad request says so" {
    var service = Service{};
    var rig = Rig{};
    try rig.init(&service);
    defer rig.deinit();

    service.submit("pick 10,10");
    rig.frame();
    {
        const body = service.takeReply();
        try std.testing.expect(std.mem.indexOf(u8, body, "pick 10.0,10.0 -> svc.toggle") != null);
    }
    service.releaseReply();

    service.submit("do click:no.such.tag");
    rig.frame();
    const refused = service.takeReply();
    defer service.releaseReply();
    try std.testing.expect(std.mem.indexOf(u8, refused, "no component with that tag") != null);
}

test "quit is the app's own quit, so the window loop ends it" {
    var service = Service{};
    var rig = Rig{};
    try rig.init(&service);
    defer rig.deinit();

    try std.testing.expect(!rig.host.isQuit());
    service.submit("quit");
    rig.frame();
    try std.testing.expect(rig.host.isQuit());
    service.releaseReply();
}

// ---- An app to drive ----

const box_mod = @import("../component.zig").box;
const button_mod = @import("../component.zig").button;
const toggle_mod = @import("../component.zig").toggle;

const App = struct {
    on: bool = false,
    clicks: u32 = 0,

    fn root(ctx: ?*anyopaque, _: u32, _: u32) void {
        box_mod.box(.{
            .id = .{ .text = "svc.root" },
            .direction = .column,
            .w = .grow,
            .h = .grow,
        }, ctx, children);
    }

    fn children(ctx: ?*anyopaque) void {
        const self: *App = @ptrCast(@alignCast(ctx.?));
        toggle_mod.toggle(.{
            .id = .{ .text = "svc.toggle" },
            .on = self.on,
            .on_click = .{ .f = onToggle, .ctx = self },
        });
        button_mod.button(.{
            .id = .{ .text = "svc.button" },
            .label = .{ .text = "Go" },
            .w = .{ .fixed = 80 },
            .h = .{ .fixed = 30 },
            .on_click = .{ .f = onButton, .ctx = self },
        });
    }

    fn onToggle(ctx: ?*anyopaque) void {
        const self: *App = @ptrCast(@alignCast(ctx.?));
        self.on = !self.on;
    }

    fn onButton(ctx: ?*anyopaque) void {
        const self: *App = @ptrCast(@alignCast(ctx.?));
        self.clicks += 1;
    }
};

const Rig = struct {
    app: App = .{},
    host: host_mod.Host = undefined,

    fn init(self: *Rig, service: *Service) !void {
        // page_allocator, matching every other Host test: the Clay arena is process-lifetime by design.
        self.host = try host_mod.Host.init(std.heap.page_allocator, &self.app, App.root);
        self.host.service = service.hooks();
        // Warm up with the service already hooked: a click lands in the last frame's registry, and the tree must be resolved for a tag to have a centre.
        self.frame();
        self.frame();
    }

    fn deinit(self: *Rig) void {
        _ = self;
    }

    // One frame, the way the window loop runs it: the service's hooks are inside.
    fn frame(self: *Rig) void {
        self.host.frame(320, 240);
    }
};
