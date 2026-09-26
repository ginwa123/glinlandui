//! glinlandui example: end-to-end UI tests for the calculator.
//!
//! This is the worked example for the toolkit's Compose-style E2E surface
//! (`glinlandui.testing`). It drives the REAL `examples/calculator.zig` app —
//! the same `App`, the same `App.root` declare callback, the same Host — with
//! no compositor, no GL context and no font engine.
//!
//! The API, by analogy with Compose:
//!
//!     Compose                                  glinlandui
//!     ---------------------------------------  ------------------------------------------
//!     onNodeWithTag("calc-k-7")                driver.onNodeWithTag("calc-k-7")
//!     onNodeWithText("7")                      driver.onNodeWithText("7")
//!     onNode(hasClickAction())                 driver.onNode(.{ .has_click_action = true })
//!     performClick()                           interaction.performClick()
//!     performScrollToNode(...)                 interaction.performScrollTo()
//!     performTouchInput { swipeUp() }          interaction.performTouchInput(Swipe.up(..))
//!     assertIsDisplayed()                      interaction.assertIsDisplayed()
//!     assertIsEnabled()                        interaction.assertIsEnabled()
//!     assertTextEquals("7")                    interaction.assertTextEquals("7")
//!     waitForIdle()                            driver.waitForIdle()
//!
//! Where it DIFFERS from Compose, and where it is stronger:
//!
//!   * `performClick` does NOT invoke the semantics OnClick lambda. It injects a
//!     real pointer press+release through `Host.onPointerEvent`, so the click
//!     travels the production path — the 6px drag threshold, release-at-press
//!     -origin, `click_registry` z-order dispatch and a `getElementData` hit
//!     test. A test written this way catches hit-testing, z-order and clipping
//!     bugs that Compose's callback-invoking `performClick` cannot.
//!   * Because the engine is IMMEDIATE MODE, "idle" is a fixed point over
//!     frames rather than a recomposition queue; `waitForIdle` is documented in
//!     `core/testing/root.zig`.
//!
//! There is deliberately no `window.run()` anywhere below: the tests are the
//! point, and every one of them is headless.
const std = @import("std");
const glinlandui = @import("glinlandui");
// NOTE: this is a MODULE import (see build.zig), not a relative file import.
// Importing "calculator.zig" by path would pull the example's 36 tests into
// THIS test binary as well as its own, running them twice and inflating the
// locked parity count. A module boundary is what Zig's test collector does not
// cross.
const calc = @import("calculator");

const Driver = glinlandui.testing.Driver;
const Swipe = glinlandui.testing.Swipe;
const Key = calc.Key;

/// The calculator is designed for a 360x430 window, so the tests pin the real
/// size instead of the driver's 720x480 default: the layout is `grow`-based and
/// would stretch, which makes geometry assertions meaningless.
const viewport = Driver.Viewport{ .width = 360, .height = 440 };

/// Build a driver around a fresh calculator, wired exactly as `main()` wires it
/// — including the Host KeyChain, so the keyboard tests exercise the same route
/// a real window would.
fn calcDriver(app: *calc.App) !Driver {
    // page_allocator, not testing.allocator: the Clay arena is intentionally
    // left alive for the process (Clay keeps a global pointer into it), so a
    // leak-checking allocator would flag it. Same convention as the toolkit's
    // own testing module.
    var driver = try Driver.initOwned(std.heap.page_allocator, app, calc.App.root);
    try driver.start(viewport);
    driver.host.keys.register(calc.App.onKey, app);
    try driver.waitForIdle();
    return driver;
}

// ---- Discovery: the semantics tree ----------------------------------------

test "e2e: every keypad key is discoverable by tag, label and role" {
    var app = calc.App{};
    var driver = try calcDriver(&app);
    defer driver.deinit();

    // Exactly the 20 keys are buttons; boxes and labels declare no semantics.
    try std.testing.expectEqual(@as(usize, Key.count), driver.onAllNodes(.{ .role = .button }));

    for (calc.KEY_IDS, calc.KEY_LABELS) |id, label| {
        const key = try driver.onNodeWithTag(id);
        try key.assertExists();
        try key.assertIsDisplayed();
        try key.assertRole(.button);
        try key.assertTextEquals(label);
        try key.assertIsEnabled();
        // Clickability is folded in from click_registry, which is what makes
        // this work for the calculator's externally-registered keys.
        try key.assertHasClickAction();
    }
}

test "e2e: the display is not a click target, and labels are keys, not text" {
    var app = calc.App{};
    var driver = try calcDriver(&app);
    defer driver.deinit();

    // The keypad is the only clickable surface: the app declares no other
    // semantics node, so there is nothing else to find.
    try std.testing.expectEqual(@as(usize, 20), driver.onAllNodes(.{ .has_click_action = true }));
    // And a label lookup resolves to the KEY with that caption.
    const seven = try driver.onNodeWithText("7");
    try seven.assertRole(.button);
    try std.testing.expectEqualStrings("calc-k-7", seven.tag);
}

