//! glinlandui: platform-agnostic Clay GUI library.
//! Linux uses the native Wayland/EGL/GLES3 runtime; other supported hosts
//! use the CPU-only backend while preserving the same component, frame, host,
//! and headless-test surface. ZERO ui/* imports by design. Consumers do
//! `@import("glinlandui")`.
const builtin = @import("builtin");

/// The composition root, exposed so an APPLICATION can reach the two things that
/// genuinely differ between platforms: `platform.allocator` and
/// `platform.web_exports`.
///
/// This is what lets one `main.zig` serve Linux, macOS and the browser. The
/// alternative — a per-platform entry point — duplicated the Host setup, the
/// window config and the delegate wiring in every application, and differed only
/// in how the program starts, which `Window.run()` already abstracts.
///
/// It is `pub` rather than private because `src/main.zig` and
/// `examples/calculator.zig` are separate modules that import the library by
/// name; they cannot see a private declaration.
pub const platform = @import("platform.zig");

// Clay bindings re-export: ui consumers must use `glinlandui.zclay` (not
// a second `@import("zclay")`) so Clay types crossing the library
// boundary (Color, RenderCommandArray) share one module identity with
// render.
pub const zclay = @import("zclay");

// Core surface. `render`/`text`/`frame` are core facades: they resolve their
// backend through core/select.zig, so they are imported from core/ directly
// rather than forwarded by platform.zig (which would close an import cycle).
pub const Window = platform.Window;
pub const WindowConfig = platform.WindowConfig;
pub const Delegate = platform.Delegate;
pub const render = @import("core/render.zig");
pub const text = @import("core/text_backend.zig");
pub const frame = @import("core/frame.zig");
pub const host = @import("core/host.zig");
/// The library's color type. Build one from a CSS hex string, 0-255 ints,
/// 0-1 floats, or an ARGB literal, and hand it straight to a widget prop --
/// every color-bearing prop is a `Color`, not a `u32`. Pure and
/// platform-agnostic like the rest of core/.
pub const Color = @import("core/color.zig").Color;
/// Portable software rasterizer surface. Exposed so applications (and the
/// demo's headless fallback) can render real pixels without a display.
pub const software_render = @import("core/render_software.zig");
/// Reusable, compositor-free UI test harness. Import this module from
/// application tests to drive the same Host/Clay path used at runtime.
pub const testing = @import("core/testing/root.zig");
/// Per-frame semantics model: the queryable node tree behind
/// `testing.Driver.onNode*`, and the intended home for accessibility and the
/// debug inspector. Resolve it per frame with `frame.FrameOptions.resolve_semantics`.
pub const semantics = @import("core/semantics.zig");

// Pure utils (geometry / input / EGL / test-frames + legacy helpers).
pub const Placement = platform.Placement;
pub const computePlacement = platform.computePlacement;
pub const min_width = platform.min_width;
pub const min_height = platform.min_height;
pub const clampSize = platform.clampSize;
pub const keyToClose = platform.keyToClose;
pub const centeredAnchor = platform.centeredAnchor;
pub const LayerSize = platform.LayerSize;
pub const layerSize = platform.layerSize;
pub const eglConfigAttribs = platform.eglConfigAttribs;
pub const parseTestFrames = platform.parseTestFrames;

/// Deprecated pre-split name for the window facade, kept so consumers that
/// spelled it `glinlandui.wayland_lib.*` keep compiling. New code should use
/// the top-level names (`glinlandui.Window`, `glinlandui.render`, …).
pub const wayland_lib = platform;

/// The file / folder / save-target dialog.
///
/// `openFile`, `openFolder` and `saveFile` resolve per platform: the XDG
/// Desktop Portal on Linux (a pure-Zig D-Bus client, no libdbus), and
/// `error.Unsupported` everywhere else until a backend lands there. The types
/// (`Options`, `Filter`, `Status`, `Selection`) come from the shared contract
/// in `core/`, so an application writes ONE call and gets the same answer shape
/// on every host.
///
///     const pick = glinlandui.file_dialog.openFolder(alloc, .{
///         .title = "Choose a workspace",
///         .current_folder = "/home/u",
///     }) catch |err| switch (err) {
///         error.Unsupported => return,          // no dialog on this platform
///         error.NoPortal => showHint("no desktop portal installed"),
///         else => return err,
///     };
///     defer pick.deinit(alloc);
///     if (pick.status == .selected) use(pick.first().?);
///
/// A cancelled dialog is a `Status`, not an error: the user closed it on
/// purpose, and an app that treats that as a failure shows an error message
/// for something nobody mistook.
pub const file_dialog = struct {
    pub const Kind = platform.FileDialogKind;
    pub const Rule = platform.FileDialogRule;
    pub const Filter = platform.FileDialogFilter;
    pub const Options = platform.FileDialogOptions;
    pub const Status = platform.FileDialogStatus;
    pub const Selection = platform.FileDialogSelection;
    pub const Error = platform.FileDialogError;

    pub const openFile = platform.file_dialog.openFile;
    pub const openFolder = platform.file_dialog.openFolder;
    pub const saveFile = platform.file_dialog.saveFile;
    /// Whether this host can open a dialog at all — so a UI can hide the
    /// button rather than let the user click something that cannot work.
    pub const available = platform.file_dialog.available;
};

