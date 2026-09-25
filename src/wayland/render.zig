//! Renderer facade used by the CPU frame path.
//!
//! Linux keeps the real GLES3 backend. Other supported host platforms use a
//! deliberately inert renderer: layout, input, components, and the headless
//! test harness still run, but no OpenGL context or pixel upload is implied.
//! This keeps platform CI meaningful without claiming a native Wayland window
//! works on a platform that does not ship its client libraries.
const std = @import("std");
const builtin = @import("builtin");
const common = @import("render_common.zig");

pub const ImageFit = common.ImageFit;
pub const ImageRef = common.ImageRef;
pub const u32ToClayColor = common.u32ToClayColor;
pub const scaledDims = common.scaledDims;
pub const coverUv = common.coverUv;
pub const containBox = common.containBox;

pub const Renderer = if (builtin.os.tag == .linux)
    @import("render_gles3.zig").Renderer
else
    struct {
        /// A real GPU renderer is a Linux/Wayland responsibility today.
        /// The portable backend exists only so the same Clay frame pipeline
        /// can be compiled and tested on macOS CI.
        pub fn init(_: std.mem.Allocator) !Renderer {
            return .{};
        }

        pub fn deinit(_: *Renderer) void {}

        pub fn drawCommands(_: *Renderer, _: []const @import("zclay").RenderCommand, _: i32, _: i32) void {}
    };
