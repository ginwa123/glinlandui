//! Windows renderer — the `renderer.zig` half of the platform mirror.
//!
//! ## Where Windows sits between the other two
//!
//! The three backends are NOT three copies of the same idea, and the whole
//! point of the mirror is that the difference is visible in one place:
//!
//!     linux/renderer.zig    GPU: EGL + GLES3. Rasterises the UI and uploads
//!                            the result. The only true GPU-rendering backend.
//!     mac/renderer.zig      CPU: the shared rasterizer, handed to CoreGraphics
//!                            (this file's Windows counterpart is identical).
//!     windows/renderer.zig  CPU: the shared rasterizer, handed to D3D11.
//!
//! So Windows presents on the GPU the way Linux does — a DXGI swap chain, a
//! texture upload and a shader, the same *role* linux/present.zig plays — but
//! the drawing itself happens in `core/render_software.zig` and only the
//! compositing is on the GPU. The payload therefore crosses the platform
//! boundary as a plain RGBA8 CPU surface, which is exactly what
//! `windows/present.zig` describes and why that module's claim ("the upload is
//! the identity") is a byte-order statement rather than a scaling one.
//!
//! Splitting it this way is what keeps the untestable surface small: the
//! untestable part is one HWND and one D3D11 device in `windows/shim.c`, and
//! every pixel that ends up on screen was produced by code with unit tests.
//!
//! Selection itself lives in the composition root (`src/platform.zig`), so this
//! module contains no OS branch: it is what Windows is told to use, not a
//! chooser.
pub const Renderer = @import("../core/render_software.zig").Renderer;

/// The CPU surface type the software renderer draws into. The D3D11 shim
/// uploads exactly this buffer, and `windows/present.zig` owns that hand-off.
pub const Surface = @import("../core/render_software.zig").Surface;
