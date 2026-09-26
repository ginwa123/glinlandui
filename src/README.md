# `glinlandui/src` — agent orientation

Read this before you change anything here. It is written for an agent picking the
library up cold: what the layout means, which invariants a plausible-looking edit
will break, and the exact commands that prove you did not break them.

Human-facing background and the refactor history live in `../REFACTOR_PLAN.md`.

---

## 1. What this is

A platform-agnostic **Clay GUI library** in Zig 0.16. Clay (in `vendor/clay`) does
layout + render-command emission; this library owns the window, the event loop,
the renderer, text measurement, input dispatch, and a widget set.

Two real backends: **Wayland/EGL/GLES3/pangocairo** on Linux, **Cocoa/CoreGraphics**
on macOS. Consumers write `@import("glinlandui")` and get the same surface on both.

```
src/
├── root.zig          the public API. The ONLY file consumers import.
├── platform.zig      the ONLY file that branches on builtin.os.tag.
├── native_test.zig   test root for the Linux-only native backends.
├── main.zig          demo app (dogfoods the public surface).
│
├── core/             platform-agnostic. Compiles identically everywhere.
│   ├── semantics.zig         per-frame semantics model (E2E + future a11y)
│   ├── host.zig              Clay arena, input routing, frame scheduler
│   ├── frame.zig             per-frame boilerplate + command stream
│   ├── window_contract.zig   WindowConfig · Delegate · WindowState · geometry
│   ├── window_portable.zig   headless/CPU backend — ALSO the test backend
│   ├── select.zig            ← the one bridge from core to platform.zig
│   ├── render.zig            renderer facade      (consumes select.zig)
│   ├── color.zig            the Color type: every prop is one, not a u32
│   ├── render_common.zig     the drawing contract the DRAWING widgets import
│   │                         (click_registry + dispatch are logic-only)
│   ├── render_software.zig   CPU rasterizer (real pixels, real RGBA8)
│   ├── render_pixels_test.zig  pixel-assertion suite
│   ├── glyphs.zig            stb_truetype glyph rasterization
│   ├── text_backend.zig      text facade         (consumes select.zig)
│   ├── text_portable.zig     deterministic text estimator
│   ├── protocol_consts.zig   evdev codes + Wayland enum constants
│   ├── components/           15 widgets (box, button, input, scroll, …)
│   ├── testing/              the E2E test layer
│   │   ├── root.zig              Driver + Interaction (onNode, performClick…)
│   │   ├── finders.zig           Query matchers
│   │   ├── actions.zig           gesture / scroll planning math
│   │   └── assertions.zig        node assertions
│   └── stb_{truetype,image}_impl.c   vendored library TUs
│
├── linux/            the Linux backend.  9 files, mirrored 1:1 with mac/
└── mac/              the macOS backend.  9 files, mirrored 1:1 with linux/
```

### The platform mirror

`linux/` and `mac/` expose the **same nine file names**, so you can read and diff
them side by side. **Same role, not same code** — the line counts carry the
information:

| file | role | linux | mac |
|---|---|---|---|
| `window.zig` | bootstrap, event loop, frame loop | 1345 | 355 |
| `input.zig` | native events → the `Delegate` contract | 60 | 324 |
| `keymap.zig` | native keycode → evdev | 40 | 359 |
| `adapter.zig` | coords / scroll / resize / quit | 65 | 484 |
| `present.zig` | finished frame → screen | 42 | 221 |
| `renderer.zig` | renderer for this OS | 1378 | 27 |
| `text.zig` | text engine for this OS | 261 | 38 |
| `shim.h` | this platform's C shim header | 30 | 111 |
| `shim.c` / `shim.m` | this platform's C shim TU | 101 | 415 |

`shim.c` ↔ `shim.m` is the one name that cannot match — Objective-C requires `.m`.

**If you add or rename a file in one folder, do the same in the other**, or update
the mirrors table above. Each file's header comment states what the *other*
platform has that it does not, and why. Keep that honest: those absences are the
most useful thing in the pair (e.g. `linux/keymap.zig` is an identity function
because Wayland already speaks evdev; `mac/keymap.zig` is a 359-line table).

