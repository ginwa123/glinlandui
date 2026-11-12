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

## Lint status — read this before you add a rule

zginlint is **not wired into this build yet**. Run it by hand:

```sh
zig build -Dtarget=native   # in ../zglint, or use a pinned copy
../zglint/zig-out/bin/zginlint --max-comment-lines 1 src build.zig
```

Two things block the gate:

- **706 comment blocks are still multi-line.** The ceiling is 1; the tree has not been converted.
  New and changed code must comply — do not add a second line to a block you touch.
- **6 `std.log.warn` sites** (`src/core/frame.zig`, `src/linux/renderer.zig`,
  `src/linux/window.zig` ×3, `src/mac/window.zig`) trip `zginlint/no-std-log-warn`. Clearing them
  needs a global Logger that a test never installs, which this repo does not have yet. That
  migration is the prerequisite for wiring `zginlint:check` as a gate.

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

## Dependencies

None. The package is std-only apart from the vendored Clay bindings and stb headers under
`vendor/`. Keep it that way — a dependency here becomes every consumer's dependency.
