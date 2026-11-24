# AGENTS.md — glinlandui

Rules for anyone (human or agent) changing this repository.

## The non-negotiables

1. **macOS works first.** This machine is macOS (Apple silicon). `zig build` and `zig build test`
   must pass **here** before a change is called done. Linux is the other first-class target; the
   test count must stay identical on both (see `ci/check_test_parity.sh`).
2. **The linter is zginlint** (`github.com/ginwa123/zglint`), not `zig fmt` alone.
3. **A comment block is at most ONE line.** Write as many comments as you like — there is no
   limit on the number — but each block is a single line. A blank line or a line of code ends a
   block, so a trailing `// note` after code is always fine.
4. **No `.zig` file may exceed 3000 lines.** Split the module instead of growing the file. The
   largest today is `src/linux/renderer.zig` at ~1378 lines.
5. **A component that takes the pointer also takes the keyboard** (WCAG 2.2 AA). Tab and Shift+Tab walk
   `core/components/focus.zig`; a focusable component calls `focus.declare(id)` while it declares and draws a
   ring when `frame.isFocused(name)` says the keyboard is on it. Escape always hands the keyboard back, so no
   component may become a keyboard trap.

## Verify before you report

```sh
zig build                  # the library, the demo, and the examples
zig build test             # the cross-platform parity suite (1234 tests; tests.lock is the count)
zig build native-test      # Linux only: the Wayland/Vulkan backend
zig build run              # the demo window
zig build run-calculator   # the calculator example
zig build run-todo         # the MVVM todo example (see examples/todo/README.md)
zig build test-todo        # the todo example's own tests, headless
zig build inspect -- --app=todo --json   # the devtool headless runner: any example's tree
zig build test-dp          # glinlanduidp's own tests; the client is built by a plain `zig build`
```

Plus the CI scripts, which are the real contract:

```sh
ci/check_layering.sh       # core/ must not know that platforms exist
ci/check_test_parity.sh    # the test count is identical on Linux and macOS
ci/check_macos_colors.sh   # the macOS blit's channel order
```

## Lint and size gates

Both are wired and both must be green:

```sh
zig build zginlint:check   # zginlint, --max-comment-lines 1, zero findings
zig build lines:check      # no .zig file over 3000 lines
```

zginlint is pinned by URL + hash in `build.zig.zon`; `zig build zginlint` installs the CLI into
`zig-out/bin/zginlint` if you want to run it by hand. There is no baseline and no suppression —
a finding is a finding.

The three rules it enforces:

| rule | what it means |
|---|---|
| `zginlint/max-comment-lines` | a comment block is at most **1** line |
| `zginlint/no-catch-unreachable` | banned — use `catch @panic("what failed")` or `try` |
| `zginlint/no-std-log-warn` | no bare `std.log.warn`; go through `core/log.zig` |

`core/log.zig` is the sink the last rule asks for: `log.warn` / `log.err` route to a sink the
application installs with `setSink`, defaulting to stderr in production and **nothing at all**
under `builtin.is_test`. A toolkit that writes to stderr behind the app's back breaks the app's
test runner, because the Zig runner relays any stderr byte from a passing test as a failure.

## Layout

```
src/root.zig        the public surface: Window, render, text, frame, host, components, file_dialog
src/platform.zig    the ONLY file that branches on OS
src/core/           platform-agnostic: Clay components, renderer, text, testing harness
src/core/devtools/  the inspector: the tree snapshot, the in-app window, the CLI
src/linux/          Wayland / Vulkan backend (+ vk.c, its one C shim)
src/mac/            Cocoa backend, plus the Objective-C shim
src/terminal/       the TUI backend (`-Dtui`): kitty/sixel pixels, CPU cells as the fallback
src/file_dialog.zig system file dialog: NSOpenPanel on macOS, a portable stub elsewhere
```

`core/` must never import a platform folder — `ci/check_layering.sh` enforces it. Platform code
reaches core through exactly one bridge, `core/select.zig`.

## The test rule

