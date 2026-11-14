// Generic agnostic dispatch tables: views / keys / pointer (no alloc, fixed caps).
const std = @import("std");
const cl = @import("zclay");
const button = @import("button.zig");
const input = @import("input.zig");
const registry = @import("click_registry.zig");
const frame_mod = @import("../frame.zig");

/// Linux BTN_LEFT (0x110): the only button that dispatches clicks.
pub const BTN_LEFT: u32 = 272;

// ---- Views ----

pub const view_cap: usize = 8;

/// One renderable sub-view: `active` gates, `show` declares (receives the owner's close-box props so headers stay uniform).
pub const ViewEntry = struct {
    active: *const fn (?*anyopaque) bool,
    show: *const fn (?*anyopaque, button.ButtonProps) void,
    ctx: ?*anyopaque,
};

/// Owner-held view table (Host owns one; Shell keeps its switch).
pub const Views = struct {
    entries: [view_cap]ViewEntry = undefined,
    n: usize = 0,

    pub fn registerView(
        self: *Views,
        active: *const fn (?*anyopaque) bool,
        show: *const fn (?*anyopaque, button.ButtonProps) void,
        ctx: ?*anyopaque,
    ) void {
        if (self.n >= view_cap) return;
        self.entries[self.n] = .{ .active = active, .show = show, .ctx = ctx };
        self.n += 1;
    }

    /// First active entry renders; true when one did, false if none.
    pub fn dispatchView(self: *const Views, close: button.ButtonProps) bool {
        for (self.entries[0..self.n]) |e| {
            if (e.active(e.ctx)) {
                e.show(e.ctx, close);
                return true;
            }
        }
        return false;
    }
};

// ---- Keys ----

pub const key_cap: usize = 8;

/// One key handler: mods snapshot + raw evdev keycode; true = consumed.
pub const KeyEntry = struct {
    handle: *const fn (?*anyopaque, input.Mods, u32) bool,
    ctx: ?*anyopaque,
};

pub const text_cap: usize = 4;

/// One text handler: a UTF-8 run the platform already composed, so Caps Lock, Shift and the layout are the platform's job.
pub const TextEntry = struct {
    handle: *const fn (?*anyopaque, []const u8) bool,
    ctx: ?*anyopaque,
};

/// Owner-held key chain: modifier latch + ordered handlers, plus the separate text chain typing goes through.
pub const KeyChain = struct {
    mods: input.Mods = .{},
    handlers: [key_cap]KeyEntry = undefined,
    n: usize = 0,
    text_handlers: [text_cap]TextEntry = undefined,
    text_n: usize = 0,

    pub fn register(
        self: *KeyChain,
        handle: *const fn (?*anyopaque, input.Mods, u32) bool,
        ctx: ?*anyopaque,
    ) void {
        if (self.n >= key_cap) return;
        self.handlers[self.n] = .{ .handle = handle, .ctx = ctx };
        self.n += 1;
    }

    /// Register a handler for composed text, which is how a printable key arrives when the backend has a layout.
    pub fn registerText(
        self: *KeyChain,
        handle: *const fn (?*anyopaque, []const u8) bool,
        ctx: ?*anyopaque,
    ) void {
        if (self.text_n >= text_cap) return;
        self.text_handlers[self.text_n] = .{ .handle = handle, .ctx = ctx };
        self.text_n += 1;
    }
};

/// Mods.track first (consumed -> false), releases ignored, else first handler returning true wins (false when none does).
pub fn handleKey(chain: *KeyChain, keycode: u32, pressed: bool) bool {
    if (chain.mods.track(keycode, pressed)) return false;
    if (!pressed) return false;
    for (chain.handlers[0..chain.n]) |h| {
        if (h.handle(h.ctx, chain.mods, keycode)) return true;
    }
    return false;
}

/// First text handler returning true wins; false when none consumed the run or the run is empty.
pub fn handleText(chain: *KeyChain, text: []const u8) bool {
    if (text.len == 0) return false;
    for (chain.text_handlers[0..chain.text_n]) |h| {
        if (h.handle(h.ctx, text)) return true;
    }
    return false;
}

// ---- Pointer ----

/// Drag threshold: press + release with less than this much motion is a click; more marks dragging (scroll drag, release fires nothing).
pub const drag_threshold_px: f32 = 6;

