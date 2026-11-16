//! The browser has no monotonic source bound into this build, so it reports 0: a double click is off rather than guessed at from a frame count.
pub fn monoMs(_: ?*anyopaque) i64 {
    return 0;
}
