# The terminal backend (TUI)

glinlandui can run its **whole component library inside a terminal**: the same
`Window` / `Delegate` / `Renderer` contracts, the same `Host`, the same widgets.
It is an opt-in build flag, because a terminal is a different presentation target
and not a smaller desktop:

```sh
zig build -Dtui                 # build the engine, the demo and every example for a terminal
zig build -Dtui run-calculator  # an existing example, unchanged, in your terminal
zig build test-tui              # the backend's own suite (not part of `zig build test`)
```

Press <kbd>Ctrl</kbd>+<kbd>C</kbd> (or <kbd>Ctrl</kbd>+<kbd>Q</kbd>) to leave.

## Two tiers: pixels first, cells as the fallback

The requirement was *"the TUI framework should be able to do graphic rendering,
else roll back to the CPU"*, so the backend is built as a chain of tiers and the
best one that works wins:

| tier | what happens | when |
|---|---|---|
| `kitty` | the real RGBA framebuffer, base64 in 4096-byte chunks, `a=T,f=24` | kitty, Ghostty, WezTerm |
| `sixel` | the real framebuffer, quantised to a 216-cube + 24-grey palette, 6-row bands with `!n` run lengths | foot, mlterm, contour, yaft, iTerm2, xterm with sixel |
| `cells` | the CPU tier: the command stream painted into a character grid, ANSI truecolor / 256 / 16 | everything else, including a dumb pipe |

`GLIN_TUI_RENDERER=kitty|sixel|cells|auto` overrides the detection, which is by
environment (`KITTY_WINDOW_ID`, `TERM`, `TERM_PROGRAM`, `LC_TERMINAL`) — a DA1
round trip needs raw mode and a deadline, and the first frame is not the place to
argue about it.

**The rollback is a property of the renderer, not of the launch.** `drawCommands`
tries the pixel tier first; the moment a surface allocation or an encode fails it
sets `mode = .cells` and paints that same frame into the grid, so a terminal that
advertised kitty and then refused it shows the UI instead of a half-painted
screen. `Renderer.tier()` and `Renderer.lastError()` say what happened.

The pixel tiers are almost free: they rasterise through `core/render_software.zig`
— the same CPU rasteriser the browser and the headless tests use — and only the
encoder is new. The cell tier consumes the *same* `Clay_RenderCommandArray`.

## Why a cell frame lays out in cells

A terminal cannot draw an 8.4-point advance. The one change outside
`src/terminal/` is `text_face.setCellMetrics(.{ .w = 8, .h = 16 })`: while it is
installed, `measureText` answers `cells * 8` and `lineHeight` answers `16`. The
window then reports `cols * 8` × `rows * 16` points, so Clay lays out at exactly
the grid the terminal has, and **every existing component lands cell-for-cell**:
a button's label is its own width in cells, a text field's caret sits on a cell
boundary, a scrollbar's track is whole cells wide.

That is why cell mode is correct rather than approximate: nothing is quantised
after the fact. The metrics are installed by the window (cells tier) and cleared
by it on exit (and they are never installed at all in a pixel tier, which must
keep real glyph metrics or the raster would quantise twice).

## What the cell tier draws

| command | cell form |
|---|---|
| `rectangle` | background colour, alpha blended over what is underneath |
| `border` | box drawing — `┌ ┬ ┐ ├ ┼ ┤ └ ┴ ┘ ─ │` — from the box's own edges |
| `text` | one glyph per cell, double-width for CJK/emoji, whole cells only |
| `image` | a shaded block: a raster has no cell form, but its box still shows |
| `scissor_start/end` | a rectangular cell clip, intersected with its parent |

Frames are **diffed**: `ansi.zig` compares the new grid with the previous one and
emits only the changed cells, each run behind one cursor move and one SGR change.
A frame that draws the same thing again emits **zero bytes**.

The pixel tiers are diffed too, by a digest of the command stream: an idle redraw
(every 500 ms, so a caret keeps blinking) costs nothing until something actually
changes.

## Input

A terminal delivers bytes, the toolkit wants events. `src/terminal/input.zig` is a
streaming decoder — a sequence split across two `read`s waits for its tail — and
`keymap.zig` turns each one into the **evdev code** the rest of the engine already
speaks:

