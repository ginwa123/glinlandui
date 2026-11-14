// Text facade.
const select = @import("select.zig");

// The resolved backend.
const native = select.TextBackend;
const face = @import("text_face.zig");

pub const TextExtent = native.TextExtent;
pub const ResolveFontError = native.ResolveFontError;
pub const resolveFont = native.resolveFont;
// Every candidate font path.
pub const fontCandidates = native.fontCandidates;
// Read a font file whole — the only fs-shaped thing in the text surface, and the reason `core/glyphs.zig` (compiled by every build, wasm included) can.
pub const readFontBytes = native.readFontBytes;
pub const estimatorExtent = native.estimatorExtent;
pub const hashMeasureKey = native.hashMeasureKey;
pub const extentCacheReset = native.extentCacheReset;
pub const pangoFamily = native.pangoFamily;
// Measured with the font that DRAWS the text (see `text_face.zig`), not with an estimate: layout and rendering must agree, or a box is the wrong width

// and a caret placed from a measurement drifts off the glyphs.
pub const measureText = face.measureText;

// A run's width in points — what a caret or a click needs, rather than the full extent.
pub fn runWidth(bytes: []const u8, font_size: u16) f32 {
    return measureText(bytes, font_size).w;
}
// True when text is measured with real metrics; false on a host with no font file (a bare CI runner, wasm).
pub const fontAvailable = face.fontAvailable;
// The face itself, so a rasteriser draws with the same one the layout measured with.
pub const face_font = face.font;
pub const extent_hits = native.extent_hits;
pub const extent_misses = native.extent_misses;
