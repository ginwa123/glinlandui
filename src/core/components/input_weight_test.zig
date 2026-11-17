// What a text field does with the row it sits in: `grow` is the weight, and a value never widens it.
const std = @import("std");
const cl = @import("zclay");
const headless = @import("../testing/headless.zig");
const prop = @import("../props.zig");
const frame_mod = @import("../frame.zig");
const input = @import("input.zig");

const Field = input.Field;
const textField = input.textField;
const beginFrame = input.beginFrame;

// One headless layout from a fresh Clay start, which is what a frame's first pass looks like.
fn layoutCommands(declare_fn: *const fn () void) ![]cl.RenderCommand {
    headless.begin(.{ .x = 99999, .y = 99999 }, false);
    cl.beginLayout();
    declare_fn();
    return cl.endLayout();
}

// One more frame on the same Clay context, which is the frame after a box became readable.
fn layoutFrame(declare_fn: *const fn () void) ![]cl.RenderCommand {
    cl.beginLayout();
    declare_fn();
    return cl.endLayout();
}

// A row shaped like an API client's URL row: a fixed button, the field, and a fixed button. The field is the weight.
var row_value: []const u8 = "https://api.example.com/v1/organizations/8f14e45fceea167a5a36dedd4bea2543/projects/9c1185a5c5e9fc54612808977ee8f548/members";

var row_field: Field = .{ .id = .{ .text = "test-row-field" } };

// The row's own width, so a test can show what a weight does when the room runs out.
var row_w: f32 = 600;

fn declareUrlRow() void {
    cl.UI()(.{
        .id = cl.getElementId("test-row.root"),
        .layout = .{
            .direction = .left_to_right,
            .sizing = .{ .w = .fixed(row_w), .h = .fixed(40) },
            .child_gap = 8,
        },
    })({
        cl.UI()(.{
            .id = cl.getElementId("test-row.method"),
            .layout = .{ .sizing = .{ .w = .fixed(96), .h = .fixed(30) } },
        })({});
        textField(&row_field);
        cl.UI()(.{
            .id = cl.getElementId("test-row.send"),
            .layout = .{ .sizing = .{ .w = .fixed(70), .h = .fixed(30) } },
        })({});
    });
}

test "a grow field is a weight: it takes the room left, and its value never widens the row" {
    frame_mod.setTime(0, 0);
    frame_mod.resetFocus();
    frame_mod.ptr_down = false;
    beginFrame();
    // A value far wider than the row, the case that used to widen the whole window and hide the button beside it.
    row_field = .{ .id = .{ .text = "test-row-field" }, .value = row_value, .w = .grow, .h = .{ .fixed = 30 } };
    row_field.bind();
    _ = try layoutCommands(declareUrlRow);
    const root = cl.getElementData(cl.getElementId("test-row.root")).bounding_box;
    const field = cl.getElementData(cl.getElementId("test-row-field")).bounding_box;
    const send = cl.getElementData(cl.getElementId("test-row.send")).bounding_box;
    // 600 - 96 - 70 - 16 of gaps: the weight takes the remainder and clips its value inside itself.
    try std.testing.expectApproxEqAbs(@as(f32, 418), field.width, 1);
    try std.testing.expectApproxEqAbs(@as(f32, 600), root.width, 0.5);
    try std.testing.expect(send.x + send.width <= root.x + root.width + 0.5);
}

test "a weighted field with a floor takes the remainder, and holds its floor in a narrow row" {
    frame_mod.setTime(0, 0);
    frame_mod.resetFocus();
    frame_mod.ptr_down = false;
    beginFrame();
    row_field = .{ .id = .{ .text = "test-row-field" }, .value = row_value, .w = .{ .clamp = .{ .min = 160, .grow = true } }, .h = .{ .fixed = 30 } };
    row_field.bind();
    _ = try layoutCommands(declareUrlRow);
    var field = cl.getElementData(cl.getElementId("test-row-field")).bounding_box;
    // The same remainder as above, because the floor of 160 never has to bind in a 600 pt row.
    try std.testing.expectApproxEqAbs(@as(f32, 418), field.width, 1);

    // A 200 pt row leaves 18 pt, so the floor is what holds, and the field stays usable.
    row_w = 200;
    _ = try layoutFrame(declareUrlRow);
    field = cl.getElementData(cl.getElementId("test-row-field")).bounding_box;
    try std.testing.expectApproxEqAbs(@as(f32, 160), field.width, 1);
    row_w = 600;
}

var weigh_a: Field = .{ .id = .{ .text = "test-row-a" } };
var weigh_b: Field = .{ .id = .{ .text = "test-row-b" } };

fn declareTwoWeights() void {
    cl.UI()(.{
        .id = cl.getElementId("test-row.two"),
        .layout = .{ .direction = .left_to_right, .sizing = .{ .w = .fixed(600), .h = .fixed(40) }, .child_gap = 8 },
    })({
        textField(&weigh_a);
        textField(&weigh_b);
    });
}

test "two weights split the row between them" {
    frame_mod.setTime(0, 0);
    frame_mod.resetFocus();
    frame_mod.ptr_down = false;
    beginFrame();
    weigh_a = .{ .id = .{ .text = "test-row-a" }, .value = "", .w = .grow, .h = .{ .fixed = 30 } };
    weigh_b = .{ .id = .{ .text = "test-row-b" }, .value = "", .w = .grow, .h = .{ .fixed = 30 } };
    weigh_a.bind();
    weigh_b.bind();
    _ = try layoutCommands(declareTwoWeights);
    const a = cl.getElementData(cl.getElementId("test-row-a")).bounding_box;
    const b = cl.getElementData(cl.getElementId("test-row-b")).bounding_box;
    // 600 less the 8 pt gap, halved: two weights get the same share, which is Clay's `GROW` between siblings.
    try std.testing.expectApproxEqAbs(@as(f32, 296), a.width, 1);
    try std.testing.expectApproxEqAbs(@as(f32, 296), b.width, 1);
}
