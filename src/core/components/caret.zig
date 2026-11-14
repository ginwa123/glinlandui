// The caret: one device pixel wide, snapped to the pixel grid, floated over the text in its own colour. It lives here so that an app cannot draw a caret

// wrong. Every mistake this primitive prevents was made once: a caret inserted as a `|` glyph (it took a character cell and the tail of the line jumped

// on every blink), a 1 pt bar at a fractional x (antialiased across two device pixels, bleeding into the glyph beside it), and a caret in the text

// colour (a bar across a digit read as a malformed character).
const cl = @import("zclay");
const Color = @import("../color.zig").Color;
const frame_mod = @import("../frame.zig");

// Where the bar sits vertically inside its parent.
pub const Align = enum {
    // Centred on the parent's height, for a single-line field.
    center,
    // Flush with the parent's top, for a line of a multi-line editor.
    top,
};

pub const Props = struct {
    // A unique id per caret, e.g. `IDI(field_id, 2)` or `editor.caret.N`.
    id: cl.ElementId,
    // Distance from the parent's left edge to the bar, in points. Snapped to the device grid for you.
    x: f32,
    // Bar height in points; a caret is usually a little taller than the font.
    height: f32,
    color: Color,
    anchor: Align = .center,
    // Extra offset from the attach point, in points.
    y: f32 = 0,
};

// Declare the bar. It floats, so it takes no space in the line and cannot reflow the text.
pub fn declare(props: Props) void {
    const attach: cl.FloatingAttachPointType = switch (props.anchor) {
        .center => .left_center,
        .top => .left_top,
    };
    cl.UI()(.{
        .id = props.id,
        .layout = .{ .sizing = .{ .w = .fixed(frame_mod.hairline()), .h = .fixed(props.height) } },
        .floating = .{
            // A decoration must not be hit-testable: capturing the pointer here makes the pointer-over set change every
            // time the caret blinks, which can flip the hover state of whatever is underneath it.
            .pointer_capture_mode = .passthrough,
            .offset = .{ .x = frame_mod.snapX(props.x), .y = props.y },
            .attach_to = .to_parent,
            .attach_points = .{ .element = attach, .parent = attach },
            .z_index = 2,
        },
        .background_color = props.color.toClay(),
    })({});
}
