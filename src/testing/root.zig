//! Reusable headless UI testing for glinlandui applications.
//!
//! The harness deliberately drives `wayland.Host` instead of reimplementing
//! layout or input. It therefore exercises the same pointer/key/scroll path,
//! Clay arena, component registry, and render-command production used by the
//! application. No Wayland display, EGL context, or GPU is required.
//!
//! Typical use:
//!!
//! ```zig
//! const ui = @import("glinlandui");
//! const Driver = ui.testing.Driver;
//!
//! test "save button applies" {
//!     var app = App{};
//!     var driver = try Driver.init(std.testing.allocator, &app, App.root);
//!     defer driver.deinit();
//!
//!     try driver.start(.{ .width = 720, .height = 480 });
//!     try driver.click("settings.save-button");
//!     try driver.expectText("Saved");
//!     try std.testing.expect(app.saved);
//! }
//! ```
//!
//! IDs passed to the driver are the same stable string IDs used by component
//! declarations (for example `"settings.save-button"`). Coordinate helpers
//! remain available for tests of gestures, but semantic-ID helpers should be
//! preferred.
const std = @import("std");
const host_mod = @import("../wayland/host.zig");
const frame_mod = @import("../wayland/frame.zig");
const dispatch = @import("../components/dispatch.zig");
const cl = @import("zclay");

pub const Host = host_mod.Host;
pub const BoundingBox = cl.BoundingBox;
pub const Color = cl.Color;
pub const RenderCommand = cl.RenderCommand;
pub const RenderCommandType = cl.RenderCommandType;
pub const ElementId = cl.ElementId;

/// A stable result from the most recently completed frame. Command bytes and
/// text bytes live only until the next frame; query them before requesting the
/// next frame. Element boxes and command records are copied into fixed test
/// storage, so common assertions remain valid after a later frame.
pub const FrameSnapshot = struct {
    width: u32 = 0,
    height: u32 = 0,
    command_count: usize = 0,
    text_count: usize = 0,
    rectangle_count: usize = 0,
    image_count: usize = 0,
    border_count: usize = 0,
    scissor_count: usize = 0,
    pointer_x: f32 = 0,
    pointer_y: f32 = 0,
    pointer_down: bool = false,
    cursor_shape: u32 = 0,
};