- printable bytes → a key press **and** `on_text` (typing never goes through the key chain);
- control bytes → `Ctrl` is announced down, the letter pressed, `Ctrl` released;
- `ESC [ A/B/C/D`, `ESC O A..D` → arrows; `ESC [ H/F`, `ESC [ n ~` → home, end, insert, delete, paging, F5–F12; `ESC O P..S` → F1–F4;
- `ESC [ 1 ; 5 C` → the modifier bits are pressed around the key, so `Ctrl+Right` reaches the engine as `Ctrl` down, `Right`, `Ctrl` up;
- SGR mouse (`ESC [ < b ; x ; y M/m`) → a press/release at the cell's centre in window points, buttons 272/273/274 on a transition and 0 on motion — exactly the contract `host.zig` expects, so drag, click and double-click work unchanged;
- the wheel (`b & 64`) → `on_scroll`, up negative;
- bracketed paste → `on_text`, so a pasted `ESC [ A` is text and not an arrow key;
- `Ctrl+C` / `Ctrl+Q` → quit. A terminal has no window manager; something has to always work.

Resize is polled (`TIOCGWINSZ` every 33 ms) rather than caught with `SIGWINCH`:
no signal handler, no `os.tag` outside `platform.zig`, and the same code shape on
every platform.

## Platforms

| platform | console | notes |
|---|---|---|
| Linux, macOS | `console_posix.zig` | `tcgetattr`/`tcsetattr` through libc (std.posix turns a closed stdin into `unreachable`), `poll` with a deadline, `ioctl(TIOCGWINSZ)` |
| Windows | `console_win32.zig` + `console_win32.c` | `ENABLE_VIRTUAL_TERMINAL_INPUT` makes the console deliver escape sequences, so **the same decoder runs everywhere**; `ENABLE_VIRTUAL_TERMINAL_PROCESSING` on output; the size comes from `GetConsoleScreenBufferInfo` |

`platform.zig` picks the console, and only there (`ci/check_layering.sh` R5). The
frame loop, the renderer, the encoders and the decoder are one shared
implementation (`window_core.zig` is generic over the console type).

A process with no tty (`Console.open` → `error.NotATerminal`) falls through to the
existing headless render, the same way a missing Wayland display does.

## Files

| file | role |
|---|---|
| `term.zig` | size, cell metrics, tier and colour-depth detection — pure |
| `cells.zig` | the character grid: rects, borders, text, images, clipping, diffing |
| `ansi.zig` | grid diff → escape bytes; truecolor/256/16 quantisers |
| `sixel.zig` | RGBA → sixel (palette, bands, `!n` RLE) |
| `kitty.zig` | RGBA → kitty graphics (chunked base64) |
| `renderer.zig` | the `Renderer`: tier chain, rollback, digest skip, last frame |
| `input.zig` / `keymap.zig` | escape decoder and evdev mapping |
| `window_core.zig` | alternate screen, raw mode, resize polling, frame loop |
| `console_posix.zig` / `console_win32.zig` (+ `.c`) | the console itself |
| `window_posix.zig` / `window_win32.zig` | the module `platform.zig` selects |

`src/terminal_test.zig` is the `test-tui` root: the encoders' byte-exact tests, the
grid's tests, a golden scene replayed in both tiers, and **a real component tree**
(box, text, button) painted into cells with a click fired through the cell grid.

## Verifying it

```sh
zig build test-tui --summary all          # 650 tests, no tty needed
zig build -Dtui -Doptimize=ReleaseSafe     # the engine, the demo and every example

GLIN_TUI_RENDERER=cells QS_SETTINGS_TEST_FRAMES=1 ./zig-out/bin/glinlandui
GLIN_TUI_RENDERER=sixel QS_SETTINGS_TEST_FRAMES=1 ./zig-out/bin/glinlandui
GLIN_TUI_RENDERER=kitty QS_SETTINGS_TEST_FRAMES=1 ./zig-out/bin/glinlandui
```

(`QS_SETTINGS_TEST_FRAMES` caps the frame count, exactly as it does for every
other backend, so a script can run one frame and exit.)

The CI job `tui` runs the suite and builds the flag on Linux, macOS and Windows;
on Linux and macOS it also drives the demo through a real pty (`script`) and
asserts a sixel frame arrived and that the cell frame contains the demo's own
labels.

## Limits, stated rather than hidden

- **A cell frame is not a pixel frame.** Rounded corners become square, a
  hairline border becomes a cell, an image becomes a shaded block, and a
  proportional font is drawn one cell per glyph (the layout was measured that way,
  so nothing overlaps — but it is a grid).
- **A sixel frame has no alpha.** Transparent pixels are the terminal's own
  background (P2=1), and the palette is 240 entries: a smooth gradient bands.
- **A kitty frame is ~1.4 MB** at 720×480, so it is only re-sent when the command
  stream changes.
- **No cursor shapes, no IME popup, no window controls.** `setAnimating` is not
  offered: a terminal frame is drawn on demand plus a 500 ms caret tick.