/// How long two clicks may be apart and still be a double click.
pub const double_click_ms: i64 = 400;
/// How far apart they may land, in points, and still be the same spot.
pub const double_click_slop_px: f32 = 4;

/// Owner-held pointer state (mirrors Shell's pointer_x/y/down).
pub const PtrState = struct {
    x: f32 = 0,
    y: f32 = 0,
    down: bool = false,
    /// Press origin (for click dispatch + drag distance).
    down_x: f32 = 0,
    down_y: f32 = 0,
    /// Press was in-bounds (only then may release dispatch a click).
    press_in_bounds: bool = false,
    /// Motion past drag_threshold_px while down (scroll drag in flight).
    dragging: bool = false,
    /// This event's time in milliseconds, stamped by the host. 0 = no clock, which never makes a double click.
    now_ms: i64 = 0,
    /// The previous click's time and press point, for double-click detection. 0 = none yet.
    last_click_ms: i64 = 0,
    last_click_x: f32 = 0,
    last_click_y: f32 = 0,
    /// 1 after a single click, 2 after a double.
    click_count: u8 = 0,
};

/// Always stores x/y.
pub fn pointerEvent(s: *PtrState, x: f32, y: f32, pressed: bool, button_code: u32, w: u32, h: u32) void {
    s.x = x;
    s.y = y;
    // BTN_LEFT == 0x110 (272).
    if (button_code == BTN_LEFT and pressed) {
        // A press anywhere but the focused field takes the keyboard away from it, so a field stops blinking when another component is clicked.
        if (frame_mod.focusKnown()) {
            if (frame_mod.focusedId()) |fid| {
                const data = cl.getElementData(cl.getElementId(fid));
                const inside = data.found and
                    x >= data.bounding_box.x and x <= data.bounding_box.x + data.bounding_box.width and
                    y >= data.bounding_box.y and y <= data.bounding_box.y + data.bounding_box.height;
                if (!inside) frame_mod.clearFocus();
            }
        }
        s.down = true;
        s.dragging = false;
        s.down_x = x;
        s.down_y = y;
        const fw: f32 = @floatFromInt(w);
        const fh: f32 = @floatFromInt(h);
        s.press_in_bounds = !(x < 0 or y < 0 or x >= fw or y >= fh);
    } else if (button_code == BTN_LEFT) {
        const fire = s.down and !s.dragging and s.press_in_bounds;
        s.down = false;
        s.dragging = false;
        s.press_in_bounds = false;
        if (fire) fireClick(s);
    } else if (s.down and !s.dragging) {
        const dx = x - s.down_x;
        const dy = y - s.down_y;
        if (dx * dx + dy * dy > drag_threshold_px * drag_threshold_px) {
            s.dragging = true;
        }
    }
}

/// Fire the click at the press point, as a double click when it is the second one on the same spot inside the window.
fn fireClick(s: *PtrState) void {
    const x = s.down_x;
    const y = s.down_y;
    const now = s.now_ms;
    const same_spot = @abs(x - s.last_click_x) <= double_click_slop_px and @abs(y - s.last_click_y) <= double_click_slop_px;
    // Without a clock there is no way to tell a double click from two clicks, so it stays a single.
    const quick = now != 0 and s.last_click_ms != 0 and now - s.last_click_ms <= double_click_ms;
    if (same_spot and quick) {
        s.click_count = 2;
        // A third click starts over rather than stacking into a triple.
        s.last_click_ms = 0;
        _ = registry.dispatchDoubleClick(x, y);
        return;
    }
    s.click_count = 1;
    s.last_click_ms = now;
    s.last_click_x = x;
    s.last_click_y = y;
    _ = registry.dispatchClick(x, y);
}

// ---- Test doubles ----

const ShowRec = struct {
    calls: usize = 0,
};

fn activeYes(_: ?*anyopaque) bool {
    return true;
}

fn activeNo(_: ?*anyopaque) bool {
    return false;
}

fn showRec(ctx: ?*anyopaque, _: button.ButtonProps) void {
    const r: *ShowRec = @ptrCast(@alignCast(ctx.?));
    r.calls += 1;
}

fn closeProps() button.ButtonProps {
    return .{ .id = .{ .text = "x" }, .label = .{ .text = "X" } };
}

