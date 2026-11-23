//! The browser's persistence backend: the page owns IndexedDB, so this side is only the slot its bytes pass through.
const storage = @import("../core/storage.zig");

/// The document's slot type, so a backend and an app agree on what is held.
pub const Slot = storage.Slot;

/// The largest document this backend holds, in bytes of JSON.
pub const max_document_bytes = storage.max_document_bytes;

var g_slot: Slot = .{};
var g_scratch: [storage.max_document_bytes]u8 = .{0} ** storage.max_document_bytes;

/// A block the page writes a loaded document into, so adopting one allocates nothing and cannot grow the heap.
pub fn scratch() []u8 {
    return g_scratch[0..];
}

/// A fresh slot: a new page, or the same page reloading with nothing stored.
pub fn reset() void {
    g_slot.reset();
}

/// The page's bytes arriving from IndexedDB. False when they do not fit.
pub fn adopt(bytes: []const u8) bool {
    return g_slot.adopt(bytes);
}

/// Take the adopted bytes into the caller's buffer, once.
pub fn takeAdopted(buf: []u8) ?[]const u8 {
    return g_slot.takeAdopted(buf);
}

/// The app's document, offered to the page. False when it does not fit.
pub fn stage(bytes: []const u8) bool {
    return g_slot.stage(bytes);
}

/// What the page still owes a write, or null when there is nothing pending.
pub fn staged() ?[]const u8 {
    return g_slot.stagedBytes();
}

/// The page confirming it wrote `staged()`.
pub fn clean() void {
    g_slot.clean();
}

/// Moves on every adopt, so the app can tell that the page answered without comparing bytes.
pub fn revision() u32 {
    return g_slot.revision();
}
