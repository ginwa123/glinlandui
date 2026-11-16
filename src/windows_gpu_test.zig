// The Windows-only GPU test root: a package root at src/ so the parity test can import ../core.
test {
    _ = @import("windows/d3d11_parity_test.zig");
}
