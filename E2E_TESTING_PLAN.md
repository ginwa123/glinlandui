# E2E Testing Plan — a Compose-style UI test API for `glinlandui`

Status: **EXECUTED** — all 6 phases landed on `main` (working tree). See
[§13 Execution log](#13-execution-log) for what the implementation changed
relative to the design below (four deviations, two of them pre-existing bugs
this work exposed).

Scope: add a declarative, semantics-based end-to-end UI testing layer
(`onNodeWithText`, `performClick`, `performScrollToNode`, `assertIsDisplayed`,
`waitForIdle`) on top of the existing Clay/Host engine.

Result: `zig build test` **425/440 (15 skipped)** · `parity: 440 tests` ·
`layering: ok` · `fmt` clean · `native-test` 83/83 · ReleaseSafe builds.

Companion: `REFACTOR_PLAN.md` (the `core/` + `linux/` + `mac/` split and the
R1–R6 layering rules this plan must obey).

---

## 1. What "Android Compose testing" actually is

It is **five** things, and it is worth naming all five because the framework
already has two of them:

| # | Piece | Compose spelling |
|---|---|---|
| 1 | A **semantics tree** — a queryable node model with `{text, role, bounds, enabled, checked, actions, children}` | `SemanticsNode` / `SemanticsOwner` / `Modifier.semantics {}` |
| 2 | **Finders / matchers** | `onNodeWithText("Save")`, `hasClickAction()`, `and`, `or` |
| 3 | **Actions** | `performClick()`, `performScrollToNode()`, `performTextInput()`, `performTouchInput { swipeUp() }` |
| 4 | **Assertions** | `assertIsDisplayed()`, `assertIsEnabled()`, `assertTextEquals()` |
| 5 | **Synchronisation / idling** | `waitForIdle()`, `waitUntil {}`, `mainClock.advanceTimeBy()` |

The single idea that makes (2)–(4) possible is (1). Everything else is
plumbing over the semantics tree. So the question "how do we build this?" is
really "how do we build a semantics tree in an *immediate-mode* engine?" — and
that is the interesting part of this plan.

---

## 2. What this repo already has (do not rebuild it)

`src/core/testing/root.zig` is **already** a headless UI driver, and its
doc-comment already aspires to this design. Concretely:

| Capability | Where it lives today |
|---|---|
| **Stable test tags** | Every component takes `id: []const u8` and it becomes the Clay `ElementId` (`ButtonProps.id`, `ScrollProps.id`, …). The `id` *is* `testTag`. |
| **Real input injection** | `Driver.clickAt/pressAt/releaseAt/drag/scroll/key/typeText` → `Host.onPointerEvent/onScrollEvent/onKeyEvent`. |
| **Real click dispatch** | `dispatch.pointerEvent` → `click_registry.dispatchClick` (z-order + release-at-press-origin + 6px drag threshold). |
| **Geometry** | `cl.getElementData(id).bounding_box` (via `Driver.box(id)`). |
| **Programmatic scroll** | `scroll.scrollBy(id, dx, dy)` — 1:1 clamped, positive `dy` = scroll down. |
| **Scroll geometry** | `cl.getScrollContainerData(id)` → `scroll_position`, `scroll_container_dimensions`, `content_dimensions`, `found`. |
| **Text capture** | `Driver.captureFrame` already snapshots every `text` render command into `last_texts`. |
| **Post-layout seam** | `frame.FrameOptions.probe` runs synchronously right after `cl.endLayout()`. |
| **The registry pattern** | `click_registry.zig`: fixed capacity, zero allocation, `beginFrame()` reset, `register*`, query-by-point, never fails. **Copy this shape.** |
| **A second registry** | `scroll.zig` keeps its own per-frame container registry (`beginScrollFrame`/`registerScroll`/`dragScroll`). |

So the raw verbs *exist*: you can already click a tag, scroll, drag and type.
What does not exist is the **model** those verbs should hang off.

---

## 3. The gap

1. **No node model.** `Driver` can answer "does the string `OK` appear
   anywhere" (`hasText`) and "what is the box of id `X`" (`box`). It cannot
   answer *"the node labelled `Save`, which is a button, which is enabled, at
   this box"*. There is no per-node text/role/state.
2. **No parent or clip chain.** Clay exposes `bounding_box`, `pointerOver`,
   `getScrollContainerData`, `getPointerOverIds` — and **no parent query**.
   Clay tracks parents internally (`ElementId.localID` calls
   `Clay__GetParentElementId()`), but nothing public reads them. Without the
   ancestor chain you cannot answer `assertIsDisplayed()` ("is this node
   clipped out of its scroll viewport?") or `performScrollToNode()`.
3. **No matchers.** Nothing composes predicates over nodes.
4. **No idle.** Actions finish before the engine has settled. This matters
   because the engine has *documented one-frame lags* (see §7.3).
5. **No scroll-to-node.** Scroll routing is hover-based; nothing maps "make
   node N visible".

---

## 4. Architecture

```
src/core/
├── semantics.zig              # ★ NEW  the node model (registry + post-layout resolve)
├── testing/
│   ├── root.zig               #  EXISTING Driver; gains onNode()/waitForIdle()
│   ├── finders.zig            # ★ NEW  Query (matcher) + match machinery
│   ├── actions.zig            # ★ NEW  performClick / performScrollToNode / performTouchInput
│   └── assertions.zig         # ★ NEW  assertIsDisplayed / assertHasClickAction / …
├── components/
│   ├── button.zig             #  register a semantics node (one line)
│   ├── checkbox.zig           #  + checked
│   ├── toggle.zig / radio.zig / slider.zig / input.zig / list.zig / dropdown.zig
│   └── scroll.zig             #  push a CLIP ancestor around children
├── host.zig                   #  declareThunk: semantics.beginFrame()
└── frame.zig                  #  clayFrameWithOptions: semantics.resolve() after endLayout
```

Every new file is **pure Zig over `zclay` + core siblings**, so:

- **R1/R2/R3** hold automatically (no platform backend, no `platform.zig`, no
  `os.tag`, no system C header).
- **R6** holds (no `@cImport(`), so the modules may join the parity suite.
- The public surface is one new name: `glinlandui.semantics`.

### 4.1 The one hard problem: immediate mode

Compose has a **retained** tree: `SemanticsNode`s persist and are *diffed*
across recompositions, so bounds are always available.

Clay is **immediate mode**: the tree is thrown away and re-declared every
frame. And Clay only computes `bounding_box` **during `endLayout`** — before
that, `getElementData` returns stale/absent data. Therefore the model must be
built in **two phases**:

```
frame():
  beginFrame()                     ← clear registry (like click_registry.beginFrame)
  beginLayout()
  declare()                        ← components call semantics.register(...)  [ids known, RECTS NOT]
  endLayout()                      ← Clay computes all bounding boxes
  semantics.resolve(w, h)          ← fill bounds/clip/visible_fraction        [RECTS NOW VALID]
  probe(commands)                  ← existing seam; Driver snapshots here
```

This is exactly the shape `click_registry` already uses (register at declare,
`getElementData` at dispatch time), just formalised.

---

## 5. Code

### 5.1 `src/core/semantics.zig` — the node model

```zig
//! Per-frame semantics model: the queryable node tree behind the test API
//! (and, later, accessibility + the debug inspector). One consumer today.
//!
//! Immediate mode means this tree is REBUILT every frame exactly like the
//! widget tree: beginFrame -> components register during declare -> resolve()
//! AFTER Clay's endLayout fills in geometry.
//!
//! Deliberate constraints, matching components/click_registry.zig:
//!   * fixed capacity, zero allocation, register() never fails
//!   * Imports: std + zclay ONLY  (layering R1-R3, parity purity R6)
const std = @import("std");
const cl = @import("zclay");

pub const cap: usize = 256;
pub const ancestor_cap: usize = 8;

pub const Role = enum {
    unknown, text, button, checkbox, radio, toggle, slider,
    text_field, dropdown, list, list_item, scroll, image, icon, container,
};

/// What this node can DO. Compose's SemanticsActions, reduced to the four
/// gestures the engine can actually perform.
pub const Actions = packed struct(u8) {
    click: bool = false,
    scroll: bool = false,
    set_text: bool = false,
    drag: bool = false,
};

/// State the test reads. `hidden` is intent; "clipped out of view" is derived
/// from geometry in resolve(), not stored here.
pub const Flags = packed struct(u8) {
    enabled: bool = true,
    checked: bool = false,
    selected: bool = false,
    focused: bool = false,
    hidden: bool = false,
};

const EMPTY = cl.BoundingBox{ .x = 0, .y = 0, .width = 0, .height = 0 };

/// One ancestor snapshot: whether it CLIPS matters (a plain container's box
/// contains its children anyway; intersecting with it would over-clip nodes
/// that legitimately overflow, e.g. floating overlays).
const Ancestor = struct {
    id: cl.ElementId,
    clips: bool,
};

pub const Node = struct {
    // ---- declare-time facts ----
    id: cl.ElementId,
    tag: []const u8,
    role: Role = .unknown,
    label: []const u8 = "",
    value: []const u8 = "",
    actions: Actions = .{},
    flags: Flags = .{},
    z: i16 = 0,
    /// Ancestor chain, outermost-first, snapshotted at declare time.
    /// IDs are known before layout; RECTS are not — resolve() reads them.
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

    /// Where a click should land: the centre of the VISIBLE region, so a
    /// half-clipped row still receives a hit inside its scroll viewport.
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
/// click_registry.beginFrame().
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

/// Register a node during declare. Never fails; drops silently past cap
/// (same contract as click_registry.register).
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

/// Fill geometry for every registered node. MUST run after cl.endLayout().
/// Safe to run with an empty registry (no-op).
pub fn resolve(viewport_w: f32, viewport_h: f32) void {
    const viewport = cl.BoundingBox{ .x = 0, .y = 0, .width = viewport_w, .height = viewport_h };
    for (nodes[0..count]) |*n| {
        const data = cl.getElementData(n.id);
        n.found = data.found;
        if (!data.found) {
            n.bounds = EMPTY;
            n.clip = EMPTY;
            n.visible_fraction = 0;
            continue;
        }
        n.bounds = data.bounding_box;
        var clip = viewport;
        for (n.ancestors[0..n.ancestor_len]) |a| {
            if (!a.clips) continue;
            const ad = cl.getElementData(a.id);
            if (ad.found) clip = intersect(clip, ad.bounding_box);
        }
        n.clip = clip;
        const a = n.area();
        n.visible_fraction = if (a <= 0) 0 else intersectionArea(n.bounds, clip) / a;
    }
}

pub fn all() []const Node {
    return nodes[0..count];
}

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
/// waitForIdle a FIXED-POINT test instead of a sleep (see root.zig).
pub fn fingerprint() u64 {
    var h: u64 = 0xcbf29ce484222325;
    for (nodes[0..count]) |n| {
        h = mix(h, n.id.id);
        h = mix(h, @as(u64, @bitCast(n.bounds.x)));
        h = mix(h, @as(u64, @bitCast(n.bounds.y)));
        h = mix(h, @as(u64, @bitCast(n.visible_fraction)));
        h = mix(h, @as(u64, @bitCast(@as(u8, @bitCast(n.flags)))));
    }
    return h;
}

fn mix(h: u64, v: u64) u64 {
    return (h ^ v) *% 0x100000001b3;
}
```

### 5.2 `src/core/testing/finders.zig` — the matcher

Two shapes are possible; the **declarative struct** is the right one here
because matchers are consumed immediately and the engine has no allocator in
play for test scaffolding. (The vtable/combinator form — `and`, `or`, `not`
over `*const fn (Node) bool` — is the alternative if arbitrary composition is
ever needed; it costs a pointer-chased predicate per node.)

```zig
//! Matchers for the semantics tree. Imports: std + zclay + ../semantics.zig.
const std = @import("std");
const sm = @import("../semantics.zig");

/// A declarative query. Unset fields do not constrain.
/// Reads almost like Compose:
///     driver.onNode(.{ .label = "Save", .has_click_action = true })
pub const Query = struct {
    tag: ?[]const u8 = null,
    label: ?[]const u8 = null,
    value: ?[]const u8 = null,
    role: ?sm.Role = null,
    has_click_action: ?bool = null,
    has_scroll_action: ?bool = null,
    enabled: ?bool = null,
    checked: ?bool = null,
    selected: ?bool = null,
    /// true  -> only nodes with visible_fraction > 0
    /// false -> only nodes fully clipped out
    displayed: ?bool = null,
    /// Which match to select when several match. Compose raises on ambiguity
    /// for onNode(); here the default is "exactly one, else error".
    index: ?usize = null,

    pub fn matches(q: Query, n: *const sm.Node) bool {
        if (q.tag) |t| if (!std.mem.eql(u8, t, n.tag)) return false;
        if (q.label) |t| if (!std.mem.eql(u8, t, n.label)) return false;
        if (q.value) |t| if (!std.mem.eql(u8, t, n.value)) return false;
        if (q.role) |r| if (r != n.role) return false;
        if (q.has_click_action) |v| if (v != n.actions.click) return false;
        if (q.has_scroll_action) |v| if (v != n.actions.scroll) return false;
        if (q.enabled) |v| if (v != n.flags.enabled) return false;
        if (q.checked) |v| if (v != n.flags.checked) return false;
        if (q.selected) |v| if (v != n.flags.selected) return false;
        if (q.displayed) |v| if (v != (n.visible_fraction > 0)) return false;
        return true;
    }
};

pub const FindError = error{ NoNodeFound, NoNodeAtIndex, TooManyNodes };

/// First (or `index`-th) matching node in the CURRENT frame.
pub fn findOne(q: Query) FindError!sm.Node {
    const want = q.index orelse 0;
    var seen: usize = 0;
    for (sm.all()) |*n| {
        if (!q.matches(n)) continue;
        if (seen == want) return n.*;
        seen += 1;
    }
    // Nothing matched at all vs. an index past the last match: different bugs,
    // different errors (Compose distinguishes these too).
    return if (seen == 0) error.NoNodeFound else error.NoNodeAtIndex;
}

/// Enforce Compose's onNode() contract: exactly one match unless index is set.
pub fn findSole(q: Query) FindError!sm.Node {
    if (q.index != null) return findOne(q);
    var found: ?sm.Node = null;
    for (sm.all()) |*n| {
        if (!q.matches(n)) continue;
        if (found != null) return error.TooManyNodes;
        found = n.*;
    }
    return found orelse error.NoNodeFound;
}

/// Count matches without copying (for assertCountEquals / onAllNodes).
pub fn count(q: Query) usize {
    var c: usize = 0;
    for (sm.all()) |*n| if (q.matches(n)) {
        c += 1;
    };
    return c;
}
```

### 5.3 `src/core/testing/root.zig` — Driver additions

```zig
const semantics = @import("../semantics.zig");
const finders = @import("finders.zig");
const scroll_mod = @import("../components/scroll.zig");

pub const idle_frame_cap: usize = 16;
pub const scroll_frame_cap: usize = 32;

/// A handle to one node. Re-resolves against the CURRENT frame on every use,
/// exactly like Compose's SemanticsNodeInteraction — because bounds are a
/// frame-scoped snapshot here, not a live object.
pub const Interaction = struct {
    driver: *Driver,
    query: finders.Query,
    id: cl.ElementId,
    tag: []const u8,

    pub fn node(self: Interaction) !semantics.Node {
        return finders.findSole(self.query);
    }

    /// Click the VISIBLE centre. Full fidelity: this goes through
    /// Host.onPointerEvent -> drag threshold -> release-at-press-origin ->
    /// click_registry z-order dispatch. It is NOT a semantics-callback call.
    pub fn performClick(self: Interaction) !void {
        const n = try self.node();
        if (n.flags.hidden or n.visible_fraction <= 0) return error.NodeNotDisplayed;
        const c = n.visibleCenter();
        self.driver.clickAt(c.x, c.y);
        try self.driver.waitForIdle();
    }

    /// Bring the node into view by scrolling its nearest scrollable ancestor.
    pub fn performScrollTo(self: Interaction) !void {
        // First resolve must succeed; the ancestor chain is stable across
        // scrolls (only geometry moves), so read it once.
        const anc = anim: {
            const n = try self.node();
            break :anim scrollAncestor(n) orelse return error.NoScrollableAncestor;
        };
        var i: usize = 0;
        while (i < scroll_frame_cap) : (i += 1) {
            const cur = try self.node();
            if (cur.visible_fraction > 0) return;
            // Positive dy scrolls content UP (scroll.scrollBy's convention).
            const dy: f32 = if (cur.bounds.y < cur.clip.y)
                cur.bounds.y - cur.clip.y // node above the viewport -> scroll up (negative)
            else
                (cur.bounds.y + cur.bounds.height) - (cur.clip.y + cur.clip.height); // below -> down
            scroll_mod.scrollBy(anc.tag, 0, dy);
            self.driver.frame();
        }
        return error.ScrollToNodeFailed;
    }

    pub fn assertIsDisplayed(self: Interaction) !void {
        const n = try self.node();
        if (n.flags.hidden or n.visible_fraction <= 0) return error.NotDisplayed;
    }
    pub fn assertIsNotDisplayed(self: Interaction) !void {
        const n = self.node() catch return; // absent counts as not displayed
        if (!n.flags.hidden and n.visible_fraction > 0) return error.Displayed;
    }
    pub fn assertHasClickAction(self: Interaction) !void {
        if (!(try self.node()).actions.click) return error.NoClickAction;
    }
    pub fn assertIsEnabled(self: Interaction) !void {
        if (!(try self.node()).flags.enabled) return error.Disabled;
    }
    pub fn assertIsSelected(self: Interaction) !void {
        if (!(try self.node()).flags.selected) return error.NotSelected;
    }
    pub fn assertIsChecked(self: Interaction) !void {
        if (!(try self.node()).flags.checked) return error.NotChecked;
    }
    pub fn assertTextEquals(self: Interaction, expected: []const u8) !void {
        const n = try self.node();
        if (!std.mem.eql(u8, n.label, expected)) return error.TextMismatch;
    }
    pub fn assertExists(self: Interaction) !void {
        _ = try self.node();
    }
};

/// The nearest ancestor that is a scroll container, from the snapshot chain.
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
```

Driver gains a field and five methods:

```zig
// in Driver:
last_semantics_hash: u64 = 0,

/// Compose's onNode*(...): find a node now, keep a handle for actions.
pub fn onNode(self: *Driver, q: finders.Query) !Interaction {
    const n = try finders.findSole(q);
    return .{ .driver = self, .query = q, .id = n.id, .tag = n.tag };
}

pub fn onAllNodes(self: *Driver, q: finders.Query) usize {
    _ = self;
    return finders.count(q);
}

pub fn onNodeWithText(self: *Driver, text: []const u8) !Interaction {
    return self.onNode(.{ .label = text });
}

pub fn onNodeWithTag(self: *Driver, tag: []const u8) !Interaction {
    return self.onNode(.{ .tag = tag });
}

/// Compose's waitForIdle, adapted to an immediate-mode engine.
///
/// There is no recomposition queue and no animation clock here, so "idle" is
/// a FIXED POINT: two consecutive frames must produce an identical semantics
/// fingerprint. TWO frames, not one, is required rather than merely cautious —
/// the engine has documented one-frame lags (§7.3): scrollbar thumbs read
/// previous-frame scroll data, hover chrome reads the previous frame's
/// pointer-over ids, and getScrollContainerData().found is false until one
/// layout has run.
pub fn waitForIdle(self: *Driver) !void {
    self.frame();
    var prev = semantics.fingerprint();
    var i: usize = 0;
    while (i < idle_frame_cap) : (i += 1) {
        // A pending wheel delta is never idle: frame() consumes it.
        if (self.host.scroll_dx != 0 or self.host.scroll_dy != 0) {
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
```

`Driver.frame()` must also resolve semantics after the frame — either by
reusing the existing probe (`captureFrame` runs post-layout already) or by
calling `semantics.resolve` at the end of `frame()` after
`clayFrameWithOptions` returns. The probe is preferable: it also works for
production callers that pass a probe.

---

## 6. Integration points (exact edits)

| # | File | Change |
|---|---|---|
| 1 | `src/core/semantics.zig` | new file (§5.1) |
| 2 | `src/core/host.zig`, `declareThunk` | add `semantics.beginFrame();` beside `registry.beginFrame(); scroll_mod.beginScrollFrame();` |
| 3 | `src/core/frame.zig`, `clayFrameWithOptions` | after `const commands = cl.endLayout();`: `semantics.resolve(...)`, then `invokeProbe` (order matters) |
| 4 | `src/core/components/button.zig`, end of `button()` | inside the existing `if (!props.disabled)` block: `semantics.register(.{ .id = cl.getElementId(props.id), .tag = props.id, .role = .button, .label = props.label, .actions = .{ .click = true } });` |
| 5 | `src/core/components/checkbox.zig` / `toggle.zig` / `radio.zig` | same, plus `.flags = .{ .checked = props.checked }` (`.selected` for radio/toggle) |
| 6 | `src/core/components/input.zig` | register `role = .text_field`, `value = <current text>`, `actions = .{ .set_text = true }` |
| 7 | `src/core/components/scroll.zig`, `scroll()` | register `role = .scroll`, `actions = .{ .scroll = true }`, and wrap `children(ctx)` in `semantics.pushAncestor(cl.getElementId(props.id), true)` / `popAncestor()` |
| 8 | `src/core/components/list.zig`, `dropdown.zig` | register `role = .list`, and `.list_item` per row with its row label |
| 9 | `src/core/testing/{finders,actions,assertions}.zig` | new files (§5.2, §5.3) |
| 10 | `src/core/testing/root.zig` | `Interaction`, `onNode`, `waitForIdle`, `onNodeWithText`, `onNodeWithTag` |
| 11 | `src/root.zig` | `pub const semantics = @import("core/semantics.zig");` + add every new module to the aggregate `test` block |
| 12 | `tests.lock` | **bump the number** — see §9 |

The component edits (#4–#8) are the "opt-in cost": one `register` line each,
in the same `if (!props.disabled)` block that already exists. A second,
zero-diff path is available: derive baseline semantics automatically from
`click_registry`'s own entries (see §8).

---

## 7. Engine gotchas (this is the part that will actually bite)

### 7.1 Bounds do not exist until `endLayout`
`cl.getElementData(id).bounding_box` is populated during layout. Registering
with geometry at declare time is impossible. Hence the mandatory
register → `endLayout` → `resolve` sequence. Any test that reads bounds before
`resolve` gets zeros.

### 7.2 Everything is a frame-scoped snapshot
Render commands *and* element data are valid only until the next
`beginLayout`. `Driver` already stores **copies** into fixed arrays for exactly
this reason. `Interaction` must therefore **re-resolve per call** rather than
caching a `Node` — which also happens to match Compose's
`SemanticsNodeInteraction` behaviour.

### 7.3 One-frame lags force a two-frame idle
Three independent, documented lags:

1. `scroll.declareScrollbars` reads **previous-frame** scroll data (the thumb
   declares nothing on the first frame — `found == false`).
2. Hover chrome (`cl.hovered()`) is driven by `setPointerState`, which
   hit-tests against **frame-1** boxes.
3. `getScrollContainerData().found` is false until one layout has run.

So `waitForIdle` requires **two consecutive identical fingerprints**, and
`performClick`/`performScrollTo` must call it. Skipping it produces
intermittent, order-dependent flakes.

### 7.4 A click is a release, at the press origin, against the previous frame
`dispatch.pointerEvent` fires on **BTN_LEFT release**, at `down_x/down_y`, only
if the press was in-bounds **and** never exceeded the **6px drag threshold**,
and `dispatchClick` hit-tests `getElementData` — i.e. the *previous* frame's
boxes. Consequences:

- `performClick` = pointer-down + pointer-up at the same point + frame. The
  existing `Driver.clickAt` already does this; reuse it.
- The UI must be **stable** when the click lands, or the previous frame's boxes
  point somewhere else. `waitForIdle` before, not just after.
- A "click" that moves more than 6px is a **drag** and fires nothing. So
  `performClick` and `performTouchInput { swipeUp() }` are genuinely different
  code paths — which is a feature: it is exactly what validates the
  "press-drag-release scrolls instead of clicking" contract
  (`host.zig`'s `onPointerEvent` → `scroll.dragScroll`).

### 7.5 Scroll is routed to the *hovered* container
`Host.onScrollEvent` only **accumulates** `scroll_dx/dy`; `clayFrameWithOptions`
feeds it to `cl.updateScrollContainers`, and Clay applies it to the scroll
container under the pointer. So a wheel-based `performScroll` must first move
the pointer inside the container. **Prefer `scroll.scrollBy()`** (deterministic,
1:1, clamped, no ×10 wheel factor and no coordinate negation) for
`performScrollToNode`. Use the wheel path only when the test's *point* is to
exercise wheel routing.

### 7.6 Clay exposes no parent/clip query
`assertIsDisplayed` and `performScrollToNode` both need the clip chain, and
Clay gives no parent accessor. Capturing our own ancestor stack at declare time
(§5.1) is the only correct option. Note `ElementId.localID` proves Clay tracks
parents internally, so this is a missing binding rather than a missing concept —
if a `getParentElementId` binding lands upstream, §5.1's stack can be deleted.

### 7.7 Do not intersect every ancestor
Intersecting with *all* ancestor boxes over-clips: floating overlays and
absolutely-positioned children legitimately paint outside their parent. Only
`clips == true` ancestors (scroll/clip containers) may narrow the visible rect.
Getting this wrong makes `assertIsDisplayed` fail for perfectly visible
overlays.

### 7.8 `cl.hovered()` must stay inside the `UI()` literal
Already a documented trap in `button.zig`/`checkbox.zig`. Semantics registration
happens *after* the element closes, which is fine for `getElementData` (it is
id-based), but any action that asserts on hover *chrome* needs the extra
`waitForIdle` frame from §7.3.

---

## 8. Two designs; pick the lazy one

**(A) Explicit semantics — Compose-faithful.** Every component calls
`semantics.register(...)`. Full fidelity (role, label, value, state), and the
tree is reusable for accessibility and the Clay debug inspector.

**(B) Derived baseline — zero component diffs.** Build the registry from what
already exists: walk `click_registry`'s entries → `actions.click = true`;
walk `scroll.zig`'s registry → `role = .scroll, actions.scroll = true`; the tag
is the `id` string. This yields `onNodeWithTag`, `performClick`,
`hasClickAction`, `performScrollToNode` with **no component edits at all** —
only label/value/role/state need (A).

**Recommendation: B now, A incrementally.** Ship (B) so the verbs are usable,
then add `register` calls component-by-component as tests need
`onNodeWithText` / `assertIsChecked`. `Driver.onNodeWithText` simply returns
`NoNodeFound` until a component volunteers its label — a clean, honest failure.

---

## 9. CI constraints (non-negotiable)

1. **`tests.lock` started at 376.** `ci/check_test_parity.sh` reads the total from
   `zig build test --summary all` and compares it to `tests.lock`. **Every test
   added must bump `tests.lock` in the same commit**, or CI fails on *both*
   platforms. Baseline when this plan was written: `363/376 passed (13 skipped)`.
   It is `425/440 (15 skipped)` now — see §13.
2. **R6: parity-suite modules must be C-free.** `ci/check_layering.sh` greps
   the new files for `@cImport(`. `semantics.zig`, `finders.zig` and
   `assertions.zig` must stay pure Zig (they will — `zclay` is a Zig module,
   not a C header).
3. **New modules must join the `test` block in `src/root.zig`** to be
   type-checked on the non-native platform. That is the mechanism that makes a
   typo in a new file fail on both OSes instead of only CI's Linux leg.
4. **The layering scan is source-only** (`*.{zig,c,h,m}`), so plan prose may
   mention `os.tag` / `@cImport` freely.
5. **`zig fmt --check` is part of the gate** — the new files must be
   `zig fmt`-clean.

---

## 10. Phased plan

| Phase | Deliverable | Gate |
|---|---|---|
| **0** | `semantics.zig` (registry + `resolve` + clip ancestry), **with tests**; wired into `declareThunk` + `clayFrameWithOptions`; added to the `root.zig` parity block; `tests.lock` bumped | `zig build test` new count; `check_layering.sh` ok |
| **1** | `finders.zig` (`Query`, `findSole`, `count`) + `Driver.onNode`/`onNodeWithTag`/`onNodeWithText`; derive baseline from `click_registry` (design B, §8) | a real test: `onNodeWithTag("testkit-button").performClick()` replaces `click(id)` |
| **2** | `waitForIdle` + `fingerprint`; `Interaction.performClick` | same click test, now idle-gated; add a deliberately-lagged case (hover chrome) |
| **3** | `scroll.zig` pushes a clip ancestor; `Interaction.performScrollTo` via `scroll.scrollBy` | scroll-to-node test on a synthetic 10-row overflow list |
| **4** | `assertions.zig` (`assertIsDisplayed` / `assertHasClickAction` / `assertIsEnabled` / `assertTextEquals`) | clip-aware display test: a row scrolled out of view asserts `NotDisplayed` |
| **5** | Optional: `performTouchInput { swipeUp() }` / `performTextInput`, and a debug/accessibility consumer of the same tree | gesture test through the 6px drag path |

Phases 0–2 are the load-bearing ones; 3–5 are additive and independently
landable.

---

## 11. Why this is better than Compose for E2E, in one respect

Compose's `performClick()` does **not** send a touch. It looks up the semantics
`OnClick` action and **invokes the lambda**. A test therefore cannot catch a
bug in hit-testing, z-order, or clipping — those layers are bypassed.

Here, actions are routed through `Host.onPointerEvent` → the 6px drag
threshold → release-at-press-origin → `click_registry.dispatchClick`
(highest-z wins, ties last-registered) → `getElementData` hit test. The test
exercises the **real gesture pipeline**. That is Espresso-with-real-events
fidelity, and it is the strongest argument for building the layer this way
rather than exposing a `callOnClick()` escape hatch.

---

## 12. Risks

| # | Risk | Severity | Mitigation |
|---|---|---|---|
| 1 | Adding `semantics.resolve` to the production frame path costs a `getElementData` per node per frame | Medium | Gate behind `FrameOptions` (resolve only when a probe/tooling flag is set), or run only in `builtin.is_test` + an explicit a11y opt-in |
| 2 | `tests.lock` drift | High | Bump in the same commit; run `ci/check_test_parity.sh` before pushing every phase |
| 3 | Over-clipping via ancestor intersection | Medium | Only `clips == true` ancestors narrow the clip (§7.7); test a floating overlay explicitly |
| 4 | Flaky clicks from the previous-frame hit test | High | `waitForIdle` **before and after** every action; two-frame fixed point (§7.3) |
| 5 | `ancestor_cap = 8` overflow in deep trees | Low | Keep the innermost 8; positions are the outermost that matter for clip in practice. Test a 9-deep scroll nest if one ever exists |
| 6 | Per-frame string slices (`label`, `tag`) point at caller memory | Low | Same lifetime rule as `ButtonProps.label` today (must outlive the frame); document it |
| 7 | Fixed `cap = 256` silently drops nodes | Low | Matches `click_registry.cap`; add a `count()` assertion helper so a full registry is detectable in tests |

---

## 13. Execution log

Executed on Linux, Zig 0.16.0. All six phases landed; every gate green from a
warm build.

| Phase | Result |
|---|---|
| 0 | `core/semantics.zig` (11 tests) + `Host.declareFrame` + `FrameOptions.resolve_semantics`. |
| 1 | `testing/finders.zig` (9) + `Driver.onNode` / `onNodeWithTag` / `onNodeWithText` / `onNodeWithIndex` / `onAllNodes`. |
| 2 | `Driver.waitForIdle` (fingerprint fixed point) + `Interaction.performClick`. |
| 3 | `scroll.zig` pushes a CLIP ancestor; `Interaction.performScrollTo` via `scroll.scrollBy`. |
| 4 | `testing/assertions.zig` (8) + the `Interaction.assert*` surface. |
| 5 | `testing/actions.zig` (9) + `performTouchInput` / `performTextInput`. |
| 6 | Component registration in `button`, `checkbox`, `toggle`, `radio`, `slider`, `image`, `input` (×2), `list` (container + rows), `dropdown`, `scroll`. |

Plus 10 E2E tests inside `testing/root.zig` (synthetic scrollable list) and
`examples/calculator_e2e_test.zig` (15 tests against the real calculator).

**Final state:** `zig build test` **425/440 (15 skipped)** · `parity: 440 tests
(matches tests.lock)` · `layering: ok` (R1–R6) · `zig fmt --check` clean ·
`native-test` **83/83** · `-Doptimize=ReleaseSafe` builds.

`tests.lock`: **376 → 440**. This work added **62** (37 library: semantics /
finders / assertions / actions, + 10 `testing/root.zig` E2E tests, + 15
calculator E2E tests); a parallel macOS/font change added the other **2**, which
is why the merged count is 440 and the skip count moved 13 → 15 (both new tests
are font-dependent and skip where the fonts are absent).

### Deviations from the plan (each forced by something the plan could not see)

#### 1. Two PRE-EXISTING bugs in the Driver path — this was the real find

Both were latent in `core/testing/root.zig` before this work and only became
visible once a *stateful, per-frame* model (semantics) sat on top of them.
Neither is a regression introduced here; both are fixed here.

**(a) `Driver.declareThunk` called `root_fn` directly, skipping the per-frame
registry resets.** `Host.declareThunk` clears `click_registry`, the scroll
registry, the image slots and (now) semantics before invoking the app root. The
Driver had its own thunk that bypassed all of it, so entries accumulated frame
after frame. `click_registry` masked this (duplicate hit targets still dispatch
the best match once, so the old click tests passed), but a tag lookup became
`TooManyNodes` by frame 2. Fix: `Host.declareFrame` is now public and the Driver
calls it; the Driver has no thunk of its own.

**(b) `Driver.frame` called `clayFrameWithOptions` directly, so the pending
wheel delta was never consumed.** `Host.frameWithOptions` reads
`scroll_dx/scroll_dy` and zeroes them; the Driver passed them straight through,
so a single `driver.scroll(0, 5)` re-applied 50px of travel on EVERY subsequent
frame — the UI could never reach a fixed point, so `waitForIdle` could never
return. Fix: `Driver.frame` now calls `Host.frameWithOptions`, which also fixes
(a) for free. Both fixes make the Driver drive the *production* frame path
rather than a lookalike, which is what its own doc-comment always claimed.

#### 2. Clickability is DERIVED, not declared (design B from §8)

`components/*` register their IDENTITY (tag, role, label, state) but never set
`actions.click`. `semantics.resolve` folds clickability in from
`click_registry` — the one authoritative record of what dispatch will actually
fire — via a new read-only `click_registry.Hit` / `hitCount` / `hitAt` view.

This was not a preference: it is required by the calculator example, which
passes `on_click = null` and registers all 20 keys externally with
`registerZCursor`. Keying semantics off `on_click` would have made every keypad
key invisible. It also means the two sources cannot drift — a widget cannot
report "clickable" when dispatch would ignore it, or vice versa.

#### 3. The E2E suite must import the calculator as a MODULE, not a file

First attempt used `@import("calculator.zig")`. That compiled and passed, but
the count came out at 476 instead of 440 — **36 too many, exactly the
calculator's own test count**. Zig's test collector walks file-path `@import`s
inside the module under test, so the E2E binary re-collected and re-ran the
example's tests. It does *not* walk into imported *modules* (which is why
`exe_tests` importing `glinlandui` has never double-counted the library). Fix:
`build.zig` passes the example as `.{ .name = "calculator", .module = calc_mod }`
and the test file does `@import("calculator")`. Worth knowing: any future test
root that relative-imports a file which already has its own test root will
double-count it.

#### 4. Small additions the design did not anticipate

- **`performClick` requires `actions.click`.** Compose raises here too. Without
  it, clicking a disabled button silently succeeded (no hit target → no
  callback) and the test then asserted "0 clicks", which is a vacuous pass.
  Now it fails with `error.NoClickAction`.
- **`assertions.Error` naming rule.** The error names what was FOUND, so
  `isDisplayed` → `NotDisplayed` and `isNotDisplayed` → `Displayed`. Without a
  rule the negative assertions were reporting the positive error name
  (`isDisabled` on an enabled node returned `error.Disabled`), which reads
  backwards in a test log.
- **`Node.visibleCenter()`** replaced the geometric centre as the click point:
  a half-clipped row's centre can fall outside its own clip rect, so the click
  must come from the intersection.
- **`resolve_semantics` is OFF by default** (risk #1 mitigation, as designed):
  production pays nothing. It is also why the semantics registry being cleared
  unconditionally every frame matters — with the flag off, the registry is
  emptied and never walked, so no stale tree can leak.

### Known limitations left in place (deliberate)

1. **`list.zig` rows carry no label.** The row text comes from the caller's
   `renderItem` callback, so there is nothing to record at declare time. Rows
   register `role = .list_item` with an empty tag, and tests select them with
   `onNodeWithIndex(.{ .role = .list_item }, i)`. Threading a label through
   would mean changing `ListProps`' render contract — a real API change, not
   part of this work.
2. **`box.zig` registers no semantics.** Boxes are layout containers and
   registering them would fill the 256-node cap with noise. Consequence: a
   `box`'s clip is not part of the ancestor chain, which is correct (it does not
   clip) but means only `scroll.zig` contributes clip ancestry today.
3. **`mergeClickable` is O(nodes × hits)** per resolved frame (256×256 worst
   case). Irrelevant in practice (the calculator is 20×20) and gated behind
   `resolve_semantics`, but it is the first thing to index if the flag is ever
   turned on in production for accessibility.
4. **`ancestor_cap = 8`** keeps the innermost 8 ancestors. Deeper clip nesting
   than that would under-report clipping; no layout in this repo comes close.
5. **No `mainClock` / `advanceTimeBy`.** The engine has no animation clock, so
   there is nothing to advance. `waitForIdle`'s fixed point is the whole
   synchronisation story, and it is sufficient because the only "in flight"
   state is the pending wheel delta and the three documented one-frame lags
   (§7.3).

