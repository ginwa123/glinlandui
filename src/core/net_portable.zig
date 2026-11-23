//! The in-memory network backend: what every test build, and every host with no transport of its own, selects.
const std = @import("std");
const net = @import("net.zig");

/// The slot type, so a backend and an app agree on what is exchanged.
pub const Slot = net.Slot;

/// The bounds an app and a backend share.
pub const max_origin = net.max_origin;
pub const max_url = net.max_url;
pub const max_request_bytes = net.max_request_bytes;
pub const max_body_bytes = net.max_body_bytes;
pub const max_meta_bytes = net.max_meta_bytes;
pub const Method = net.Method;
pub const Header = net.Header;
pub const Reply = net.Reply;

var g_slot: Slot = .{};

/// A fresh slot: no origin, nothing staged, nothing settled.
pub fn reset() void {
    g_slot.reset();
}

/// The page's origin. False when it does not fit.
pub fn setOrigin(origin: []const u8) bool {
    return g_slot.setOrigin(origin);
}

/// The origin once, or null when the page has not named one since the last take.
pub fn takeOrigin(buf: []u8) ?[]const u8 {
    return g_slot.takeOrigin(buf);
}

/// The origin as it stands.
pub fn originBytes() []const u8 {
    return g_slot.originBytes();
}

/// Stage a request for the transport. False when one is still owed, or it does not fit.
pub fn stage(ticket: u32, method: Method, url: []const u8, headers: []const Header, body: []const u8) bool {
    return g_slot.stage(ticket, method, url, headers, body);
}

/// What the transport still owes, or null when there is nothing pending.
pub fn staged() ?[]const u8 {
    return g_slot.stagedBytes();
}

/// The transport confirming it read the request.
pub fn clean() void {
    g_slot.clean();
}

/// The transport's answer. False when the status it serialised is not one.
pub fn settle(ticket: u32, meta: []const u8, body: []const u8) bool {
    return g_slot.settle(ticket, meta, body);
}

/// The answer once, or null when nothing arrived since the last take.
pub fn takeReply() ?*const Reply {
    return g_slot.takeReply();
}

/// Moves on every settle.
pub fn revision() u32 {
    return g_slot.revision();
}

// ---- tests ---------------------------------------------------------------------------------------------------

const testing = std.testing;

test "the in-memory backend keeps a staged request until the transport confirms it read one" {
    reset();
    defer reset();
    try testing.expect(staged() == null);
    try testing.expect(stage(1, .get, "http://h/api/companies", &.{}, ""));
    try testing.expectEqualStrings("1 GET http://h/api/companies\n\n", staged().?);
    clean();
    try testing.expect(staged() == null);
}

test "the in-memory backend hands an answer over once and forgets it on reset" {
    reset();
    defer reset();
    try testing.expect(settle(2, "200\n\"0123456789abcdef\"\n\n", "{\"ok\":true}"));
    try testing.expectEqualStrings("{\"ok\":true}", takeReply().?.bodyText());
    try testing.expect(takeReply() == null);
    reset();
    try testing.expect(takeReply() == null);
}

test "the in-memory backend remembers the origin the page named" {
    reset();
    defer reset();
    var buf: [max_origin]u8 = undefined;
    try testing.expect(setOrigin("http://127.0.0.1:8099"));
    try testing.expectEqualStrings("http://127.0.0.1:8099", originBytes());
    try testing.expectEqualStrings("http://127.0.0.1:8099", takeOrigin(&buf).?);
    try testing.expect(takeOrigin(&buf) == null);
}