test "e2e: ambiguous and absent queries are reported distinctly" {
    var app = calc.App{};
    var driver = try calcDriver(&app);
    defer driver.deinit();

    // Absence: distinct error, so a test can tell a missing widget from a
    // wrong-index bug.
    try std.testing.expectError(error.NoNodeFound, driver.onNodeWithTag("calc-k-nope"));
    // Ambiguity: 20 buttons match a bare role query, and Compose's onNode
    // contract is "exactly one" — silently taking the first match would hide
    // the bug the test just expressed.
    try std.testing.expectError(error.TooManyNodes, driver.onNode(.{ .role = .button }));
    // An index resolves the ambiguity deliberately.
    const second = try driver.onNodeWithIndex(.{ .role = .button }, 1);
    try second.assertTextEquals("DEL");
}

// ---- Interaction: performClick ---------------------------------------------

test "e2e: a keypad click computes 42 the way a user would" {
    var app = calc.App{};
    var driver = try calcDriver(&app);
    defer driver.deinit();

    // 12 + 30 = 42, entirely through the UI.
    const digits = [_][]const u8{ "1", "2", "+", "3", "0", "=" };
    for (digits) |caption| {
        const key = try driver.onNodeWithText(caption);
        try key.performClick();
    }

    try std.testing.expectEqualStrings("42", app.m.display());
    // The app's own tests pin this arithmetic; here the point is that the
    // CLICK path produced it, not that the machine can add.
    try driver.expectText("42");
}

test "e2e: clicking is order-sensitive, so the pending operation shows up" {
    var app = calc.App{};
    var driver = try calcDriver(&app);
    defer driver.deinit();

    // No operation pending: the view declares no expression line at all.
    try driver.expectNoText("12 +");

    const one = try driver.onNodeWithText("1");
    try one.performClick();
    try one.assertIsDisplayed();
    const two = try driver.onNodeWithText("2");
    try two.performClick();
    const plus = try driver.onNodeWithTag("calc-k-plus");
    try plus.performClick();

    // The semantics layer and the render layer agree on the same state.
    try std.testing.expectEqualStrings("12 +", app.m.expression());
    try driver.expectText("12 +");
}

test "e2e: the C key clears, and delete edits, through real clicks" {
    var app = calc.App{};
    var driver = try calcDriver(&app);
    defer driver.deinit();

    const nine = try driver.onNodeWithText("9");
    try nine.performClick();
    try nine.performClick();
    try std.testing.expectEqualStrings("99", app.m.display());

    const del = try driver.onNodeWithText("DEL");
    try del.performClick();
    try std.testing.expectEqualStrings("9", app.m.display());

    const clear = try driver.onNodeWithText("C");
    try clear.performClick();
    try std.testing.expectEqualStrings("0", app.m.display());
    try driver.expectText("0");
}

test "e2e: divide by zero latches ERR and the next key recovers" {
    var app = calc.App{};
    var driver = try calcDriver(&app);
    defer driver.deinit();

    for ([_][]const u8{ "5", "/", "0", "=" }) |caption| {
        const key = try driver.onNodeWithText(caption);
        try key.performClick();
    }
    try std.testing.expect(app.m.err);
    try std.testing.expectEqualStrings("ERR", app.m.display());
    try driver.expectText("ERR");

    // The machine recovers on the next key, so the view must too.
    const seven = try driver.onNodeWithText("7");
    try seven.performClick();
    try std.testing.expectEqualStrings("7", app.m.display());
    try driver.expectNoText("ERR");
}

// ---- Interaction: the keyboard route ---------------------------------------

test "e2e: keyboard input and keypad clicks drive the same machine" {
    var app = calc.App{};
    var driver = try calcDriver(&app);
    defer driver.deinit();

    // Keypad: press 6.
    const six = try driver.onNodeWithText("6");
    try six.performClick();

    // Keyboard: evdev 8 is the "7" row key. It routes through the Host's
    // KeyChain, which is how the real window delivers keys.
    try std.testing.expect(try driver.key(8));

    try std.testing.expectEqualStrings("67", app.m.display());
    // The keyboard path reaches the view as well as the state.
    try driver.expectText("67");
}

test "e2e: Escape is left unconsumed so the window can still close" {
    var app = calc.App{};
    var driver = try calcDriver(&app);
    defer driver.deinit();

    const escape_evdev: u32 = 1;
    // keyToClose owns Escape; the calculator must not swallow it.
    try std.testing.expect(glinlandui.keyToClose(escape_evdev));
    try std.testing.expect(!try driver.key(escape_evdev));
    try std.testing.expectEqualStrings("0", app.m.display());
}

// ---- Interaction: gestures -------------------------------------------------

