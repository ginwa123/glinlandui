//! Per-frame semantics model: the queryable node tree behind the E2E test
//! API (`glinlandui.testing`) and, in time, accessibility and the debug
//! inspector. One consumer today.
//!
//! IMMEDIATE MODE, so the tree is REBUILT every frame exactly like the widget
//! tree. Three phases, in this order, per frame:
//!
//!   1. `beginFrame()`      — clear (called from Host.declareThunk, beside
//!                            click_registry.beginFrame).
//!   2. `register(...)`     — components declare their node DURING declare.
//!                            The Clay `id` is known here; geometry is NOT.
//!   3. `resolve(w, h)`     — AFTER `cl.endLayout()`, when Clay has computed
//!                            every bounding box. Fills bounds/clip/visibility
//!                            and folds in clickability from click_registry.
//!
//! The split exists because `cl.getElementData` returns nothing useful before
//! layout runs. Getting this order wrong yields nodes with zero-size boxes and
//! a `visible_fraction` of 0 — which reads as "not displayed" rather than as a
//! bug, so it is worth being explicit about.
//!
//! Deliberate constraints, mirroring components/click_registry.zig:
//!   * fixed capacity, zero allocation, `register` never fails
//!   * Imports: std + zclay + the sibling registry ONLY
//!     (layering rules R1-R3, parity purity R6)
//!
//! LIFETIME: `tag`, `label` and `value` are borrowed slices, exactly like
//! `ButtonProps.label` today — they must outlive the frame they are declared
//! in. Every caller in this repo passes a string literal or app-owned state.
const std = @import("std");
const cl = @import("zclay");
const registry = @import("components/click_registry.zig");

/// Node capacity. Matches click_registry.cap: the semantics layer must be able
/// to hold every hit target plus the labels/containers around them.
pub const cap: usize = 256;

/// Ancestor chain depth kept per node. Clipping deeper than this is not a
/// layout anyone can reason about; the innermost entries are kept.
pub const ancestor_cap: usize = 8;

pub const Role = enum {
    unknown,
    text,
    button,
    checkbox,
    radio,
    toggle,
    slider,
    text_field,
    dropdown,
    list,
    list_item,
    scroll,
    image,
    icon,
    container,
};

/// What this node can DO. Compose's SemanticsActions, reduced to the four
/// gestures this engine can actually perform.
///
/// `click` is NOT set by components: it is folded in during `resolve` from
/// click_registry, which is the one authoritative record of "is this id
/// clickable this frame". That matters because widgets are registered in more
/// than one way — `button()` self-registers when `on_click` is set, while the
/// calculator example passes `on_click = null` and registers all 20 keys
/// externally with `registerZCursor`. Deriving from the registry captures both
/// and cannot drift from what dispatch will actually do.
pub const Actions = packed struct(u8) {
    click: bool = false,
    scroll: bool = false,
    set_text: bool = false,
    drag: bool = false,
    /// Explicit padding so the backing integer is a full byte, which keeps
    /// `@bitCast` (in `fingerprint`) a plain u8 <-> struct cast.
    pad: u4 = 0,
};

/// State a test reads. `hidden` is intent (a collapsed panel); "clipped out of
/// view" is DERIVED from geometry in `resolve`, never stored here.
pub const Flags = packed struct(u8) {
    enabled: bool = true,
    checked: bool = false,
    selected: bool = false,
    focused: bool = false,
    hidden: bool = false,
    /// Explicit padding (see Actions.pad).
    pad: u3 = 0,
};

const EMPTY = cl.BoundingBox{ .x = 0, .y = 0, .width = 0, .height = 0 };

/// One ancestor snapshot. `clips` matters: a plain container's box contains its
/// children anyway, so intersecting with it is a no-op at best and wrong at
/// worst — floating overlays and absolutely-positioned children legitimately
/// paint outside their parent. ONLY clip/scroll containers may narrow the
/// visible rect.
const Ancestor = struct {
    id: cl.ElementId,
    clips: bool,
};

