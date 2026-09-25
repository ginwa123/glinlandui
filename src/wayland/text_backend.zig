//! Text facade.
//!
//! Production on Linux uses wayland/text.zig (pangocairo). Every other host —
//! and every TEST build, on every OS — uses text_portable.zig, the same
//! deterministic estimator with no native dependencies.
//!
//! The test-build rule is what keeps the cross-platform test count identical:
//! the parity suite must not pull in the native Pango-backed text module's
//! tests on Linux but not on macOS. Selecting the portable backend under
//! `builtin.is_test` makes both platforms analyze exactly the same text module,
//! so both report the same tests. The native text module is still tested — in
//! the Linux-only `native-test` step.
const std = @import("std");
const builtin = @import("builtin");
const portable = @import("text_portable.zig");

const use_native = builtin.os.tag == .linux and !builtin.is_test;

// Only the native module is imported when it is actually used, so a test or
// non-Linux build never touches the Pango-backed shim at all.
const native = if (use_native) @import("text.zig") else portable;

pub const TextExtent = native.TextExtent;
pub const ResolveFontError = native.ResolveFontError;
pub const resolveFont = native.resolveFont;
pub const estimatorExtent = native.estimatorExtent;
pub const hashMeasureKey = native.hashMeasureKey;
pub const extentCacheReset = native.extentCacheReset;
pub const pangoFamily = native.pangoFamily;
pub const measureText = native.measureText;
pub const extent_hits = native.extent_hits;
pub const extent_misses = native.extent_misses;