### Data flow

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

The widget layer never sees a platform; the platform never sees a widget — it
only calls the `Delegate`. That contract is the whole integration surface.

---

## 2. Invariants. Breaking these fails CI, not just a test

### I1 — Test parity: `zig build test` must report exactly **458**

`tests.lock` holds `458`; `ci/check_test_parity.sh` asserts it. The suite compiles
a **fixed, platform-independent set** of test roots so Linux and macOS run the
same tests, which is what makes the macOS path trustworthy without a Mac.

The count is `404` (`root.zig` aggregate) + `1` (`main.zig`) + `36` (the
calculator example) + `15` (`examples/calculator_e2e_test.zig`, the E2E suite).

- **Adding or removing a `test` block changes the count.** Update `tests.lock` in
  the same commit, deliberately. Never "fix" a parity failure by editing the lock
  without understanding which test moved.
- **Adding a file to the aggregate block in `root.zig` adds its tests.** If that
  file has no `test` blocks, the count is unchanged and the file merely gets
  type-checked — that is a deliberate, useful trick used for `mac/renderer.zig`,
  `mac/text.zig` and `linux/{keymap,input,adapter}.zig`.
- **Test collection crosses FILE imports but not MODULE imports.** A test root
  runs the tests of every file it reaches by relative `@import`, but it does not
  descend into `addImport`ed modules — which is why `exe_tests` has never
  re-counted the library. This matters concretely:
  `examples/calculator_e2e_test.zig` reaches the calculator through an imported
  module (`@import("calculator")`, wired in `build.zig`), **not** a relative
  `@import("calculator.zig")`. The relative form compiles and passes but makes the
  count 494 instead of 458, by re-running the example's 36 tests in the E2E
  binary.

`zig build native-test` is a SEPARATE count (`99`) and is not locked: it is one
consolidated root (`src/native_test.zig`) that reaches the Linux backends, and
it also pulls in whatever `core/` those backends import. That is why adding
`core/color.zig` moved native from `83` to `99` as well as the parity count —
its 16 tests are collected by both roots. A new `core/` file with tests is
counted twice; that is expected, not double-counting to fix.

### I2 — The test build must select the portable backend on every OS

`platform.zig` takes the `core/window_portable.zig` + `core/render_software.zig` +
`core/text_portable.zig` branch whenever `builtin.is_test`. **Do not tighten this
to an OS check.** If a test build started analysing `linux/renderer.zig` on Linux
but not on macOS, the parity count would diverge and CI would fail on both legs.

### I3 — Layering rules R1–R6, enforced by `ci/check_layering.sh`

| | rule |
|---|---|
| R1 | nothing under `core/` may import `linux/` or `mac/` |
| R2 | only `core/select.zig` may import `../platform.zig` |
| R3 | `core/` may not read `os.tag` or include a platform C header |
| R4 | `linux/` and `mac/` may not import each other |
| R5 | only `platform.zig` may read `os.tag` (the OS is chosen in one place) |
| R6 | every module in the parity suite must be pure Zig (no `@cImport(` call) |

Run `./ci/check_layering.sh` before you push. It is grep-based and takes
milliseconds. **Add a rule when you find a new way to cross a boundary** — the
script is the documentation of the architecture, and it is cheap to extend.

Two things to know about the script itself, because they are deliberate:

- **It only scans source files** (`*.zig`, `*.c`, `*.h`, `*.m`). Markdown is
  excluded, because this README, `REFACTOR_PLAN.md` and the module headers all
  legitimately *discuss* these rules. Same reasoning for R6, which matches the
  `@cImport(` call rather than the bare token.
- **R3/R5 match `os.tag`, not `builtin.os.tag`.** The literal form is trivially
  evaded by `const b = @import("builtin"); … b.os.tag`, and nothing outside
  `platform.zig` legitimately reads `os.tag` anyway. `builtin.is_test` is *not* an
  OS branch and stays allowed — `core/window_portable.zig` and `core/frame.zig`
  use it to no-op real presentation under test.

