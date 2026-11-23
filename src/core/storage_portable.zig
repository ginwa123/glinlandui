//! The in-memory persistence backend: what every test build, and every host with no store of its own, selects.
const std = @import("std");
const storage = @import("storage.zig");

/// The document's slot type, so a backend and an app agree on what is held.
pub const Slot = storage.Slot;

/// The largest document this backend holds, in bytes.
pub const max_document_bytes = storage.max_document_bytes;

var g_slot: Slot = .{};

/// A fresh slot: nothing adopted, nothing owed.
pub fn reset() void {
    g_slot.reset();
}

/// The host's bytes arriving. False when they do not fit.
pub fn adopt(bytes: []const u8) bool {
    return g_slot.adopt(bytes);
}

/// Take the adopted bytes into the caller's buffer, once.
pub fn takeAdopted(buf: []u8) ?[]const u8 {
    return g_slot.takeAdopted(buf);
}

/// The app's document, offered to the host. False when it does not fit.
pub fn stage(bytes: []const u8) bool {
    return g_slot.stage(bytes);
}

/// What the host still owes a write, or null when there is nothing pending.
pub fn staged() ?[]const u8 {
    return g_slot.stagedBytes();
}

/// The host confirming it wrote `staged()`.
pub fn clean() void {
    g_slot.clean();
}

/// Moves on every adopt.
pub fn revision() u32 {
    return g_slot.revision();
}

// ---- tests ---------------------------------------------------------------------------------------------------

const testing = std.testing;

test "the in-memory backend keeps a staged document until the host confirms the write" {
    reset();
    defer reset();
    try testing.expect(staged() == null);
    try testing.expect(stage("{\"v\":2,\"e\":{}}"));
    try testing.expectEqualStrings("{\"v\":2,\"e\":{}}", staged().?);
    clean();
    try testing.expect(staged() == null);
}

test "the in-memory backend hands an adopted document over once and moves the revision" {
    reset();
    defer reset();
    var buf: [max_document_bytes]u8 = undefined;
    const before = revision();
    try testing.expect(takeAdopted(&buf) == null);
    try testing.expect(adopt("{\"v\":2,\"e\":{\"dense\":\"1\"}}"));
    try testing.expect(revision() != before);
    try testing.expectEqualStrings("{\"v\":2,\"e\":{\"dense\":\"1\"}}", takeAdopted(&buf).?);
    try testing.expect(takeAdopted(&buf) == null);
}
