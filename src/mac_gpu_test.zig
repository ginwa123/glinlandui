//! Standalone test root for the macOS-only `test-macos-gpu` step: Metal must draw the CPU reference's pixels.
test {
    _ = @import("mac/metal_parity_test.zig");
}
