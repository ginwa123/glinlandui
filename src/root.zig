//! glinlandui: platform-agnostic Clay GUI library.
const builtin = @import("builtin");

/// The composition root, exposed so an APPLICATION can reach the two things that genuinely differ between platforms: `platform.allocator` and.
pub const platform = @import("platform.zig");

// Clay bindings re-export: ui consumers must use `glinlandui.zclay` (not a second `@import("zclay")`) so Clay types crossing the library boundary.
pub const zclay = @import("zclay");

// Core surface.
pub const Window = platform.Window;
pub const WindowConfig = platform.WindowConfig;
pub const Delegate = platform.Delegate;
pub const render = @import("core/render.zig");
pub const text = @import("core/text_backend.zig");
pub const frame = @import("core/frame.zig");
pub const host = @import("core/host.zig");
/// The library's color type.
pub const Color = @import("core/color.zig").Color;
/// Portable software rasterizer surface.
pub const software_render = @import("core/render_software.zig");
/// Reusable, compositor-free UI test harness.
pub const testing = @import("core/testing/root.zig");
/// Per-frame semantics model: the queryable node tree behind `testing.Driver.onNode*`, and the intended home for accessibility and the debug inspector.
pub const semantics = @import("core/semantics.zig");

/// The text model every field uses: buffer, caret, selection, and every edit and movement. A single-line field is this with the newline ignored.
pub const text_editor = @import("core/text_editor.zig");

/// Table virtualisation: which rows and columns to draw, given a scroll position.
pub const table = @import("core/table.zig");

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

/// Deprecated pre-split name for the window facade, kept so consumers that spelled it `glinlandui.wayland_lib.*` keep compiling.
pub const wayland_lib = platform;

/// The file / folder / save-target dialog.
/// The system clipboard: `read(buf)` and `write(text)`. A no-op on a platform with no backend.
pub const clipboard = platform.clipboard;

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
    /// Whether this host can open a dialog at all — so a UI can hide the button rather than let the user click something that cannot work.
    pub const available = platform.file_dialog.available;

    /// A scriptable dialog a test installs, so the outcomes past the call — a selection, a cancellation, each backend error — are reachable without a.
    pub const fake = @import("core/file_dialog_fake.zig");
};

/// The browser backend's modules, for the wasm entry point (`src/web_main.zig`).
pub const web = struct {
    pub const window = @import("web/window.zig");
    pub const input = @import("web/input.zig");
    pub const adapter = @import("web/adapter.zig");
    pub const keymap = @import("web/keymap.zig");
    pub const present = @import("web/present.zig");
    pub const renderer = @import("web/renderer.zig");
    pub const text = @import("web/text.zig");
    /// The C-heap arithmetic.
    pub const compat_heap = @import("web/compat_heap.zig");
    /// The freestanding C runtime's `export fn` surface — `malloc`, `free`, `strtol`, the `str*` family.
    pub fn compatImpl() type {
        return @import("web/compat_impl.zig");
    }
};

// Agnostic reusable Clay components (moved from qs src/ui/components).
pub const components = struct {
    pub const box = @import("core/components/box.zig");
    pub const button = @import("core/components/button.zig");
    /// The caret primitive: one device pixel, snapped to the grid, floated over the text.
    pub const caret = @import("core/components/caret.zig");
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
    pub const tree = @import("core/components/tree.zig");
    pub const tabs = @import("core/components/tabs.zig");
    pub const badge = @import("core/components/badge.zig");
};

test {
    // This aggregate test block is the PARITY contract: it imports exactly the same portable modules on every platform, so `zig build test` runs an.
    _ = @import("core/testing/root.zig");
    // The semantics model and the E2E test surface built on it.
    _ = @import("core/semantics.zig");
    _ = @import("core/text_editor.zig");
    _ = @import("core/text_face.zig");
    _ = @import("core/audit.zig");
    _ = @import("core/audit_cases.zig");
    _ = @import("core/font_io.zig");
    _ = @import("core/table.zig");
    _ = @import("core/testing/finders.zig");
    _ = @import("core/testing/assertions.zig");
    _ = @import("core/testing/actions.zig");
    _ = @import("core/host.zig");
    _ = @import("core/frame.zig");
    _ = @import("core/render_common.zig");
    _ = @import("core/render_software.zig");
    // Real glyph rasterization for the CPU renderer (stb_truetype).
    _ = @import("core/glyphs.zig");
    _ = @import("core/render_pixels_test.zig");
    _ = @import("core/protocol_consts.zig");
    _ = @import("core/window_contract.zig");
    // The file dialog's shared contract, and the portable backend every non-Linux (and every test) build selects.
    _ = @import("core/file_dialog_contract.zig");
    _ = @import("core/file_dialog_portable.zig");
    _ = @import("core/clipboard_portable.zig");
    // The scriptable dialog a consumer's test installs.
    _ = @import("core/file_dialog_fake.zig");
    // The Color type every color-bearing prop uses.
    _ = @import("core/color.zig");
    // The macOS backend's keycode translation.
    _ = @import("mac/keymap.zig");
    // The macOS blit's pixel shuffle (channel order + row order).
    _ = @import("mac/present.zig");
    // The macOS event adapter: origin flip, resize coalescing, scroll normalisation.
    _ = @import("mac/adapter.zig");
    // The AppKit file panel's PURE half: which panel a request turns into, and what a modal answer MEANS.
    _ = @import("mac/file_dialog_model.zig");
    // The macOS pointer/button translation into the Delegate contract.
    _ = @import("mac/input.zig");
    // macOS's renderer/text modules.
    _ = @import("mac/renderer.zig");
    _ = @import("mac/text.zig");
    // The Linux backend's PURE role modules — the mirror image of the mac ones above, and here for the mirror-image reason: they live under src/linux/.
    _ = @import("linux/keymap.zig");
    _ = @import("linux/input.zig");
    _ = @import("linux/adapter.zig");
    // The XDG file dialog's PURE half, for the same reason as the three above: a D-Bus framing mistake or a mis-encoded `a{sv}` is a file dialog that.
    _ = @import("linux/dbus.zig");
    _ = @import("linux/portal.zig");
    // The Windows backend's PURE role modules — the mirror image of the mac and Linux ones above, for the same mirror-image reason.
    _ = @import("windows/keymap.zig");
    _ = @import("windows/input.zig");
    _ = @import("windows/adapter.zig");
    _ = @import("windows/present.zig");
    _ = @import("windows/renderer.zig");
    _ = @import("windows/text.zig");
    // The IFileDialog's PURE half: which COM class a request creates, the FILEOPENDIALOGOPTIONS it needs, and the 1-based filter index SetFileTypeIndex.
    _ = @import("windows/file_dialog_model.zig");
    // The portable window backend + its headless-render test.
    _ = @import("core/window_portable.zig");

    // The web backend's PURE parts — everything in src/web/ that makes a decision, as opposed to forwarding.
    _ = @import("web/compat_heap.zig");
    // The browser's event translations, added to the parity suite for exactly the reason the linux/ and mac/ ones are: a dropped evdev code or a swapped.
    _ = @import("web/keymap.zig");
    _ = @import("web/input.zig");
    _ = @import("web/adapter.zig");
    _ = @import("web/present.zig");
    // No tests, imported so they are TYPE-CHECKED on both platforms — the same trick mac/renderer.zig and mac/text.zig use.
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
    _ = @import("core/components/tree.zig");
    _ = @import("core/components/tabs.zig");
    _ = @import("core/components/badge.zig");
}