/// IDs are looked up after each frame, so a test can target any stable Clay
/// ID without hard-coding screen coordinates.
pub const Driver = struct {
    alloc: std.mem.Allocator,
    host: *Host,
    viewport: Viewport,
    last_frame: FrameSnapshot = .{},
    last_commands: [command_storage_cap]RenderCommand = undefined,
    last_command_len: usize = 0,
    last_texts: [text_storage_cap][text_storage_bytes]u8 = undefined,
    last_text_lens: [text_storage_cap]usize = undefined,
    last_text_count: usize = 0,
    options: frame_mod.FrameOptions = .{},
    initialized: bool = false,

    const command_storage_cap: usize = 2048;
    const text_storage_cap: usize = 256;
    const text_storage_bytes: usize = 512;

    pub const Viewport = struct {
        width: u32 = 720,
        height: u32 = 480,
    };

    /// Initialize a driver around an already-created Host. This is useful
    /// when the application owns Host state and wants to inspect it directly.
    pub fn init(alloc: std.mem.Allocator, host: *Host) Driver {
        return .{ .alloc = alloc, .host = host, .viewport = .{} };
    }

    /// Initialize a Host with the supplied application root callback. The
    /// Host is intentionally owned by the driver; call deinit when the test
    /// ends. The allocator is used by Host for its Clay arena.
    pub fn initOwned(
        alloc: std.mem.Allocator,
        ctx: ?*anyopaque,
        root_fn: host_mod.RootFn,
    ) !Driver {
        const host = try alloc.create(Host);
        errdefer alloc.destroy(host);
        host.* = try Host.init(alloc, ctx, root_fn);
        return .{ .alloc = alloc, .host = host, .viewport = .{}, .initialized = true };
    }

    pub fn deinit(self: *Driver) void {
        if (self.initialized) {
            // Clay stores a process-global pointer into the most recently
            // initialized arena. Freeing that arena would make the next
            // Host.init() read a dangling currentContext in
            // Clay_MinMemorySize(). Keep the page-allocator arena alive for
            // the rest of the test process; this path is only for the
            // headless test harness, not a production allocator owner.
            self.alloc.destroy(self.host);
            self.host = undefined;
            self.initialized = false;
        }
    }

    /// Run the initial frame at a deterministic viewport.
    pub fn start(self: *Driver, viewport: Viewport) !void {
        try self.resize(viewport.width, viewport.height);
    }

    /// Change the viewport and render the next frame.
    pub fn resize(self: *Driver, width: u32, height: u32) !void {
        if (width == 0 or height == 0) return error.InvalidViewport;
        self.viewport = .{ .width = width, .height = height };
        self.host.onResizeEvent(width, height);
        self.frame();
    }

    /// Render one frame through the normal Host/Clay frame path.
    pub fn frame(self: *Driver) void {
        self.last_command_len = 0;
        self.last_text_count = 0;
        self.options = .{
            .probe = captureFrame,
            .probe_user_data = @ptrCast(self),
        };
        const shape = frame_mod.clayFrameWithOptions(
            self.alloc,
            &self.host.renderer,
            &self.host.renderer_attempted,
            self.host.ptr.x,
            self.host.ptr.y,
            self.host.ptr.down,
            self.host.scroll_dx,
            self.host.scroll_dy,
            self.viewport.width,
            self.viewport.height,
            declareThunk,
            @ptrCast(self),
            &self.options,
        );
        self.last_frame.cursor_shape = shape;
        self.last_frame.width = self.viewport.width;
        self.last_frame.height = self.viewport.height;
        self.last_frame.pointer_x = self.host.ptr.x;
        self.last_frame.pointer_y = self.host.ptr.y;
        self.last_frame.pointer_down = self.host.ptr.down;
    }

    /// Move the pointer and render a frame. `button` is normally 0 for a
    /// motion-only event; the current Host contract accepts it for parity
    /// with Wayland forwarding.
    pub fn move(self: *Driver, x: f32, y: f32) void {
        self.host.onPointerEvent(x, y, false, 0);
        self.frame();
    }

    /// Press and release at a point, rendering once after the complete
    /// gesture. This matches Host's release-based click semantics.
    pub fn clickAt(self: *Driver, x: f32, y: f32) void {
        self.host.onPointerEvent(x, y, true, dispatch.BTN_LEFT);
        self.host.onPointerEvent(x, y, false, dispatch.BTN_LEFT);
        self.frame();
    }

    /// Click the center of a stable element ID.
    pub fn click(self: *Driver, id: []const u8) !void {
        const element_box = self.box(id) orelse return error.ElementNotFound;
        const x = element_box.x + element_box.width * 0.5;
        const y = element_box.y + element_box.height * 0.5;
        self.clickAt(x, y);
    }

    /// Press at a point without releasing. The next motion/release event is
    /// delivered through the same Host state as a real Wayland gesture.
    pub fn pressAt(self: *Driver, x: f32, y: f32) void {
        self.host.onPointerEvent(x, y, true, dispatch.BTN_LEFT);
        self.frame();
    }

    /// Release a previously pressed point.
    pub fn releaseAt(self: *Driver, x: f32, y: f32) void {
        self.host.onPointerEvent(x, y, false, dispatch.BTN_LEFT);
        self.frame();
    }

    /// Drag from one point to another with one motion event. The final
    /// release is sent with button 0, matching the framework's current tests
    /// and its drag-threshold contract.
    pub fn drag(self: *Driver, x0: f32, y0: f32, x1: f32, y1: f32) void {
        self.host.onPointerEvent(x0, y0, true, dispatch.BTN_LEFT);
        self.host.onPointerEvent(x1, y1, false, 0);
        self.host.onPointerEvent(x1, y1, false, dispatch.BTN_LEFT);
        self.frame();
    }

    pub fn scroll(self: *Driver, dx: f32, dy: f32) void {
        self.host.onScrollEvent(dx, dy);
        self.frame();
    }

    pub fn key(self: *Driver, keycode: u32) !bool {
        const consumed = self.host.onKeyEvent(keycode, true);
        _ = self.host.onKeyEvent(keycode, false);
        self.frame();
        return consumed;
    }

    /// Type a string as raw evdev key presses. The input component owns the
    /// exact US-layout mapping; this helper is intentionally simple and
    /// handles ASCII letters/digits, space, and a few common punctuation keys.
    pub fn typeText(self: *Driver, input_text: []const u8) !void {
        for (input_text) |byte| {
            const code = keyCodeForAscii(byte) orelse return error.UnsupportedCharacter;
            _ = try self.key(code);
        }
    }

    /// Return the current geometry for a stable ID.
    pub fn box(self: *Driver, id: []const u8) ?BoundingBox {
        _ = self;
        const data = cl.getElementData(cl.getElementId(id));
        if (!data.found) return null;
        return data.bounding_box;
    }

    pub fn exists(self: *Driver, id: []const u8) bool {
        return self.box(id) != null;
    }

    pub fn isPointerOver(self: *Driver, id: []const u8) bool {
        _ = self;
        return cl.pointerOver(cl.getElementId(id));
    }

    /// Iterate/count commands in the most recent frame.
    pub fn commands(self: *const Driver) []const RenderCommand {
        return self.last_commands[0..self.last_command_len];
    }

    pub fn texts(self: *const Driver) []const []const u8 {
        // This intentionally remains a lightweight compatibility method.
        // Prefer hasText/expectText for assertions; returning a slice-of-slices
        // would require temporary storage in a value-returning method.
        _ = self;
        return &.{};
    }

    pub fn hasText(self: *const Driver, expected: []const u8) bool {
        for (self.last_texts[0..self.last_text_count], 0..) |*bytes, i| {
            if (std.mem.eql(u8, bytes[0..self.last_text_lens[i]], expected)) return true;
        }
        return false;
    }

    pub fn expectText(self: *const Driver, expected: []const u8) !void {
        if (!self.hasText(expected)) return error.TextNotFound;
    }

    pub fn expectNoText(self: *const Driver, unexpected: []const u8) !void {
        if (self.hasText(unexpected)) return error.UnexpectedText;
    }

    pub fn snapshot(self: *const Driver) FrameSnapshot {
        return self.last_frame;
    }

    /// Find a command by stable Clay numeric ID. This is mainly for command
    /// snapshots and color assertions; normal tests should use semantic IDs.
    pub fn commandForId(self: *const Driver, id: []const u8) ?RenderCommand {
        const numeric = cl.getElementId(id).id;
        for (self.commands()) |cmd| {
            if (cmd.id == numeric) return cmd;
        }
        return null;
    }

    pub fn expectRectColor(self: *const Driver, id: []const u8, expected: Color) !void {
        const cmd = self.commandForId(id) orelse return error.ElementNotRendered;
        if (cmd.command_type != .rectangle) return error.NotRectangle;
        try expectColor(expected, cmd.render_data.rectangle.background_color);
    }

    fn expectColor(expected: Color, actual: Color) !void {
        for (expected, actual) |e, a| {
            try std.testing.expectApproxEqAbs(e, a, 0.001);
        }
    }

    pub fn text(self: *const Driver, index: usize) ?[]const u8 {
        if (index >= self.last_text_count) return null;
        return self.last_texts[index][0..self.last_text_lens[index]];
    }

    fn captureFrame(
        user_data: ?*anyopaque,
        frame_commands: []const RenderCommand,
        width: u32,
        height: u32,
    ) void {
        const self: *Driver = @ptrCast(@alignCast(user_data.?));
        self.last_frame.width = width;
        self.last_frame.height = height;
        self.last_frame.command_count = frame_commands.len;
        self.last_frame.text_count = 0;
        self.last_frame.rectangle_count = 0;
        self.last_frame.image_count = 0;
        self.last_frame.border_count = 0;
        self.last_frame.scissor_count = 0;

        const count = @min(frame_commands.len, self.last_commands.len);
        @memcpy(self.last_commands[0..count], frame_commands[0..count]);
        self.last_command_len = count;

        for (frame_commands) |cmd| {
            switch (cmd.command_type) {
                .text => {
                    self.last_frame.text_count += 1;
                    if (self.last_text_count < self.last_texts.len) {
                        const src = cmd.render_data.text.string_contents;
                        const len = @min(@as(usize, @intCast(src.length)), text_storage_bytes);
                        @memcpy(self.last_texts[self.last_text_count][0..len], src.chars[0..len]);
                        self.last_text_lens[self.last_text_count] = len;
                        self.last_text_count += 1;
                    }
                },
                .rectangle => self.last_frame.rectangle_count += 1,
                .image => self.last_frame.image_count += 1,
                .border => self.last_frame.border_count += 1,
                .scissor_start, .scissor_end => self.last_frame.scissor_count += 1,
                else => {},
            }
        }
    }

    fn declareThunk(ctx: *anyopaque, w: u32, h: u32) void {
        const self: *Driver = @ptrCast(@alignCast(ctx));
        self.host.root_fn(self.host.root_ctx, w, h);
    }
};

