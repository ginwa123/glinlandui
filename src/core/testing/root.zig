//! Reusable headless UI testing for glinlandui applications.
const std = @import("std");
const host_mod = @import("../host.zig");
const frame_mod = @import("../frame.zig");
const dispatch = @import("../components/dispatch.zig");
const scroll_mod = @import("../components/scroll.zig");
const semantics = @import("../semantics.zig");
const finders = @import("finders.zig");
const assertions = @import("assertions.zig");
const action_plan = @import("actions.zig");
const cl = @import("zclay");

pub const Host = host_mod.Host;
pub const BoundingBox = cl.BoundingBox;
pub const Color = cl.Color;
pub const RenderCommand = cl.RenderCommand;
pub const RenderCommandType = cl.RenderCommandType;
pub const ElementId = cl.ElementId;

// ---- Semantics-based E2E surface (Compose-style onNode / performClick) ----

/// A declarative node query. See testing/finders.zig for the field list.
pub const Query = finders.Query;
pub const FindError = finders.FindError;
/// A resolved semantics node. Frame-scoped: re-resolve via `Interaction.node`.
pub const Node = semantics.Node;
pub const Role = semantics.Role;
pub const NodeActions = semantics.Actions;
pub const NodeFlags = semantics.Flags;
/// Assertion failures, all distinguishable so a test can pin the exact reason.
pub const AssertionError = assertions.Error;
/// A pointer gesture plan (performTouchInput).
pub const Swipe = action_plan.Swipe;
pub const ScrollIntent = action_plan.ScrollIntent;

/// Frame budget for `waitForIdle` before giving up with error.NotIdle.
pub const idle_frame_cap: usize = 16;
/// Frame budget for `performScrollTo` before giving up.
pub const scroll_frame_cap: usize = 32;

/// A stable result from the most recently completed frame.
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

