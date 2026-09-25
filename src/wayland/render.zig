//! Renderer facade used by the CPU frame path.
//!
//! Linux keeps the real GLES3 backend. Every other supported host uses the
//! portable software rasterizer (`render_software.zig`) — a real renderer
//! that produces real RGBA8 pixels, not a stub. That is what lets the macOS
//! window blit genuine output and lets the shared pixel-assertion suite run
//! identically on every platform.
const std = @import("std");
const builtin = @import("builtin");
const common = @import("render_common.zig");
const soft = @import("render_software.zig");

pub const ImageFit = common.ImageFit;
pub const ImageRef = common.ImageRef;
pub const u32ToClayColor = common.u32ToClayColor;
pub const scaledDims = common.scaledDims;
pub const coverUv = common.coverUv;
pub const containBox = common.containBox;

/// The renderer the frame path drives. Production on Linux is the GLES3
/// backend; every other host — and every TEST build on any OS — is the
/// portable software rasterizer, which produces real pixels and has no
/// platform-specific tests. Selecting the portable backend under
/// `builtin.is_test` is what keeps the cross-platform test count identical.
/// The GLES3 backend itself is still tested, in the Linux-only `native-test`
/// step.
pub const Renderer = if (builtin.os.tag == .linux and !builtin.is_test)
    @import("render_gles3.zig").Renderer
else
    soft.Renderer;

/// Re-export the software surface type so platform windows can blit the
/// pixels the renderer produced.
pub const Surface = soft.Surface;
pub const Image = soft.Image;
pub const fragRoundBox = soft.fragRoundBox;
pub const cornerRadiusVec4 = soft.cornerRadiusVec4;
pub const img_placeholder = soft.img_placeholder;