const KeyRec = struct {
    calls: usize = 0,
    last: u32 = 0,
    ret: bool = false,
};

fn keyRec(ctx: ?*anyopaque, _: input.Mods, keycode: u32) bool {
    const r: *KeyRec = @ptrCast(@alignCast(ctx.?));
    r.calls += 1;
    r.last = keycode;
    return r.ret;
}

fn escLike(ctx: ?*anyopaque, _: input.Mods, keycode: u32) bool {
    _ = ctx;
    return keycode == 1;
}

fn stubMeasure(s: []const u8, cfg: *cl.TextElementConfig, _: void) cl.Dimensions {
    return .{
        .w = @as(f32, @floatFromInt(s.len)) * @as(f32, @floatFromInt(cfg.font_size)) * 0.6,
        .h = @as(f32, @floatFromInt(cfg.font_size)),
    };
}

fn layoutOne() !void {
    const mem_size = cl.minMemorySize();
    // NOTE: intentionally leaked (page_allocator, never freed).
    const buf = try std.heap.page_allocator.alloc(u8, mem_size);
    const arena = cl.Arena.init(buf);
    _ = cl.initialize(arena, .{ .w = 720, .h = 480 }, .{});
    cl.setMeasureTextFunction(void, {}, stubMeasure);
    cl.setPointerState(.{ .x = 99999, .y = 99999 }, false);
    cl.beginLayout();
    cl.UI()(.{
        .id = .ID("dp-list"),
        .layout = .{ .direction = .top_to_bottom, .sizing = .{ .w = .grow, .h = .fit } },
    })({
        cl.UI()(.{
            .id = .IDI("dp-list", 1),
            .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(40) } },
        })({});
    });
    _ = cl.endLayout();
}

const ClickRec = struct {
    calls: usize = 0,
};

fn onClick(ctx: ?*anyopaque) void {
    const r: *ClickRec = @ptrCast(@alignCast(ctx.?));
    r.calls += 1;
}

fn boxCenter() cl.BoundingBox {
    return cl.getElementData(cl.ElementId.IDI("dp-list", 1)).bounding_box;
}

fn rowId() cl.ElementId {
    return cl.ElementId.IDI("dp-list", 1);
}

// ---- Views tests ----

test "views: first active entry renders and wins" {
    var v = Views{};
    var a = ShowRec{};
    var b = ShowRec{};
    v.registerView(activeYes, showRec, &a);
    v.registerView(activeYes, showRec, &b);
    try std.testing.expect(v.dispatchView(closeProps()));
    try std.testing.expectEqual(@as(usize, 1), a.calls);
    try std.testing.expectEqual(@as(usize, 0), b.calls);
}

test "views: inactive first falls through to second" {
    var v = Views{};
    var a = ShowRec{};
    var b = ShowRec{};
    v.registerView(activeNo, showRec, &a);
    v.registerView(activeYes, showRec, &b);
    try std.testing.expect(v.dispatchView(closeProps()));
    try std.testing.expectEqual(@as(usize, 0), a.calls);
    try std.testing.expectEqual(@as(usize, 1), b.calls);
}

test "views: none active returns false, nothing renders" {
    var v = Views{};
    var a = ShowRec{};
    v.registerView(activeNo, showRec, &a);
    try std.testing.expect(!v.dispatchView(closeProps()));
    try std.testing.expectEqual(@as(usize, 0), a.calls);
}

// ---- Keys tests ----

test "keys: shift press latches mods and is consumed" {
    var c = KeyChain{};
    try std.testing.expect(!handleKey(&c, 42, true));
    try std.testing.expect(c.mods.shift);
}

test "keys: shift release unlatches, returns false" {
    var c = KeyChain{};
    _ = handleKey(&c, 42, true);
    try std.testing.expect(!handleKey(&c, 42, false));
    try std.testing.expect(!c.mods.shift);
}

test "keys: release of a normal key is ignored, handler not called" {
    var c = KeyChain{};
    var r = KeyRec{ .ret = true };
    c.register(keyRec, &r);
    try std.testing.expect(!handleKey(&c, 30, false));
    try std.testing.expectEqual(@as(usize, 0), r.calls);
}