test "e2e: a swipe over the keypad is a drag, so no key is pressed" {
    var app = calc.App{};
    var driver = try calcDriver(&app);
    defer driver.deinit();

    const five = try driver.onNodeWithTag("calc-k-5");
    const node = try five.node();
    const c = node.visibleCenter();
    // 40px of travel is well past dispatch.drag_threshold_px (6), so the
    // release must NOT fire a click. The calculator has no scroll container,
    // so the drag itself is inert — the assertion is that the key stayed up.
    try five.performTouchInput(Swipe.up(c.x, c.y, 40));
    try std.testing.expectEqualStrings("0", app.m.display());

    // And the gesture did not leave the pointer latched: a plain click on the
    // same key still works afterwards.
    try five.performClick();
    try std.testing.expectEqualStrings("5", app.m.display());
}

test "e2e: performTextInput refuses a node that is not editable" {
    var app = calc.App{};
    var driver = try calcDriver(&app);
    defer driver.deinit();

    // No keypad key declares `set_text`, so typing into one is a test bug and
    // is reported as such instead of silently injecting keystrokes into a
    // widget that cannot receive them.
    const seven = try driver.onNodeWithTag("calc-k-7");
    try std.testing.expectError(error.NoSetTextAction, seven.performTextInput("hello"));
    try std.testing.expectEqualStrings("0", app.m.display());
}

// ---- Geometry: the semantics tree carries real layout ----------------------

test "e2e: the resolved geometry matches the declared 4x5 grid" {
    var app = calc.App{};
    var driver = try calcDriver(&app);
    defer driver.deinit();

    const seven = try (try driver.onNodeWithTag("calc-k-7")).node();
    const eight = try (try driver.onNodeWithTag("calc-k-8")).node();
    const four = try (try driver.onNodeWithTag("calc-k-4")).node();

    // Same row: 8 is strictly to the right of 7, and level with it.
    try std.testing.expect(eight.bounds.x > seven.bounds.x + seven.bounds.width);
    try std.testing.expectApproxEqAbs(seven.bounds.y, eight.bounds.y, 0.5);
    // Next row down: 4 sits below 7 and starts at the same left edge.
    try std.testing.expect(four.bounds.y > seven.bounds.y + seven.bounds.height);
    try std.testing.expectApproxEqAbs(seven.bounds.x, four.bounds.x, 0.5);

    // Every key is fully on screen in this viewport, so all are clickable.
    for (calc.KEY_IDS) |id| {
        const key = try driver.onNodeWithTag(id);
        try key.assertIsDisplayed();
        try key.assertVisibleAtLeast(1.0);
    }
}

test "e2e: a key's click point lands inside its own box" {
    var app = calc.App{};
    var driver = try calcDriver(&app);
    defer driver.deinit();

    // performClick clicks `visibleCenter()`; for an unclipped node that must be
    // the geometric centre, and it must sit inside the resolved bounds. This is
    // the invariant that makes a tag-based click equivalent to a coordinate
    // click at the widget's middle.
    for (calc.KEY_IDS) |id| {
        const node = try (try driver.onNodeWithTag(id)).node();
        const c = node.visibleCenter();
        try std.testing.expect(c.x >= node.bounds.x and c.x <= node.bounds.x + node.bounds.width);
        try std.testing.expect(c.y >= node.bounds.y and c.y <= node.bounds.y + node.bounds.height);
    }
}

// ---- Idling ----------------------------------------------------------------

test "e2e: waitForIdle is idempotent and the tree is stable once settled" {
    var app = calc.App{};
    var driver = try calcDriver(&app);
    defer driver.deinit();

    // Already idled by calcDriver; idling again must find the fixed point
    // immediately rather than failing after the frame budget.
    try driver.waitForIdle();
    const before = glinlandui.semantics.fingerprint();
    try driver.waitForIdle();
    try std.testing.expectEqual(before, glinlandui.semantics.fingerprint());

    // A state change is observable in the very next resolved frame.
    const five = try driver.onNodeWithText("5");
    try five.performClick();
    try driver.waitForIdle();
    try std.testing.expect(glinlandui.semantics.fingerprint() == before);
    // (The tree's GEOMETRY is unchanged by a digit: only the render commands
    // differ, which is why the fingerprint is stable here and the text
    // assertion below is what proves the value changed.)
    try driver.expectText("5");
}

test "e2e: the semantics tree survives a window resize" {
    var app = calc.App{};
    var driver = try calcDriver(&app);
    defer driver.deinit();

    const before = try (try driver.onNodeWithTag("calc-k-7")).node();
    try driver.resize(420, 480);
    try driver.waitForIdle();

    // The grid re-lays out, and the semantics layer follows the new geometry
    // without any re-registration on the app's side.
    const after = try (try driver.onNodeWithTag("calc-k-7")).node();
    try std.testing.expect(after.found);
    try std.testing.expect(after.bounds.width > 0);
    try std.testing.expectApproxEqAbs(before.bounds.width, after.bounds.width, 1.0);
    // Still fully clickable after the resize.
    try (try driver.onNodeWithTag("calc-k-7")).performClick();
    try std.testing.expectEqualStrings("7", app.m.display());
}
