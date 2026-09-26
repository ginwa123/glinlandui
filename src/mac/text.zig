//! macOS text engine — the `text.zig` half of the platform mirror.
//!
//! Linux talks to pangocairo through `linux/text.zig` plus the `linux/shim.h`
//! header. macOS has no native text engine in this project: it uses the
//! deterministic estimator in `core/text_portable.zig` — the same module every
//! test build uses on every platform.
//!
//! This file re-exports that surface so
//!
//!     linux/text.zig   (pangocairo via the C shim)     ~260 lines
//!     mac/text.zig     (the shared estimator, this file)
//!
//! sit at the same path in each platform folder, and `platform.zig` can name a
//! macOS text module instead of special-casing "macOS has none". When a CoreText
//! backend lands, this is the file that grows.
//!
//! The re-export list is deliberately the exact set `core/text_backend.zig`
//! forwards, so `core/select.zig` can treat either platform's module the same.
//!
//! NOTE: `pangoFamily` is a pangocairo concept with no macOS meaning. It is
//! re-exported for surface parity with `linux/text.zig`; on this platform the
//! portable estimator ignores it.
const portable = @import("../core/text_portable.zig");

pub const TextExtent = portable.TextExtent;
pub const ResolveFontError = portable.ResolveFontError;
pub const resolveFont = portable.resolveFont;
/// Every candidate font path. The CPU glyph rasterizer needs the whole list
/// because the first file that merely EXISTS may be a TrueType collection,
/// which no rasterizer can load; it keeps the first that actually parses.
pub const fontCandidates = portable.fontCandidates;
pub const estimatorExtent = portable.estimatorExtent;
pub const hashMeasureKey = portable.hashMeasureKey;
pub const extentCacheReset = portable.extentCacheReset;
pub const pangoFamily = portable.pangoFamily;
pub const measureText = portable.measureText;
pub const extent_hits = portable.extent_hits;
pub const extent_misses = portable.extent_misses;