A **test build selects `core/window_portable.zig` on every platform**, and the portable renderer
and text estimator with it. That is what makes the Linux and macOS test counts identical. If that
`builtin.is_test` branch in `platform.zig` is ever lost, `ci/check_test_parity.sh` fails on both
platforms. That is the intended alarm.

The native backends are still tested: the Wayland one in the Linux-only `native-test` step, and
the macOS one's decision logic (pure Zig, in `src/mac/`) through the parity suite itself. The
terminal backend has its own step too — `zig build test-tui`, whose root is `src/terminal_test.zig`
(encoders, cell grid, a real component tree) — and for the same reason it is not in the parity count.

## The macOS shim

`src/mac/shim.m` is the only untestable part of the toolkit. It owns the `NSWindow`, the `NSView`,
and the `NSOpenPanel`, and it makes **no decisions** — keycodes, the y-axis flip, the BGRA byte
order, resize coalescing and the file-dialog's extension mapping all live in Zig where they are
unit-tested.

It compiles with `-Werror`, and that is load-bearing: messaging a selector AppKit does not
implement is a clang *warning*, so without it the build passes and the app ships a runtime
`NSInvalidArgumentException` on every event.

## The performance gate

`zig build bench-lazy-scroll` measures `examples/lazy_scroll/` headless: 600 frames at 900x640,
scale 1, scrolling 10,000 virtualised rows to the bottom. The `lazy-scroll` CI job runs that bench
on macOS, Linux and Windows and gates it with `ci/check_lazy_scroll_bench.sh`.

Two different things are asserted, and they are deliberately not the same thing:

- **The work is identical on every platform.** `rows`, `frames`, `size`, `scale`, `declared` and
  `scroll_y` must match `ci/lazy_scroll_bench.expected` exactly. The scroll path is driven by the
  frame count, not the wall clock, so a difference means a platform stopped measuring the same
  thing. `declared` and `scroll_y` are font-independent because the header and footer are fixed
  boxes, which is what makes the comparison legitimate at all.
- **The timing fits one ceiling.** `avg_ms` and `p95_ms` are checked against the budget in that
  same file — 12 ms and 25 ms, against ~1 ms measured on an M-series Mac. A hosted runner is
  several times slower than a developer machine, so this is a regression gate rather than a
  144 Hz claim, and it is never compared across platforms.

The bench's own pixel checksum is NOT part of it — it is a smoke signal, not a contract. The ink is
gated separately and much more strictly by `golden_test.zig`, which is comparable on every platform
because the toolkit embeds its own typeface.

Changing the bench — the frame count, the size, the scroll speed — means changing
`ci/lazy_scroll_bench.expected` in the same commit. Those numbers are contractual.

## Cross-platform parity

The app code is the same everywhere (`main` -> `Window.init` -> `Host.init` -> `content()`). What
differs is the backend, so parity is enforced at four **seams**, each with its own gate. A backend
that fails a seam is a bug in that backend, never a reason to fork the app.

| seam | invariant | gate |
|---|---|---|
| layout | the Clay command stream | `golden_test.zig` (via the composite scene) |
| raster | identical RGBA bytes for a fixed command list | `golden_test.zig` + `golden_expected.zig` |
| scale | a W x H logical window at scale S rasterizes W*S x H*S pixels | `src/core/scale.zig`, `ci/check_render_scale.sh` |
| present | displayed == written (colour, byte order) | `ci/check_macos_colors.sh`, `ci/check_windows_colors.sh` |

**One typeface.** `src/assets/IBMPlexMono-Regular.ttf` (OFL, license beside it) is embedded via
`@embedFile` and tried FIRST by `Font.loadDefault`. Without it, every platform measured and drew with
its own system font and no pixel comparison was meaningful. The system list stays as the fallback for
a face stb cannot parse. The wasm build embeds the same file (`detectFont()` in `build.zig`).

**The raster gate is the reference a GPU backend must match.** `golden_test.zig` renders four fixed
scenes at 200x120, 1x, and compares the SHA-256 of every RGBA byte against `golden_expected.zig`. It
runs inside `zig build test`, so it runs on all three CI legs for free. A mismatch prints the actual
hash and names the file to re-record it in — re-recording is a deliberate act that belongs in the
commit that changes the pixels.

