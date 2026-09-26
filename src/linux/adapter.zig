//! Linux coordinate / scroll / resize adaptation — the `adapter.zig` half of
//! the platform mirror.
//!
//! ## Scope note
//!
//! `mac/adapter.zig` is the larger of the pair, and legitimately so: AppKit's
//! origin is bottom-left, its scroll deltas need clamping, and its resize
//! notifications arrive from a delegate callback that must be coalesced. Each of
//! those is a real correction.
//!
//! Wayland needs none of them. Surface coordinates are already top-left, the
//! compositor's axis values need no clamp, and a configure event is applied
//! directly by the frame loop. What is left is:
//!
//!   - pixel-cell hover dedup  (`pointerPosChanged`)
//!   - axis -> pending scroll delta (`applyScrollAxis`)
//!
//! Both live here rather than inline in `window.zig` so the two platform
//! folders can be read side by side. The resize/quit handling stays in the
//! frame loop, because it is interleaved with the frame-callback state machine
//! and splitting it out would be a restructure, not a move.
//!
//! ## The duplicate this file removes
//!
//! `pointerPosChanged` used to be DEFINED in `linux/window.zig` — byte-identical
//! to `core/window_contract.zig`'s copy. Two definitions of one rule is exactly
//! the drift hazard the contract exists to prevent, and on Linux the local copy
//! silently won. It is now re-exported, so there is one definition again.
//!
//! Pure Zig — no `@cImport` — so the parity suite type-checks it on macOS too.
//! See `ci/check_layering.sh` rule R6.

const contract = @import("../core/window_contract.zig");

/// Re-exported from the shared contract, NOT redefined. See the note above.
///
/// Hover/drag floods and sub-pixel repeats must not dirty the frame loop: the
/// app's `on_pointer` only stores x/y for click routing, so gating `needs_draw`
/// on pixel-CELL movement is sound, and exact f32 comparison would redraw on
/// invisible 1/256px jitter.
pub const pointerPosChanged = contract.pointerPosChanged;

/// Apply one `wl_pointer.axis` event to the window's pending scroll delta.
///
/// `axis` is the protocol enum: 0 = vertical, 1 = horizontal. Kept as the
/// original two-branch form — including its `else` fallback — so the extraction
/// is a pure move. The event is consumed by the frame loop, which hands the
/// delta to the delegate so Clay's scroll containers move.
pub fn applyScrollAxis(axis: u32, value: f32, dx: *f32, dy: *f32) void {
    if (axis == 0) {
        dy.* += value;
    } else {
        dx.* += value;
    }
}

/// The delta the delegate is told about for one axis event: only the axis that
/// actually moved is reported, so a vertical wheel tick does not look like a
/// horizontal drag.
pub fn scrollDelta(axis: u32, value: f32) struct { dx: f32, dy: f32 } {
    return .{
        .dx = if (axis == 1) value else 0,
        .dy = if (axis == 0) value else 0,
    };
}
