//! Root for `zig build test-macos-gpu`: a package root at `src/` so the Metal test can reach both `core/` and `mac/`.
test {
    _ = @import("mac/metal_parity_test.zig");
}