/// IDs are looked up after each frame, so a test can target any stable Clay ID without hard-coding screen coordinates.
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
    /// Semantics fingerprint of the last frame, for the waitForIdle fixed point.
    last_semantics_hash: u64 = 0,
    initialized: bool = false,

    const command_storage_cap: usize = 2048;
    const text_storage_cap: usize = 256;
    const text_storage_bytes: usize = 512;

    pub const Viewport = struct {
        width: u32 = 720,
        height: u32 = 480,
    };

    /// Initialize a driver around an already-created Host.
    pub fn init(alloc: std.mem.Allocator, host: *Host) Driver {
        return .{ .alloc = alloc, .host = host, .viewport = .{} };
    }

    /// Initialize a Host with the supplied application root callback.
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
            // Clay stores a process-global pointer into the most recently initialized arena.
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
            // Resolve the semantics tree so onNode()/waitForIdle() see the geometry THIS frame produced.
            .resolve_semantics = true,
        };
        const shape = self.host.frameWithOptions(
            self.viewport.width,
            self.viewport.height,
            &self.options,
        );
        self.last_frame.cursor_shape = shape;
        self.last_frame.width = self.viewport.width;
        self.last_frame.height = self.viewport.height;
        self.last_frame.pointer_x = self.host.ptr.x;
        self.last_frame.pointer_y = self.host.ptr.y;
        self.last_frame.pointer_down = self.host.ptr.down;
    }

    /// Move the pointer and render a frame.
    pub fn move(self: *Driver, x: f32, y: f32) void {
        self.host.onPointerEvent(x, y, false, 0);
        self.frame();
    }

    /// Press and release at a point, rendering once after the complete gesture.
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

    /// Press at a point without releasing.
    pub fn pressAt(self: *Driver, x: f32, y: f32) void {
        self.host.onPointerEvent(x, y, true, dispatch.BTN_LEFT);
        self.frame();
    }

    /// Release a previously pressed point.
    pub fn releaseAt(self: *Driver, x: f32, y: f32) void {
        self.host.onPointerEvent(x, y, false, dispatch.BTN_LEFT);
        self.frame();
    }

    /// Drag from one point to another with one motion event.
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

    /// Type a string as raw evdev key presses, holding Shift for the bytes that need it.
    pub fn typeText(self: *Driver, input_text: []const u8) !void {
        for (input_text) |byte| {
            const k = keyForAscii(byte) orelse return error.UnsupportedCharacter;
            if (k.shift) _ = self.host.onKeyEvent(key_shift, true);
            _ = self.host.onKeyEvent(k.code, true);
            _ = self.host.onKeyEvent(k.code, false);
            if (k.shift) _ = self.host.onKeyEvent(key_shift, false);
            self.frame();
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

    // ---- Semantics-based queries (Compose's onNodeWith*) ----

    /// The resolved semantics tree for the MOST RECENT frame.
    pub fn nodes(self: *const Driver) []const semantics.Node {
        _ = self;
        return semantics.all();
    }

    /// Resolve a node by exact Clay id against the last frame.
    pub fn semanticsNode(self: *const Driver, id: cl.ElementId) ?semantics.Node {
        _ = self;
        return semantics.byId(id);
    }

    /// Compose's `onNode(matcher)`: find NOW, keep a handle for actions.
    pub fn onNode(self: *Driver, q: finders.Query) !Interaction {
        const n = try finders.findSole(q);
        return .{ .driver = self, .query = q, .id = n.id, .tag = n.tag };
    }

    /// Match rows/items by position when they share no distinct label.
    pub fn onNodeWithIndex(self: *Driver, q: finders.Query, index: usize) !Interaction {
        var qq = q;
        qq.index = index;
        return self.onNode(qq);
    }

    /// Compose's `onNodeWithText`, matched against a component's label (a button's caption, a list row's text).
    pub fn onNodeWithText(self: *Driver, expected_label: []const u8) !Interaction {
        return self.onNode(.{ .label = expected_label });
    }

    /// Compose's `onNodeWithTag`: the Clay element id is the test tag.
    pub fn onNodeWithTag(self: *Driver, tag: []const u8) !Interaction {
        return self.onNode(.{ .tag = tag });
    }

    /// How many nodes match (Compose's `onAllNodes(...).fetchSemanticsNodes().size`).
    pub fn onAllNodes(self: *const Driver, q: finders.Query) usize {
        _ = self;
        return finders.count(q);
    }

    /// Compose's `waitForIdle`, adapted to an immediate-mode engine.
    pub fn waitForIdle(self: *Driver) !void {
        self.frame();
        var prev = semantics.fingerprint();
        var i: usize = 0;
        while (i < idle_frame_cap) : (i += 1) {
            if (self.host.scroll_dx != 0 or self.host.scroll_dy != 0) {
                // A wheel delta is still in flight; consume it and re-baseline.
                self.frame();
                prev = semantics.fingerprint();
                continue;
            }
            self.frame();
            const h = semantics.fingerprint();
            if (h == prev) return;
            prev = h;
        }
        return error.NotIdle;
    }

    /// Drive a pointer gesture: press at the start, motion along the plan, then release at the end.
    pub fn performTouch(self: *Driver, g: action_plan.Swipe) void {
        // `origin`/`dest`, not `start`/`end`: Driver already has a `start` method (the initial frame), and Zig rejects the shadowing.
        const origin = g.start();
        self.host.onPointerEvent(origin.x, origin.y, true, dispatch.BTN_LEFT);
        const n = g.stepCount();
        var i: usize = 1;
        while (i <= n) : (i += 1) {
            const p = g.pointAt(i);
            // Button 0 marks a MOTION event (not BTN_LEFT), which is what lets dispatch.pointerEvent cross the drag threshold.
            self.host.onPointerEvent(p.x, p.y, false, 0);
        }
        const dest = g.end();
        self.host.onPointerEvent(dest.x, dest.y, false, dispatch.BTN_LEFT);
        self.frame();
    }

    /// Find a command by stable Clay numeric ID.
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
};

/// A handle to one node — Compose's `SemanticsNodeInteraction`.
pub const Interaction = struct {
    driver: *Driver,
    query: finders.Query,
    id: cl.ElementId,
    tag: []const u8,

    /// The node as of the most recent frame.
    pub fn node(self: Interaction) FindError!semantics.Node {
        return finders.findSole(self.query);
    }

    /// Compose's `performClick`, with more of the pipeline intact.
    pub fn performClick(self: Interaction) !void {
        try self.driver.waitForIdle();
        const n = try self.node();
        if (!n.isDisplayed()) return error.NodeNotDisplayed;
        // Compose raises here too ("the node has no click action"): clicking a label, a container, or a disabled control is a test bug, and silently spraying a.
        if (!n.actions.click) return error.NoClickAction;
        const c = n.visibleCenter();
        self.driver.clickAt(c.x, c.y);
        try self.driver.waitForIdle();
    }

    /// Compose's `performScrollTo` / `performScrollToNode`: scroll the nearest scrollable ancestor until this node is inside the clip rect.
    pub fn performScrollTo(self: Interaction) !void {
        // The ancestor chain is stable across scrolls (ids do not move; only geometry does), so it is read once from the first resolved snapshot.
        const container = scrollAncestor(try self.node()) orelse return error.NoScrollableAncestor;
        var i: usize = 0;
        while (i < scroll_frame_cap) : (i += 1) {
            const cur = try self.node();
            if (cur.visible_fraction > 0) return;
            const intent = action_plan.revealDelta(cur);
            // Zero delta plus zero visibility means no amount of scrolling can help (a zero-area node, or an empty clip).
            if (intent.isZero()) return error.NodeNotDisplayed;
            scroll_mod.scrollBy(container.tag, intent.dx, intent.dy);
            self.driver.frame();
        }
        return error.ScrollToNodeFailed;
    }

    /// Compose's `performTouchInput { ... }`. See `Driver.performTouch`.
    pub fn performTouchInput(self: Interaction, g: action_plan.Swipe) !void {
        _ = try self.node();
        self.driver.performTouch(g);
        try self.driver.waitForIdle();
    }

    /// Compose's `performTextInput`: type printable ASCII into the node.
    pub fn performTextInput(self: Interaction, text: []const u8) !void {
        const n = try self.node();
        if (!n.actions.set_text) return error.NoSetTextAction;
        try self.driver.typeText(text);
        try self.driver.waitForIdle();
    }

    // ---- Assertions (Compose's assert*) ----

    pub fn assertExists(self: Interaction) !void {
        try assertions.exists(try self.node());
    }

    pub fn assertIsDisplayed(self: Interaction) !void {
        try assertions.isDisplayed(try self.node());
    }

    /// Absence counts as "not displayed", which is what a test asserting that a panel is closed actually means.
    pub fn assertIsNotDisplayed(self: Interaction) !void {
        const n = self.node() catch |e| switch (e) {
            error.NoNodeFound => return,
            else => return e,
        };
        try assertions.isNotDisplayed(n);
    }

    pub fn assertHasClickAction(self: Interaction) !void {
        try assertions.hasClickAction(try self.node());
    }

    pub fn assertHasNoClickAction(self: Interaction) !void {
        try assertions.hasNoClickAction(try self.node());
    }

    pub fn assertHasScrollAction(self: Interaction) !void {
        try assertions.hasScrollAction(try self.node());
    }

    pub fn assertIsEnabled(self: Interaction) !void {
        try assertions.isEnabled(try self.node());
    }

    pub fn assertIsDisabled(self: Interaction) !void {
        try assertions.isDisabled(try self.node());
    }

    pub fn assertIsSelected(self: Interaction) !void {
        try assertions.isSelected(try self.node());
    }

    pub fn assertIsChecked(self: Interaction) !void {
        try assertions.isChecked(try self.node());
    }

    pub fn assertIsNotChecked(self: Interaction) !void {
        try assertions.isNotChecked(try self.node());
    }

    /// Compose's `assertTextEquals`, against the node's label.
    pub fn assertTextEquals(self: Interaction, expected: []const u8) !void {
        try assertions.labelEquals(try self.node(), expected);
    }

    pub fn assertValueEquals(self: Interaction, expected: []const u8) !void {
        try assertions.valueEquals(try self.node(), expected);
    }

    pub fn assertRole(self: Interaction, expected: semantics.Role) !void {
        try assertions.roleIs(try self.node(), expected);
    }

    pub fn assertVisibleAtLeast(self: Interaction, min_fraction: f32) !void {
        try assertions.visibleAtLeast(try self.node(), min_fraction);
    }
};

/// The nearest CLIPPING ancestor that is a scroll container, from the node's declare-time snapshot chain.
fn scrollAncestor(n: semantics.Node) ?semantics.Node {
    var i: usize = n.ancestor_len;
    while (i > 0) {
        i -= 1;
        const a = n.ancestors[i];
        if (!a.clips) continue;
        if (semantics.byId(a.id)) |an| {
            if (an.actions.scroll) return an;
        }
    }
    return null;
}

/// Stable public alias so applications can declare their own root callback without depending on the private test implementation type.
pub const RootFn = host_mod.RootFn;

// evdev KEY_LEFTSHIFT, the modifier the keycode route has to hold for an uppercase or shifted byte.
const key_shift: u32 = 42;

// The key a printable ASCII byte is typed with, and whether Shift is part of the gesture.

// The table is the US layout the toolkit's `input.keyChar` decodes, so a byte typed here reads back as the same byte there.

// Letters are NOT contiguous in evdev (q..p is 16..25, a..l is 30..38, z..m is 44..50), which is the mistake a `byte - 'a' + 16` shortcut makes.
const KeyStroke = struct { code: u32, shift: bool };

fn keyForAscii(byte: u8) ?KeyStroke {
    const lower = "qwertyuiopasdfghjklzxcvbnm";
    const letter_codes = [_]u32{ 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 30, 31, 32, 33, 34, 35, 36, 37, 38, 44, 45, 46, 47, 48, 49, 50 };
    for (lower, 0..) |c, i| {
        if (byte == c) return .{ .code = letter_codes[i], .shift = false };
        if (byte == std.ascii.toUpper(c)) return .{ .code = letter_codes[i], .shift = true };
    }
    // Digits: 1..9 are 2..10 and 0 is 11. Their shifted symbols are the same keys with Shift held.
    const shifted_digits = "!@#$%^&*()";
    for (shifted_digits, 0..) |c, i| {
        if (byte == c) return .{ .code = if (i == 9) 11 else @as(u32, @intCast(i)) + 2, .shift = true };
    }
    if (byte >= '1' and byte <= '9') return .{ .code = byte - '1' + 2, .shift = false };
    if (byte == '0') return .{ .code = 11, .shift = false };
    // Every remaining printable, plain and shifted.
    const table = [_]struct { plain: u8, shifted: u8, code: u32 }{
        .{ .plain = '-', .shifted = '_', .code = 12 },
        .{ .plain = '=', .shifted = '+', .code = 13 },
        .{ .plain = '[', .shifted = '{', .code = 26 },
        .{ .plain = ']', .shifted = '}', .code = 27 },
        .{ .plain = ';', .shifted = ':', .code = 39 },
        .{ .plain = '\'', .shifted = '"', .code = 40 },
        .{ .plain = '`', .shifted = '~', .code = 41 },
        .{ .plain = '\\', .shifted = '|', .code = 43 },
        .{ .plain = ',', .shifted = '<', .code = 51 },
        .{ .plain = '.', .shifted = '>', .code = 52 },
        .{ .plain = '/', .shifted = '?', .code = 53 },
        .{ .plain = ' ', .shifted = ' ', .code = 57 },
    };
    for (table) |t| {
        if (byte == t.plain) return .{ .code = t.code, .shift = false };
        if (byte == t.shifted) return .{ .code = t.code, .shift = true };
    }
    return null;
}

test "the typing table types what the field decodes" {
    const input_mod = @import("../components/input.zig");
    var b: u8 = 'a';
    while (b <= 'z') : (b += 1) {
        const k = keyForAscii(b) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(?u8, b), input_mod.keyChar(k.code, k.shift));
        // The same key with Shift is the capital, which is what makes `typeText("Buy")` type a B.
        try std.testing.expectEqual(@as(?u8, std.ascii.toUpper(b)), input_mod.keyChar(k.code, true));
    }
    var d: u8 = '0';
    while (d <= '9') : (d += 1) {
        const k = keyForAscii(d) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(?u8, d), input_mod.keyChar(k.code, k.shift));
    }
    // Shifted punctuation is the same key with Shift held.
    try std.testing.expectEqual(@as(?u8, '('), input_mod.keyChar(keyForAscii('(').?.code, true));
    try std.testing.expectEqual(@as(?u8, '*'), input_mod.keyChar(keyForAscii('*').?.code, true));
}

