//! The allocator for a WASM build.
const std = @import("std");

/// The module's allocator. One linear memory, grown on demand.
pub const allocator = std.heap.wasm_allocator;
