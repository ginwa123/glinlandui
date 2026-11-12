//! Text facade.
const select = @import("select.zig");

/// The resolved backend.
const native = select.TextBackend;

pub const TextExtent = native.TextExtent;
pub const ResolveFontError = native.ResolveFontError;
pub const resolveFont = native.resolveFont;
/// Every candidate font path.
pub const fontCandidates = native.fontCandidates;
/// Read a font file whole — the only fs-shaped thing in the text surface, and the reason `core/glyphs.zig` (compiled by every build, wasm included) can.
pub const readFontBytes = native.readFontBytes;
pub const estimatorExtent = native.estimatorExtent;
pub const hashMeasureKey = native.hashMeasureKey;
pub const extentCacheReset = native.extentCacheReset;
pub const pangoFamily = native.pangoFamily;
pub const measureText = native.measureText;
pub const extent_hits = native.extent_hits;
pub const extent_misses = native.extent_misses;
