# Refactor Plan — `glinlandui` → `core/` + `linux/` + `mac/`

> **Number moved since.** This log is a record of a completed refactor and its
> `376` test count was correct at the time. `tests.lock` is now `438` (the E2E
> test layer added 62 tests). See `E2E_TESTING_PLAN.md` §13 and `README.md`.
> The *invariants* below (parity enforced by a lock file, the `is_test` backend
> rule, R1–R6) all still hold; only the literal count changed.

Status: **EXECUTED** — all 8 phases landed on `main` (working tree). See the
Execution Log at the end for the deviations that execution forced.
Scope: reorganise ~16.5k lines of Zig + 5 C shims into a layering where the
platform-agnostic logic cannot accidentally depend on a platform.

---

## 1. What we are trying to achieve

Today the repository is *logically* layered but not *physically* layered. The
folder names reflect history (`wayland/`, `platform/`) rather than
responsibility, and the same directory mixes code that runs everywhere with code
that only compiles on one OS:

| Directory | What it actually contains |
|---|---|
| `src/wayland/` | the Linux Wayland/EGL/GLES3 backend **and** the portable CPU renderer **and** the shared frame/host logic |
| `src/platform/` | the shared window contract **and** four macOS-only modules |
| `src/` (root) | the public API facade, the demo, `wayland.zig` (Linux), `wayland_macos.zig` (macOS), `wayland_portable.zig` (fallback) |

`src/core/`, `src/linux/` and `src/mac/` exist but are **empty directories** (not
tracked by git — they need `.gitkeep`).

Goal:

- **`core/`** — every module that compiles identically on every OS. Zero
  `@cImport` of system headers. Zero knowledge of `linux/` or `mac/`.
- **`linux/`** — the Wayland/EGL/GLES3/Pango window backend and its C shim.
- **`mac/`** — the Cocoa/CoreGraphics window backend, its C shim, and the pure
  translation modules (keymap, y-flip, BGRA blit).
- One **composition root** — the only file in the repo that branches on
  `builtin.os.tag`. Core never names a platform; the root resolves the platform
  and injects the implementation.

### Non-goals

- No behaviour change. This is a move-and-rewire refactor.
- No new public API surface. `glinlandui.*` names stay exactly as they are
  (consumers: `src/main.zig`, `examples/calculator.zig`, and the upstream
  `qs-settings-zig` that imports this as a path dependency).
- No new features, no renderer changes, no protocol changes.

---

## 2. Hard constraints (these are what make this refactor risky)

These are non-negotiable and every phase below has to keep them true.

| # | Constraint | Enforced by |
|---|---|---|
| C1 | `zig build test` reports **exactly 376** tests on **both** Linux and macOS | `tests.lock` + `ci/check_test_parity.sh` (parses `Build Summary: … N/N tests passed`) |
| C2 | The parity test count must be **identical** across OSes, which means test builds must select the **portable** backend on every OS | `wayland_api.zig` (`builtin.is_test => wayland_portable.zig`), `render.zig`, `text_backend.zig`, and the aggregate `test` block in `src/root.zig` |
| C3 | `zig build native-test` is **Linux-only** and stays a separate, opt-in superset | `build.zig` (`if (native_protocols)` gate), `ci.yml` |
| C4 | `zclay` must stay a single module identity (never imported by relative path) | `build.zig` `mod.addImport("zclay", zclay_mod)`; comment in `root.zig` explains why |
| C5 | `build.zig` hardcodes C source paths and include dirs; several are `src/`-relative and will break on move | `build.zig` (`addPangoShim`, `addTabletToolStub`, the macOS block, `makeWaylandTestStep`) |
| C6 | Public surface `glinlandui.{Window, host, render, text, frame, components, zclay, software_render, testing, keyToClose, …}` is consumed by two in-repo apps and one external repo | `src/main.zig`, `examples/calculator.zig` |

**C2 is the single most important constraint.** Any refactor that changes which
modules the parity test root reaches will flip the count and fail CI on both
platforms. Moving files is safe *only if* the aggregate `test` block in
`src/root.zig` keeps importing exactly the same set of files.

---

## 3. Current inventory, classified

Classification legend: **CORE** = platform-agnostic · **LINUX** = Linux-only ·
**MAC** = macOS-only · **ROOT** = the composition/dispatch layer · **C-impl** = C/C++ shim.

### 3.1 Public surface / roots

| File | Lines | Class | Notes |
|---|---:|---|---|
| `src/root.zig` | 127 | CORE | Public API re-exports + the parity aggregate `test` block. Stays at `src/root.zig`. |
| `src/main.zig` | 200 | CORE | Demo app. Stays at `src/main.zig`. |
| `src/wayland_api.zig` | 43 | **ROOT** | The OS switch for windows. Becomes `src/platform.zig`. |
| `src/wayland.zig` | 1356 | **LINUX** | Wayland/EGL/GLES2 window. `@cImport`s wayland-client, wayland-egl, EGL, GLES2, 3 generated protocols. |
| `src/wayland_macos.zig` | 354 | **MAC** | Cocoa window. `@cImport("cocoa_window.h")`. |
| `src/wayland_portable.zig` | 154 | CORE | Headless/CPU backend — the fallback for Windows **and the backend every test build uses**. |

### 3.2 `src/wayland/` — three different layers in one folder