If you change a rule, **plant a violation and watch it fail** before trusting it.
A gate that has never been seen to fail is not a gate.

### I4 — One C TU per platform folder

`linux/` owns exactly `shim.c` (+ `shim.h`); `mac/` owns exactly `shim.m`
(+ `shim.h`). Vendored-library TUs (`stb_*_impl.c`) live in `core/`.

Consequence you must respect: **both folders have a file called `shim.h` with
different contents**, so the include paths are mutually exclusive —
`addIncludePath("src/mac")` is gated inside `if (is_macos)`. If you ever make a
platform include path unconditional, `@cInclude("shim.h")` may silently resolve
to the *other* platform's header.

### I5 — `zclay` is a module, never a relative path

Import it as `@import("zclay")` everywhere. A second `@import("../../vendor/…")`
would create a second module instance, and Clay types crossing the boundary
(`Color`, `RenderCommandArray`) would stop being the same type. This failure looks
like a confusing type mismatch, not a missing import.

---

## 3. Verify your change

```bash
# The full local gate. All four must pass.
zig fmt --check build.zig src examples    # formatting is gate 1 in CI
zig build test --summary all              # expect: 443/458 (15 skipped)  ← see I1 + §5
./ci/check_test_parity.sh                 # expect: parity: 458 tests (matches tests.lock)
./ci/check_layering.sh                    # expect: layering: ok

# Linux native backends (Wayland/EGL/GLES3/pango). NOT part of the parity count.
zig build native-test --summary all       # expect: 99/99

# Real build + a headless smoke test that proves pixels were painted.
zig build -Doptimize=ReleaseSafe
env QS_SETTINGS_TEST_FRAMES=1 WAYLAND_DISPLAY= ./zig-out/bin/glinlandui-calculator
#   → "…rendered 360x440 headless (158400 painted pixels, no display available)"
```

`zig build run` / `zig build run-calculator` open a real window and need a
Wayland display. Without one, the calculator falls back to headless rendering and
still reports a painted-pixel count — use that for smoke tests.

**On a machine with no macOS SDK you cannot compile `mac/window.zig` or
`mac/shim.m`.** Their imports are mechanically checkable (see §6) but CI's `macos`
leg is the only real gate. Say so in your summary rather than implying you tested
them.

---

## 4. Traps that cost real time

1. **`@import` cannot escape the module's root *directory*.** A module whose root
   is `src/linux/x.zig` can import only within `src/linux/`. This is why
   `native_test.zig` sits at `src/` (it must reach both `core/` and `linux/`) and
   why `zig build native-test` is one consolidated root rather than three. If you
   add a standalone test step, root it at `src/` or you will hit
   `error: import of file outside module path`.

2. **A test root runs the tests of every file it reaches.** Adding an `@import`
   to a test root can increase the count without you writing a test — this is how
   Phase 1 of the refactor silently moved `native-test` from 65 to 87. Check
   `--summary all` after touching imports in a test root.

3. **`@cImport` instances are per-file.** `linux/present.zig` takes
   `?*anyopaque` rather than `c.EGLDisplay` precisely so two different EGL
   `@cImport`s do not have to agree on a type identity. Do the same when passing
   opaque C pointers across files.

4. **An empty struct field named like a module collides.** `mac/window.zig` has a
   method `presentFrame` (not `present`) because the module alias `present` is in
   scope. If you hit `error: ambiguous reference`, that is why.

5. **`zig fmt --check` is CI gate 1.** Run `zig fmt build.zig src examples`
   before committing; it is the cheapest failure to avoid.

6. **The parity script reads the test *set* size, not the pass count** — a
   `(15 skipped)` suffix is normal and must not fail the gate. If you see
   `could not parse test count`, the summary format changed again; fix the regex
   in `ci/check_test_parity.sh`, do not weaken the check.

---

## 5. Why 15 tests skip locally (and why that is not a bug to fix)

`core/glyphs.zig`'s font-dependent tests do
`requireFont() orelse return error.SkipZigTest`, and `Font.loadDefault()` walks
`fontCandidates()`.

