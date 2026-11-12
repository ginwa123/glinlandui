//! Renderer facade used by the CPU frame path.
const common = @import("render_common.zig");
const soft = @import("render_software.zig");
const select = @import("select.zig");

pub const ImageFit = common.ImageFit;
pub const ImageRef = common.ImageRef;
/// Re-exported from render_common so `render.Draw` resolves on every platform, not just Linux hosts that compile renderer.zig.
pub const Draw = common.Draw;
pub const u32ToClayColor = common.u32ToClayColor;
/// The library's color type, re-exported next to `u32ToClayColor` so everything needed to turn a color into pixels is on one module.
pub const Color = @import("color.zig").Color;
pub const scaledDims = common.scaledDims;
pub const coverUv = common.coverUv;
pub const containBox = common.containBox;

/// The renderer the frame path drives.
pub const Renderer = select.Renderer;

/// Re-export the software surface type so platform windows can blit the pixels the renderer produced.
pub const Surface = soft.Surface;
pub const Image = soft.Image;
pub const fragRoundBox = soft.fragRoundBox;
pub const cornerRadiusVec4 = soft.cornerRadiusVec4;
pub const img_placeholder = soft.img_placeholder;