pub const Node = struct {
    // ---- declare-time facts ----
    id: cl.ElementId,
    tag: []const u8 = "",
    role: Role = .unknown,
    label: []const u8 = "",
    value: []const u8 = "",
    actions: Actions = .{},
    flags: Flags = .{},
    z: i16 = 0,
    /// Ancestor chain, outermost-first, snapshotted by `register`.
    ancestors: [ancestor_cap]Ancestor = undefined,
    ancestor_len: u8 = 0,

    // ---- resolved post-layout (see resolve) ----
    found: bool = false,
    bounds: cl.BoundingBox = EMPTY,
    /// Intersection of every CLIPPING ancestor's box with the viewport.
    clip: cl.BoundingBox = EMPTY,
    /// 0..1: the fraction of this node's own area that survives clipping.
    visible_fraction: f32 = 0,

    pub fn area(self: Node) f32 {
        return self.bounds.width * self.bounds.height;
    }

    /// True when the node exists and some part of it survives clipping.
    pub fn isDisplayed(self: Node) bool {
        return self.found and !self.flags.hidden and self.visible_fraction > 0;
    }

    /// Where a click should land: the centre of the VISIBLE region, so a
    /// half-clipped row still receives a hit inside its scroll viewport rather
    /// than at its geometric centre (which may be clipped away entirely).
    pub fn visibleCenter(self: Node) cl.Vector2 {
        const x0 = @max(self.bounds.x, self.clip.x);
        const y0 = @max(self.bounds.y, self.clip.y);
        const x1 = @min(self.bounds.x + self.bounds.width, self.clip.x + self.clip.width);
        const y1 = @min(self.bounds.y + self.bounds.height, self.clip.y + self.clip.height);
        return .{ .x = (x0 + x1) * 0.5, .y = (y0 + y1) * 0.5 };
    }
};

var nodes: [cap]Node = undefined;
var count: usize = 0;

/// Declare-time ancestor stack. Containers push/pop around their children.
var stack: [ancestor_cap]Ancestor = undefined;
var stack_len: usize = 0;

/// Reset for a new frame. Called from Host.declareThunk, beside
/// click_registry.beginFrame() and scroll.beginScrollFrame().
pub fn beginFrame() void {
    count = 0;
    stack_len = 0;
}

/// Containers call these for the span of their children's declaration.
/// `clips` = this element scrolls/clips its content (scroll.zig passes true).
pub fn pushAncestor(id: cl.ElementId, clips: bool) void {
    if (stack_len < stack.len) stack[stack_len] = .{ .id = id, .clips = clips };
    stack_len += 1;
}

pub fn popAncestor() void {
    if (stack_len > 0) stack_len -= 1;
}

/// Register a node during declare. Never fails; drops silently past `cap`
/// (the same contract as click_registry.register).
pub fn register(node: Node) void {
    if (count >= cap) return;
    var n = node;
    const depth = @min(stack_len, ancestor_cap);
    const off = stack_len - depth; // keep the INNERMOST ancestors
    for (0..depth) |i| n.ancestors[i] = stack[off + i];
    n.ancestor_len = @intCast(depth);
    nodes[count] = n;
    count += 1;
}

/// Fill geometry for every registered node, then fold in clickability.
/// MUST run after `cl.endLayout()`. A no-op for an empty registry.
pub fn resolve(viewport_w: f32, viewport_h: f32) void {
    const viewport = cl.BoundingBox{ .x = 0, .y = 0, .width = viewport_w, .height = viewport_h };
    for (nodes[0..count]) |*n| {
        const data = cl.getElementData(n.id);
        n.found = data.found;
        if (!data.found) {
            n.bounds = EMPTY;
            n.clip = EMPTY;
            n.visible_fraction = 0;
        } else {
            n.bounds = data.bounding_box;
            var clip = viewport;
            var i: usize = 0;
            while (i < n.ancestor_len) : (i += 1) {
                const a = n.ancestors[i];
                if (!a.clips) continue;
                const ad = cl.getElementData(a.id);
                if (ad.found) clip = intersect(clip, ad.bounding_box);
            }
            n.clip = clip;
            const a = n.area();
            n.visible_fraction = if (a <= 0) 0 else intersectionArea(n.bounds, clip) / a;
        }
    }
    mergeClickable();
}

