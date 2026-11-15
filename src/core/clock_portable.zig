//! A host with no monotonic source, which is every test build: 0 means "no clock", so a double click is never guessed at and a frame keeps its fixed.
pub fn monoMs(_: ?*anyopaque) i64 {
    return 0;
}