In a **test** build, `text_impl` is `core/text_portable.zig` (invariant I2), and
its `font_candidates` are **macOS paths** (`/System/Library/Fonts/…`). So:

- on **macOS**, those paths exist → the 15 tests run → `458/458 passed`;
- on **Linux/macOS-local without those paths** → 15 skip → `443/458 (15 skipped)`.

The count is still 458 either way, so parity holds and the gate passes. The real
consequence is a **coverage gap: the glyph rasterizer is only exercised on
macOS.** `linux/text.zig` *does* carry Linux font paths, but the parity suite never
selects it. A useful, contained improvement would be to give
`core/text_portable.zig` a per-OS candidate list so those 13 tests execute on both
platforms. It is not done yet — do not mistake it for a passing test.

---

## 6. Recipes

**Add a widget** — a file in `core/components/`. A *drawing* widget imports `std`,
`zclay`, `../render_common.zig` and `../color.zig`; a logic-only one (`click_registry`,
`dispatch`) needs only `std` + `zclay`. Then add it to the `components` struct in
`root.zig` *and* to the aggregate test block there. If it has tests, `tests.lock`
changes.

**Add something to the public API** — add the export to `root.zig`. Keep the
existing names stable: `main.zig` and `examples/calculator.zig` compile against
this surface, and `build.zig`'s comments say a pre-split consumer
(`qs-settings-zig`) does too. `wayland_lib` is a deprecated alias kept for that
reason — do not remove it without checking that consumer.

**Add a platform-specific module** — create it in *both* folders with the same
name, keep the pure parts pure, and state in the header comment what the other
platform does instead. Then add the pure ones to the aggregate test block in
`root.zig` so they are type-checked on both OSes (I1: no `test` blocks → count
unchanged) and add them to R6's list in `ci/check_layering.sh`.

**Add a step or a CI job** — the `layering` job is deliberately first and
cheapest. Keep new jobs' expectations explicit; do not make a job depend on a
count that is not in `tests.lock`.

**Mechanically check every path** (catches typos in files you cannot compile):

```bash
# every relative @import resolves
python3 - <<'PY'
import re,pathlib
for f in pathlib.Path("src").rglob("*.zig"):
    t=f.read_text(errors="replace")
    for m in re.finditer(r'@import\("([^"]+)"\)',t):
        p=m.group(1)
        if p.endswith(".zig") or "/" in p:
            assert (f.parent/p).resolve().exists(), f"{f}: {p}"
print("ok")
PY
```

---

## 7. Known debt

Deliberate, and each is a good first task:

1. **Coverage gap in §5** — the glyph rasterizer only really runs on macOS.
2. **`core/frame.zig` owns the cursor-shape mapping** (`shape_default`,
   `currentShape`, `shouldApplyShape`) — those are Wayland `cursor-shape-v1`
   values living in the platform-agnostic layer, and they are the only reason
   `linux/window.zig` imports `core/frame.zig`. Moving them to `linux/` would
   tighten the split.
3. **Legacy layer-shell helpers** (`LayerSize`, `centeredAnchor`, `layerSize`)
   are re-exported by both backends and used by nothing but tests.
4. **`protocol_consts.zig` mixes two vocabularies** — Linux evdev codes and
   Wayland enum constants — in one file.

---

## 8. Reading order

1. `root.zig` — the public surface. Its exports ARE the whole API.
2. `platform.zig` — how a platform is chosen, and the `is_test` rule.
3. `core/window_contract.zig` — `Delegate`, `WindowConfig`, `WindowState`, geometry.
4. `core/host.zig` → `core/frame.zig` — how a frame is driven.
5. `linux/window.zig` **next to** `mac/window.zig` — the real difference between
   the platforms, in two files you can read side by side.
6. `core/testing/root.zig` — how to drive the whole stack headlessly in a test.
7. `core/semantics.zig` — the per-frame node model, and the `register` →
   `endLayout` → `resolve` ordering that immediate mode forces on it.
8. `examples/calculator_e2e_test.zig` — the worked E2E example. The design
   rationale for this layer lives in `../E2E_TESTING_PLAN.md`.
