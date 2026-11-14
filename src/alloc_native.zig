//! The allocator for a NATIVE build.
const std = @import("std");

/// The process allocator.
pub const allocator = std.heap.smp_allocator;