/// The browser backend's modules, for the wasm entry point (`src/web_main.zig`).
///
/// ## Why this exists rather than a relative import in the entry point
///
/// Zig rejects a file that belongs to two modules: `src/root.zig`'s aggregate
/// test block already imports every one of these, so a relative
/// `@import("web/window.zig")` from `src/web_main.zig` fails with
/// `file exists in modules 'root' and 'glinlandui'`. Re-exporting them here is
/// the only way the entry point can reach them, and it is also the honest
/// statement of the dependency — the entry point uses the library's public
/// surface, exactly as `src/main.zig` does.
///
/// ## What is deliberately NOT here
///
/// `web/compat_impl.zig` and `web/window.zig`'s allocator. `compat_impl.zig`
/// names `std.heap.wasm_allocator`, whose methods lower to `@wasmMemoryGrow` and
/// cannot be analysed on a native target — and this module IS analysed on Linux
/// and macOS by the parity suite. So the entry point imports that one file
/// relatively, and it is the only `src/web/` file it may do that with.
///
/// `web/window.zig` itself is reachable here only as a TYPE and a set of
/// methods; it is not selected by `platform.zig` on a native build, so importing
/// it costs a native build nothing but a type-check.
pub const web = struct {
    pub const window = @import("web/window.zig");
    pub const input = @import("web/input.zig");
    pub const adapter = @import("web/adapter.zig");
    pub const keymap = @import("web/keymap.zig");
    pub const present = @import("web/present.zig");
    pub const renderer = @import("web/renderer.zig");
    pub const text = @import("web/text.zig");
    /// The C-heap arithmetic. Pure and allocator-generic, so it is in the parity
    /// suite; `compat_impl.zig` (the `export fn` surface) is not, and is reached
    /// only from the wasm entry point.
    pub const compat_heap = @import("web/compat_heap.zig");
    /// The freestanding C runtime's `export fn` surface — `malloc`, `free`,
    /// `strtol`, the `str*` family.
    ///
    /// Re-exported so an application OUTSIDE `src/` can force it into the link.
    /// `src/main.zig` imports it relatively (both sit in `src/`), but
    /// `examples/calculator.zig` cannot: a relative path would escape its module
    /// root, which Zig rejects. So the library carries it, and the example
    /// references `glinlandui.web.compat_impl` in a `comptime` block.
    ///
    /// It is NOT in the parity suite and must not be: it names
    /// `std.heap.wasm_allocator`, whose methods lower to `@wasmMemoryGrow` and
    /// cannot be analysed on a native target. The reference is guarded by
    /// `isWasm` at every call site for that reason.
    ///
    /// Reached through a FUNCTION rather than a direct `@import`, because a
    /// direct import would put `web/compat_impl.zig` in this module — and the
    /// application root already imports it relatively, so Zig would reject the
    /// file for belonging to two modules (`file exists in modules 'root' and
    /// 'glinlandui'`). A function body is only analysed when called, and the
    /// call sites are all guarded by `isWasm`.
    pub fn compatImpl() type {
        return @import("web/compat_impl.zig");
    }
};

// Agnostic reusable Clay components (moved from qs src/ui/components).
// Namespaced under `components` so `components.text` (label widget) never
// collides with `text` (wayland font utils) above.
pub const components = struct {
    pub const box = @import("core/components/box.zig");
    pub const button = @import("core/components/button.zig");
    pub const checkbox = @import("core/components/checkbox.zig");
    pub const click_registry = @import("core/components/click_registry.zig");
    pub const dispatch = @import("core/components/dispatch.zig");
    pub const dropdown = @import("core/components/dropdown.zig");
    pub const icon = @import("core/components/icon.zig");
    pub const image = @import("core/components/image.zig");
    pub const input = @import("core/components/input.zig");
    pub const list = @import("core/components/list.zig");
    pub const radio = @import("core/components/radio.zig");
    pub const scroll = @import("core/components/scroll.zig");
    pub const slider = @import("core/components/slider.zig");
    pub const text = @import("core/components/text.zig");
    pub const toggle = @import("core/components/toggle.zig");
};

