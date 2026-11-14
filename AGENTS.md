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

## Verify before you report

```sh
zig build                  # the library, the demo, and the calculator example
zig build test             # the cross-platform parity suite (442 tests on macOS)
zig build native-test      # Linux only: the Wayland/EGL/GLES3 backend
zig build run              # the demo window
zig build run-calculator   # the calculator example
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
src/linux/          Wayland / EGL / GLES3 backend
src/mac/            Cocoa backend, plus the Objective-C shim
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
the macOS one's decision logic (pure Zig, in `src/mac/`) through the parity suite itself.

## The macOS shim

`src/mac/shim.m` is the only untestable part of the toolkit. It owns the `NSWindow`, the `NSView`,
and the `NSOpenPanel`, and it makes **no decisions** — keycodes, the y-axis flip, the BGRA byte
order, resize coalescing and the file-dialog's extension mapping all live in Zig where they are
unit-tested.

It compiles with `-Werror`, and that is load-bearing: messaging a selector AppKit does not
implement is a clang *warning*, so without it the build passes and the app ships a runtime
`NSInvalidArgumentException` on every event.

## The performance gate

`zig build bench-lazy-scroll` measures `examples/lazy_scroll.zig` headless: 600 frames at 900x640,
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

Pixel checksums are NOT part of it: the three platforms use different fonts, so the glyphs differ
by design. What is comparable is the layout and the scroll, not the ink.

Changing the bench — the frame count, the size, the scroll speed — means changing
`ci/lazy_scroll_bench.expected` in the same commit. Those numbers are contractual.

## Scrolling and repaint

A gesture delta is in **points and moves that many points of content**. Clay multiplies a wheel delta by 10 internally
(`scrollPosition += scrollDelta * 10`), so `frame.wheel_factor` cancels it and every call site divides by it. Handing Clay the raw
platform delta makes a trackpad scroll ten times further than the fingers moved, which reads on screen as the list jumping and
rows flashing in and out of the virtualisation window.

A container's offset is looked up **by element ID** (`clay.getScrollOffsetById`), never with Clay's `Clay_GetScrollOffset()`: that one
matches the element being declared by pointer into the per-frame element array, which is stale mid-declare, so it silently returns zero
whenever an element earlier in the frame appears or disappears — a blinking caret was enough to snap a scrolled list back to the top of
its content for one frame, which is exactly the flash users report as "the list blinks".

A frame whose render commands are **identical to the previous frame's** is not presented: `frame.commandsRepeated()` is what the
Cocoa window checks before blitting, and a resize is never skipped. Re-presenting an unchanged surface is wasted work, and it is
the window through which any glitch in the blit or the composite reaches the eye as a blink.

`GLIN_FRAME_DIFF=1 ./app` reports the two cases worth chasing: commands identical but pixels different (the engine), and a small
changed frame with the colour it flipped between (a state flip, usually hover). Whole-area changes are scrolling and are
suppressed — they are not a bug.

## Dependencies

None. The package is std-only apart from the vendored Clay bindings and stb headers under
`vendor/`. Keep it that way — a dependency here becomes every consumer's dependency.
