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
| Linux | Wayland (`xdg-shell`) | Vulkan | pangocairo | native, tested in CI |
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
- [Colors](#colors)
- [File and folder dialogs](#file-and-folder-dialogs)
- [Architecture](#architecture)
- [Terminal (TUI) backend](#terminal-tui-backend)
- [Testing](#testing)
- [End-to-end UI testing](#end-to-end-ui-testing)
- [Devtool: inspect a running app](#devtool-inspect-a-running-app)
- [Project layout](#project-layout)
- [Further reading](#further-reading)

---

## Requirements

- **Zig 0.16.0** (`minimum_zig_version` in `build.zig.zon`).
- **Linux** — a C toolchain plus:
  - `wayland-scanner` at `/usr/sbin/wayland-scanner` (used at build time for protocol codegen)
  - `wayland-client`, `vulkan`
  - the pangocairo stack: `cairo`, `pango-1.0`, `pangocairo-1.0`, `fontconfig`, `freetype`, `harfbuzz`, `gobject-2.0`, `glib-2.0` (with headers)
- **macOS** — Xcode command line tools (AppKit, Foundation, CoreGraphics).

Clay and stb are **vendored** (`vendor/`), so the build never needs the network.

---

## Quick start

```bash
git clone <this repo> && cd glinlandui

zig build run               # the demo app  (needs a Wayland display)
zig build run-calculator    # the calculator example (needs a Wayland display)
zig build run-todo          # the MVVM todo example — state, ViewModel, view, setContent
zig build run-lazy-scroll   # 10,000 virtualised rows, with a live frame-rate meter
zig build run-catalog       # every component on one screen, in the kit's palette

# No display? Both fall back to headless rendering and report painted pixels:
env WAYLAND_DISPLAY= ./zig-out/bin/glinlandui-calculator
#   window unavailable (NoWaylandDisplay); rendering headless instead
#   glinlandui calculator rendered 360x440 headless (158400 painted pixels, no display available)

# The full gate — all of these must pass before pushing.
zig fmt --check build.zig src examples
zig build test --summary all     # 682/698 tests passed (16 skipped)
./ci/check_test_parity.sh        # parity: 698 tests (matches tests.lock)
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

    /// The declare callback: everything the app draws happens here.
    fn root(ctx: ?*anyopaque, _: u32, _: u32) void {
        const self: *App = @ptrCast(@alignCast(ctx.?));
        components.box.box(.{
            .id = .{ .text = "hello.root" },
            .w = .grow,
            .h = .grow,
            .pad = glinlandui.props.Pad.all(16),
            .gap = 8,
        }, self, children);
    }

    fn children(self: *App) void {
        components.text.label(.{ .label = .{ .text = "Hello, glinlandui", .size = 20 } });
        components.button.button(.{
            .id = .{ .text = "hello.button" },   // the element id IS the E2E test tag
            .label = .{ .text = if (self.clicks == 0) "Click me" else "Clicked!" },
            .on_click = .{ .f = onClick, .ctx = self },
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

    var window = glinlandui.Window.init(alloc, .{
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

## State and MVVM

An immediate-mode app re-declares its whole tree every frame, so "where does the state live?" has one honest
answer: in a value that frame reads. Two small pieces make that shape ergonomic.

| module | what it gives you | Compose |
|---|---|---|
| `glinlandui.view_model` | `Store(T)` — one instance per screen, `onCleared` on leave | `ViewModelStore` + `viewModel()` |
| `glinlandui.theme` | `Theme` = colour roles + type scale, with `dark` / `light` | `MaterialTheme` |

There is **no state container and no composition runtime**, on purpose. A ViewModel owns a plain value, an
intent replaces it, and the next frame reads whatever it says — no observable, no collector, no version, no
slot table. Compose needs all of that because a composable may be skipped, cached or re-ordered; here the frame
*is* the recomposition. Two consequences worth knowing:

- **Replacing the state does not schedule a repaint.** The window repaints after every key and pointer event,
  and a click is dispatched *before* that repaint, so an intent the user raised is on screen in the next frame.
  An app that changes state from a timer asks the window for a frame itself (`Window.setAnimating`).
- **View-local state that must survive a frame is a field.** `remember` would need a slot table keyed by an id;
  a field on the screen's own struct is typed, inspectable, and needs no key.

```zig
const Vm = struct {
    state: State = .{},

    // An intent replaces the value. Its answer is for the caller: a draft it did not take stays in the field.
    pub fn add(self: *Vm, title: []const u8) bool {
        if (title.len == 0) return false;
        self.state = self.state.withTodo(title);
        return true;
    }

    pub fn onCleared(self: *Vm) void {}                // the store calls this when the screen goes away
};

const App = struct {
    store: glinlandui.view_model.Store(Vm) = .{},

    fn content(ctx: ?*anyopaque, w: u32, h: u32) void {
        const self: *App = @ptrCast(@alignCast(ctx.?));
        const vm = self.store.getOrCreate(Vm.init);     // `viewModel()`
        // ... declare the screen from `vm.state`
    }
};

var host = try Host.init(gpa, &app, App.content);       // `setContent { }`
```

Two lifetimes decide whether an app works, and each one is a bug the todo example hit first:

1. **Text handed to Clay must outlive the declare.** A composable returns before the frame is laid out, so a
   label built from a stack value points at dead memory. Copy it with `frame.formatText` / `frame.claimText`.
2. **A click callback's `ctx` must outlive the frame.** Clicks are dispatched *after* the declare returns, so a
   pointer to a local is already gone. Own the context on the screen's struct.

Two components already do the plumbing an app would otherwise repeat: `components.input.textField` takes a
`Field` that owns the look, the intents and the draft (buffer, caret, selection, measure) — declare it with
`textField(&field)` and the engine types into it, calls `on_change` and `on_submit`, and the app routes no
key at all — and `components.list` owns a list's rows, their ids, hover and per-row clicks (registering each
row's target before its box, so a button inside the row wins the hit test).

Every field also offers its own right-click card: **Cut, Copy, Paste and Select All** are always there, and
`Field.menu` appends the app's own rows after them — the engine calls the app's `on_select` with the app's OWN
index, so adding rows never shifts the four. A read-only field still shows all four and dims Cut and Paste,
because they would edit it. A right click takes the caret where it landed and keeps a selection it landed
inside, so Copy has something to copy.

`Field.multiline = true` makes the same field a text area: Enter types a new line (the caret moves onto it, per
line, with its selection drawn per line), Ctrl/Cmd+Enter raises `on_submit`, and a click picks a line before a
column — so an app that needs a body editor, a query pane or a notes box no longer hand-rolls one. Give it
`Field.scroll_id` (the enclosing `components.scroll` id) and it keeps the caret's line on screen as you type:
it asks for a reveal, and the `Host` applies it the moment the layout closes (`scroll.revealAfterLayout` →
`scroll.applyReveals`, because a box only exists after the layout). A caret whose line is out of view is not
drawn — it is a floating bar, which an enclosing scroll's clip cannot cut. The field also
owns the clipboard: Ctrl/Cmd+C, +X and +V copy, cut and paste its selection through the system pasteboard
(`Field.clipboard` is the seam a test replaces, so a headless suite needs no pasteboard).
`components.box` takes `on_click` for the same reason: a clickable container registers its own hit target and
cursor, and a clickable child still wins a click over the box that contains it.
`components.sidebar` is the third: a resizable, collapsible panel that owns its width and its grab line, so an
app hands it children and reads `state.width` next frame instead of tracking a drag itself — dragging the line
past `collapse_below` snaps the panel shut, and clicking the line brings it back.
`components.split` is the same gesture for one pane: `grip(props)` declares the draggable line, the app gives its
pane `split.size(props)` and lays the two panes out around the call. `axis` picks a horizontal line (drags height,
`ns_resize` cursor) or a vertical one, `side` says whether the sized pane sits before or after the line, and
`min`/`max` clamp it. The line registers no click, only a hover cursor and a drag, so it never swallows one.

An app draws with components, never with Clay: `glinlandui` does not re-export the bindings, so a view that
wants a box, a label or a field uses `components.*`. What an app may need from the engine is on `frame`
(`elementId`, `clayId`, `bounds`) and `scroll` (`view`).

`examples/todo/` is the worked example, and its README is the full Compose-to-glinlandui mapping table.

---

## Colors

Every color-bearing prop is a `glinlandui.Color`. It is the same 32 bits the
old `u32` props held, so it stays copyable and `==`-comparable — but you can now
write a color the way you actually received it:

```zig
const Color = glinlandui.Color;

// Four ways in. Use `hexC` for a constant, `hex` when the string is runtime data.
const primary = Color.hexC("#6200EE");   // hex string   (from a design tool)
const accent  = Color.rgb(98, 0, 238);   // 0-255 ints   (from legacy code)
const ghost   = Color.rgbF(.38, 0, .93); // 0-1 floats   (from a spec)
const ink     = Color.argb(0xFF6200EE);  // ARGB hex     (a copied constant)

components.text.label(.{
    .str = "Hello",
    .color = primary,                 // hand the Color straight to a prop
});
```

A palette is a block of constants, which is why `hexC` exists — a typo is a
**compile error** that names the bad literal, not a runtime surprise:

```zig
const COLOR_BG   = Color.hexC("#101014");
const COLOR_FG   = Color.hexC("#f0f0f5");
const COLOR_ERR  = Color.hexC("#ff6b6b");
```

Beyond construction:

| | |
|---|---|
| `c.r() c.g() c.b() c.a()` | channels, 0-255 |
| `c.isOpaque()` | is alpha fully 255? |
| `c.withAlpha(128)` / `.withAlphaF(0.5)` | fade, keeping RGB |
| `Color.lerp(from, to, t)` | blend for hover/press states, `t` clamped |
| `c.toClay()` | `[4]f32` for Clay (0-255, **carries alpha**) |
| `c.toU32()` | `0xRRGGBB` for a pre-`Color` consumer (**drops alpha**) |
| `c.hexString(&buf)` | write `"#rrggbb"` / `"#rrggbbaa"` into your buffer |

**One asymmetry worth knowing:** alpha is stored, but only `toClay()` carries it.
`toU32()` drops it because 0xRRGGBB has no room for it. So
`Color.rgba(255, 0, 0, 128)` reaches the screen translucent through a Clay
config field and opaque through `toU32()`. Nothing silently discards a channel
you asked for — the two outputs just report what each format can hold.

Rendering works exactly as before: props are `Color`, and the widgets hand
`.toClay()` to Clay. `render.u32ToClayColor` still exists as a legacy shim for a
pre-`Color` caller and now delegates to the same `Color` rule, so the GPU and
CPU backends cannot drift apart.

---

## File and folder dialogs

`glinlandui.file_dialog` opens the system file picker, on all three desktop
platforms:

| host | what it runs | how it is reached |
|---|---|---|
| Linux | the **XDG Desktop Portal** | D-Bus, in **pure Zig** — no `libdbus`, no new system dependency |
| macOS | `NSOpenPanel` | through `mac/shim.m` |
| Windows | `IFileDialog` | through `windows/shim.c` |
| browser | — | `error.Unsupported`; see below |

One API, three unrelated system dialogs:

```zig
const pick = glinlandui.file_dialog.openFolder(alloc, .{
    .title = "Choose a workspace",
    .current_folder = "/home/u",
}) catch |err| {
    // The error set is per BACKEND, so this matches on the NAME (see below).
    const name = @errorName(err);
    if (std.mem.eql(u8, name, "Unsupported")) {
        return;                                 // no dialog backend here
    } else if (std.mem.eql(u8, name, "NoPortal")) {
        tellUser("install xdg-desktop-portal");
    }
    return err;                                 // the rest is the backend's own
};
defer pick.deinit(alloc);

switch (pick.status) {
    // `pick.paths` is BORROWED from `alloc` — copy it before the defer runs.
    .selected => openWorkspace(copyOf(pick.first().?)),
    .cancelled => {},                 // the user pressed Escape: not a failure
    .other => {},
}
```

`openFile`, `openFolder` and `saveFile` take one `Options` and return one
`Selection`, and the **types** are shared across every platform (see
`src/core/file_dialog_contract.zig`) — which is why the call above compiles
on Linux, macOS and Windows alike. The **error set** is the one thing that is
not shared, and that is the next section.

### The error set is per backend, so match on the name

`src/core/file_dialog_contract.zig` defines one `Error` set with five named
members and documents the obvious call shape:

```zig
catch |err| switch (err) {
    error.Unsupported => ...,
    else => ...,
};
```

**That switch does not compile.** The error set belongs to the *backend*, and
the backends do not agree on it:

| backend | what it declares | what's in it |
|---|---|---|
| `linux/file_dialog.zig` | `!Selection` — **inferred** | 23 errors: `NoSessionBus`, `NoPortal`, `PortalError`, `Timeout`, `OutOfMemory`, the socket errors, the D-Bus errors — and **no `error.Unsupported`**, because a portal client is always wired up |
| `mac/file_dialog.zig`, `windows/file_dialog.zig` | `!Selection` — **inferred** | the same shape: real backend, so no `Unsupported`; no D-Bus, so no `NoSessionBus` / `NoPortal` |
| `core/file_dialog_portable.zig` | `Error!Selection`, `Error = contract.Error` | all five names — it declares the contract's set and only ever returns `Unsupported` |

So `error.Unsupported` is a compile error on all three desktops, and
`error.NoPortal` is a compile error on macOS and Windows. An `else` does not
rescue it: Zig checks each arm against the set it is switching over before it
ever reaches the `else`. The shape above only compiled where the portable stub
is what `glinlandui.file_dialog` resolves to — a browser, or any test build,
since `platform.zig` selects the stub under `builtin.is_test`.

The fix is to match on `@errorName(err)`, as the sample above does. Zig cannot
`switch` on a string, so it is a short `std.mem.eql` chain — exactly what
`Machine.fromError` in the example does. It costs one string comparison on a
path that is already showing a dialog, and it compiles against every backend.
The five contract errors keep their own messages because they are the ones a
user can act on; everything else collapses into a catch-all, which is the
honest "the dialog could not be completed".

Narrowing every backend to `contract.Error` would make the documented switch
work again, and is the real fix — but it is a change to the error contract
rather than to a caller, because the contract has no name for `OutOfMemory`
and would need one. `contract.Error`'s own comment already says a backend may
return errors outside the five on purpose, so this is deliberate future work
rather than a bug to paper over at the call site.

The browser is the one host without a backend, and it is not a smaller version
of the same problem: a page's `<input type="file">` has no filesystem paths
and answers asynchronously, through a file handle the page can read but the
application cannot. The three functions return `error.Unsupported` there, and
`glinlandui.file_dialog.available()` is a constant `false` — which is what a UI
checks to decide whether to draw the button at all.

Three things about the Linux backend are worth knowing before using it:

- **It blocks.** A file dialog is modal: the application cannot do anything
  else while it is open, and on the Wayland backend the event loop is parked
  anyway. `Options.timeout_ms` is the escape hatch for an app with a deadline
  of its own; without it the call waits as long as the user takes.
- **A cancelled dialog is a `Status`, not an error.** The user closed the
  window on purpose. An app that treats that as a failure shows an error
  message for something nobody mistook.
- **The portal is a separate service.** A Wayland session with no desktop
  portal installed gets `error.NoPortal`, which is a different problem from
  "the user cancelled" and deserves a different message. macOS and Windows
  have no such failure: the dialog is a window in the process.
- **A filter list is best effort on Linux.** `Options.filters` is sent, and
  a portal that will not take it gets a second, plainer request instead of a
  dialog that never opens — see `portal.filters_signature` for what was
  measured, and why. The dialog opens either way; on a portal that refuses
  filters it simply has no filter dropdown.
- **`timeout_ms` is Linux-only.** It bounds the wait for the portal's answer.
  AppKit and COM own their own modal loops, and the only way to stop one is to
  post a cancel from a timer the host does not run while it is blocked. A host
  that needs a deadline should open the dialog on a worker thread.

### Run it: `zig build run-file-dialog`

`examples/file_dialog/` is all of the above, running: three buttons — one per
`Kind` — and a status line that says how the last dialog actually ended. It is
wired for Linux, macOS and Windows and deliberately **not** for the browser,
where there is no dialog to show and an example of `error.Unsupported` would
be an example of a string.

```bash
zig build run-file-dialog
```

Four things in it are the ones an app actually gets wrong:

| what | the rule |
|---|---|
| cancellation | it is a `Status`, not an error — `Outcome.isProblem()` deliberately excludes it |
| `Selection` | it **borrows** the allocator you passed in, so copy the path before `deinit` |
| errors | the set is per backend, so `fromError` matches on `@errorName` — see above |
| `available()` | gate the button on it; a button that cannot work is worse than no button |

The logic lives in a `Machine` with pure `fromSelection` / `fromError` rather
than in the click handler, and that is not tidiness for its own sake: it is what
puts the example's 8 tests in the cross-platform parity suite, where they run
on every OS against the real contract types with no window, no compositor and
no session bus in sight. The live XDG round trip is a different file
(`src/linux/file_dialog.zig`) and it is covered by `zig build native-test`.

### Running it without a desktop

```bash
GLIN_FILE_DIALOG_CHECK=1 zig build run-file-dialog
```

That opens no window and no dialog. It prints which backend this build resolved
to, what `available()` says, and how a real `openFile` call ends on this host —
a specific answer (`NoSessionBus` on a bare CI runner, `NoPortal` on a desktop
with no portal installed) rather than a green exit code. The probe passes
`timeout_ms`, so a developer running it on a machine that *can* show a dialog
gets an answer in two seconds instead of a modal window nobody is there to
dismiss. This is the mode CI runs, and it is a real check rather than a smoke
test: the call it makes is the same `glinlandui.file_dialog` the GUI path calls,
so it proves the module resolved, the types are the ones the contract promises,
and the backend reports itself honestly.

### How it is put together

Every backend is the same two halves, and the halves are not the same size:

| file | what it is | in the parity suite? |
|---|---|---|
| `src/linux/dbus.zig` | the D-Bus wire format: framing, alignment, SASL, addresses | **yes** — pure, 30+ tests on every OS |
| `src/linux/portal.zig` | the FileChooser protocol: options, request path, response | **yes** — pure, 19 tests on every OS |
| `src/mac/file_dialog_model.zig` | the AppKit panel: which panel, and what a modal answer means | **yes** — pure, 14 tests |
| `src/windows/file_dialog_model.zig` | the IFileDialog: which COM class, which options, the 1-based filter index | **yes** — pure, 14 tests |
| `src/linux/file_dialog.zig` | the socket, the handshake, the wait | no — needs a real bus; tested in `native-test` |
| `src/mac/file_dialog.zig` / `src/windows/file_dialog.zig` | the wiring to the shim | no — needs AppKit or COM |

So the two things most likely to be wrong in each backend — *what to ask for*
and *what the answer means* — are in files the parity suite runs on **every**
platform, and only the call into the system dialog is untested. That is the
same bargain the rest of this repository makes with its shims, and it is why
`NSModalResponse` being OK = 1 and Cancel = **2** is a tested function rather
than an `if` in a file a Linux runner never opens.

What the macOS backend returns is a `file://` URL, and what the Windows one
returns is already a path — so the URI codec in
`src/core/file_dialog_contract.zig` has two users and the Windows backend does
not need it at all. One implementation, tested everywhere, beats two where one
of them is only tested on the OS that has it.

`zig build native-test` additionally runs a **live round trip**: the test
provides its own portal on the session bus, answers a real FileChooser call and
emits a real `Response`, and the client decodes it. It skips where there is no
session bus (a CI runner), and on a machine where a real portal holds the
`org.freedesktop.portal.Desktop` name it uses a name of its own instead. It is
worth the length: two bugs in this feature — a wrong SASL identity and an
object path announced as a string — produced no error at all. The bus simply
closed the connection, and only talking to a real bus found them.

## Clipboard

`glinlandui.clipboard` is the system pasteboard, and it is deliberately tiny:

```zig
var buf: [64 * 1024]u8 = undefined;
const text = glinlandui.clipboard.read(&buf);   // []const u8, empty when there is nothing
glinlandui.clipboard.write("SELECT 1");         // replaces the pasteboard's text
```

There is no allocation across the boundary: the caller owns the buffer and the
length comes back, so a clipboard larger than the buffer is truncated rather
than leaked.

- **macOS** (`mac/clipboard.zig`) uses `NSPasteboard` through the shim, so it is
  the same pasteboard every other app on the machine reads and writes.
- **Windows** (`windows/clipboard.zig`) uses the Win32 clipboard
  (`CF_UNICODETEXT`) through the shim, which is also where the UTF-16 conversion
  happens — the Zig side stays UTF-8, and a read costs no allocation.
- **Linux** (`linux/clipboard.zig`) has no single clipboard: Wayland owns the
  selection through a data device and X11 through its own. The backend runs the
  session's helper — `wl-copy`/`wl-paste` when `WAYLAND_DISPLAY` is set, else
  `xclip`, else `xsel` — and which one to run is decided by
  `linux/clipboard_model.zig`, which is pure and therefore tested on every OS.
  A session with none of them installed reads as empty and drops writes.
- **Anywhere else** (`core/clipboard_portable.zig`) is a no-op: `read` returns
  empty and `write` drops the text. The port exists on every target so a caller
  compiles everywhere.

`core/clipboard_contract.zig` holds the one ceiling and the two rules every
backend follows — `cap` and `trim` — so the numbers cannot drift per platform.

A declared `input.Field` already binds Ctrl/Cmd+C, +X and +V for you, through
the pasteboard above. What stays the app's is what "copy" *means*: an app that
draws its own editor calls `text_editor.copySelection`, `cutSelection` and
`paste` itself and hands them this clipboard. See `Text arrives two ways` in
`src/core/components/README.md` for the typing half.

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

### What a frame costs

Immediate mode has one cost model, and it is worth stating plainly: **a frame
costs what it DECLARES, not what the app's model holds.** Clay lays out every
element the callback opens, so a 10 000-row model of which 28 rows are declared
costs the same as a 28-row model.

Measured on the frame thread — declare + `endLayout` + the command digest, no
present and no raster — at 1280x840, `ReleaseFast`, Zig 0.16.0:

| declared | rectangles | + one label each | + a fresh string each frame |
|---|---|---|---|
| 100 | 0.04 ms | 0.05 ms | 0.12 ms |
| 500 | 0.22 ms | 0.27 ms | 0.64 ms |
| 1000 | 0.46 ms | 0.61 ms | 1.51 ms |
| 2000 | 1.27 ms | 1.55 ms | 3.38 ms |
| 4000 | 3.71 ms | 4.30 ms | 8.24 ms |
| 8000 | 10.17 ms | over the ceiling | over the ceiling |

Reading it:

- **~0.5 µs per element** up to a thousand, ~0.95 µs at four thousand. The curve
  is slightly superlinear, so nothing about it is free at scale.
- **A clip does not help the frame thread.** 4000 rows inside a scroll pane cost
  the same with a clip as without one — layout still visits every declared
  element. Culling (backgrounds included since #28) saves render commands and
  their digest work, not the layout pass.
- **Text is measured once per distinct string.** Static labels add ~0.15 ms per
  4000 rows; text that changes every frame roughly doubles the rectangle case,
  because every new string is a fresh `stb_truetype` measurement.
- **Budgets**: 60 Hz gives a frame 16.67 ms and 144 Hz gives it 6.94 ms, for
  layout *and* raster *and* present together. Keep declared elements in the low
  thousands, and virtualise anything that can grow.

#### The element ceiling

Clay sizes its per-element arrays from a ceiling: **8192 elements** by default. A
frame past it is truncated — Clay drops the tail of the tree. Since #29 that is a
panic in `Debug`, one `log.err` in `Release`, and nothing at all in a test build
unless the test installs `frame.capacity_error_sink`. An app that genuinely needs
more says so before its host exists, because the arena is measured from it:

```zig
frame.max_elements = 32_768; // before Host.init; memory grows linearly with it
```

Related, and cheaper: `frame.warn_past_elements` (4000 by default) makes the
engine log **once** on the frame that declares more than that. An app that
doubled its tree hears about it at the frame that did it, instead of from a
profiler a week later. Set it to 0 to turn the warning off.

#### Virtualisation is the pattern, and it is the only one

There is no declared-side skip and no subtree memo, deliberately. A memo in front
of immediate-mode layout is a retained tree wearing a disguise: the same
invalidation bugs, plus a cache to keep honest. What the engine gives you
instead is virtualisation — declare only the rows the viewport can show:

- [`examples/lazy_scroll`](examples/lazy_scroll) is the reference: 10 000 rows in
  the model, 28 declared per frame at 900x640 (`ci/lazy_scroll_bench.expected`),
  about 1.2 ms average on an M-series Mac *including* the software rasteriser.
  Model size never enters frame cost; only declared elements do.
- The `lazy-scroll` CI job runs that bench on macOS, Linux and Windows and gates
  both the work (identical numbers everywhere) and the timing.

The two present-side levers exist for the other tail of the problem — a frame
that is expensive to *draw* rather than to declare:

- `frame.commandsRepeated()` — true when this frame's commands are byte-for-byte
  the previous frame's. It is one FNV-1a digest, computed once per frame.
- `frame.memo_enabled` — makes the renderer skip the draw on such a frame. Off by
  default: presenting an identical frame again is usually cheaper than proving it
  was not needed.

---

## Terminal (TUI) backend

The same engine runs **inside a terminal**: the same `Host`, the same components,
the same `Window` / `Delegate` / `Renderer` contracts. It is a build flag, because
a terminal is a different presentation target rather than a smaller desktop:

```sh
zig build -Dtui                 # the engine, the demo and every example, for a terminal
zig build -Dtui run-calculator  # an existing example, unchanged, in your terminal
zig build test-tui              # the backend's own suite
```

It is **graphics first**: the real RGBA framebuffer is encoded with the kitty
graphics protocol or with sixel, so a terminal that can draw pixels gets the
pixel-identical UI (rounded corners, anti-aliasing, images). A terminal that
cannot falls back to the **CPU tier**, which paints the same command stream into a
character grid with ANSI truecolor and box drawing — and if a pixel encode fails
at runtime, the renderer rolls back to that grid mid-session instead of leaving a
half-painted screen.

The layout is measured in whole cells (`text_face.setCellMetrics`), so every
existing component lands cell-for-cell: a button's label is its own width in
cells, a caret sits on a cell boundary. `Ctrl`+`C` quits. `docs/terminal-backend.md`
is the design record.

## Testing

Six gates. They are cheap, and each one catches a class of mistake the others
cannot.

| gate | command | expectation |
|---|---|---|
| formatting | `zig fmt --check build.zig src examples` | silent |
| unit + parity suite | `zig build test --summary all` | `443/458 tests passed (15 skipped)` |
| locked test count | `./ci/check_test_parity.sh` | `parity: 458 tests (matches tests.lock)` |
| architecture | `./ci/check_layering.sh` | `layering: ok` |
| native backends (Linux only) | `zig build native-test --summary all` | `99/99 tests passed` |
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
> elsewhere 15 skip. The *total* is 458 either way, so parity holds — but it
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
  exactly why `examples/calculator/calculator_test.zig` imports the calculator as a
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

Runs the real Wayland/Vulkan/pangocairo tests. Deliberately **outside** the
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

The complete worked example is **`examples/calculator/calculator_test.zig`** — 15 tests
driving the real calculator (`examples/calculator/`) with no compositor, no GL
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

From `examples/calculator/calculator_test.zig`:

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

## Devtool: inspect a running app

Every app in this repository ships the inspector, and any app can: it is one line after the `Host` exists.

```zig
var host = try glinlandui.host.Host.init(alloc, &app, App.content);
defer host.deinit();
_ = glinlandui.devtools.attach(alloc, &host);
```

Right-click anywhere in the window and a context menu names the node under the pointer. **Inspect element** opens a
floating window with the component tree: id, role and label per row, expandable and scrollable. The footer describes
the selected node — box, clip rectangle, z, actions, flags, its label, its nearest ancestors — and two source lines:
`component` is the widget that drew it (`core/components/box.zig:62`, the path Zig reports relative to the module),
and `declared` is the app's own call site, when the app recorded one. `Escape` closes it, and the app underneath keeps
running and staying clickable outside the window.

A **search box** under the header narrows the tree to the nodes a query names: the tag (an id), the role, the label,
the field's value, the component file and the app's call site, all case-insensitive. Each hit keeps the ancestor path
that leads to it, drawn dim, so a hit is shown in the tree it belongs to and not in a flat result list, and the bar
counts the hits. `Enter` walks them and scrolls each row into view; `Escape` empties the box, and only the next
`Escape` closes the window, so a filtered tree never outlives its query. A query that *is* a number names a node by
its Clay id — the decimal the JSON prints as `hash` — so `1293847561`, `#1293847561` and `0x4d2b8c19` all find the
node whose tag you do not know. The box is the same `input.Field` an app declares, so the caret, the selection,
double-click word select, paste and macOS's composed-text route all work, and the engine types into it.

Every line of the footer is a target of its own: hovering lights it, a click marks it and puts its **value** on the
system clipboard — `core/components/box.zig:69`, `catalog/view.zig:112`, the id, the label — so a path or a hash can
be pasted where it is wanted instead of retyped. The mark stays on the line and the search bar says `copied`, which is
the panel answering "what did I just copy?".

Two things make an overlay inside the inspector work at all, and both are visible here: the overlay declares real
widgets that are deliberately **not** part of the app's tree (`semantics.pause()`/`unpause()`), so its own search box
never appears in the tree it searches; and a widget inside an overlay that swallows clicks passes a `click_z`, so its
own target answers above the panel's. `--query=TEXT` fills the box for a picture:

```sh
zig build inspect -- --app=catalog --shot=/tmp/tree.tga --query=button
```

### Where the code lives, and why the app has to say

`component` is inferred. `declared` cannot be: Zig has no caller location — `@src()` describes the expression that
calls it, there are no default arguments, and neither a generic nor an `inline fn` sees its call site (all three were
tried). So a widget takes the call site from the app:

```zig
box_mod.box(.{ .id = .{ .text = s.id }, .src = @src(), /* … */ }, ctx, children);
```

`examples/catalog/view.zig` does that for its cards and their heads, which is why those rows show
`declared catalog/view.zig:126` — module, file and line, so the name is unambiguous. Every other widget simply omits
it and shows only `component`.

The outline is how the two halves stay connected, and it works in both directions. Click a row in the tree and that
component is outlined and labelled in the app, so a name in the list is a place on the screen. The header's **pick**
button arms the other direction, like a browser's element inspector: whatever the pointer is over is outlined — the
deepest node under it, so a key inside a row names the key — and the next click opens that node in the window.

Nothing is painted over the app unless the window is open: a right-click on its own only raises the menu, which already
names the node it would inspect. Closing the window takes the outline with it.

The tree holds every widget that registers semantics (`button`, `input`, `list`, `tree`, `scroll`, …), every container
declared with `box`, and the parent of each. Text runs are not nodes: a Clay text element has no id, so it has no box a
devtool could point at.

Nothing is added to the app's frame cost while the window is closed — the overlay declares nothing when idle — and an
attached devtool turns on `resolve_semantics`, the same per-frame tree `testing.Driver` reads, so the nodes keep the
geometry the window draws from.

### `glinlanduidp`, the debug process

`glinlanduidp` is an **independent binary**: it imports nothing from this framework — no Clay, no examples, no library —
and drives a running app over its socket, the way `adb` drives a phone. `zig build` produces it once into
`zig-out/bin/`; after that it is just a program, and nothing about it depends on the app it talks to.

```sh
GLIN_DEVTOOLS=1 ./zig-out/bin/glinlandui-todo &    # the app serves itself
./zig-out/bin/glinlanduidp devices                 # todo
./zig-out/bin/glinlanduidp tree                    # the window's own tree, live
./zig-out/bin/glinlanduidp text todo.field "buy milk"
./zig-out/bin/glinlanduidp key 28                  # a new row appears, on screen
```

| verb | what it does |
|---|---|
| `devices` | the apps that are serving right now |
| `tree` · `json` | the component tree, as indented lines or as JSON |
| `pick X,Y` | the node under one point |
| `tap TAG` · `tap @X,Y` | press and release it |
| `longpress TAG` | hold the press, then release |
| `press` · `release TAG` | one half of a click |
| `move TAG` | move the pointer onto it |
| `scroll TAG DX,DY` | wheel over it |
| `swipe TAG DX,DY` | press on it and drag |
| `text TAG TEXT` | focus it, then type |
| `key CODE` | an evdev key code (28 Enter, 1 Escape) |
| `quit` | ask the app to close |

`-s NAME` picks the app when several are serving; with one, it is implied. The socket is
`$XDG_RUNTIME_DIR/glinlandui-<name>.sock` (or `/tmp` when there is no runtime dir): per-user, no port allocated, and a
file a killed app left behind is replaced on the next start. With `GLIN_DEVTOOLS` unset there is no socket, no thread
and no pipe — `serve` returns null and the frame loop's two hooks are a null check.

The service runs **in the app's own frame loop** — a request fires before the app declares, and its answer is
serialised after the tree is resolved — so the socket thread only ever moves bytes and never touches Host or GL state.
Linux has the wake path (the window polls the service's pipe beside the Wayland display fd, so a request wakes an idle
window). macOS and Windows report the service as unavailable until their own wake hook lands; the library still
compiles and runs there.

### Driving a headless run

`--do=ACTION`, repeatable and played in order, acts on a component by the tag the tree printed — the same actions
`glinlanduidp` sends to a live app, played against a run this process owns. The tree is printed
after the last action, in the same process, so the effect is visible:

```sh
zig build inspect -- --app=todo --do=type:todo.field:buy milk --do=key:28
```

That run starts with 7 nodes and prints 12: the typed text reached the field, Enter raised the app's intent, and the
new row, its checkbox, spacer and delete button are in the dump. The actions go through the same pointer and key path
a user does — nothing is faked, the app's own handlers run.

| action | what it does |
|---|---|
| `click:TAG` | press and release |
| `longpress:TAG` | hold the press across frames, then release |
| `press:TAG` / `release:TAG` | one half of a click, for a drag held by hand |
| `move:TAG` | move the pointer onto it |
| `scroll:TAG:DX,DY` | wheel over it, in points |
| `drag:TAG:DX,DY` | press on it and drag by DX,DY |
| `type:TAG:TEXT` | focus it, then type TEXT |
| `key:CODE` | press and release an evdev key code (28 is Enter, 1 Escape) |

`TAG` is the id the tree prints; `@x,y` addresses a point with no tag. A tag that is not found fails with the tag named
and a non-zero exit, so a script knows its selector was wrong rather than the app.

### Reading a tree with no app running

The repository also ships a headless runner that **links** the examples, so an agent can read a tree when nothing is
running. This one is repo-specific by design, and it is what `zig build inspect` runs:

```sh
zig build inspect -- --app=todo                      # indented lines
zig build inspect -- --app=calculator --json         # one JSON document
zig build inspect -- --app=todo --do=type:todo.field:ship it --do=key:28
```

`--app` is `demo`, `calculator`, `todo`, `catalog`, `file-dialog` or `lazy-scroll`; `--size=WxH`, `--frames=N`,
`--depth=N`, `--pick=X,Y` and `--do=ACTION` behave as they do over the socket. `--shot=PATH.tga` writes the frame with
the inspector window open, which is how a machine with no compositor can see what it is describing.

### Reading the tree from your own code

`glinlandui.devtools.snapshot.Snapshot.build(w, h)` returns the nodes of the last resolved frame as the same `Item`
records the window draws, so a `--dump` mode in any app is a few lines:

```zig
var driver = try glinlandui.testing.Driver.initOwned(alloc, &app, App.content);
driver.headless = true;                       // no GL, no window
try driver.start(.{ .width = 720, .height = 480 });
driver.frame();
const snap = glinlandui.devtools.snapshot.Snapshot.build(720, 480);
try snap.writeJson(&writer, .{});             // or snap.writeText(&writer, 16)
```

---

## Project layout

```
src/
├── root.zig          the public API. The ONLY file consumers import.
├── platform.zig      the ONLY file that branches on builtin.os.tag.
├── native_test.zig   test root for the Linux-only native backends.
├── main.zig          demo app (dogfoods the public surface).
├── dp_main.zig       ★ `glinlanduidp`: the independent debug client (no framework import).
├── inspect_main.zig  the repo's headless runner: any example app's tree, no app running.
│
├── core/             platform-agnostic. Compiles identically everywhere.
│   ├── semantics.zig         ★ per-frame semantics model (E2E + future a11y)
│   ├── host.zig              Clay arena, input routing, frame scheduler
│   ├── frame.zig             per-frame boilerplate + command stream
│   ├── window_contract.zig   WindowConfig · Delegate · WindowState · geometry
│   ├── window_portable.zig   headless/CPU backend — ALSO the test backend
│   ├── file_dialog_contract.zig  ★ the file dialog's shared types (every OS)
│   ├── file_dialog_portable.zig  the dialog on hosts that have none yet
│   ├── select.zig            ← the one bridge from core to platform.zig
│   ├── render.zig            renderer facade        (consumes select.zig)
│   ├── color.zig            the Color type: every prop is one, not a u32
│   ├── render_common.zig     the drawing contract the drawing widgets import
│   ├── render_software.zig   CPU rasterizer (real pixels, real RGBA8)
│   ├── render_pixels_test.zig  pixel-assertion suite
│   ├── glyphs.zig            stb_truetype glyph rasterization
│   ├── text_backend.zig      text facade            (consumes select.zig)
│   ├── text_portable.zig     deterministic text estimator
│   ├── protocol_consts.zig   evdev codes + Wayland enum constants
│   ├── devtools/             ★ the inspector: tree snapshot, overlay window, CLI
│   ├── components/           15 widgets (box, button, input, scroll, …)
│   ├── testing/              ★ the E2E test layer
│   │   ├── root.zig              Driver + Interaction (onNode, performClick…)
│   │   ├── finders.zig           Query matchers
│   │   ├── actions.zig           gesture / scroll planning math
│   │   └── assertions.zig        node assertions
│   └── stb_{truetype,image}_impl.c   vendored library TUs
│
├── terminal/         the TUI backend (`-Dtui`): kitty/sixel pixels, CPU cells as the fallback
├── linux/            the Linux backend.  12 files, mirrored 1:1 with mac/
│   ├── file_dialog.zig   ★ the XDG portal client (socket + handshake + wait)
│   ├── file_dialog_model.zig  ★ the AppKit panel — PURE, tested on every OS
│   ├── dbus.zig          ★ the D-Bus wire codec — PURE, tested on every OS
│   └── portal.zig        ★ the FileChooser protocol — PURE, same
├── mac/              the macOS backend.  10 files, mirrored 1:1 with linux/
├── windows/          the Windows backend.  11 files, mirrored 1:1 with linux/

★ = the file dialog. See "File and folder dialogs" above.

examples/
├── calculator/               the example app (+ 36 tests) — calculator_test.zig is
                              ★ 15 E2E tests driving that app
├── file_dialog/              ★ the dialog how-to — 3 buttons, 8 tests
├── lazy_scroll/              10,000 virtualised rows + a frame-rate meter
└── todo/                     ★ MVVM the way Jetpack Compose does it — state, ViewModel,
                              composition (remember / collectAsState), view, setContent.
                              Its README is the Compose → glinlandui mapping table.

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
| `examples/calculator/calculator_test.zig` | the worked E2E example — read this first if you are writing tests |
| `examples/calculator/` | an app written against the public surface only |
| `examples/todo/README.md` | MVVM in an immediate-mode toolkit: the Compose mapping, and the three lifetime rules |

---

## Known limitations

Honest list; each is a reasonable next task.

- **Glyph rasterization is only exercised on macOS** (15 skipped tests). See
  `src/README.md` §5.
- **List rows carry no label** — the text comes from the caller's `renderItem`
  callback, so E2E tests select rows with
  `onNodeWithIndex(.{ .role = .list_item }, i)` rather than by text.
- **`box` registers semantics as a container, or as a button when it carries
  `on_click`**, and a container only contributes clip ancestry — so `scroll` is
  still the only element whose clipping a click is tested against.
- **No accessibility bridge.** The semantics tree is exactly what an AT-SPI / UIA
  backend would consume, but nothing wires it up yet.
- **Windows has a real backend** (`src/windows/`): a Win32 window composited by
  D3D11, and a GDI blit when the machine's driver cannot execute a shader — so
  the window is real either way and never blank. The example is wired there and
  CI runs the same assertions as on the other two platforms. What it does NOT
  have is a Direct3D *rasterizer*: the shared CPU rasterizer draws, and D3D11
  composites, exactly as CoreGraphics does on macOS. Only the Linux Vulkan path
  rasterises on the GPU.
- **The Linux clipboard needs a helper installed** (`wl-clipboard`, `xclip` or
  `xsel`) until the Wayland data-device protocol is implemented in the backend
  itself; without one, copy and paste are a no-op there and nowhere else.
- **`core/frame.zig` owns the cursor-shape mapping**, which is a Wayland
  `cursor-shape-v1` concern living in the platform-agnostic layer.
- **The file dialog's error set is per backend**, so the `switch (err)` that
  `core/file_dialog_contract.zig` documents does not compile. Only the
  portable stub declares `contract.Error`; the three desktop backends return
  an *inferred* set, and Linux's has no `error.Unsupported` in it at all. A
  caller has to match on `@errorName` until every backend is narrowed to
  `contract.Error`, which first needs a name for `OutOfMemory`. See "File and
  folder dialogs" above.