test "keys: first handler returning true wins, later ones skipped" {
    var c = KeyChain{};
    var r1 = KeyRec{ .ret = true };
    var r2 = KeyRec{ .ret = true };
    c.register(keyRec, &r1);
    c.register(keyRec, &r2);
    try std.testing.expect(handleKey(&c, 30, true));
    try std.testing.expectEqual(@as(usize, 1), r1.calls);
    try std.testing.expectEqual(@as(usize, 0), r2.calls);
}

test "keys: false from first falls through to second" {
    var c = KeyChain{};
    var r1 = KeyRec{ .ret = false };
    var r2 = KeyRec{ .ret = true };
    c.register(keyRec, &r1);
    c.register(keyRec, &r2);
    try std.testing.expect(handleKey(&c, 30, true));
    try std.testing.expectEqual(@as(usize, 1), r1.calls);
    try std.testing.expectEqual(@as(usize, 1), r2.calls);
    try std.testing.expectEqual(@as(u32, 30), r2.last);
}

test "keys: Escape-like code routes to the handler" {
    var c = KeyChain{};
    c.register(escLike, null);
    try std.testing.expect(handleKey(&c, 1, true));
    try std.testing.expect(!handleKey(&c, 30, true));
}

pub const TextRec = struct {
    calls: usize = 0,
    last: [16]u8 = [_]u8{0} ** 16,
    last_len: usize = 0,
    ret: bool = false,
};

pub fn textRec(ctx: ?*anyopaque, text: []const u8) bool {
    const r: *TextRec = @ptrCast(@alignCast(ctx.?));
    r.calls += 1;
    const n = @min(text.len, r.last.len);
    @memcpy(r.last[0..n], text[0..n]);
    r.last_len = n;
    return r.ret;
}

test "text: the run reaches the handler verbatim (Caps Lock A, star, e-acute)" {
    var c = KeyChain{};
    var r = TextRec{ .ret = true };
    c.registerText(textRec, &r);
    try std.testing.expect(handleText(&c, "A"));
    try std.testing.expect(handleText(&c, "*"));
    try std.testing.expect(handleText(&c, "\xc3\xa9"));
    try std.testing.expectEqual(@as(usize, 3), r.calls);
    try std.testing.expectEqualStrings("\xc3\xa9", r.last[0..r.last_len]);
}

test "text: an empty run is not dispatched" {
    var c = KeyChain{};
    var r = TextRec{ .ret = true };
    c.registerText(textRec, &r);
    try std.testing.expect(!handleText(&c, ""));
    try std.testing.expectEqual(@as(usize, 0), r.calls);
}

test "text: false falls through to the next handler, true stops the chain" {
    var c = KeyChain{};
    var r1 = TextRec{ .ret = false };
    var r2 = TextRec{ .ret = true };
    var r3 = TextRec{ .ret = true };
    c.registerText(textRec, &r1);
    c.registerText(textRec, &r2);
    c.registerText(textRec, &r3);
    try std.testing.expect(handleText(&c, "("));
    try std.testing.expectEqual(@as(usize, 1), r1.calls);
    try std.testing.expectEqual(@as(usize, 1), r2.calls);
    try std.testing.expectEqual(@as(usize, 0), r3.calls);
}

test "text: no handler means not consumed, key chain untouched" {
    var c = KeyChain{};
    try std.testing.expect(!handleText(&c, "x"));
    try std.testing.expectEqual(@as(usize, 0), c.n);
}

// ---- Double click ----

const DblRec = struct { singles: usize = 0, doubles: usize = 0 };

fn dblSingle(ctx: ?*anyopaque) void {
    const r: *DblRec = @ptrCast(@alignCast(ctx.?));
    r.singles += 1;
}

fn dblDouble(ctx: ?*anyopaque) void {
    const r: *DblRec = @ptrCast(@alignCast(ctx.?));
    r.doubles += 1;
}

/// One press+release at the centre of the laid-out row.
fn clickOnce(s: *PtrState, cx: f32, cy: f32) void {
    pointerEvent(s, cx, cy, true, BTN_LEFT, 720, 480);
    pointerEvent(s, cx, cy, false, BTN_LEFT, 720, 480);
}