/// Fold clickability in from click_registry — the authoritative record of what
/// dispatch will actually fire on this frame. Nodes already marked clickable
/// (components that self-register) skip the scan.
fn mergeClickable() void {
    const hits = registry.hitCount();
    for (nodes[0..count]) |*n| {
        if (n.actions.click) continue;
        var i: usize = 0;
        while (i < hits) : (i += 1) {
            const h = registry.hitAt(i) orelse continue;
            if (h.id.id != n.id.id) continue;
            if (h.clickable) n.actions.click = true;
            if (h.z > n.z) n.z = h.z;
        }
    }
}

pub fn all() []const Node {
    return nodes[0..count];
}

pub fn nodeCount() usize {
    return count;
}

/// Exact id lookup against the last resolved frame.
pub fn byId(id: cl.ElementId) ?Node {
    for (nodes[0..count]) |n| if (n.id.id == id.id) return n;
    return null;
}

fn intersect(a: cl.BoundingBox, b: cl.BoundingBox) cl.BoundingBox {
    const x0 = @max(a.x, b.x);
    const y0 = @max(a.y, b.y);
    const x1 = @min(a.x + a.width, b.x + b.width);
    const y1 = @min(a.y + a.height, b.y + b.height);
    return .{ .x = x0, .y = y0, .width = @max(0, x1 - x0), .height = @max(0, y1 - y0) };
}

fn intersectionArea(a: cl.BoundingBox, b: cl.BoundingBox) f32 {
    const i = intersect(a, b);
    return i.width * i.height;
}

/// FNV-1a over the observable semantics of this frame. This is what makes
/// `Driver.waitForIdle` a FIXED-POINT test instead of a sleep: two consecutive
/// frames with the same fingerprint have nothing left to settle.
pub fn fingerprint() u64 {
    var h: u64 = 0xcbf29ce484222325;
    h = mix(h, count);
    for (nodes[0..count]) |n| {
        h = mix(h, n.id.id);
        h = mix(h, @as(u32, @bitCast(n.bounds.x)));
        h = mix(h, @as(u32, @bitCast(n.bounds.y)));
        h = mix(h, @as(u32, @bitCast(n.bounds.width)));
        h = mix(h, @as(u32, @bitCast(n.bounds.height)));
        h = mix(h, @as(u32, @bitCast(n.visible_fraction)));
        h = mix(h, @as(u8, @bitCast(n.actions)));
        h = mix(h, @as(u8, @bitCast(n.flags)));
    }
    return h;
}

fn mix(h: u64, v: u64) u64 {
    return (h ^ v) *% 0x100000001b3;
}

// ---- Test doubles ----

fn stubMeasure(s: []const u8, cfg: *cl.TextElementConfig, _: void) cl.Dimensions {
    return .{
        .w = @as(f32, @floatFromInt(s.len)) * @as(f32, @floatFromInt(cfg.font_size)) * 0.6,
        .h = @as(f32, @floatFromInt(cfg.font_size)),
    };
}

/// One headless Clay layout of a single fixed-size box.
/// NOTE: the arena is intentionally leaked (page_allocator, never freed).
/// Clay keeps a process-global currentContext pointer inside it, so freeing it
/// would dangle the NEXT test's minMemorySize/initialize (segfault) — the same
/// convention every component test follows.
fn layoutBox(id: []const u8, w: f32, h: f32) !void {
    const mem_size = cl.minMemorySize();
    const buf = try std.heap.page_allocator.alloc(u8, mem_size);
    const arena = cl.Arena.init(buf);
    _ = cl.initialize(arena, .{ .w = 720, .h = 480 }, .{});
    cl.setMeasureTextFunction(void, {}, stubMeasure);
    cl.setPointerState(.{ .x = 99999, .y = 99999 }, false);
    cl.beginLayout();
    cl.UI()(.{
        .id = .ID(id),
        .layout = .{ .sizing = .{ .w = .fixed(w), .h = .fixed(h) } },
    })({});
    _ = cl.endLayout();
}