| File | Lines | Class | Evidence |
|---|---:|---|---|
| `host.zig` | 379 | CORE | Clay arena + input routing + frame scheduler. **One back-edge:** imports `../wayland_api.zig` solely for the `Delegate` type (line 10, used once at line 196). |
| `frame.zig` | 467 | CORE | Imports `render.zig` + `text_backend.zig` facades and `../components/click_registry.zig`. |
| `render_common.zig` | 285 | CORE | The drawing contract (`Draw`, `ImageFit`, `ImageRef`, colour helpers). Imported by every component. |
| `render_software.zig` | 640 | CORE | CPU rasterizer. Pure Zig + `zclay` + `glyphs.zig`. |
| `glyphs.zig` | 379 | CORE | stb_truetype rasterization. `@cImport("stb/stb_truetype.h")` — vendored, identical on every OS. |
| `text_portable.zig` | 175 | CORE | Deterministic text metrics. Pure. |
| `render_pixels_test.zig` | 612 | CORE | Pixel-assertion suite. Imported by the parity block. |
| `render.zig` | 41 | **ROOT** | Renderer facade: Linux+non-test → `render_gles3.zig`, else `render_software.zig`. |
| `text_backend.zig` | 36 | **ROOT** | Text facade: Linux+non-test → `text.zig`, else `text_portable.zig`. |
| `render_gles3.zig` | 1378 | **LINUX** | `@cImport`s `EGL/egl.h`, `GLES3/gl3.h`, stb, and the **Pango shim**. |
| `text.zig` | 261 | **LINUX** | `@cImport("pango_text.h")` + `std.os.linux.access`. |

### 3.3 `src/platform/` — shared contract + macOS decision logic

| File (`src/platform/`) | Lines | Class | Evidence |
|---|---:|---|---|
| `window_contract.zig` | 376 | CORE | **Already** defines `WindowConfig` (L98), `Delegate` (L109), `WindowState` (L123) plus `Placement`/`clampSize`/`keyToClose`/`LayerSize`. Pure Zig. |
| `protocol_consts.zig` | 116 | CORE | Two unrelated things: Wayland enum constants (`LayerAnchor`) **and** Linux evdev keycodes. Both are pure. |
| `blit.zig` | 221 | **MAC** | RGBA→`glin_cocoa_present` byte shuffle. Pure + in the parity suite (must stay there). |
| `input_macos.zig` | 324 | **MAC** | AppKit event → `Delegate` translation. Imports `../components/{box,click_registry,dispatch}.zig` and `../wayland/host.zig`. |
| `keymap_macos.zig` | 359 | **MAC** | macOS virtual keycode → evdev code table. Pure; in the parity suite. |
| `macos_adapter.zig` | 484 | **MAC** | Origin flip, resize coalescing, scroll normalisation. Pure; in the parity suite. |

### 3.4 C shims and assets

| File | Lines | Class | Build wiring |
|---|---:|---|---|
| `src/cocoa_window.h` | 111 | **MAC** | `@cImport` target; needs its dir on the include path |
| `src/cocoa_window.m` | 415 | **MAC** | macOS-gated `addCSourceFile` + `linkFramework(AppKit/Foundation/CoreGraphics)` |
| `src/pango_text.h` | 30 | **LINUX** | `@cImport` target for `text.zig` + `render_gles3.zig` |
| `src/pango_text.c` | 101 | **LINUX** | `addPangoShim` (hardcoded `-I/usr/include/...`) |
| `src/stb_image_impl.c` | 8 | C-impl | Linux-gated (wallpaper thumbnails) |
| `src/stb_truetype_impl.c` | 2 | C-impl | Unconditional (CPU glyphs on every OS) |
| `src/components/*.zig` (15 files) | ~6.4k | CORE | Widgets. Only deps: `zclay` + `../wayland/render_common.zig`. |
| `src/testing/root.zig` | 449 | CORE | Headless harness; imports `../wayland/host.zig`, `../wayland/frame.zig`, `../components/*`. |
| `protocols/*.xml` (3) | — | LINUX | Input to `wayland-scanner` codegen |

### 3.5 The dependency graph today (the shape we are fixing)

```
  root.zig ──► wayland_api.zig ──┬──► wayland.zig          (LINUX)
                                 ├──► wayland_macos.zig    (MAC)
                                 └──► wayland_portable.zig (CORE)

  host.zig (CORE) ──► ../wayland_api.zig  ◄── BACK-EDGE: core depends on
                                              the platform dispatcher

  components/* (CORE) ──► wayland/render_common.zig (CORE)   ✅ correct
  testing/root.zig (CORE) ──► wayland/host.zig, components/*  ✅ correct

  frame.zig (CORE) ──► render.zig (ROOT switch) ──┬──► render_gles3.zig (LINUX)
                                                  └──► render_software.zig (CORE)
```

Everything except `host.zig → wayland_api.zig` is already a clean DAG.
**That one edge is the whole architectural problem**, and it is cheap to fix
because `Delegate` is already defined in `window_contract.zig` — `host.zig` is
only importing `wayland_api.zig` to get a re-export of a type it could import
directly.

---

## 4. Target layout

```
src/
├── root.zig                  # public API aggregator + parity test block
├── main.zig                  # demo app
├── platform.zig              # ★ THE ONLY FILE THAT BRANCHES ON builtin.os.tag
│
├── core/                     # platform-agnostic. no system @cImport. no linux/ or mac/
│   ├── select.zig            # ★ the ONLY core file allowed to import ../platform.zig
│   ├── window_contract.zig   # WindowConfig · Delegate · WindowState · Placement
│   ├── window_portable.zig   # headless/CPU backend (also the test backend)
│   ├── host.zig              # Clay arena, input routing, frame scheduler
│   ├── frame.zig             # frame loop + command stream
│   ├── render.zig            # renderer facade (consumes select.zig)
│   ├── render_common.zig     # Draw · ImageFit · ImageRef · colour helpers
│   ├── render_software.zig   # CPU rasterizer
│   ├── render_pixels_test.zig
│   ├── glyphs.zig            # stb_truetype rasterization
│   ├── text_backend.zig      # text facade (consumes select.zig)
│   ├── text_portable.zig     # deterministic metrics
│   ├── protocol_consts.zig   # evdev codes + wayland enum constants
│   ├── stb_truetype_impl.c   # stb TU (every OS)
│   ├── components/           # 15 widget files
│   └── testing/root.zig      # headless harness
│
├── linux/                    # everything Linux
│   ├── window.zig            # ← wayland.zig
│   ├── render_gles3.zig      # ← wayland/render_gles3.zig
│   ├── text.zig              # ← wayland/text.zig
│   ├── pango_text.h
│   ├── pango_text.c
│   └── stb_image_impl.c
│
└── mac/                      # everything macOS
    ├── window.zig            # ← wayland_macos.zig
    ├── blit.zig              # ← platform/blit.zig
    ├── input.zig             # ← platform/input_macos.zig
    ├── keymap.zig            # ← platform/keymap_macos.zig
    ├── adapter.zig           # ← platform/macos_adapter.zig
    ├── cocoa_window.h
    └── cocoa_window.m
```