test "double click: a second click on the same spot inside the window is a double" {
    try layoutOne();
    registry.beginFrame();
    var rec = DblRec{};
    registry.registerClickDoubleCursor(rowId(), dblSingle, dblDouble, &rec, .text);
    const bb = boxCenter();
    const cx = bb.x + bb.width * 0.5;
    const cy = bb.y + bb.height * 0.5;
    var s = PtrState{};
    s.now_ms = 1000;
    clickOnce(&s, cx, cy);
    try std.testing.expectEqual(@as(usize, 1), rec.singles);
    try std.testing.expectEqual(@as(usize, 0), rec.doubles);
    s.now_ms = 1150;
    clickOnce(&s, cx, cy);
    try std.testing.expectEqual(@as(usize, 1), rec.singles);
    try std.testing.expectEqual(@as(usize, 1), rec.doubles);
    try std.testing.expectEqual(@as(u8, 2), s.click_count);
}

test "double click: a slow second click is two singles" {
    try layoutOne();
    registry.beginFrame();
    var rec = DblRec{};
    registry.registerClickDoubleCursor(rowId(), dblSingle, dblDouble, &rec, .text);
    const bb = boxCenter();
    const cx = bb.x + bb.width * 0.5;
    const cy = bb.y + bb.height * 0.5;
    var s = PtrState{};
    s.now_ms = 1000;
    clickOnce(&s, cx, cy);
    s.now_ms = 1000 + double_click_ms + 50;
    clickOnce(&s, cx, cy);
    try std.testing.expectEqual(@as(usize, 2), rec.singles);
    try std.testing.expectEqual(@as(usize, 0), rec.doubles);
}

test "double click: a second click elsewhere is two singles" {
    try layoutOne();
    registry.beginFrame();
    var rec = DblRec{};
    registry.registerClickDoubleCursor(rowId(), dblSingle, dblDouble, &rec, .text);
    const bb = boxCenter();
    const cy = bb.y + bb.height * 0.5;
    var s = PtrState{};
    s.now_ms = 1000;
    clickOnce(&s, bb.x + bb.width * 0.5, cy);
    s.now_ms = 1100;
    clickOnce(&s, bb.x + bb.width * 0.5 + double_click_slop_px * 4, cy);
    try std.testing.expectEqual(@as(usize, 2), rec.singles);
    try std.testing.expectEqual(@as(usize, 0), rec.doubles);
}

test "double click: with no clock a second click is still a single" {
    try layoutOne();
    registry.beginFrame();
    var rec = DblRec{};
    registry.registerClickDoubleCursor(rowId(), dblSingle, dblDouble, &rec, .text);
    const bb = boxCenter();
    var s = PtrState{};
    clickOnce(&s, bb.x + bb.width * 0.5, bb.y + bb.height * 0.5);
    clickOnce(&s, bb.x + bb.width * 0.5, bb.y + bb.height * 0.5);
    try std.testing.expectEqual(@as(usize, 2), rec.singles);
    try std.testing.expectEqual(@as(usize, 0), rec.doubles);
}

// ---- Press/release disambiguation (drag support): press records, motion past the threshold marks dragging, release fires only when not dragged.

test "pointer: press alone fires nothing (click deferred to release)" {
    try layoutOne();
    registry.beginFrame();
    var rec = ClickRec{};
    registry.registerClick(rowId(), onClick, &rec);
    const bb = boxCenter();
    var s = PtrState{};
    pointerEvent(&s, bb.x + bb.width * 0.5, bb.y + bb.height * 0.5, true, 272, 720, 480);
    try std.testing.expectEqual(@as(usize, 0), rec.calls);
    try std.testing.expect(s.down);
}

test "pointer: press + release without motion fires once" {
    try layoutOne();
    registry.beginFrame();
    var rec = ClickRec{};
    registry.registerClick(rowId(), onClick, &rec);
    const bb = boxCenter();
    const cx = bb.x + bb.width * 0.5;
    const cy = bb.y + bb.height * 0.5;
    var s = PtrState{};
    pointerEvent(&s, cx, cy, true, 272, 720, 480);
    pointerEvent(&s, cx, cy, false, 272, 720, 480);
    try std.testing.expectEqual(@as(usize, 1), rec.calls);
    try std.testing.expect(!s.down);
}