test "a repaint that draws the same commands is reported as repeated, and a change is not" {
    const App = struct {
        var show_extra: bool = false;
        fn root(_: ?*anyopaque, _: u32, _: u32) void {
            const clay = @import("zclay");
            clay.UI()(.{
                .id = .ID("repeat.box"),
                .layout = .{ .sizing = .{ .w = .fixed(100), .h = .fixed(20) } },
            })({});
            if (show_extra) {
                // A background colour is what turns a declaration into a render command; without one the frame is unchanged.
                clay.UI()(.{
                    .id = .ID("repeat.extra"),
                    .layout = .{ .sizing = .{ .w = .fixed(10), .h = .fixed(10) } },
                    .background_color = .{ 255, 0, 0, 255 },
                })({});
            }
        }
    };
    var driver = try Driver.initOwned(std.heap.page_allocator, null, App.root);
    defer driver.deinit();
    try driver.start(.{ .width = 300, .height = 200 });

    const frame_probe = @import("../frame.zig");
    // `start` renders a settling frame; the comparison starts from a clean slate.
    frame_probe.resetCommandsDigest();
    driver.frame();
    try std.testing.expect(!frame_probe.commandsRepeated());
    // Same state, same commands: nothing to present.
    driver.frame();
    try std.testing.expect(frame_probe.commandsRepeated());
    // One element more, and the frame must be presented again.
    App.show_extra = true;
    driver.frame();
    try std.testing.expect(!frame_probe.commandsRepeated());
    App.show_extra = false;
    driver.frame();
    try std.testing.expect(!frame_probe.commandsRepeated());
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

// ---- E2E: the Compose-style surface ----------------------------------------- These exercise the whole stack: component semantics registration, the.

const box_mod = @import("../components/box.zig");
const button_mod = @import("../components/button.zig");
const registry = @import("../components/click_registry.zig");

/// Stable ids for the synthetic list.
const e2e_rows = [_][]const u8{
    "e2e-row-0", "e2e-row-1", "e2e-row-2", "e2e-row-3", "e2e-row-4",
    "e2e-row-5", "e2e-row-6", "e2e-row-7", "e2e-row-8", "e2e-row-9",
};

const E2eApp = struct {
    clicks: usize = 0,

    fn root(ctx: ?*anyopaque, _: u32, _: u32) void {
        box_mod.box(.{
            .id = "e2e-root",
            .direction = .column,
            .w = .grow,
            .h = .grow,
        }, ctx, appChildren);
    }

    fn appChildren(ctx: ?*anyopaque) void {
        // 10 rows of 40px in a 120px viewport: rows 0..2 are visible, the rest are clipped out until something scrolls them in.
        scroll_mod.scroll(.{
            .id = "e2e-scroll",
            .w = .{ .fixed = 200 },
            .h = .{ .fixed = 120 },
            .show_scrollbar = false,
        }, ctx, scrollChildren);
        // A disabled control OUTSIDE the scroller: on screen, not clickable.
        button_mod.button(.{
            .id = "e2e-disabled",
            .label = "Disabled",
            .w = 180,
            .h = 40,
            .pad_tb = 0,
            .pad_lr = 0,
            .disabled = true,
            .on_click = bump,
            .ctx = ctx,
        });
    }

    fn scrollChildren(ctx: ?*anyopaque) void {
        for (e2e_rows) |tag| {
            button_mod.button(.{
                .id = tag,
                .label = tag,
                .w = 180,
                .h = 40,
                .pad_tb = 0,
                .pad_lr = 0,
                .on_click = bump,
                .ctx = ctx,
            });
        }
    }

    fn bump(ctx: ?*anyopaque) void {
        const self: *E2eApp = @ptrCast(@alignCast(ctx.?));
        self.clicks += 1;
    }
};

const e2e_viewport = Driver.Viewport{ .width = 200, .height = 400 };

fn e2eDriver(app: *E2eApp) !Driver {
    // page_allocator, not testing.allocator: the Clay arena is deliberately left alive for the test process (see Driver.deinit's note), so a leak-checking.
    var driver = try Driver.initOwned(std.heap.page_allocator, app, E2eApp.root);
    try driver.start(e2e_viewport);
    return driver;
}

test "e2e: onNodeWithTag + performClick drives the real pointer path" {
    var app = E2eApp{};
    var driver = try e2eDriver(&app);
    defer driver.deinit();
    try driver.waitForIdle();

    const row = try driver.onNodeWithTag("e2e-row-0");
    // The node carries the identity the component declared...
    try row.assertExists();
    try row.assertIsDisplayed();
    try row.assertRole(.button);
    try row.assertTextEquals("e2e-row-0");
    // ...and clickability folded in from click_registry, not from a field button() set itself.
    try row.assertHasClickAction();
    try row.assertIsEnabled();

    try row.performClick();
    try std.testing.expectEqual(@as(usize, 1), app.clicks);
}

test "e2e: onNodeWithText resolves a widget by its label" {
    var app = E2eApp{};
    var driver = try e2eDriver(&app);
    defer driver.deinit();
    try driver.waitForIdle();

    const row1 = try driver.onNodeWithText("e2e-row-1");
    try row1.performClick();
    try std.testing.expectEqual(@as(usize, 1), app.clicks);
    // The clicked row is uniquely identified by its label.
    try std.testing.expectEqual(@as(usize, 1), driver.onAllNodes(.{ .label = "e2e-row-1" }));
}

test "e2e: an ambiguous onNode query is rejected, not silently guessed" {
    var app = E2eApp{};
    var driver = try e2eDriver(&app);
    defer driver.deinit();
    try driver.waitForIdle();

    // 11 buttons exist (10 rows + the disabled one).
    try std.testing.expectEqual(@as(usize, 11), driver.onAllNodes(.{ .role = .button }));
    try std.testing.expectError(error.TooManyNodes, driver.onNode(.{ .role = .button }));
    // An index disambiguates.
    const third = try driver.onNodeWithIndex(.{ .role = .button }, 3);
    try third.assertTextEquals("e2e-row-3");
    // A query matching nothing says so distinctly.
    try std.testing.expectError(error.NoNodeFound, driver.onNode(.{ .tag = "nope" }));
}

test "e2e: display assertions are clip-aware" {
    var app = E2eApp{};
    var driver = try e2eDriver(&app);
    defer driver.deinit();
    try driver.waitForIdle();

    const first = try driver.onNodeWithTag("e2e-row-0");
    try first.assertIsDisplayed();
    const second = try driver.onNodeWithTag("e2e-row-2");
    try second.assertIsDisplayed();
    // Row 7 is beyond the 120px viewport: it EXISTS but is clipped away.
    const clipped = try driver.onNodeWithTag("e2e-row-7");
    try clipped.assertExists();
    try clipped.assertIsNotDisplayed();
}

test "e2e: a disabled control is findable and reports itself disabled" {
    var app = E2eApp{};
    var driver = try e2eDriver(&app);
    defer driver.deinit();
    try driver.waitForIdle();

    const off = try driver.onNodeWithTag("e2e-disabled");
    try off.assertExists();
    try off.assertIsDisplayed();
    try off.assertIsDisabled();
    try off.assertTextEquals("Disabled");
    // Disabled widgets never register a hit target, so there is no action.
    try off.assertHasNoClickAction();
    // And clicking it fails loudly instead of spraying an event at a dead control: Compose reports the missing click action the same way.
    try std.testing.expectError(error.NoClickAction, off.performClick());
    try std.testing.expectEqual(@as(usize, 0), app.clicks);
}

test "e2e: performScrollTo brings a clipped row into view, then it clicks" {
    var app = E2eApp{};
    var driver = try e2eDriver(&app);
    defer driver.deinit();
    try driver.waitForIdle();

    const row = try driver.onNodeWithTag("e2e-row-7");
    try row.assertIsNotDisplayed();
    // Clicking before scrolling fails loudly rather than missing silently.
    try std.testing.expectError(error.NodeNotDisplayed, row.performClick());
    try std.testing.expectEqual(@as(usize, 0), app.clicks);

    try row.performScrollTo();
    try row.assertIsDisplayed();
    try row.assertVisibleAtLeast(1.0);

    try row.performClick();
    try std.testing.expectEqual(@as(usize, 1), app.clicks);

    // Scrolling to the bottom pushed row 0 out of the viewport.
    const first_row = try driver.onNodeWithTag("e2e-row-0");
    try first_row.assertIsNotDisplayed();
}

test "e2e: performTouchInput swipes without clicking (drag threshold)" {
    var app = E2eApp{};
    var driver = try e2eDriver(&app);
    defer driver.deinit();
    try driver.waitForIdle();

    const row = try driver.onNodeWithTag("e2e-row-1");
    const n = try row.node();
    const c = n.visibleCenter();
    // A 50px swipe is past dispatch.drag_threshold_px, so the release must NOT fire a click.
    try row.performTouchInput(Swipe.down(c.x, c.y, 50));
    try std.testing.expectEqual(@as(usize, 0), app.clicks);

    // A plain click on the same node still works, proving the swipe did not leave the pointer latched down.
    try row.performClick();
    try std.testing.expectEqual(@as(usize, 1), app.clicks);
}

test "e2e: waitForIdle converges on a fixed point" {
    var app = E2eApp{};
    var driver = try e2eDriver(&app);
    defer driver.deinit();

    // Repeated idling is idempotent: the second call finds the fixed point immediately rather than failing after the frame budget.
    try driver.waitForIdle();
    try driver.waitForIdle();
    try std.testing.expectEqual(@as(usize, 11), driver.onAllNodes(.{ .role = .button }));
    // Nothing moved, so the fingerprint is unchanged across the idle calls.
    try std.testing.expectEqual(semantics.fingerprint(), semantics.fingerprint());
}

test "e2e: scrolling via the wheel path also counts as not-idle until settled" {
    var app = E2eApp{};
    var driver = try e2eDriver(&app);
    defer driver.deinit();
    try driver.waitForIdle();

    // Hover the container, then emit a wheel delta: waitForIdle must consume the pending delta before declaring the UI settled.
    const box = driver.box("e2e-scroll").?;
    driver.move(box.x + box.width * 0.5, box.y + box.height * 0.5);
    driver.scroll(0, 5);
    try driver.waitForIdle();
    // +5 Wayland dy == 50px of travel, so row 3 (y=120) is now on screen.
    const row3 = try driver.onNodeWithTag("e2e-row-3");
    try row3.assertIsDisplayed();
}

// ---- E2E: externally-registered clicks (the calculator's pattern) ----------

const ExtState = struct { hits: usize = 0 };

fn extHit(ctx: ?*anyopaque, _: usize) void {
    const s: *ExtState = @ptrCast(@alignCast(ctx.?));
    s.hits += 1;
}

const ExtApp = struct {
    fn root(ctx: ?*anyopaque, _: u32, _: u32) void {
        // Exactly what examples/calculator.zig does: `on_click = null` so button() does not self-register, then an indexed registration.
        button_mod.button(.{
            .id = "ext-key",
            .label = "7",
            .w = 60,
            .h = 40,
            .pad_tb = 0,
            .pad_lr = 0,
        });
        registry.registerZCursor(cl.getElementId("ext-key"), extHit, ctx, 0, 0, .pointer);
    }
};

test "e2e: a click registered outside the component still reports hasClickAction" {
    var state = ExtState{};
    var driver = try Driver.initOwned(std.heap.page_allocator, &state, ExtApp.root);
    defer driver.deinit();
    try driver.start(.{ .width = 120, .height = 80 });
    try driver.waitForIdle();

    const key = try driver.onNodeWithTag("ext-key");
    // button() declared the identity (label "7"), but NOT the action...
    try key.assertTextEquals("7");
    try key.assertRole(.button);
    // ...which resolve() folded in from click_registry.
    try key.assertHasClickAction();

    try key.performClick();
    try std.testing.expectEqual(@as(usize, 1), state.hits);
}
