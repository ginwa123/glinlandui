//! Text facade.
//!
//! Production on Linux uses the pangocairo shim (`linux/text.zig`). Every other
//! host — and every TEST build, on every OS — uses `text_portable.zig`, the same
//! deterministic estimator with no native dependencies.
//!
//! The test-build rule is what keeps the cross-platform test count identical:
//! the parity suite must not pull in the native Pango-backed text module's tests
//! on Linux but not on macOS. Selecting the portable backend under
//! `builtin.is_test` makes both platforms analyze exactly the same text module,
//! so both report the same tests. The native text module is still tested — in
//! the Linux-only `native-test` step.
//!
//! As with `render.zig`, the selection lives in the composition root and arrives
//! here through `select.zig`, so this facade carries no OS branch.
const select = @import("select.zig");

/// The resolved backend. `platform.zig` imports the native module only in the
/// branch that uses it, so a test or non-Linux build never touches the
/// Pango-backed shim at all — that property is preserved by delegating the
/// choice rather than re-deciding it here.
const native = select.TextBackend;

pub const TextExtent = native.TextExtent;
pub const ResolveFontError = native.ResolveFontError;
pub const resolveFont = native.resolveFont;
/// Every candidate font path. The CPU glyph rasterizer needs the whole list
/// because the first file that merely EXISTS may be a TrueType collection,
/// which no rasterizer can load; it keeps the first that actually parses.
pub const fontCandidates = native.fontCandidates;
pub const estimatorExtent = native.estimatorExtent;
pub const hashMeasureKey = native.hashMeasureKey;
pub const extentCacheReset = native.extentCacheReset;
pub const pangoFamily = native.pangoFamily;
pub const measureText = native.measureText;
pub const extent_hits = native.extent_hits;
pub const extent_misses = native.extent_misses;