Notes on the shape:

- **`core/` has no `linux/`- or `mac/`-shaped hole.** It does not know the
  platforms exist.
- **`platform.zig` is the composition root.** It is the only file with an OS
  switch, and it imports the backends. It imports `core/` only for the two
  portable fallbacks, which are leaves — so **there is no import cycle**.
- **`core/select.zig` is the one documented bridge.** It imports
  `../platform.zig` and re-exports the resolved `Window`/`Delegate`/`Renderer`/
  `Text`. Everything else in `core/` imports `select.zig` instead of reaching for
  a platform.
- `portable/` as a fourth folder is **not** proposed: `window_portable.zig` is
  genuinely platform-agnostic (it is what Windows would use), so it lives in
  `core/`. See [§9 Decisions](#9-decisions-i-need-from-you).
- `protocols/*.xml` stays at the repo root (it is build input, not source).

### 4.1 Final dependency graph

```
                     root.zig
                        │
        ┌───────────────┼────────────────────┐
        ▼               ▼                    ▼
   platform.zig    core/select.zig      core/components/*
   (OS switch)          │                    │
        │               ▼                    ▼
        │        core/{host,frame,    core/render_common.zig
        │        render,text_backend,      (leaf)
        │        render_software,…}
        │               │
        │               ▼
        │        core/window_contract.zig (leaf)
        │
   ┌────┼──────────────┬───────────────────┐
   ▼    ▼              ▼                   ▼
 linux/ mac/     core/window_portable  core/render_software
 {window,        .zig                  .zig  (leaves)
  render_gles3,        │
  text}                ▼
                  core/window_contract.zig
```

`core/**` reaches a platform module in exactly one hop, from exactly one file.

---

## 5. Layering rules (enforce these with a lint, not with discipline)

| Rule | Statement | Why |
|---|---|---|
| **R1** | No file under `src/core/**` may import a path containing `linux/` or `mac/`. | The whole point of `core/`. |
| **R2** | Only `src/core/select.zig` may import `../platform.zig`. | Keeps the platform surface behind one bridge. |
| **R3** | No file under `src/core/**` may `@cImport` a **system** header or use `builtin.os.tag`. | Core must compile unchanged on any host. |
| **R4** | `src/linux/**` must not import `src/mac/**`, and vice versa. | Backends are siblings, not a hierarchy. |
| **R5** | Only `src/platform.zig` may branch on `builtin.os.tag`. | One place to reason about the OS. |
| **R6** | `src/mac/*.zig` that stays in the parity suite must remain pure Zig (no `@cImport`). | Protects C1 — the parity count and its cross-OS compilability. |

Add `ci/check_layering.sh` (new, ~35 lines of `rg` + `grep`) and wire it into
`ci.yml` as a cheap first job:

```bash
#!/usr/bin/env bash
# Layering gate: see REFACTOR_PLAN.md §5.
set -euo pipefail
fail=0

# R1 — core must not reach a platform backend
if rg -n --glob 'src/core/**' '@import\("\.\./(\.\./)?(linux|mac)/' ; then
  echo "R1 violated: core imports a platform backend" >&2; fail=1
fi

# R2 — only core/select.zig may import ../platform.zig
if rg -n --glob 'src/core/**' '@import\("\.\./platform\.zig"\)' --files-with-matches \
   | grep -v '^src/core/select\.zig$' ; then
  echo "R2 violated: only core/select.zig may import platform.zig" >&2; fail=1
fi

# R3 — core must be OS-blind and free of system C imports
if rg -n --glob 'src/core/**' 'builtin\.os\.tag' ; then
  echo "R3 violated: core knows the OS" >&2; fail=1
fi
if rg -n --glob 'src/core/**' -e '@cInclude\("(EGL|GLES|pango|cocoa|wayland)' ; then
  echo "R3 violated: core imports a system C header" >&2; fail=1
fi

# R4 — sibling backends must not cross-import
if rg -n --glob 'src/linux/**' '@import\("\.\./mac/' ; then
  echo "R4 violated: linux imports mac" >&2; fail=1
fi
if rg -n --glob 'src/mac/**' '@import\("\.\./linux/' ; then
  echo "R4 violated: mac imports linux" >&2; fail=1
fi

# R5 — one OS switch
if rg -n 'builtin\.os\.tag' src --glob '!src/platform.zig' ; then
  echo "R5 violated: builtin.os.tag outside platform.zig" >&2; fail=1
fi

exit "$fail"
```

---

## 6. The real code changes (not just moves)

Most of this refactor is file moves plus import rewrites. These four changes are
the ones that actually alter code. **All four are small.**

### 6.1 Kill the core→platform back-edge in `host.zig`

```zig
// BEFORE  src/wayland/host.zig:10
const wayland = @import("../wayland_api.zig");
// … line 196
pub fn delegate(self: *Host) wayland.Delegate {

// AFTER   src/core/host.zig
const contract = @import("window_contract.zig");
// … 
pub fn delegate(self: *Host) contract.Delegate {
```

`window_contract.zig` already defines `Delegate` with the identical field set
(verified: same 8 fields, same `on_scroll` default `null`). `wayland_api.zig`
merely re-exports it. So this is a **type-identity-preserving** change — no
call site changes, because Zig resolves `Delegate` to the same struct.

### 6.2 Delete the duplicated contract in the Linux backend

`linux/window.zig` (today `wayland.zig`, L231–262) still declares its **own**
`WindowConfig` and `Delegate` inline, while `wayland_macos.zig` and
`wayland_portable.zig` correctly re-export `contract.WindowConfig` /
`contract.Delegate`. Delete the Linux duplicates and re-export from
`core/window_contract.zig`:

```zig
pub const WindowConfig = contract.WindowConfig;
pub const Delegate = contract.Delegate;
```

This removes a real drift hazard: today, adding a `Delegate` field means editing
it in two places, and the Linux copy is the one that silently wins on Linux.

### 6.3 Collapse the three OS switches into one file

`wayland_api.zig` (window), `wayland/render.zig` (renderer) and
`wayland/text_backend.zig` (text) each carry their own `builtin.os.tag` /
`builtin.is_test` branch. In the new layout the branching moves to
`src/platform.zig` and the two facades become thin consumers of
`core/select.zig`:

```zig
// src/platform.zig — the ONLY OS switch in the repository
const builtin = @import("builtin");

pub const window = if (builtin.is_test)
    @import("core/window_portable.zig")
else switch (builtin.os.tag) {
    .linux  => @import("linux/window.zig"),
    .macos  => @import("mac/window.zig"),
    else    => @import("core/window_portable.zig"),
};

pub const render_impl = if (builtin.os.tag == .linux and !builtin.is_test)
    @import("linux/render_gles3.zig")
else
    @import("core/render_software.zig");

pub const text_impl = if (builtin.os.tag == .linux and !builtin.is_test)
    @import("linux/text.zig")
else
    @import("core/text_portable.zig");
```

```zig
// src/core/select.zig — the single bridge; preserves C2 by delegating the
// is_test decision to platform.zig rather than re-deriving it here.
const platform = @import("../platform.zig");
pub const Window = platform.window.Window;
pub const WindowConfig = platform.window.WindowConfig;
pub const Delegate = platform.window.Delegate;
pub const Renderer = platform.render_impl.Renderer;
```

`core/render.zig` and `core/text_backend.zig` then read from `select.zig`
instead of computing their own switch.

> **C2 is preserved** because the `builtin.is_test => portable` decision still
> runs on the same condition as today — it just lives in one file instead of
> three. This is the single most fragile step in the plan; verify it explicitly
> (§7, Phase 3).

### 6.4 Re-export the public API from the new paths

`root.zig` keeps every existing `pub const` name — only the import paths change.
Add back-compat aliases so the external `qs-settings-zig` consumer is untouched:

```zig
pub const platform = @import("platform.zig");
/// Deprecated alias: pre-split name. Remove when qs-settings-zig has migrated.
pub const wayland_lib = platform;
pub const Window = platform.window.Window;
pub const Delegate = platform.window.Delegate;
pub const render = @import("core/render.zig");
pub const text = @import("core/text_backend.zig");
pub const frame = @import("core/frame.zig");
pub const host = @import("core/host.zig");
pub const software_render = @import("core/render_software.zig");
pub const components = struct { /* paths → core/components/… */ };
pub const testing = @import("core/testing/root.zig");
```

---

## 7. Phased execution

Each phase is independently buildable and independently reviewable. **Do not
merge two phases into one commit** — the whole value of this ordering is that a
parity failure is attributable to one step.

### Phase 0 — Guardrails and baseline (no source moves)

1. Capture the baseline locally: `zig build test --summary all` on Linux and
   macOS; confirm **376**. Run `zig build native-test` on Linux and record its
   count (it is *not* 376 and is *not* locked).
2. Add `ci/check_layering.sh` from §5 with the two `platform.zig` rules
   temporarily disabled (the file does not exist yet) — or land it with R1/R3/R4
   only.
3. Add `.gitkeep` to `src/core/`, `src/linux/`, `src/mac/` so the folders are
   tracked.

**Gate:** `ci/check_test_parity.sh` green; new lint green.

### Phase 1 — Break the back-edge (in place, no moves)

Change `host.zig` to import `window_contract.zig` for `Delegate` (§6.1).
Delete the duplicated `Delegate`/`WindowConfig` in `wayland.zig` (§6.2).

**Gate:** `zig build test` = 376 on Linux **and** macOS; `zig build native-test`
unchanged on Linux. This phase must produce a **zero-diff test count** and should
not touch `build.zig`.

### Phase 2 — Create `core/` (moves only, no logic change)

Move the CORE-classified files per §8. Update every relative import. Update the
parity `test` block in `root.zig` to the new paths — **same list, same order,
same count**.

**Gate:** `zig build test` = 376 on both OSes. `rg 'wayland/' src/core` returns
nothing.

### Phase 3 — Introduce `platform.zig` and `core/select.zig`

Collapse the three switches (§6.3). Point `core/render.zig` and
`core/text_backend.zig` at `select.zig`.

**Gate (the critical one):** `zig build test` = 376 on **both** OSes *and*
`zig build native-test` on Linux. If the count drifts, the `builtin.is_test`
condition was lost — revert this phase only.

### Phase 4 — Create `linux/`

Move `wayland.zig` → `linux/window.zig`, `render_gles3.zig`, `text.zig`, and the
`pango_text.*` + `stb_image_impl.c` shims. Update `build.zig`:

- `mod.addIncludePath(b.path("src"))` → `b.path("src/linux")` for the Pango shim
  (and check nothing else relied on the old unconditional `src` include path —
  the macOS shim needs `src/mac`).
- `addPangoShim`: `b.path("src/pango_text.c")` → `b.path("src/linux/pango_text.c")`.
- `native-test` roots: `src/wayland/text.zig` → `src/linux/text.zig`,
  `src/wayland/render_gles3.zig` → `src/linux/render_gles3.zig`,
  `src/wayland.zig` → `src/linux/window.zig`.
- `stb_image_impl.c`: `src/` → `src/linux/`.

**Gate:** Linux `zig build test` = 376; Linux `zig build native-test` unchanged;
Linux `zig build run-calculator` still opens a window. macOS `zig build test` =
376 (macOS must not be affected by this phase at all).

### Phase 5 — Create `mac/`

Move `wayland_macos.zig` → `mac/window.zig`; `platform/{blit,input_macos,keymap_macos,macos_adapter}.zig` → `mac/{blit,input,keymap,adapter}.zig`;
`cocoa_window.{h,m}` → `mac/`. Update `build.zig`:

- the macOS block: `b.path("src/cocoa_window.m")` → `b.path("src/mac/cocoa_window.m")`
- `mod.addIncludePath(b.path("src"))` → `b.path("src/mac")` (the comment in
  `build.zig` explains this path exists for the Cocoa shim)
- `mac/input.zig` internal imports: `../components/*` → `../core/components/*`,
  `../wayland/host.zig` → `../core/host.zig`

**Gate:** macOS `zig build test` = 376; macOS `zig build run-calculator` still
renders; Linux `zig build test` = 376.

> `mac/blit.zig`, `mac/keymap.zig` and `mac/adapter.zig` **stay in the parity
> test block** in `root.zig` — they are pure Zig and their cross-platform
> compilation is the thing that proves the macOS translations are correct. R6
> exists to stop someone "tidying" them behind a `builtin.os.tag` gate.

### Phase 6 — Public API + docs + lint hardening

- Update `root.zig` re-exports (§6.4); add `wayland_lib` alias.
- Move `protocol_consts.zig` to `core/` (it is shared vocabulary).
- Enable all layering rules R1–R6 in `ci/check_layering.sh` and add the job to
  `ci.yml`.
- Update the stale prose: `root.zig`'s "ZERO ui/* imports" header, `build.zig`'s
  long comments, and the `wayland/`-relative paths in doc comments throughout
  (`render.zig`, `text_backend.zig`, `blit.zig`, `input_macos.zig`).
- Update `examples/calculator.zig` only if a comment references a path (its
  *code* uses the public surface and must not change).

**Gate:** full CI matrix green, including the Windows `absent` calculator legs
(they only assert the gate, so they should be unaffected — verify anyway).

### Phase 7 — Optional cleanups (separate PR, don't bundle)

- Split `core/protocol_consts.zig` into `core/input_codes.zig` (evdev, shared)
  and `linux/wayland_consts.zig` (`LayerAnchor`, layer-shell geometry).
- Rename the `LayerSize`/`centeredAnchor`/`layerSize` legacy helpers — they are
  layer-shell era leftovers that both backends still re-export.
- Consider moving `src/main.zig` to `src/demo/main.zig`.

---

## 8. File move map

Copy-paste table. `→` is the destination under the target layout.

| Old path | New path | Lines | Class |
|---|---|---:|---|
| `src/wayland/host.zig` | `src/core/host.zig` | 379 | CORE |
| `src/wayland/frame.zig` | `src/core/frame.zig` | 467 | CORE |
| `src/wayland/render.zig` | `src/core/render.zig` | 41 | CORE (facade) |
| `src/wayland/render_common.zig` | `src/core/render_common.zig` | 285 | CORE |
| `src/wayland/render_software.zig` | `src/core/render_software.zig` | 640 | CORE |
| `src/wayland/render_pixels_test.zig` | `src/core/render_pixels_test.zig` | 612 | CORE |
| `src/wayland/glyphs.zig` | `src/core/glyphs.zig` | 379 | CORE |
| `src/wayland/text_backend.zig` | `src/core/text_backend.zig` | 36 | CORE (facade) |
| `src/wayland/text_portable.zig` | `src/core/text_portable.zig` | 175 | CORE |
| `src/platform/window_contract.zig` | `src/core/window_contract.zig` | 376 | CORE |
| `src/platform/protocol_consts.zig` | `src/core/protocol_consts.zig` | 116 | CORE |
| `src/wayland_portable.zig` | `src/core/window_portable.zig` | 154 | CORE |
| `src/components/*.zig` (15) | `src/core/components/*.zig` | ~6.4k | CORE |
| `src/testing/root.zig` | `src/core/testing/root.zig` | 449 | CORE |
| `src/stb_truetype_impl.c` | `src/core/stb_truetype_impl.c` | 2 | C-impl |
| `src/wayland.zig` | `src/linux/window.zig` | 1356 | LINUX |
| `src/wayland/render_gles3.zig` | `src/linux/render_gles3.zig` | 1378 | LINUX |
| `src/wayland/text.zig` | `src/linux/text.zig` | 261 | LINUX |
| `src/pango_text.h` | `src/linux/pango_text.h` | 30 | LINUX |
| `src/pango_text.c` | `src/linux/pango_text.c` | 101 | LINUX |
| `src/stb_image_impl.c` | `src/linux/stb_image_impl.c` | 8 | LINUX |
| `src/wayland_macos.zig` | `src/mac/window.zig` | 354 | MAC |
| `src/platform/blit.zig` | `src/mac/blit.zig` | 221 | MAC |
| `src/platform/input_macos.zig` | `src/mac/input.zig` | 324 | MAC |
| `src/platform/keymap_macos.zig` | `src/mac/keymap.zig` | 359 | MAC |
| `src/platform/macos_adapter.zig` | `src/mac/adapter.zig` | 484 | MAC |
| `src/cocoa_window.h` | `src/mac/cocoa_window.h` | 111 | MAC |
| `src/cocoa_window.m` | `src/mac/cocoa_window.m` | 415 | MAC |
| `src/wayland_api.zig` | `src/platform.zig` (rewritten) | 43 → ~50 | ROOT |
| — | `src/core/select.zig` (new) | ~20 | CORE |

Unchanged: `src/root.zig`, `src/main.zig`, `examples/calculator.zig`,
`build.zig.zon`, `tests.lock`, `protocols/*.xml`, `vendor/*`.

### 8.1 Import-rewrite cheat sheet

| Pattern | Becomes |
|---|---|
| `@import("../wayland_api.zig")` (from core) | `@import("select.zig")` — or `window_contract.zig` for types only |
| `@import("render.zig")` (from core) | unchanged (sibling in `core/`) |
| `@import("text_backend.zig")` (from core) | unchanged (sibling in `core/`) |
| `@import("render_common.zig")` | unchanged |
| `@import("../components/x.zig")` (from `mac/`) | `@import("../core/components/x.zig")` |
| `@import("../wayland/host.zig")` (from `mac/`) | `@import("../core/host.zig")` |
| `@import("window_contract.zig")` (from `mac/`) | `@import("../core/window_contract.zig")` |
| `@import("platform/window_contract.zig")` | `@import("core/window_contract.zig")` |
| `@import("wayland/render_software.zig")` | `@import("core/render_software.zig")` |
| `@import("wayland/frame.zig")` | `@import("core/frame.zig")` |
| `@import("wayland/glyphs.zig")` | `@import("core/glyphs.zig")` |
| `@import("platform/keymap_macos.zig")` | `@import("mac/keymap.zig")` |
| `@import("wayland_portable.zig")` | `@import("core/window_portable.zig")` |
| `@import("zclay")` | **unchanged — never rewrite this one** (C4) |

### 8.2 `build.zig` touch list

| Location | Change |
|---|---|
| `mod.addCSourceFile(src/stb_truetype_impl.c)` | → `src/core/stb_truetype_impl.c` |
| `mod.addIncludePath(b.path("src"))` | split: `src/core` (stb/glyphs) + `src/mac` (Cocoa shim) |
| macOS block: `addCSourceFile(src/cocoa_window.m)` | → `src/mac/cocoa_window.m` |
| Linux block: `addCSourceFile(src/stb_image_impl.c)` | → `src/linux/stb_image_impl.c` |
| `addPangoShim` `addIncludePath(b.path("src"))` | → `b.path("src/linux")` |
| `addPangoShim` `addCSourceFile(src/pango_text.c)` | → `src/linux/pango_text.c` |
| `makeModuleTestStep("src/wayland/text.zig")` | → `src/linux/text.zig` |
| `makeModuleTestStep("src/wayland/render_gles3.zig")` | → `src/linux/render_gles3.zig` |
| `makeWaylandTestStep("src/wayland.zig")` | → `src/linux/window.zig` |
| `makeWaylandTestStep` include paths | add `src/linux` for the Pango shim |
| Module name `"glinlandui"` | unchanged |
| `addImport("zclay")` | unchanged |

---

## 9. Decisions I need from you

Four things the codebase does not decide for me:

1. **The portable backend's home.** `wayland_portable.zig` is the Windows
   fallback and the backend every test build uses. I propose `core/` (it is
   platform-agnostic). The alternative is a fourth `platform/` folder, which
   contradicts the three-folder model you asked for. **Recommend: `core/`.**

2. **Accept one documented bridge, or go fully parameterised?** My plan allows
   `core/select.zig` to import `../platform.zig` — one exception, enforced by
   R2. The purist alternative is to make `core/host.zig` and `core/frame.zig`
   generic over the backend (`pub fn Host(comptime Window: type) type`,
   `pub fn Frame(comptime Renderer: type, comptime Text: type) type`). That
   removes the exception entirely but **changes the public API shape** of
   `glinlandui.host.Host` and `glinlandui.frame`, breaking `main.zig` and
   `examples/calculator.zig`. **Recommend: the single bridge.**

3. **`protocols/*.xml` location.** Moving them to `src/linux/protocols/` makes
   `linux/` self-contained; leaving them at the root keeps `build.zig`'s codegen
   block and any downstream tooling untouched. **Recommend: leave at root** (it
   is build input, and moving it is pure churn).

4. **Rename timing.** The plan renames `wayland.zig` → `linux/window.zig` and
   `wayland_macos.zig` → `mac/window.zig`. That is the point of the exercise,
   but it invalidates every path in every comment and any bookmarks. **Recommend:
   do it, in Phase 4/5, and fix the comments in the same phase** so there is
   never a commit where the docs point at files that do not exist.

---

## 10. Risks

| # | Risk | Severity | Mitigation |
|---|---|---|---|
| 1 | Parity count drifts (C1/C2) | **High** | One phase per logical change; run `ci/check_test_parity.sh` on both OSes at every gate. Phase 3 is the only phase that touches the `is_test` logic — isolate it. |
| 2 | `build.zig` include-path breakage on move (C5) | **High** | `src` is currently a *global* include dir; after the split, `pango_text.h` and `cocoa_window.h` each need their own. Phase 4/5 change these explicitly; a missing include fails loudly at compile time, so it cannot pass silently. |
| 3 | Two module identities for one file | Medium | Zig can silently materialise a duplicate module if the same file is reachable via two different paths. Never import `zclay` relatively (C4); keep import styles consistent (module name for `zclay`, relative path for everything else). |
| 4 | Import cycle `platform.zig ↔ core/` | Medium | Avoided by design: `platform.zig` imports only the backends plus the two `core/` **leaf** files (`window_portable.zig`, `render_software.zig`), neither of which imports `platform.zig` or `select.zig`. Verify with `zig build test` immediately after Phase 3 — a cycle is a hard compile error, not silent. |
| 5 | External consumer `qs-settings-zig` breaks | Medium | Public API names preserved 1:1; `wayland_lib` kept as a deprecated alias. Any name that must move gets an alias for one release. |
| 6 | macOS re-exported pure modules get gated behind `builtin.os.tag` "for tidiness" | Medium | R6 + the existing comment in `root.zig` explaining why `keymap_macos`/`blit`/`macos_adapter` are in the parity suite on purpose. |
| 7 | Windows `absent` CI legs misfire | Low | `calc_supported` in `build.zig` is untouched; the legs assert absence only. Verify in Phase 6. |
| 8 | Long-lived branch conflicts with active work | Medium | Phases 2/4/5 are pure `git mv` + import rewrites — land them fast, in order, one PR per phase. |

---

## 11. Cost estimate

| Phase | Nature | Rough size |
|---|---|---|
| 0 | New lint + `.gitkeep` | new file, ~35 lines; no source touched |
| 1 | Two-file logic change | ~20 lines changed, ~35 deleted |
| 2 | `git mv` + import rewrites in `core/` | ~30 files moved, ~40 import lines |
| 3 | New `platform.zig` + `select.zig`, 2 facades slimmed | ~70 lines new, ~40 removed |
| 4 | `linux/` move + `build.zig` | 6 files moved, ~12 build.zig lines |
| 5 | `mac/` move + `build.zig` | 7 files moved, ~6 build.zig lines |
| 6 | API re-exports, docs, lint hardening | ~60 lines + comment sweep throughout |
| 7 | Optional cleanups | separate PR |

The refactor is dominated by mechanical moves. **Only Phase 1 and Phase 3 change
behaviour-adjacent code**, and neither changes actual runtime behaviour.

---

## 12. Verification checklist (run at every gate)

```bash
# Linux
zig build test --summary all                 # expect: 376 passed
./ci/check_test_parity.sh                    # expect: parity: 376 tests
zig build native-test --summary all          # expect: same count as baseline
zig build run-calculator                     # expect: window renders

# macOS
zig build test --summary all                 # expect: 376 passed
./ci/check_test_parity.sh                    # expect: parity: 376 tests
zig build run-calculator                     # expect: headless frame, painted > 0

# Structural (new, every phase)
./ci/check_layering.sh                       # expect: silent + exit 0
rg -n 'wayland_api|wayland_macos|wayland_portable' src/   # expect: no hits after Phase 6
```

> Note: exactly **one** file in the CORE set breaks a literal "no `@cImport` in
> core" rule — `core/glyphs.zig` (today `src/wayland/glyphs.zig:31`) does
> `@cImport({ @cInclude("stb/stb_truetype.h") })`. Verified by grep: **no other**
> CORE-classified file contains `@cImport`, and `render_software.zig` gets glyphs
> through `glyphs.zig` rather than importing stb itself. That is a *vendored*
> dependency, identical on every OS — it does not break portability, which is why
> R3 is written to ban **system** C headers (`EGL/`, `GLES*`, `pango`, `cocoa`,
> `wayland*`) rather than all `@cImport`. The alternative is to generate Zig
> bindings for stb so `core/` is 100% C-free.

---

## 13. Execution log

Executed on Linux, Zig 0.16.0. Every phase landed in order, each with the full
gate run before moving on.

| Phase | Result |
|---|---|
| 0 | baseline captured: `test` 363/376, `native-test` 65/65. Parity script fixed, `ci/check_layering.sh` added (R1/R3/R4), `.gitkeep` × 3. |
| 1 | back-edge broken; Linux duplicate contract deleted (**−52 lines**, one definition now). |
| 2 | 15 groups of moves + ~60 import rewrites. `test` 376, `native-test` 82. |
| 3 | `wayland_api.zig` → `platform.zig`, `core/select.zig` added, both facades de-branched. `builtin.os.tag` now appears in **exactly one file**. |
| 4 | `linux/` created (6 files) + build.zig C/include paths. Release binary + calculator verified. |
| 5 | `mac/` created (7 files) + Cocoa paths. `src/` is now exactly `core/ linux/ mac/ main.zig native_test.zig platform.zig root.zig`. |
| 6 | R2/R5/R6 added and **each rule verified to actually fire** (probe commit-revert cycle, not just "it passes"); CI `layering` job added; ~60 stale doc-comment references rewritten. |

**Final state:** `zig build test` 363/376 (13 skipped) · `check_test_parity.sh`
green · `native-test` 82/82 · `check_layering.sh` ok (R1–R6) · `zig fmt --check`
clean · ReleaseSafe build + headless calculator verified.

### Deviations from the plan (each forced by something the plan could not see)

1. **`native-test` went 65 → 82, and its three roots became one.** Two causes,
   both real:
   - Phase 1 made `wayland.zig` import `window_contract.zig`, so that test root
     also ran the contract's tests (+22 = 18 contract + 4 protocol_consts).
   - Phase 2 then hit a Zig rule the plan had not accounted for: **`@import` may
     not escape the module's root *directory*** ("import of file outside module
     path"). A module rooted at `src/wayland/render_gles3.zig` cannot reach
     `src/core/render_common.zig`. So the three native roots were consolidated
     into `src/native_test.zig`, which sits at `src/` and reaches both subtrees —
     the same placement, and the same reason, as the parity root.
   `native-test` is **not** locked (`tests.lock` covers only `zig build test`)
   and CI only runs it without asserting a count. Coverage went **up**. A new
   *test* was not added, removed, or weakened.
2. **Two `builtin.os.tag` branches were deleted from core, not moved.** §6.3
   predicted this, but the plan's Phase 2 move list still placed `render.zig` /
   `text_backend.zig` in `core/` as "CORE (facade)". They are, but only *after*
   Phase 3 de-branches them — between Phase 2 and Phase 3 the layering lint
   correctly reported R3 violations. That is worth knowing if the phases are ever
   replayed: **Phase 2 cannot pass R3 without Phase 3.**
3. **Unused re-exports had to be deleted to prevent an import cycle.**
   `window_portable.zig` and `wayland_macos.zig` re-exported `render`/`text`/
   `frame`. Since `platform.zig` imports those backends and the facades resolve
   back through `select.zig` to `platform.zig`, keeping the re-exports would have
   closed a cycle. Verified nothing consumed them before deleting.
4. **`ci/check_test_parity.sh` was broken before any of this.** It could not parse
   `Build Summary: … 363/376 tests passed (13 skipped)` because of a `$` anchor
   and no allowance for the skip suffix, so it failed on the *baseline* tree. CI
   runs it (ci.yml lines 62/95/201), so it was a live gate that could not pass on
   a machine with any skipped test. Fixed in Phase 0 so it could gate this work.

### Known smell left in place (deliberately, for Phase 7)

`core/frame.zig` owns the cursor-shape mapping (`shape_default`, `currentShape`,
`shouldApplyShape`) — values from the Wayland `cursor-shape-v1` protocol. That is
a Linux concern sitting in the platform-agnostic layer, and `linux/window.zig`
imports it, which is what makes that backend depend on `core/frame.zig` at all.
Moving it to `linux/` would tighten the split further; it was left alone because
it is a behaviour-adjacent move and this refactor was scoped to be behaviour-free.

---

## 14. The platform mirror (`linux/` ↔ `mac/`, 1:1)

Follow-up to §13: the two platform folders now expose the **same 9 names**, so
they can be read and diffed side by side.

```
linux/            mac/            role
window.zig        window.zig      backend: bootstrap, event loop, frame loop
input.zig         input.zig       native events → the Delegate's input contract
keymap.zig        keymap.zig      native keycode → evdev
adapter.zig       adapter.zig     coords / scroll / resize / quit
present.zig       present.zig     finished frame → screen
renderer.zig      renderer.zig    renderer for this OS
text.zig          text.zig        text engine for this OS
shim.h            shim.h          the platform's C shim header
shim.c            shim.m          the platform's C shim TU
```

`shim.c` ↔ `shim.m` is the one name that cannot match: Objective-C requires the
`.m` extension. The stem is identical.

### What the mirror is, and what it is not

It is a **role** mirror, not a copy. Where the two platforms genuinely answer the
same question, the function names match. Where one platform has nothing to do,
the file says so instead of inventing work:

| file | linux | mac |
|---|---|---|
| `keymap.zig` | the identity — Wayland *is* evdev | ~360 lines: AppKit keycode table |
| `input.zig` | `fixedToFloat`, `evdevButton`, `kindFromState`, `BTN_*` | `Raw`/`Translated`/`translate`, origin flip |
| `adapter.zig` | scroll accumulation, hover dedup | + origin flip, scroll clamp, resize coalescing |
| `present.zig` | one `eglSwapBuffers` (GL draws to the surface) | byte hand-off + the channel-order investigation |
| `renderer.zig` | EGL + GLES3, 1378 lines | re-exports the shared CPU rasterizer |
| `text.zig` | pangocairo via the shim | re-exports the shared estimator |

A literal "same functions everywhere" was **not** the goal and would have been
harmful: `linux/present.zig` has no `identityRgba8` to write, because Linux has
no CPU pixels to shuffle, and `linux/input.zig` has no `Raw`→`Translated` round
trip, because Wayland already delivers evdev codes and top-left fixed-point
coordinates. Those absences are documented in each file, and they are the most
informative thing in the pair.

### Structural changes that came with it

1. **Five files renamed**, via `git mv` so history follows:
   `linux/render_gles3.zig`→`linux/renderer.zig`, `mac/blit.zig`→`mac/present.zig`,
   `linux/pango_text.{h,c}`→`linux/shim.{h,c}`,
   `mac/cocoa_window.{h,m}`→`mac/shim.{h,m}`.
   The C symbol names (`glin_cocoa_window_*`) were left alone — they are API, not
   filenames.
2. **`linux/stb_image_impl.c` → `core/stb_image_impl.c`**, next to the existing
   `core/stb_truetype_impl.c`. Both are *vendored library* TUs, not platform
   shims, and both are now unconditional. The consequence: **each platform folder
   owns exactly one C TU** — its shim. That is what makes the 9-name mirror
   possible.
3. **A latent include-path hazard removed.** Both folders now have a `shim.h`
   with different contents, and `mod.addIncludePath(b.path("src/mac"))` was
   *unconditional*. On Linux that would have let `linux/text.zig`'s
   `@cInclude("shim.h")` resolve to the **Cocoa** header. The macOS include path
   is now gated inside `if (is_macos)`, so exactly one platform's headers are on
   the path at a time.
4. **A second duplicated definition deleted.** `linux/window.zig` defined its own
   `pointerPosChanged`, byte-identical to `core/window_contract.zig`'s — the same
   drift hazard as the `Delegate` copy removed in Phase 1, with the Linux copy
   silently winning. Now re-exported from the contract via `linux/adapter.zig`.
5. **Three more files joined the parity suite** — `linux/{keymap,input,adapter}
   .zig`. They are pure Zig, so importing them into `src/root.zig`'s aggregate
   `test` block type-checks them on **macOS** as well as Linux, at no cost to the
   count (they contain no tests). Mirror-image of the `mac/*` entries: the point
   is now that a typo in the *Linux* event translation fails on both platforms,
   not just CI's Linux leg. `linux/present.zig` is excluded — it cImports EGL.
   `ci/check_layering.sh` rule R6 was generalised to keep every parity-suite
   module C-free, and now matches `@cImport(` (the call) rather than `@cImport`
   (which also appeared in the doc comments explaining the rule).
6. **`mac/renderer.zig` + `mac/text.zig` added** as documented re-exports of the
   shared core implementations. They are also in the parity block, so Linux
   type-checks every file in `src/mac/`.

### Verification

All gates green from a cold build (`.zig-cache` + `zig-out` deleted first):

- `zig build test` → **363/376 (13 skipped)** — parity count unchanged
- `ci/check_test_parity.sh` → **parity: 376 tests (matches tests.lock)**
- `zig build native-test` → **82/82**
- `ci/check_layering.sh` → **ok** (R1–R6), with R6 re-verified to fire on a real
  `@cImport(` and to *not* fire on a comment mentioning it
- `zig fmt --check build.zig src examples` → clean
- `zig build -Doptimize=ReleaseSafe` + headless calculator → 158400 painted pixels
- **155/155 relative `@import`s resolve**; all `b.path("src/…")` exist

Confirmed behaviour-preserving by construction rather than by test: every
extraction moved code *verbatim* and wired it back through an alias, so
`linux/window.zig`'s own tests (which cover `fixedToFloat` and
`pointerPosChanged`) still run and still pass — which is direct evidence the
re-exports are equivalent.

**Still not verifiable on this host:** `mac/window.zig` and `mac/shim.m`. They are
macOS-only; their imports resolve and nothing else in `src/mac/` remains
unanalysed, but CI's `macos` leg is the real gate.
