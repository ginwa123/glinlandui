# `core/components/` — the reusable widget layer

Every file here is a **widget an application declares**, not a thing the toolkit runs. They are
the vocabulary a consumer writes its UI in: `box`, `text`, `button`, `input`, `list`, `tree`,
`tabs`, `badge`, and the rest.

The folder exists so that a consumer never has to re-implement a tree view, a tab bar or a
scroll container. If a widget is generic — useful to any app, not just the one that needed it
first — it belongs here, not in the application.

## The rule that keeps them reusable

A component imports **only**:

- `std`
- `zclay` (the Clay bindings)
- `../color.zig`, `../semantics.zig`, `../render_common.zig`
- its sibling components (`click_registry.zig`, `box.zig`, …)

It must **never** import an application, a theme, a platform folder (`linux/`, `mac/`,
`windows/`), or `../platform.zig`. `ci/check_layering.sh` enforces the platform half of that
(R1, R3); the rest is a review rule, and the reason is the same: a component that knows about
one app's theme cannot be used by the next app.

That is also why every component takes its colours as props with neutral defaults. There is no
theme import and no global palette — the caller passes `bg`, `fg`, `hover_bg` and so on.

## The catalogue

| file | what it declares |
|---|---|
| `box.zig` | the container: direction, sizing, padding, gap, radius, border, background. Also `row`, `column` and `spacer` helpers |
| `text.zig` | a single text run: size, colour, wrap |
| `button.zig` | a clickable label with hover, disabled and border states |
| `input.zig` | a text field (`fieldEdit`) that draws a caret and a selection from an `EditState` |
| `list.zig` | rows, cells or a grid, with selection, hover and per-row click targets |
| `tree.zig` | hierarchical rows: depth indent, caret, expansion state, selection, right-aligned meta |
| `tabs.zig` | a tab bar: active state, optional accent dot, optional close button |
| `badge.zig` | a short label in a rounded pill — a type, a count, a state |
| `scroll.zig` | a scroll container with a scrollbar, plus `scrollBy` |
| `dropdown.zig` | an overlay menu that floats above in-flow content |
| `checkbox.zig`, `radio.zig`, `toggle.zig`, `slider.zig` | the form controls |
| `icon.zig`, `image.zig` | a glyph and a bitmap |
| `click_registry.zig` | the per-frame hit-target table (not visual) |
| `dispatch.zig` | routes a pointer event to the registered target (not visual) |

## The shape of a component

Every one follows the same four beats, and a new one should too:

1. **A props struct** with neutral defaults, so `.{ .id = "x" }` is a valid declaration.
2. **Declare-only.** A component draws; it does not own state. Expansion, selection and scroll
   position live in the caller's model, which is what makes the widget reusable and testable.
3. **Clicks through the registry.** A component that is clickable registers its own target with
   `click_registry.registerZCursor` and takes a `ctx: ?*anyopaque` plus a plain `fn` pointer —
   there are no closures, so the callback is a top-level function.
4. **Semantics.** Register the element with `semantics.register` so the E2E layer can find it by
   role and assert on it.

## The click budget

`click_registry.cap` is **256 entries per frame**, and entries past it are silently dropped. A
component that registers one target per row therefore stops responding at row 256. That is why
`tree` registers exactly one target per row (not one for the caret and one for the label), and
why a caller with an unbounded list must cap the rows it declares.

## Adding a component

1. Put it in this folder, named after the widget.
2. Import only what the rule above allows.
3. Give it a props struct with defaults, a `ctx` and a `fn`-pointer callback if it is clickable.
4. Add a headless test: declare it inside a Clay frame and assert the render-command counts
   (`box.zig` and `list.zig` have the harness to copy).
5. Export it from `src/root.zig` under `components`, and add it to the parity test block there —
   that block is the contract that every component type-checks on every platform.
6. Run `zig build test`, `zig build zginlint:check` and `zig build lines:check`.

If the widget needs to know which OS it is on, it does not belong here — it belongs in
`linux/`, `mac/` or `windows/`, behind the contract in `core/`.