**`ci/render_scale.expected` is a ratchet.** It lists the backends that are known NOT to honour the
display scale. The gate fails both when an unlisted backend stops honouring it (a regression) and
when a listed backend starts honouring it (a stale entry). So the list can only shrink, and deleting
a line is the proof a fix landed. **The list is empty today:** macOS divides `glin_cocoa_backing_scale`
in, Windows and the browser size their surface from the scale, and Linux binds `wl_output`, takes the
largest scale among the outputs the surface has entered (plus `wl_surface.preferred_buffer_scale`),
calls `set_buffer_scale`, sizes the Vulkan swapchain in device pixels, and rasterises text at `fs * scale`
so the glyphs are drawn at device resolution rather than upscaled.

## Scrolling and repaint

A gesture delta is in **points and moves that many points of content**. Clay multiplies a wheel delta by 10 internally
(`scrollPosition += scrollDelta * 10`), so `frame.wheel_factor` cancels it and every call site divides by it. Handing Clay the raw
platform delta makes a trackpad scroll ten times further than the fingers moved, which reads on screen as the list jumping and
rows flashing in and out of the virtualisation window.

A container's offset is looked up **by element ID** (`clay.getScrollOffsetById`), never with Clay's `Clay_GetScrollOffset()`: that one
matches the element being declared by pointer into the per-frame element array, which is stale mid-declare, so it silently returns zero
whenever an element earlier in the frame appears or disappears — a blinking caret was enough to snap a scrolled list back to the top of
its content for one frame, which is exactly the flash users report as "the list blinks".

The scrollbar thumb floats over the viewport, so an **overflowing** container insets its content by the bar's width plus its margin: without
that gutter a right-aligned value (a column type in a schema tree) runs under the thumb and is unreadable. The thumb is a **control**: a press on
it grabs it and dragging it moves the content through the ratio its own travel implies (`scroll.beginThumbGrab` / `moveThumb`), so the pill stays
under the pointer instead of nudging the content 1:1 the way a drag over the content itself does. A click target declared inside a
scroll container answers **only inside that container** (`click_registry.pushClip`), so a row scrolled under a footer cannot swallow the
footer's click — which is what the audit's `hit_target_not_self` was reporting.

A frame whose render commands are **identical to the previous frame's** is not presented: `frame.commandsRepeated()` is what the
Cocoa window checks before blitting, and a resize is never skipped. Re-presenting an unchanged surface is wasted work, and it is
the window through which any glitch in the blit or the composite reaches the eye as a blink.

`GLIN_FRAME_DIFF=1 ./app` reports the two cases worth chasing: commands identical but pixels different (the engine), and a small
changed frame with the colour it flipped between (a state flip, usually hover). Whole-area changes are scrolling and are
suppressed — they are not a bug.

A backend draws when the display wants a frame, not when an event arrives. On the browser that is `requestAnimationFrame`, and the
wheel handler is the one exception to "an input event is a reason to draw": a trackpad delivers several wheel events per refresh and a
non-passive listener is not coalesced, so drawing inside it rasterizes and presents three surfaces for one displayed frame, off vsync.
Measured at 2880x1800: 90 events cost 90 frames where 30 were shown, and 93% of the main thread — which is the "scroll is not smooth"
report. The toolkit accumulates the burst and the frame spends it once; `mac/window.zig` already worked that way, because AppKit
invalidate-only draws at the next display refresh. `web/smoke.mjs` pins the invariant that makes coalescing safe: the same total travel
lands at the same pixel whether it arrives as one event or six.

