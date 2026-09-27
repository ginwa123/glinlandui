//! The allocator for a WASM build.
//!
//! `std.heap.wasm_allocator` is the only allocator that grows a wasm module's
//! linear memory. `std.heap.page_allocator` compiles for a freestanding target
//! but its allocation path is a comptime-known `error.OutOfMemory`, so using it
//! here would fail every allocation at runtime with nothing in the logs.
//!
//! See `alloc_native.zig` for why the two live in separate files rather than in
//! two branches of one `if`.
const std = @import("std");

/// The module's allocator. One linear memory, grown on demand.
pub const allocator = std.heap.wasm_allocator;