/// One headless Clay layout of an id'd clip container holding one child that
/// overflows it on the vertical axis (100px viewport, 400px child).
fn layoutClipped() !void {
    const mem_size = cl.minMemorySize();
    const buf = try std.heap.page_allocator.alloc(u8, mem_size);
    const arena = cl.Arena.init(buf);
    _ = cl.initialize(arena, .{ .w = 720, .h = 480 }, .{});
    cl.setMeasureTextFunction(void, {}, stubMeasure);
    cl.setPointerState(.{ .x = 99999, .y = 99999 }, false);
    cl.beginLayout();
    cl.UI()(.{
        .id = .ID("sem-clip"),
        .layout = .{ .sizing = .{ .w = .fixed(100), .h = .fixed(100) } },
        .clip = .{ .vertical = true },
    })({
        cl.UI()(.{
            .id = .ID("sem-child"),
            .layout = .{ .sizing = .{ .w = .fixed(50), .h = .fixed(400) } },
        })({});
    });
    _ = cl.endLayout();
}

test "register snapshots the ancestor chain innermost-first" {
    beginFrame();
    pushAncestor(cl.getElementId("a"), false);
    pushAncestor(cl.getElementId("b"), true);
    register(.{ .id = cl.getElementId("leaf"), .tag = "leaf" });
    popAncestor();
    popAncestor();

    const n = all()[0];
    try std.testing.expectEqual(@as(u8, 2), n.ancestor_len);
    try std.testing.expectEqual(cl.getElementId("a").id, n.ancestors[0].id.id);
    try std.testing.expect(!n.ancestors[0].clips);
    try std.testing.expectEqual(cl.getElementId("b").id, n.ancestors[1].id.id);
    try std.testing.expect(n.ancestors[1].clips);
}

test "beginFrame clears nodes and the ancestor stack" {
    beginFrame();
    pushAncestor(cl.getElementId("x"), false);
    register(.{ .id = cl.getElementId("n"), .tag = "n" });
    try std.testing.expectEqual(@as(usize, 1), nodeCount());

    beginFrame();
    try std.testing.expectEqual(@as(usize, 0), nodeCount());
    // The stack was cleared too, so this node sees no ancestors.
    register(.{ .id = cl.getElementId("m"), .tag = "m" });
    try std.testing.expectEqual(@as(u8, 0), all()[0].ancestor_len);
}

test "register drops nodes past the cap instead of failing" {
    beginFrame();
    var i: usize = 0;
    while (i < cap + 8) : (i += 1) {
        register(.{ .id = .{ .id = @intCast(i), .offset = 0, .base_id = 0, .string_id = .{
            .chars = &.{},
            .length = 0,
            .is_statically_allocated = false,
        } }, .tag = "n" });
    }
    try std.testing.expectEqual(cap, nodeCount());
}

test "resolve fills bounds from Clay geometry and reports fully visible" {
    try layoutBox("sem-box", 100, 40);
    beginFrame();
    register(.{ .id = cl.getElementId("sem-box"), .tag = "sem-box" });
    resolve(720, 480);

    const n = all()[0];
    try std.testing.expect(n.found);
    try std.testing.expectApproxEqAbs(@as(f32, 100), n.bounds.width, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 40), n.bounds.height, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 1), n.visible_fraction, 0.001);
    // No clipping ancestors: the clip rect is the viewport itself.
    try std.testing.expectApproxEqAbs(@as(f32, 720), n.clip.width, 0.5);
    try std.testing.expect(n.isDisplayed());
}

test "resolve reports not-found for an id Clay never laid out" {
    try layoutBox("sem-present", 10, 10);
    beginFrame();
    register(.{ .id = cl.getElementId("sem-absent"), .tag = "sem-absent" });
    resolve(720, 480);

    const n = all()[0];
    try std.testing.expect(!n.found);
    try std.testing.expectEqual(@as(f32, 0), n.visible_fraction);
    try std.testing.expect(!n.isDisplayed());
}