/// Stable public alias so applications can declare their own root callback
/// without depending on the private test implementation type.
pub const RootFn = host_mod.RootFn;

/// Linux evdev code table for the subset used by `Driver.typeText`.
fn keyCodeForAscii(byte: u8) ?u32 {
    return switch (byte) {
        'a'...'z' => @as(u32, byte - 'a') + 16,
        'A'...'Z' => @as(u32, byte - 'A') + 16,
        '0'...'9' => @as(u32, byte - '0') + 2,
        ' ' => 57,
        '-' => 12,
        '=' => 13,
        '[' => 26,
        ']' => 27,
        '\\' => 43,
        ';' => 39,
        '\'' => 40,
        '`' => 41,
        ',' => 51,
        '.' => 52,
        '/' => 53,
        else => null,
    };
}

test "driver exposes deterministic viewport and empty root" {
    const root = struct {
        fn declare(_: ?*anyopaque, _: u32, _: u32) void {}
    }.declare;
    var driver = try Driver.initOwned(std.heap.page_allocator, null, root);
    defer driver.deinit();
    try driver.start(.{ .width = 800, .height = 600 });
    try std.testing.expectEqual(@as(u32, 800), driver.viewport.width);
    try std.testing.expectEqual(@as(u32, 600), driver.viewport.height);
    try std.testing.expectEqual(@as(usize, 0), driver.snapshot().text_count);
}

