//! The one Windows file that `@cImport`s the D3D11 shim header. It exists so `src/windows/renderer.zig` can stay pure Zig: that file is on `ci/check_layering.sh`'s pure list and `src/root.zig` compiles it on EVERY platform, so a `@cImport` there would make a macOS or Linux build parse the Windows SDK. The `usable` guard means even this file can be analysed elsewhere without a header: the untaken branch is never evaluated.
const builtin = @import("builtin");

/// True only where the shim can exist: the D3D11 half of the toolkit.
pub const usable = builtin.os.tag == .windows;

/// The plain-C surface of `shim.h` (vertices, segments, the GPU entry points).
pub const c = if (usable) @cImport({
    @cInclude("shim.h");
}) else struct {};