test "a clipping ancestor narrows the clip and lowers visible_fraction" {
    try layoutClipped();
    beginFrame();
    // The scroll container declares itself, then pushes its clip around the
    // child — the order scroll.zig uses.
    register(.{
        .id = cl.getElementId("sem-clip"),
        .tag = "sem-clip",
        .role = .scroll,
        .actions = .{ .scroll = true },
    });
    pushAncestor(cl.getElementId("sem-clip"), true);
    register(.{ .id = cl.getElementId("sem-child"), .tag = "sem-child" });
    popAncestor();
    resolve(720, 480);

    const child = byId(cl.getElementId("sem-child")).?;
    const clip = byId(cl.getElementId("sem-clip")).?;
    try std.testing.expect(child.found);
    // The child's OWN box is the full 400px — Clay does not shrink it.
    try std.testing.expectApproxEqAbs(@as(f32, 400), child.bounds.height, 0.5);
    // But only the 100px the container exposes survives clipping.
    try std.testing.expectApproxEqAbs(@as(f32, 100), child.clip.height, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), child.visible_fraction, 0.01);
    // The container itself is unclipped and fully visible.
    try std.testing.expectApproxEqAbs(@as(f32, 1), clip.visible_fraction, 0.001);
}

test "a non-clipping ancestor does not narrow the visible region" {
    try layoutClipped();
    beginFrame();
    // Same shape, but the ancestor is NOT marked as clipping: a floating
    // overlay legitimately paints outside its parent, so its box must not
    // clip the child.
    pushAncestor(cl.getElementId("sem-clip"), false);
    register(.{ .id = cl.getElementId("sem-child"), .tag = "sem-child" });
    popAncestor();
    resolve(720, 480);

    const child = byId(cl.getElementId("sem-child")).?;
    // The clip falls back to the VIEWPORT (480 tall), not to the ancestor's
    // 100px box: a non-clipping ancestor contributes nothing.
    try std.testing.expectApproxEqAbs(@as(f32, 480), child.clip.height, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 1), child.visible_fraction, 0.001);
}

test "visibleCenter clamps to the clip rect, not the geometric centre" {
    // Half the node is clipped away: the geometric centre would fall outside
    // the visible strip, so the click point must come from the intersection.
    const n = Node{
        .id = cl.getElementId("half"),
        .tag = "half",
        .bounds = .{ .x = 0, .y = 0, .width = 100, .height = 100 },
        .clip = .{ .x = 0, .y = 0, .width = 100, .height = 40 },
    };
    const c = n.visibleCenter();
    try std.testing.expectApproxEqAbs(@as(f32, 50), c.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 20), c.y, 0.001);
}

test "fingerprint is stable for identical frames and moves with geometry" {
    beginFrame();
    register(.{ .id = cl.getElementId("fp"), .tag = "fp" });
    const h1 = fingerprint();

    beginFrame();
    register(.{ .id = cl.getElementId("fp"), .tag = "fp" });
    try std.testing.expectEqual(h1, fingerprint());

    beginFrame();
    var moved = Node{ .id = cl.getElementId("fp"), .tag = "fp" };
    moved.bounds.x = 5;
    register(moved);
    try std.testing.expect(fingerprint() != h1);

    // The node COUNT is part of the fingerprint: a node appearing or
    // disappearing is a UI change even when the survivors are identical.
    beginFrame();
    register(.{ .id = cl.getElementId("fp"), .tag = "fp" });
    register(.{ .id = cl.getElementId("fp2"), .tag = "fp2" });
    try std.testing.expect(fingerprint() != h1);
}

test "fingerprint reacts to a flag flip with no geometry change" {
    beginFrame();
    register(.{ .id = cl.getElementId("f"), .tag = "f" });
    const off = fingerprint();
    beginFrame();
    register(.{ .id = cl.getElementId("f"), .tag = "f", .flags = .{ .checked = true } });
    try std.testing.expect(fingerprint() != off);
}

test "byId finds a registered node and returns null for a stranger" {
    beginFrame();
    register(.{ .id = cl.getElementId("find-me"), .tag = "find-me", .role = .button });
    const n = byId(cl.getElementId("find-me")).?;
    try std.testing.expectEqual(Role.button, n.role);
    try std.testing.expect(byId(cl.getElementId("nope")) == null);
}
