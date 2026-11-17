//! The fixed command lists the raster gates share: the CPU golden test hashes them, and the Metal parity test replays them on the GPU.
const cl = @import("zclay");

pub fn rect(x: f32, y: f32, rw: f32, rh: f32, color: [4]f32) cl.RenderCommand {
    return .{
        .bounding_box = .{ .x = x, .y = y, .width = rw, .height = rh },
        .render_data = .{ .rectangle = .{ .background_color = color, .corner_radius = .{} } },
        .user_data = null,
        .id = 0,
        .z_index = 0,
        .command_type = .rectangle,
    };
}

pub fn roundRect(x: f32, y: f32, rw: f32, rh: f32, radius: f32, color: [4]f32) cl.RenderCommand {
    var c = rect(x, y, rw, rh, color);
    c.render_data.rectangle.corner_radius = .{
        .top_left = radius,
        .top_right = radius,
        .bottom_left = radius,
        .bottom_right = radius,
    };
    return c;
}

pub fn border(x: f32, y: f32, rw: f32, rh: f32, width: f32, color: [4]f32) cl.RenderCommand {
    return .{
        .bounding_box = .{ .x = x, .y = y, .width = rw, .height = rh },
        .render_data = .{ .border = .{
            .color = color,
            .corner_radius = .{},
            .width = .outside(@intFromFloat(width)),
        } },
        .user_data = null,
        .id = 0,
        .z_index = 0,
        .command_type = .border,
    };
}

pub fn textCmd(x: f32, y: f32, rw: f32, rh: f32, s: [:0]const u8, size: u16, color: [4]f32) cl.RenderCommand {
    return .{
        .bounding_box = .{ .x = x, .y = y, .width = rw, .height = rh },
        .render_data = .{ .text = .{
            .string_contents = .{ .chars = s.ptr, .base_chars = s.ptr, .length = @intCast(s.len) },
            .text_color = color,
            .font_size = size,
            .font_id = 0,
            .letter_spacing = 0,
            .line_height = 0,
        } },
        .user_data = null,
        .id = 0,
        .z_index = 0,
        .command_type = .text,
    };
}

/// A border whose sides differ: Clay's model is four widths, and a backend that draws one of them turns a left bar into a ring.
pub fn sideBorder(x: f32, y: f32, rw: f32, rh: f32, width: cl.BorderWidth, color: [4]f32) cl.RenderCommand {
    return .{
        .bounding_box = .{ .x = x, .y = y, .width = rw, .height = rh },
        .render_data = .{ .border = .{ .color = color, .corner_radius = .{}, .width = width } },
        .user_data = null,
        .id = 0,
        .z_index = 0,
        .command_type = .border,
    };
}

/// The colour every scene is cleared to. Shared so the CPU hash and the GPU comparison start from the same pixels.
pub const clear: [4]f32 = .{ 18, 18, 22, 255 };

pub const rects = [_]cl.RenderCommand{
    rect(0, 0, 200, 40, .{ 30, 30, 36, 255 }),
    rect(10, 50, 80, 30, .{ 200, 80, 60, 255 }),
    rect(60, 60, 80, 30, .{ 60, 200, 120, 128 }),
    rect(100, 50, 90, 40, .{ 80, 120, 240, 255 }),
};

pub const rounded = [_]cl.RenderCommand{
    roundRect(10, 10, 90, 50, 8, .{ 210, 210, 220, 255 }),
    roundRect(30, 40, 90, 50, 12, .{ 40, 60, 90, 200 }),
    border(10, 80, 100, 30, 2, .{ 240, 200, 80, 255 }),
};

pub const text = [_]cl.RenderCommand{
    rect(0, 0, 200, 120, .{ 24, 24, 28, 255 }),
    textCmd(8, 8, 180, 18, "Hello, glinlandui", 14, .{ 230, 230, 235, 255 }),
    textCmd(8, 34, 180, 24, "0123456789", 20, .{ 140, 200, 255, 255 }),
    textCmd(8, 66, 180, 16, "{}[]()<>*&^%$#@", 12, .{ 200, 200, 200, 255 }),
};

pub const composite = [_]cl.RenderCommand{
    rect(0, 0, 200, 120, .{ 20, 20, 24, 255 }),
    roundRect(6, 6, 188, 30, 6, .{ 38, 38, 46, 255 }),
    textCmd(12, 10, 170, 16, "toolbar", 13, .{ 232, 232, 236, 255 }),
    roundRect(6, 44, 90, 40, 4, .{ 52, 90, 140, 255 }),
    border(6, 44, 90, 40, 1, .{ 120, 160, 220, 255 }),
    textCmd(12, 56, 78, 16, "ok", 14, .{ 255, 255, 255, 255 }),
    rect(110, 44, 84, 40, .{ 60, 60, 70, 128 }),
};

/// The selected row of a tree: a fill with a 2 pt bar down its left side, on each of three rows.
pub const side_bar = [_]cl.RenderCommand{
    rect(0, 0, 200, 120, .{ 20, 20, 24, 255 }),
    roundRect(8, 14, 184, 28, 4, .{ 34, 50, 73, 255 }),
    sideBorder(8, 14, 184, 28, .{ .left = 2 }, .{ 135, 169, 135, 255 }),
    roundRect(8, 46, 184, 28, 4, .{ 34, 50, 73, 255 }),
    sideBorder(8, 46, 184, 28, .{ .left = 2 }, .{ 135, 169, 135, 255 }),
    roundRect(8, 78, 184, 28, 4, .{ 34, 50, 73, 255 }),
    sideBorder(8, 78, 184, 28, .{ .left = 3 }, .{ 135, 169, 135, 255 }),
};

/// Every scene, with the name the failure message should use.
pub const all = [_]struct { name: []const u8, cmds: []const cl.RenderCommand }{
    .{ .name = "rects", .cmds = &rects },
    .{ .name = "rounded", .cmds = &rounded },
    .{ .name = "text", .cmds = &text },
    .{ .name = "composite", .cmds = &composite },
    .{ .name = "side_bar", .cmds = &side_bar },
};
