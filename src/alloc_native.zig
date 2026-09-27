//! The allocator for a NATIVE build.
//!
//! ## Why this is its own file
//!
//! `std.heap.page_allocator` reaches into `std.Io.Threaded` for its
//! `getrandom`-based initialisation, and `std.Io.Threaded` is an OS-threaded
//! reactor that cannot be analysed for a freestanding target. So merely
//! MENTIONING `page_allocator` in a file a wasm build compiles drags the whole
//! reactor in, and the wasm build fails with:
//!
//!     std/Io/Threaded.zig: struct 'posix.system' has no member named 'getrandom'
//!     std/posix.zig:       struct 'posix.system' has no member named 'IOV_MAX'
//!
//! A comptime `if` does not help: both branches of
//! `if (isWasm) wasm_allocator else page_allocator` are analysed, so the native
//! name is still resolved.
//!
//! The fix is the same one `platform.zig` already uses for `window`,
//! `render_impl` and `text_impl`: select by MODULE, not by expression. A wasm
//! build imports `alloc_wasm.zig` and never sees this file at all.
//!
//! This is the fourth native-only dependency to leak into the wasm graph in this
//! port (`libclay.a`, `zclay`'s archive, the entry-point root, and now
//! `page_allocator`). The rule they all teach: **on a wasm build, nothing native
//! may be mentioned, not even in an untaken branch.**
const std = @import("std");

/// The process allocator. The Clay arena outlives `run()` and is
/// process-lifetime, so this matches the harness convention (see
/// `core/testing/root.zig`).
pub const allocator = std.heap.page_allocator;
