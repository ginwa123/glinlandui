//! glinlandui: platform-agnostic Clay GUI library.
//! Linux uses the native Wayland/EGL/GLES3 runtime; other supported hosts
//! use the CPU-only backend while preserving the same component, frame, host,
//! and headless-test surface. ZERO ui/* imports by design. Consumers do
//! `@import("glinlandui")`.
const builtin = @import("builtin");
const platform = @import("platform.zig");

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
    // The portable window backend + its headless-render test. This file has no
    // C imports and compiles identically everywhere, so its tests are part of
    // the parity count on Linux AND macOS. (It is NOT the platform selected by
    // platform.zig on Linux — that is linux/window.zig — it is imported purely so
    // its portable tests run everywhere.)
    _ = @import("core/window_portable.zig");

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