test {
    // This aggregate test block is the PARITY contract: it imports exactly
    // the same portable modules on every platform, so `zig build test` runs an
    // identical set of tests on Linux and macOS with an identical count.
    //
    // The native Wayland/EGL/GLES3/Pango tests are NOT here — they live in the
    // opt-in `native-test` step (Linux only) and never affect the default
    // cross-platform count. Keep this list platform-independent.
    _ = @import("core/testing/root.zig");
    // The semantics model and the E2E test surface built on it. They are
    // already reachable through core/testing/root.zig, but they are listed
    // here explicitly because this block IS the parity contract: every file
    // named here is type-checked on BOTH platforms, so a typo in the
    // Compose-style query/action/assertion layer fails on macOS too, not only
    // in CI's Linux leg.
    _ = @import("core/semantics.zig");
    _ = @import("core/testing/finders.zig");
    _ = @import("core/testing/assertions.zig");
    _ = @import("core/testing/actions.zig");
    _ = @import("core/host.zig");
    _ = @import("core/frame.zig");
    _ = @import("core/render_common.zig");
    _ = @import("core/render_software.zig");
    // Real glyph rasterization for the CPU renderer (stb_truetype). Tests that
    // need a font no-op where none is installed, so the COUNT stays identical
    // on every platform while the behaviour is still asserted wherever a font
    // exists.
    _ = @import("core/glyphs.zig");
    _ = @import("core/render_pixels_test.zig");
    _ = @import("core/protocol_consts.zig");
    _ = @import("core/window_contract.zig");
    // The file dialog's shared contract, and the portable backend every
    // non-Linux (and every test) build selects. Both are pure Zig, so the
    // types and the `error.Unsupported` behaviour are asserted on every
    // platform rather than only on the one that has a portal.
    _ = @import("core/file_dialog_contract.zig");
    _ = @import("core/file_dialog_portable.zig");
    // The Color type every color-bearing prop uses. Pure Zig and
    // platform-free, so it belongs in the parity suite like every other core
    // module: a hex-parsing bug is a bug on both OSes, not just CI's Linux
    // leg.
    _ = @import("core/color.zig");
    // The macOS backend's keycode translation. It is a pure table, so it
    // belongs in the parity suite on every platform: it proves macOS hands the
    // Delegate the same evdev codes Linux does, which is what keeps the widget
    // layer platform-free.
    _ = @import("mac/keymap.zig");
    // The macOS blit's pixel shuffle (channel order + row order). Pure, so it
    // is tested on every platform — a mistake there is the kind that renders
    // a plausible-looking but wrong window.
    _ = @import("mac/present.zig");
    // The macOS event adapter: origin flip, resize coalescing, scroll
    // normalisation. Pure, so the translations AppKit needs are tested here
    // rather than only observable in a running window.
    _ = @import("mac/adapter.zig");
    // The macOS pointer/button translation into the Delegate contract. The evdev
    // button code is what dispatch keys on, so a backend that reports 0 makes
    // every click a silent no-op; these tests drive the real dispatcher.
    _ = @import("mac/input.zig");
    // macOS's renderer/text modules. They contain no tests — they re-export the
    // shared core implementations, because macOS has no GPU path or native text
    // engine here — but they are imported so that every file in src/mac/ is at
    // least TYPE-CHECKED on Linux. macOS itself is not available to this suite,
    // and an unanalysed file is a file whose typos reach CI's macOS leg only.
    _ = @import("mac/renderer.zig");
    _ = @import("mac/text.zig");
    // The Linux backend's PURE role modules — the mirror image of the mac ones
    // above, and here for the mirror-image reason: they live under src/linux/,
    // which the suite never compiles, so importing them is the only thing that
    // type-checks the Linux event translation on a macOS runner. They contain no
    // tests, so the parity count is unchanged; what is gained is that a typo in
    // the Linux input path fails on BOTH platforms instead of only in CI's
    // Linux leg. linux/present.zig is deliberately absent: it @cImports EGL, and
    // the whole suite must stay C-free (layering rule R6).
    _ = @import("linux/keymap.zig");
    _ = @import("linux/input.zig");
    _ = @import("linux/adapter.zig");
    // The XDG file dialog's PURE half, for the same reason as the three above:
    // a D-Bus framing mistake or a mis-encoded `a{sv}` is a file dialog that
    // silently does the wrong thing, and `linux/file_dialog.zig` — which owns
    // the socket — is not in this suite. These two carry the entire wire
    // format, so their tests are the ones that would catch it, on macOS and
    // Windows as well as on Linux.
    //
    // `linux/file_dialog.zig` itself is deliberately ABSENT, exactly like
    // `linux/window.zig`: it opens a real socket to a real session bus, which
    // no CI runner has. Its live round trip — a fake portal on a real bus —
    // lives in the Linux-only `native-test` step (src/native_test.zig).
    _ = @import("linux/dbus.zig");
    _ = @import("linux/portal.zig");
    // The Windows backend's PURE role modules — the mirror image of the mac and
    // Linux ones above, for the same mirror-image reason. They live under
    // src/windows/, which the parity suite never compiles (a test build selects
    // core/window_portable.zig), so importing them is the only thing that
    // type-checks the Windows VK->evdev table, the pointer translation and the
    // D3D11 byte-order contract on a Linux or macOS runner.
    //
    // keymap.zig and input.zig contain tests, and those tests are part of the
    // locked cross-platform count: a Windows keycode typo is a typo the user
    // hits on Windows, and it is much cheaper to find it on every platform.
    // adapter.zig's and present.zig's tests are counted for the same reason.
    // windows/window.zig and windows/renderer.zig are deliberately ABSENT: the
    // first @cImports the shim, and the second is a two-line re-export that
    // `platform.zig` already pulls in on Windows. windows/text.zig is pure but
    // its font-path assertions are about a filesystem, so it is imported only
    // for its type-checking, not to assert anything about a particular
    // machine's fonts — see its own header for why.
    _ = @import("windows/keymap.zig");
    _ = @import("windows/input.zig");
    _ = @import("windows/adapter.zig");
    _ = @import("windows/present.zig");
    _ = @import("windows/renderer.zig");
    _ = @import("windows/text.zig");
    // The portable window backend + its headless-render test. This file has no
    // C imports and compiles identically everywhere, so its tests are part of
    // the parity count on Linux AND macOS. (It is NOT the platform selected by
    // platform.zig on Linux — that is linux/window.zig — it is imported purely so
    // its portable tests run everywhere.)
    _ = @import("core/window_portable.zig");

    // The web backend's PURE parts — everything in src/web/ that makes a
    // decision, as opposed to forwarding. The mirror-image reason to the
    // linux/ and mac/ entries above: a typo in a browser event translation or in
    // the C-heap arithmetic is a bug that would otherwise be reachable only by
    // opening a tab, and this suite makes it fail on Linux and macOS instead.
    //
    // What is deliberately ABSENT: web/window.zig and web/compat_impl.zig. Both
    // name `std.heap.wasm_allocator`, whose methods lower to `@wasmMemoryGrow`
    // and therefore cannot be analysed on a native target at all. They are
    // forwarding code by construction; the logic they forward to is here.
    _ = @import("web/compat_heap.zig");
    // The browser's event translations, added to the parity suite for exactly the
    // reason the linux/ and mac/ ones are: a dropped evdev code or a swapped
    // button number is silently wrong in a way only a real user notices, so it
    // must fail on Linux and macOS rather than only in a browser.
    _ = @import("web/keymap.zig");
    _ = @import("web/input.zig");
    _ = @import("web/adapter.zig");
    _ = @import("web/present.zig");
    // No tests, imported so they are TYPE-CHECKED on both platforms — the same
    // trick mac/renderer.zig and mac/text.zig use. Nothing here may cImport
    // (rule R6).
    _ = @import("web/renderer.zig");
    _ = @import("web/text.zig");

    _ = @import("core/components/box.zig");
    _ = @import("core/components/button.zig");
    _ = @import("core/components/checkbox.zig");
    _ = @import("core/components/click_registry.zig");
    _ = @import("core/components/dispatch.zig");
    _ = @import("core/components/dropdown.zig");
    _ = @import("core/components/icon.zig");
    _ = @import("core/components/image.zig");
    _ = @import("core/components/input.zig");
    _ = @import("core/components/list.zig");
    _ = @import("core/components/radio.zig");
    _ = @import("core/components/scroll.zig");
    _ = @import("core/components/slider.zig");
    _ = @import("core/components/text.zig");
    _ = @import("core/components/toggle.zig");
}