test "driver captures a real component frame" {
    const button = @import("../components/button.zig");
    const Rec = struct { clicks: usize = 0 };
    const App = struct {
        state: Rec = .{},
        fn root(ctx: ?*anyopaque, _: u32, _: u32) void {
            const app: *@This() = @ptrCast(@alignCast(ctx.?));
            button.button(.{
                .id = "testkit-button",
                .label = "OK",
                .w = 100,
                .h = 40,
                .on_click = onClick,
                .ctx = &app.state,
            });
        }
        fn onClick(ctx: ?*anyopaque) void {
            const rec: *Rec = @ptrCast(@alignCast(ctx.?));
            rec.clicks += 1;
        }
    };
    var app = App{};
    var driver = try Driver.initOwned(std.heap.page_allocator, &app, App.root);
    defer driver.deinit();
    try driver.start(.{});
    try std.testing.expect(driver.exists("testkit-button"));
    try driver.expectText("OK");
    try driver.click("testkit-button");
    try std.testing.expectEqual(@as(usize, 1), app.state.clicks);
    try driver.expectRectColor("testkit-button", .{ 45, 45, 45, 255 });
}

test "driver follows pointer press/release and keyboard routes" {
    const input = @import("../components/input.zig");
    const App = struct {
        key_hits: usize = 0,
        fn root(_: ?*anyopaque, _: u32, _: u32) void {}
        fn onKey(ctx: ?*anyopaque, _: input.Mods, keycode: u32) bool {
            _ = keycode;
            const app: *@This() = @ptrCast(@alignCast(ctx.?));
            app.key_hits += 1;
            return true;
        }
    };
    var app = App{};
    var driver = try Driver.initOwned(std.heap.page_allocator, &app, App.root);
    defer driver.deinit();
    try driver.start(.{});
    driver.pressAt(10, 10);
    try std.testing.expect(driver.host.ptr.down);
    driver.releaseAt(10, 10);
    try std.testing.expect(!driver.host.ptr.down);
    driver.host.keys.register(App.onKey, &app);
    try std.testing.expect(try driver.key(input.KEY_A));
    try std.testing.expectEqual(@as(usize, 1), app.key_hits);
}
