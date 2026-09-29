// glinlandui Windows window shim — plain C surface.
//
// This header is deliberately free of every Win32 and Direct3D type, for the
// same reason `mac/shim.h` and `linux/shim.h` are: Zig's @cImport only ever
// sees this file, so the D3D11/DXGI headers (and their COM macros) never have
// to survive translation. The implementation lives in `windows/shim.c`.
//
// The split of responsibility is the whole point of this shim:
//   - Zig owns ALL logic. Layout, rendering, hit-testing, the Delegate
//     contract, keycode translation, scroll clamping, resize coalescing.
//   - This shim owns ONLY the HWND, the D3D11 device/swap chain, and turning
//     Win32 messages into C callbacks. It makes no decisions.
//
// That is what keeps the untestable part small. The conversions that are easy
// to get silently wrong — the VK->evdev keycode table, the evdev button code,
// the RGBA8 byte order D3D11 samples — all live in Zig and are unit-tested in
// the cross-platform parity suite.
//
// Callbacks are invoked synchronously on the thread that called
// glin_win_window_run(), which for a Win32 GUI is the thread that owns the
// window (the process entry point, in every app in this repo).

#ifndef GLIN_WIN32_WINDOW_H
#define GLIN_WIN32_WINDOW_H

#ifdef __cplusplus
extern "C" {
#endif

/// Opaque handle to the window + its D3D11 swap chain.
typedef struct GlinWinWindow GlinWinWindow;

/// Called from the WM_PAINT handler before the shim composites. The host is
/// expected to render its frame and then call glin_win_present() with an
/// R,G,B,A buffer whose row 0 is the top row. Returns nothing: the shim does
/// not care whether a frame was produced, and clears the back buffer itself
/// when it was not — an unpainted swap-chain buffer is whatever the driver
/// last left there, which is how a "nothing happened" bug becomes an
/// unmissable screen of garbage.
typedef void (*GlinWinOnFrame)(void *user);

/// Pointer event. `kind` distinguishes MOTION from a button transition, which
/// the toolkit's dispatcher treats completely differently: motion carries a
/// button code of 0 (so it lands in the drag arm), while a transition carries
/// the evdev code the host translates to. Collapsing the two is what made
/// every click a silent no-op on macOS, so the distinction is explicit here
/// too — one ABI, one toolkit, one meaning.
///
/// `x`/`y` are in the CLIENT area's own space with a TOP-LEFT origin, which is
/// already the toolkit's convention: Win32 needs no y flip (see
/// windows/adapter.zig, which exists to pin exactly that difference).
/// `pressed` is 1 on a button-down transition, 0 on release, and MOTION's
/// `pressed` is filled in by the shim (it means "is the left button held").
/// `button_number` is 0 left, 1 right, 2 middle — the same numbering
/// `NSEvent.buttonNumber` uses, so the two shims are interchangeable.
typedef void (*GlinWinOnPointer)(void *user, int kind, int button_number,
                                double x, double y, int pressed);

/// Raw scroll deltas in Win32's convention (positive dy = wheel rotated away
/// from the user). The host clamps and negates them.
typedef void (*GlinWinOnScroll)(void *user, double dx, double dy);

/// Key event carrying the Win32 virtual-key code (NOT an evdev code — the host
/// translates). Return 1 if the key was consumed.
typedef int (*GlinWinOnKey)(void *user, int vk, int pressed);

/// Proposed size after clamping. Not applied immediately: the host coalesces
/// resizes and applies at most one per drawn frame.
typedef void (*GlinWinOnResize)(void *user, int w, int h);

/// The window's close button was pressed.
typedef void (*GlinWinOnClose)(void *user);

/// Ask the shim to redraw the window. The host MUST call this after any event
/// that changes what should be displayed. Win32 only sends WM_PAINT when the
/// update region is non-empty, and a toolkit that owns its own frame loop
/// never invalidates anything on its own — so without this a click advances
/// the state machine and nothing is ever painted.
void glin_win_invalidate(GlinWinWindow *win);

/// Create the window and the D3D11 device + swap chain. Returns NULL when the
/// window itself could not be created (no interactive window station, which is
/// what a fully headless service session looks like).
/// `min_w`/`min_h` of 0 disable the minimum size.
///
/// NOTE: a NULL return means "no window at all", NOT "no GPU". A machine with
/// no usable D3D11 driver still gets a window; glin_win_adapter_name() then
/// reports "none" and glin_win_present() clears the back buffer instead of
/// compositing, so the app stays alive and says so out loud.
GlinWinWindow *glin_win_window_create(const char *title, int w, int h,
                                      int min_w, int min_h);

void glin_win_window_destroy(GlinWinWindow *win);

/// Install the event callbacks. Must be called before run.
void glin_win_window_set_callbacks(GlinWinWindow *win,
                                   GlinWinOnFrame on_frame,
                                   GlinWinOnPointer on_pointer,
                                   GlinWinOnScroll on_scroll,
                                   GlinWinOnKey on_key,
                                   GlinWinOnResize on_resize,
                                   GlinWinOnClose on_close,
                                   void *user);

/// Run the Win32 message loop; blocks until the app quits.
/// `max_frames` of 0 runs until the user quits. A positive value stops after
/// that many PRESENTED frames, which is how the test harness gets a
/// deterministic, screenshot-able run instead of an interactive one.
void glin_win_window_run(GlinWinWindow *win, int max_frames);

/// Hand the D3D11 pipeline a frame to display. `rgba` must be `w * h * 4`
/// bytes of straight (non-premultiplied) R,G,B,A with row 0 the TOP row, which
/// is exactly `soft.Surface` and exactly the IDENTITY transform — see
/// windows/present.zig for why the identity is right and why the plausible
/// alternatives (swap R/B, flip rows) each produce a wrong-looking window
/// rather than an error.
///
/// If D3D11 cannot present the frame, the shim abandons the device and blits
/// the same buffer into the window's DC with GDI instead, so a host with a
/// broken GPU driver still shows a working window rather than a blank one.
/// The buffer contract does not change: a top-down 32-bit DIB takes row 0 as
/// its first row and its bytes in B,G,R,A order on screen, so the blit reads
/// the bytes back out in B,G,R,A. See `glin_win_present_mode`.
///
/// Safe to call with a NULL buffer or a zero dimension, in which case the
/// previous frame stays on screen.
void glin_win_present(GlinWinWindow *win, const unsigned char *rgba, int w, int h);

/// Ask the event loop to stop. Safe to call from any callback.
void glin_win_quit(GlinWinWindow *win);

/// The window's current client size in pixels (0 if the window is gone).
void glin_win_content_size(GlinWinWindow *win, int *out_w, int *out_h);

/// 1 when a D3D11 device and swap chain are live, 0 when the window fell back
/// to a clear-only back buffer.
int glin_win_d3d11_active(GlinWinWindow *win);

/// Which D3D11 driver type this window ended up on: "hardware", "warp" (the
/// Direct3D software rasterizer, which is what CI and VMs get) or "none".
const char *glin_win_adapter_name(GlinWinWindow *win);

/// How this window is ACTUALLY putting pixels on screen right now:
/// "d3d11" (a device and swap chain are live and the last Present succeeded),
/// or "gdi" (the Direct3D device was abandoned and frames are being blitted
/// into the window's DC with GDI).
///
/// Two reasons this is a query and not a constant. First, the choice can
/// change mid-run: a machine whose driver cannot execute a shader creates a
/// D3D11 device perfectly happily and only fails on the first real Present, and
/// a window that has already opened should not then sit there blank. Second,
/// the host has to be able to SAY which path ran, because "the calculator is
/// blank" and "the calculator is showing the wrong colours" need different
/// bug reports.
const char *glin_win_present_mode(GlinWinWindow *win);

/// Frames actually presented through the D3D11 swap chain so far. Zero on a
/// host that could not create a device, which is what makes it a usable
/// assertion for CI rather than just a log line.
int glin_win_presented_frames(GlinWinWindow *win);

/// Run `rgba` through the SAME D3D11 device selection, shader, sampler and
/// draw call the window uses, but into an offscreen target instead of a
/// swap-chain back buffer, and write the DISPLAYED bytes back into `out`.
///
/// This is the Windows counterpart of ci/check_macos_colors.c, and it exists
/// for the same reason: the identity transform documented in
/// windows/present.zig is only trustworthy if something actually checks the
/// colour that comes OUT of the GPU. It needs no window, no display and no
/// desktop, because WARP is a software rasterizer — so it is safe on a stock
/// Windows CI runner.
///
/// `out` must hold at least `h` rows of `out_stride` bytes. Returns 0 on
/// success and a negative value when D3D11 is unavailable on this host, so
/// the caller can report that rather than pretending the check passed.
int glin_win_probe_color(const unsigned char *rgba, int w, int h,
                         unsigned char *out, int out_stride);

// ---------------------------------------------------------------------------
// The file dialog.
//
// Same rules as everything above: plain C in, no COM type in this header, and
// NO DECISIONS. Which COM class a request creates, which
// FILEOPENDIALOGOPTIONS it needs and what the answer means are in
// `windows/file_dialog_model.zig`, which is pure Zig and unit-tested on
// every platform. This section owns the IFileDialog and nothing else.
// ---------------------------------------------------------------------------

/// One `COMDLG_FILTERSPEC` pair, flattened to plain C: a display name and a
/// SEMICOLON-separated spec ("*.png;*.jpg"). The joining is done by
/// `model.flattenFilters`, which is where the separator is tested — Windows
/// splits on ';', so a comma here produces one filter that matches nothing.
typedef struct {
    const char *name;
    const char *spec;
} GlinWinFileFilter;

/// Everything the dialog needs. Plain C so the shim takes one pointer and
/// Zig builds it in one place.
typedef struct {
    /// 0 = open a file, 1 = choose a folder, 2 = choose a save target.
    int kind;
    /// `FILEOPENDIALOGOPTIONS` as a bit field. Computed by the model, never
    /// here — the combinability rules (a folder dialog must not also insist on
    /// a file) are the part worth testing, and they live in the model.
    unsigned int options;
    /// 1-based, exactly as `SetFileTypeIndex` wants. 0 means "do not call it".
    unsigned int file_type_index;
    /// 0 means "no SetFileTypes call at all": passing an empty array installs
    /// a filter that matches nothing.
    int filter_count;
    const GlinWinFileFilter *filters;
    const char *title;
    const char *accept_label;
    const char *current_folder;
    const char *current_name;
    /// 1 when the dialog is modal to the calling window.
    int modal;
    /// The owner window as a raw HWND, or 0 for none.
    ///
    /// `IFileDialog::Show` takes this, and it is the difference between a
    /// dialog that is a child of the application window and one that merely
    /// looks like one: an unowned dialog can be moved independently and does
    /// not disable the window behind it. The toolkit has no portable handle to
    /// give here yet (see `windows/file_dialog.zig`), so this is 0 and the
    /// field exists so that fixing it is a one-line change rather than an ABI
    /// one.
    /// `unsigned long long`, not `uintptr_t`: this header deliberately has NO
    /// #include at all, so that @cImport never has to survive a platform
    /// header. That is why the cast in the shim goes through
    /// `(uintptr_t)` and not from here.
    unsigned long long owner_hwnd;
} GlinWinFileRequest;

/// One selected path, delivered as a UTF-8 C string valid ONLY for the
/// duration of the call.
///
/// Two things make this a callback rather than a returned array. The
/// `IShellItem` is released as soon as the loop moves on, so the shim cannot
/// keep it; and the path comes from a COM `LPWSTR` that the shim owns and
/// frees, so a pointer into it would be freed before the caller looked at it.
typedef void (*GlinWinOnPath)(void *user, const char *path_utf8);

/// Run the dialog and return 0 on success, or a negative value when it could
/// not be created, could not be shown, or the user cancelled.
///
/// Deliberately NOT a "response enum": Win32 has no such thing, and inventing
/// one that looks like AppKit's `NSModalResponse` would invite the two
/// backends' results to be read interchangeably — which is exactly the mistake
/// `mac/file_dialog_model.zig` documents (OK is 1, Cancel is 2) as easy to
/// make. 0 = the user chose something, -1 = cancelled, -2 = the dialog could
/// not be created, -3 = showing it failed.
int glin_win_file_dialog(const GlinWinFileRequest *request,
                        GlinWinOnPath on_path, void *user);

/// The byte order the D3D11 swap chain and the probe target are created in:
/// straight (non-premultiplied) R,G,B,A, alpha ignored by the blend stage
/// because the pipeline uses no blending. Exposed as a number rather than a
/// DXGI_FORMAT so that the CI check can assert the window and the probe agree
/// without including a Direct3D header.
#define GLIN_SWAP_FORMAT_RGBA8 1

#ifdef __cplusplus
}
#endif

#endif // GLIN_WIN32_WINDOW_H
