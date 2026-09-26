# glinlandui

A **platform-agnostic GUI toolkit for Zig 0.16**, built on [Clay](https://github.com/nicbarker/clay).

Clay does layout and emits a stream of render commands. `glinlandui` owns
everything around that: the window, the event loop, the renderer, text
measurement, input dispatch, a widget set — and a headless **end-to-end test
layer** that can click, scroll, drag and type into your UI without a compositor,
a GPU, or a font engine.

Consumers write `@import("glinlandui")` and get the same surface everywhere:

| host | window | renderer | text | status |
|---|---|---|---|---|
| Linux | Wayland (`xdg-shell`) | EGL + GLES3 | pangocairo | native, tested in CI |
| macOS | Cocoa | CoreGraphics / shared CPU rasterizer | shared estimator | native, tested in CI |
| anywhere else | — | shared CPU rasterizer (real RGBA8 pixels) | shared estimator | portable fallback |
| **test builds** | — | shared CPU rasterizer | deterministic estimator | **every OS** |

That last row is the point: **the test build always selects the portable
backend**, so `zig build test` compiles and runs one identical suite on every
platform. Design decisions in the macOS backend are proven on Linux and vice
versa.

---

## Table of contents

- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Using it as a dependency](#using-it-as-a-dependency)
- [Hello world](#hello-world)
- [Architecture](#architecture)
- [Testing](#testing)
- [End-to-end UI testing](#end-to-end-ui-testing)
- [Project layout](#project-layout)
- [Further reading](#further-reading)

---

## Requirements

- **Zig 0.16.0** (`minimum_zig_version` in `build.zig.zon`).
- **Linux** — a C toolchain plus:
  - `wayland-scanner` at `/usr/sbin/wayland-scanner` (used at build time for protocol codegen)
  - `wayland-client`, `wayland-egl`, `EGL`, `GLESv2`
  - the pangocairo stack: `cairo`, `pango-1.0`, `pangocairo-1.0`, `fontconfig`, `freetype`, `harfbuzz`, `gobject-2.0`, `glib-2.0` (with headers)
- **macOS** — Xcode command line tools (AppKit, Foundation, CoreGraphics).

Clay and stb are **vendored** (`vendor/`), so the build never needs the network.

---

## Quick start

```bash
git clone <this repo> && cd glinlandui

zig build run               # the demo app  (needs a Wayland display)
zig build run-calculator    # the calculator example (needs a Wayland display)

# No display? Both fall back to headless rendering and report painted pixels:
env WAYLAND_DISPLAY= ./zig-out/bin/glinlandui-calculator
#   window unavailable (NoWaylandDisplay); rendering headless instead
#   glinlandui calculator rendered 360x440 headless (158400 painted pixels, no display available)

# The full gate — all of these must pass before pushing.
zig fmt --check build.zig src examples
zig build test --summary all     # 425/440 tests passed (15 skipped)
./ci/check_test_parity.sh        # parity: 440 tests (matches tests.lock)
./ci/check_layering.sh           # layering: ok
```

---

## Using it as a dependency

```zig
// build.zig.zon
.dependencies = .{
    .glinlandui = .{ .path = "../glinlandui" },
},
```

```zig
// build.zig
const dep = b.dependency("glinlandui", .{ .target = target, .optimize = optimize });

const exe = b.addExecutable(.{
    .name = "my-app",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "glinlandui", .module = dep.module("glinlandui") }},
    }),
});
b.installArtifact(exe);
```

Your app's tests then import the same module and drive the UI headlessly — see
[End-to-end UI testing](#end-to-end-ui-testing).

---

## Hello world

```zig
const std = @import("std");
const glinlandui = @import("glinlandui");

const components = glinlandui.components;

const App = struct {
    clicks: usize = 0,

    /// The Clay declare callback. Everything the app draws happens here, and
    /// `ctx` is the app object so the tree is built against live state.
    fn root(ctx: ?*anyopaque, _: u32, _: u32) void {
        const self: *App = @ptrCast(@alignCast(ctx.?));
        components.box.box(.{
            .id = "hello-root",
            .w = .grow,
            .h = .grow,
            .pad = 16,
            .gap = 8,
        }, self, children);
    }

    fn children(self: *App) void {
        components.text.label(.{ .str = "Hello, glinlandui", .font_size = 20 });
        components.button.button(.{
            .id = "hello-button",       // the element id IS the E2E test tag
            .label = if (self.clicks == 0) "Click me" else "Clicked!",
            .on_click = onClick,
            .ctx = self,
        });
    }

    fn onClick(ctx: ?*anyopaque) void {
        const self: *App = @ptrCast(@alignCast(ctx.?));
        self.clicks += 1;
    }
};

pub fn main() !void {
    // The Clay arena is process-lifetime, so the page allocator matches the
    // toolkit's own convention (see `core/testing/root.zig`).
    const alloc = std.heap.page_allocator;

    var app = App{};
    var host = try glinlandui.host.Host.init(alloc, &app, App.root);
    defer host.deinit();

    var window = glinlandui.Window.init(.{
        .app_id = "hello",
        .title = "Hello",
        .width = 360,
        .height = 220,
        .min_width = 240,
        .min_height = 160,
    });
    window.delegate = host.delegate();
    try window.run();
}
```

The two things worth noticing:

- **Every widget takes an `id`.** It becomes the Clay element id, and it is also
  the E2E **test tag** — there is no separate `testTag` plumbing to add.
- **`Host` hands the platform a `Delegate`.** That contract
  (`core/window_contract.zig`) is the entire integration surface: the platform
  never sees a widget, and the widget layer never sees a platform.

---

## Architecture

```
consumer → root.zig → platform.zig ─┬─ linux/window.zig ─┐
                                     └─ mac/window.zig ───┤
                                                          ▼
   core/frame.zig ──► core/render.zig ──► core/select.zig ──► platform.zig
        │                     │                                   │
        │                     └─ core/render_software.zig          │
        ▼                                                          │
   core/host.zig ──► core/components/* ──► core/render_common.zig  │
        │                                                          │
        └─ returns a Delegate ─────────────────────────────────────┘
           (core/window_contract.zig) → handed to the platform window
```

Three rules hold the whole thing together, enforced by
`ci/check_layering.sh` rather than by discipline:

- **`src/core/`** compiles identically on every OS. It may not import
  `linux/` or `mac/`, may not read `os.tag`, and may not include a platform C header.
- **`src/platform.zig`** is the *only* file that branches on `builtin.os.tag`.
- **`src/linux/` and `src/mac/`** are siblings exposing nine files with the same
  names and the same roles (a *role* mirror, not a copy) — so you can read them
  side by side.

`src/README.md` documents the layout, the invariants (I1–I5), the traps, and the
verification recipes in detail. Read it before changing anything under `src/`.

### The one thing to internalize

This is an **immediate-mode** toolkit: your `root` callback re-declares the whole
tree, every frame, from scratch. There is no retained widget tree and no
recomposition. Clay discards the previous frame's layout during `beginLayout`
and computes the new one during `endLayout`.

Two consequences that shape both the app API and the test API:

1. **Nothing has geometry until `endLayout` has run.** A widget's bounding box is
   only knowable *after* the frame that declared it.
2. **Anything read off a frame is a frame-scoped snapshot.** Render commands and
   element data are valid until the next `beginLayout`.

The E2E layer is built around those two facts, and it is why it looks slightly
different from Compose's.

---

## Testing

Six gates. They are cheap, and each one catches a class of mistake the others
cannot.

| gate | command | expectation |
|---|---|---|
| formatting | `zig fmt --check build.zig src examples` | silent |
| unit + parity suite | `zig build test --summary all` | `425/440 tests passed (15 skipped)` |
| locked test count | `./ci/check_test_parity.sh` | `parity: 440 tests (matches tests.lock)` |
| architecture | `./ci/check_layering.sh` | `layering: ok` |
| native backends (Linux only) | `zig build native-test --summary all` | `83/83 tests passed` |
| macOS colour hand-off (macOS only) | `zig build check-colors` | `skipped` off macOS |

### 1. `zig build test` — the cross-platform suite

This is the gate that matters. It compiles a **fixed, platform-independent set**
of test roots, so Linux and macOS run the *same* tests and report the *same*
count. The suite covers the widget set, the frame path, host/input dispatch, the
CPU rasterizer (with pixel assertions), the text estimator, the macOS
translation modules, the Linux pure modules, the calculator example, and the E2E
test layer.

It needs no display, no GPU and no font.

> **Why 15 tests skip.** `core/glyphs.zig`'s font-dependent tests call
> `requireFont() orelse return error.SkipZigTest`, and in a test build the font
> candidates come from the portable backend (macOS paths). On macOS all 13 run;
> elsewhere 15 skip. The *total* is 440 either way, so parity holds — but it
> means the glyph rasterizer is only really exercised on macOS. This is known
> debt, tracked in `src/README.md` §5.

### 2. `tests.lock` + `ci/check_test_parity.sh` — the locked count

`tests.lock` holds a single number. The parity script extracts the total from
`zig build test --summary all` and compares.

**If you add or remove a test, update `tests.lock` in the same commit.** That is
the whole mechanism: it makes "the suite is the same on both platforms" an
enforced fact rather than an assumption. Never resolve a parity failure by
editing the lock without knowing which test moved.

There is a subtlety about *how* tests get collected, and it bites:

- A test root runs the tests of **every file it reaches by relative `@import`**.
  Adding one import to a test root can raise the count without you writing a test.
- Test collection **does not cross module boundaries**. `exe_tests` importing
  `glinlandui` as a module has never re-counted the library's tests — which is
  exactly why `examples/calculator_e2e_test.zig` imports the calculator as a
  **module** (`@import("calculator")`, wired in `build.zig`) rather than as a
  file. A relative import there would have run the example's 36 tests twice.

### 3. `ci/check_layering.sh` — the architecture gate

Six grep rules (R1–R6) that say "this token does not appear in this subtree".
They are milliseconds to run and they are the documentation of the split:

| | rule |
|---|---|
| R1 | nothing under `src/core/` may import `linux/` or `mac/` |
| R2 | only `src/core/select.zig` may import `../platform.zig` |
| R3 | `src/core/` may not read `os.tag` or include a platform C header |
| R4 | `src/linux/` and `src/mac/` may not import each other |
| R5 | only `src/platform.zig` may read `os.tag` |
| R6 | every module in the parity suite must be pure Zig (no `@cImport(` call) |

If you change a rule, **plant a violation and watch it fail** before trusting it.

### 4. `zig build native-test` — the Linux-only superset

Runs the real Wayland/EGL/GLES3/pangocairo tests. Deliberately **outside** the
parity count (it is a superset, and it cannot run on macOS), and it is empty off
Linux.

### 5. Smoke test the real binary

```bash
zig build -Doptimize=ReleaseSafe
env WAYLAND_DISPLAY= ./zig-out/bin/glinlandui-calculator
#   glinlandui calculator rendered 360x440 headless (158400 painted pixels, no display available)
```

That path exercises the software rasterizer end to end on a release build: a
painted-pixel count of 0 would mean something is genuinely broken.

---

## End-to-end UI testing

`glinlandui.testing` is a Compose-style API: find a node by tag/text/role, then
act on it and assert on it.

```zig
const ui = @import("glinlandui");
const Driver = ui.testing.Driver;

test "the save button applies the change" {
    var app = App{};
    var driver = try Driver.initOwned(std.heap.page_allocator, &app, App.root);
    defer driver.deinit();
    try driver.start(.{ .width = 720, .height = 480 });
    try driver.waitForIdle();

    try (try driver.onNodeWithTag("settings.save")).performClick();
    try (try driver.onNodeWithText("Saved")).assertIsDisplayed();
    try std.testing.expect(app.saved);
}
```

The complete worked example is **`examples/calculator_e2e_test.zig`** — 15 tests
driving the real calculator (`examples/calculator.zig`) with no compositor, no GL
context and no font engine. Run it with:

```bash
zig build test        # it is part of the parity suite
```

### The model: a semantics tree

Compose's testing is built on a `SemanticsNode` tree; everything else is
plumbing over it. `glinlandui` has the equivalent in `glinlandui.semantics`:

```zig
pub const Node = struct {
    id: ElementId,
    tag: []const u8,        // the widget's id — the test tag
    role: Role,             // .button .checkbox .text_field .list_item …
    label: []const u8,      // a button's caption, a row's text
    value: []const u8,      // a field's committed content
    actions: Actions,       // .click .scroll .set_text .drag
    flags: Flags,           // .enabled .checked .selected .hidden, + focused
    // resolved after layout:
    found: bool,
    bounds: BoundingBox,
    clip: BoundingBox,      // intersection of every CLIPPING ancestor + viewport
    visible_fraction: f32,  // 0..1 of the node's area that survives clipping
    // …
};
```

Because the engine is immediate mode, the tree is **rebuilt every frame**, in
three phases:

```
frame():
  beginFrame()         ← clear the registry (Host.declareFrame)
  beginLayout()
  declare()            ← components call semantics.register(...)   ids known, RECTS NOT
  endLayout()          ← Clay computes every bounding box
  resolve(w, h)        ← fill bounds / clip / visible_fraction     RECTS NOW VALID
  probe(commands)
```

Registration gives identity; geometry is resolved afterwards. `actions.click` is
deliberately **not** declared by widgets — `resolve()` folds it in from the click
registry, which is the one authoritative record of what dispatch will actually
fire. That is what lets a widget registered in an unusual way still report
correctly (the calculator passes `on_click = null` and registers its keys
externally, and `assertHasClickAction` still passes).

Resolution is **off in production** — `FrameOptions.resolve_semantics` defaults to
`false`, so a shipping app pays nothing. The test driver turns it on.

### The API

**Finding nodes** — `Driver`:

| method | notes |
|---|---|
| `onNodeWithTag(tag)` | the widget's `id`. Compose's `onNodeWithTag` |
| `onNodeWithText(text)` | matches `label` — a button caption, a row's text |
| `onNode(query)` | full declarative query (see below) |
| `onNodeWithIndex(query, i)` | disambiguate deliberately |
| `onAllNodes(query)` | how many match |
| `semanticsNode(id)` / `nodes()` | the raw resolved tree |

A `Query` is a plain struct; unset fields do not constrain:

```zig
driver.onNode(.{ .label = "Save", .has_click_action = true });
driver.onNode(.{ .role = .list_item, .selected = true });
driver.onNode(.{ .displayed = false });          // clipped out of view
driver.onNodeWithIndex(.{ .role = .list_item }, 3);
```

Fields: `tag` `label` `value` `role` `has_click_action` `has_scroll_action`
`set_text_action` `enabled` `checked` `selected` `hidden` `displayed` `index`.

`onNode` enforces Compose's contract: **exactly one match, or an error**
(`error.TooManyNodes` / `error.NoNodeFound`). Silently taking the first match
hides a genuine test bug.

**Acting** — `Interaction`:

| method | what it does |
|---|---|
| `performClick()` | real pointer press+release at the *visible* centre |
| `performScrollTo()` | scrolls the nearest scrollable ancestor until the node is visible |
| `performTouchInput(Swipe.up(x, y, 40))` | a real gesture: press, motion, release |
| `performTextInput(text)` | types into an editable node (requires `set_text`) |
| `node()` | re-resolve the node against the current frame |

**Asserting** — also on `Interaction`:

| method | fails with |
|---|---|
| `assertExists()` | `NotDisplayed` if not laid out |
| `assertIsDisplayed()` / `assertIsNotDisplayed()` | `NotDisplayed` / `Displayed` |
| `assertVisibleAtLeast(f)` | `NotDisplayed` |
| `assertIsEnabled()` / `assertIsDisabled()` | `Disabled` / `Enabled` |
| `assertIsSelected()` / `assertIsChecked()` | `NotSelected` / `NotChecked` |
| `assertHasClickAction()` / `assertHasNoClickAction()` | `NoClickAction` / `HasClickAction` |
| `assertHasScrollAction()` | `NoScrollAction` |
| `assertTextEquals(t)` / `assertValueEquals(v)` | `LabelMismatch` / `ValueMismatch` |
| `assertRole(r)` | `RoleMismatch` |

Errors name what was **found**, so `assertIsNotDisplayed` on a visible node
reports `Displayed` — a bare error in a test log is unambiguous about which
direction failed.

**Synchronising**:

| method | notes |
|---|---|
| `waitForIdle()` | runs frames until the semantics fingerprint reaches a fixed point |
| `resize(w, h)` | change the viewport and re-render |
| `move` `scroll` `key` `typeText` `drag` `pressAt` `releaseAt` `clickAt` | the lower-level primitives the actions above are built from |
| `hasText` `expectText` `expectNoText` | assertions on the *render commands* |
| `box(id)` `exists(id)` `isPointerOver(id)` | geometry / hit-test queries |
| `snapshot()` | command counts, pointer state, cursor shape |

### A worked example

From `examples/calculator_e2e_test.zig`:

```zig
test "e2e: a keypad click computes 42 the way a user would" {
    var app = calc.App{};
    var driver = try calcDriver(&app);
    defer driver.deinit();

    // 12 + 30 = 42, entirely through the UI.
    for ([_][]const u8{ "1", "2", "+", "3", "0", "=" }) |caption| {
        const key = try driver.onNodeWithText(caption);
        try key.performClick();
    }

    try std.testing.expectEqualStrings("42", app.m.display());
    try driver.expectText("42");          // and the VIEW agrees
}
```

Clipping is understood, not worked around:

```zig
test "e2e: performScrollTo brings a clipped row into view, then it clicks" {
    const row = try driver.onNodeWithTag("e2e-row-7");
    try row.assertIsNotDisplayed();                     // below the 120px viewport
    try std.testing.expectError(error.NodeNotDisplayed, row.performClick());

    try row.performScrollTo();
    try row.assertIsDisplayed();
    try row.assertVisibleAtLeast(1.0);

    try row.performClick();                             // now it works
    // scrolling to the bottom pushed row 0 out of view
    try (try driver.onNodeWithTag("e2e-row-0")).assertIsNotDisplayed();
}
```

And the gesture contract is testable because the actions are real events:

```zig
test "e2e: a swipe over the keypad is a drag, so no key is pressed" {
    const five = try driver.onNodeWithTag("calc-k-5");
    const c = (try five.node()).visibleCenter();

    // 40px of travel is past the engine's 6px drag threshold, so the release
    // must NOT fire a click.
    try five.performTouchInput(Swipe.up(c.x, c.y, 40));
    try std.testing.expectEqualStrings("0", app.m.display());
}
```

### What actually happens on a click

`performClick()` does **not** invoke a stored callback. It injects a real pointer
press+release through `Host.onPointerEvent`, so the click travels the production
path:

```
performClick() → waitForIdle()          (settle: dispatch hit-tests the PREVIOUS frame)
              → node.visibleCenter()    (the centre of bounds ∩ clip)
              → Host.onPointerEvent(down, BTN_LEFT)
              → Host.onPointerEvent(up,   BTN_LEFT)
                 └─ dispatch.pointerEvent
                    ├─ was the press in window bounds?
                    ├─ did it move more than drag_threshold_px (6px)?
                    └─ click_registry.dispatchClick(press origin)
                       └─ highest-z containing target wins → callback
              → waitForIdle()
```

**This is stronger than Compose in one specific way.** Compose's `performClick()`
looks up the semantics `OnClick` action and invokes the lambda — it never sends a
touch, so it structurally cannot catch a bug in hit-testing, z-order or clipping.
Here the test exercises all three. (The trade-off is that it also means a test can
fail because the *layout* moved, which is usually the bug you wanted to find.)

### Immediate-mode rules to internalize

These are the things that will surprise you if you come from Compose:

1. **Nothing has geometry until after `endLayout`.** `resolve()` runs inside the
   frame, after layout. `driver.box(id)` therefore describes the *last completed*
   frame — which is also the frame a click will be hit-tested against.
2. **A node is a snapshot.** Bounds and visibility are rebuilt every frame, so
   `Interaction` re-resolves on every call. Never cache a `Node` across an action.
3. **`waitForIdle` needs two stable frames — not one.** The engine has three
   documented one-frame lags: scrollbar thumbs read previous-frame scroll data;
   hover chrome is driven by the previous frame's pointer-over ids; and
   `getScrollContainerData().found` is false until one layout has run. A pending
   wheel delta also counts as not-idle, because the next frame will consume it.
4. **A click is a release, at the press origin, against the previous frame.**
   `performClick` idles *before* clicking for that reason, and a gesture that
   travels more than 6px is a **drag** and fires nothing — which is what
   `performTouchInput` is for.
5. **Wheel scroll is routed to the hovered container.** So `performScrollTo()`
   uses the deterministic `scroll.scrollBy()` (1:1, clamped, no ×10 wheel factor)
   instead. Use `Driver.scroll()` when the *point* of the test is wheel routing.
6. **Only clipping ancestors narrow visibility.** Floating overlays legitimately
   paint outside their parent, so a non-clipping ancestor contributes nothing to
   `clip`. Otherwise `assertIsDisplayed` would fail for perfectly visible overlays.

### Making your own widgets testable

A widget registers its identity during declare; geometry is filled in later.

```zig
// core/components/button.zig, at the end of button()
semantics.register(.{
    .id = cl.getElementId(props.id),
    .tag = props.id,                    // the test tag
    .role = .button,
    .label = props.label,
    .flags = .{ .enabled = !props.disabled },
});
// NOTE: no `.actions = .{ .click = true }` here — resolve() folds that in from
// click_registry, so an externally-registered click still reports correctly.
```

A container that clips declares the clip so descendants can compute visibility:

```zig
// core/components/scroll.zig, around the children
semantics.pushAncestor(cl.getElementId(props.id), true);   // true = this clips
children(ctx);
semantics.popAncestor();
```

Whatever you register, **add a test for it**, and bump `tests.lock`.

---

## Project layout

```
src/
├── root.zig          the public API. The ONLY file consumers import.
├── platform.zig      the ONLY file that branches on builtin.os.tag.
├── native_test.zig   test root for the Linux-only native backends.
├── main.zig          demo app (dogfoods the public surface).
│
├── core/             platform-agnostic. Compiles identically everywhere.
│   ├── semantics.zig         ★ per-frame semantics model (E2E + future a11y)
│   ├── host.zig              Clay arena, input routing, frame scheduler
│   ├── frame.zig             per-frame boilerplate + command stream
│   ├── window_contract.zig   WindowConfig · Delegate · WindowState · geometry
│   ├── window_portable.zig   headless/CPU backend — ALSO the test backend
│   ├── select.zig            ← the one bridge from core to platform.zig
│   ├── render.zig            renderer facade        (consumes select.zig)
│   ├── render_common.zig     the drawing contract the drawing widgets import
│   ├── render_software.zig   CPU rasterizer (real pixels, real RGBA8)
│   ├── render_pixels_test.zig  pixel-assertion suite
│   ├── glyphs.zig            stb_truetype glyph rasterization
│   ├── text_backend.zig      text facade            (consumes select.zig)
│   ├── text_portable.zig     deterministic text estimator
│   ├── protocol_consts.zig   evdev codes + Wayland enum constants
│   ├── components/           15 widgets (box, button, input, scroll, …)
│   ├── testing/              ★ the E2E test layer
│   │   ├── root.zig              Driver + Interaction (onNode, performClick…)
│   │   ├── finders.zig           Query matchers
│   │   ├── actions.zig           gesture / scroll planning math
│   │   └── assertions.zig        node assertions
│   └── stb_{truetype,image}_impl.c   vendored library TUs
│
├── linux/            the Linux backend.  9 files, mirrored 1:1 with mac/
└── mac/              the macOS backend.  9 files, mirrored 1:1 with linux/

examples/
├── calculator.zig            the example app (+ 36 tests)
└── calculator_e2e_test.zig   ★ 15 E2E tests driving that app

ci/
├── check_test_parity.sh      the locked cross-platform test count
└── check_layering.sh         rules R1–R6

vendor/
├── clay/                     the layout engine (vendored)
├── clay-zig-bindings/        zic bindings, imported as `zclay`
└── stb/                      stb_truetype, stb_image
```

---

## Further reading

| document | what it covers |
|---|---|
| `src/README.md` | agent orientation for `src/`: layout, invariants I1–I5, traps, verification recipes, known debt |
| `REFACTOR_PLAN.md` | the `core/` + `linux/` + `mac/` split, the R1–R6 layering rules, and its execution log |
| `E2E_TESTING_PLAN.md` | the design of the E2E layer, the immediate-mode constraints it works around, and its execution log |
| `examples/calculator_e2e_test.zig` | the worked E2E example — read this first if you are writing tests |
| `examples/calculator.zig` | an app written against the public surface only |

---

## Known limitations

Honest list; each is a reasonable next task.

- **Glyph rasterization is only exercised on macOS** (15 skipped tests). See
  `src/README.md` §5.
- **List rows carry no label** — the text comes from the caller's `renderItem`
  callback, so E2E tests select rows with
  `onNodeWithIndex(.{ .role = .list_item }, i)` rather than by text.
- **`box` registers no semantics** (they are layout containers, not targets), so
  only `scroll` contributes clip ancestry today.
- **No accessibility bridge.** The semantics tree is exactly what an AT-SPI / UIA
  backend would consume, but nothing wires it up yet.
- **Windows** builds the CPU-only surface, but `examples/calculator.zig` is
  deliberately not wired for it (`calc_supported` in `build.zig`) because nothing
  has verified that path.
- **`core/frame.zig` owns the cursor-shape mapping**, which is a Wayland
  `cursor-shape-v1` concern living in the platform-agnostic layer.
