//! macOS text engine — the `text.zig` half of the platform mirror.
const portable = @import("../core/text_portable.zig");

pub const TextExtent = portable.TextExtent;
pub const ResolveFontError = portable.ResolveFontError;
pub const resolveFont = portable.resolveFont;
/// Every candidate font path.
pub const fontCandidates = portable.fontCandidates;
/// Read a font file whole.
pub const readFontBytes = portable.readFontBytes;
pub const estimatorExtent = portable.estimatorExtent;
pub const hashMeasureKey = portable.hashMeasureKey;
pub const extentCacheReset = portable.extentCacheReset;
pub const pangoFamily = portable.pangoFamily;
pub const measureText = portable.measureText;
pub const extent_hits = portable.extent_hits;
pub const extent_misses = portable.extent_misses;