test "pointer: small jitter under threshold still clicks on release" {
    try layoutOne();
    registry.beginFrame();
    var rec = ClickRec{};
    registry.registerClick(rowId(), onClick, &rec);
    const bb = boxCenter();
    const cx = bb.x + bb.width * 0.5;
    const cy = bb.y + bb.height * 0.5;
    var s = PtrState{};
    pointerEvent(&s, cx, cy, true, 272, 720, 480);
    // 2px motion (button 0 = motion event) stays under the drag threshold.
    pointerEvent(&s, cx + 2, cy + 1, false, 0, 720, 480);
    try std.testing.expect(!s.dragging);
    pointerEvent(&s, cx + 2, cy + 1, false, 272, 720, 480);
    try std.testing.expectEqual(@as(usize, 1), rec.calls);
}

test "pointer: drag past threshold suppresses the release click" {
    try layoutOne();
    registry.beginFrame();
    var rec = ClickRec{};
    registry.registerClick(rowId(), onClick, &rec);
    const bb = boxCenter();
    const cx = bb.x + bb.width * 0.5;
    const cy = bb.y + bb.height * 0.5;
    var s = PtrState{};
    pointerEvent(&s, cx, cy, true, 272, 720, 480);
    // 50px motion marks dragging (scroll drag, not a click).
    pointerEvent(&s, cx, cy + 50, false, 0, 720, 480);
    try std.testing.expect(s.dragging);
    try std.testing.expect(s.down);
    pointerEvent(&s, cx, cy + 50, false, 272, 720, 480);
    try std.testing.expectEqual(@as(usize, 0), rec.calls);
    try std.testing.expect(!s.down);
    try std.testing.expect(!s.dragging);
}

test "pointer: out-of-bounds press never clicks, even on release" {
    try layoutOne();
    registry.beginFrame();
    var rec = ClickRec{};
    registry.registerClick(rowId(), onClick, &rec);
    var s = PtrState{};
    pointerEvent(&s, 800, 10, true, 272, 720, 480);
    pointerEvent(&s, 100, 100, false, 272, 720, 480);
    try std.testing.expectEqual(@as(usize, 0), rec.calls);
}

test "pointer: in-bounds press + release fires the registered click" {
    try layoutOne();
    registry.beginFrame();
    var rec = ClickRec{};
    registry.registerClick(rowId(), onClick, &rec);
    const bb = boxCenter();
    try std.testing.expect(cl.getElementData(rowId()).found);
    var s = PtrState{};
    const cx = bb.x + bb.width * 0.5;
    const cy = bb.y + bb.height * 0.5;
    pointerEvent(&s, cx, cy, true, 272, 720, 480);
    try std.testing.expectEqual(@as(usize, 0), rec.calls);
    pointerEvent(&s, cx, cy, false, 272, 720, 480);
    try std.testing.expectEqual(@as(usize, 1), rec.calls);
    try std.testing.expect(!s.down);
    try std.testing.expectEqual(cx, s.x);
}

test "pointer: out-of-bounds press stores pos and down, never fires" {
    try layoutOne();
    registry.beginFrame();
    var rec = ClickRec{};
    registry.registerClick(rowId(), onClick, &rec);
    var s = PtrState{};
    pointerEvent(&s, 800, 10, true, 272, 720, 480);
    try std.testing.expectEqual(@as(usize, 0), rec.calls);
    try std.testing.expect(s.down);
    try std.testing.expectEqual(@as(f32, 800), s.x);
    // Release (even back in-bounds) still fires nothing: the press began out-of-window.
    pointerEvent(&s, 100, 100, false, 272, 720, 480);
    try std.testing.expectEqual(@as(usize, 0), rec.calls);
    try std.testing.expect(!s.down);
}

test "pointer: left release clears down" {
    var s = PtrState{ .x = 10, .y = 10, .down = true };
    pointerEvent(&s, 10, 10, false, 272, 720, 480);
    try std.testing.expect(!s.down);
    try std.testing.expectEqual(@as(f32, 10), s.x);
}

test "pointer: other buttons are ignored" {
    try layoutOne();
    registry.beginFrame();
    var rec = ClickRec{};
    registry.registerClick(rowId(), onClick, &rec);
    const bb = boxCenter();
    var s = PtrState{};
    pointerEvent(&s, bb.x + bb.width * 0.5, bb.y + bb.height * 0.5, true, 273, 720, 480);
    try std.testing.expectEqual(@as(usize, 0), rec.calls);
    try std.testing.expect(!s.down);
}