A trackpad on Linux sends axis events only while the fingers move — libinput has no kinetic scroll, and the browser exposes no gesture
phase — so a flick used to stop dead the moment the fingers left the pad. The ENGINE now supplies the coast, in `core/momentum.zig`: it
measures the gesture's speed from the delta a frame actually carried (bounded to 3000 pt/s, so a burst of events cannot become a lurch, and
a frame that reverses direction is a new measurement rather than an average), waits out a 64 ms silence, then spends a velocity decaying at
`e^-3.6t` until it falls under 90 pt/s. That silence is the whole reason an OS animating the flick itself is never doubled: macOS and
Windows deliver their momentum as more wheel events, one per refresh, so the gap never opens; a hand that came to rest before lifting
leaves a speed too low to glide. The gap is measured in frames, so `Glide.pending()` keeps the backend drawing through it — otherwise
nothing would ever wake the coast — and a coast that moves nothing (the list is at its end, or no list is under the pointer) ends at once
rather than drawing a second of identical frames. `ci/check_test_parity.sh` counts the behaviour in `core/momentum.zig` and two `host.zig`
tests, and `web/smoke.mjs` asserts the coast in the wasm module itself.

**A detent is an impulse, not a gesture, and only a measured gesture may coast.** That same coast was handed to a mouse wheel, where it
did not belong: a WINDOWS notch is ONE `WM_MOUSEWHEEL` worth 60 points in ONE frame, macOS sends 1-3 the same way, and two notches are
50-200 ms apart — so the 64 ms gap opens between them and every single notch bought a 3000 pt/s glide, which is 784 points of travel the
user never asked for (844 for one 60-point notch, measured). The engine now needs `min_samples` = **3** frames of one gesture to carry a
delta before it may invent motion of its own, with `sample_gap_s` (1/30 s) as the boundary between one gesture and the next: a continuous
device reports on frame after frame, while a detent, a scrollbar jump and a Home key are each a single frame of delta with no speed in them
to hand over. Three is what keeps a wheel spun by hand out (three notches inside 33 ms is 90 a second, faster than a hand turns one) while a
trackpad flick, twenty-odd frames long, is never in doubt. `Glide.pending()` gates on the same count, so a notch no longer asks its backend
for the four frames it used to spend on a coast that was not there.

## Allocation discipline

A dynamic allocator is not the default. Before adding or keeping one, name the owner, the lifetime, and the maximum size.

- **Fixed and lifetime-known:** use a value, a static array, or `std.heap.FixedBufferAllocator` over storage that outlives every slice. Reset and reuse scratch between frames; never call the dynamic allocator's `free` on fixed storage.
- **Configurable but usually bounded:** keep a fixed fast path and fall back to the caller's allocator only above the inline capacity. `core/frame.zig` does this for the duplicate-id set: Clay's default ceiling fits 16,384 inline slots, while a raised ceiling still works.
- **Unbounded or externally sized:** keep the allocator. App text and undo history, font/glyph caches, image pixels, window surfaces, renderer geometry, file-dialog paths, and terminal image encoders do not have an honest compile-time maximum.
- **Foreign-owned:** leave C shim objects, system-dialog results, and the wasm C-compat heap to their owner. A Zig fixed buffer cannot replace an API that requires `malloc`/`free`, and freeing such memory with another allocator is a bug.

`FixedBufferAllocator` is a bump allocator with last-allocation reclamation, not a general heap. It is not thread-safe, and interleaved allocations with different lifetimes will exhaust it even when the total live bytes would fit. Use it for one bounded scratch block or one arena-like lifetime, not as a drop-in replacement for `smp_allocator`.

The browser has exactly one UI per page, so `web/exports.zig` keeps the comptime-known `App`, key scratch, and route scratch in static storage. The terminal's nominal 80x24 headless capture uses a fixed 64 KiB buffer; this also removes the old mismatch where bytes were appended with `page_allocator` and freed with the window's allocator.

Prove the boundary, not just the happy path:

```sh
zig build test --search-prefix /usr --summary all
zig build test-tui --search-prefix /usr --summary all
zig build web --summary all && node web/smoke.mjs
```

A fixed-buffer behavior test should use `std.testing.FailingAllocator` with `fail_index = 0` to prove the normal path performs zero heap allocations, then exercise the exact capacity and the first byte above it. Assert the observable result as well: duplicate ids are still caught, output is still correct, and exhaustion truncates or returns an error instead of panicking.

## Dependencies

None. The package is std-only apart from the vendored Clay bindings and stb headers under
`vendor/`. Keep it that way — a dependency here becomes every consumer's dependency.
