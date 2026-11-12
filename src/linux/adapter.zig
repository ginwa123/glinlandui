//! Linux coordinate / scroll / resize adaptation — the `adapter.zig` half of the platform mirror.

const contract = @import("../core/window_contract.zig");

/// Re-exported from the shared contract, NOT redefined.
pub const pointerPosChanged = contract.pointerPosChanged;

/// Apply one `wl_pointer.axis` event to the window's pending scroll delta.
pub fn applyScrollAxis(axis: u32, value: f32, dx: *f32, dy: *f32) void {
    if (axis == 0) {
        dy.* += value;
    } else {
        dx.* += value;
    }
}

/// The delta the delegate is told about for one axis event: only the axis that actually moved is reported, so a vertical wheel tick does not look like a.
pub fn scrollDelta(axis: u32, value: f32) struct { dx: f32, dy: f32 } {
    return .{
        .dx = if (axis == 1) value else 0,
        .dy = if (axis == 0) value else 0,
    };
}
