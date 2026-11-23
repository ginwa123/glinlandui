//! The browser's network backend: the page owns `fetch`, so this side is only the slot its bytes pass through.
const net = @import("../core/net.zig");

/// The slot type, so a backend and an app agree on what is exchanged.
pub const Slot = net.Slot;

/// The bounds the page must respect, in bytes.
pub const max_origin = net.max_origin;
pub const max_request_bytes = net.max_request_bytes;
pub const max_body_bytes = net.max_body_bytes;
pub const max_meta_bytes = net.max_meta_bytes;

pub const Method = net.Method;
pub const Header = net.Header;
pub const Reply = net.Reply;

var g_slot: Slot = .{};
var g_origin_scratch: [net.max_origin]u8 = .{0} ** net.max_origin;
var g_meta_scratch: [net.max_meta_bytes]u8 = .{0} ** net.max_meta_bytes;
var g_body_scratch: [net.max_body_bytes]u8 = .{0} ** net.max_body_bytes;

/// A block the page writes the origin it was told to use into, so naming one allocates nothing.
pub fn originScratch() []u8 {
    return g_origin_scratch[0..];
}

/// A block the page writes `"<status>\n<etag>\n<version>\n"` into.
pub fn metaScratch() []u8 {
    return g_meta_scratch[0..];
}

/// A block the page writes a response body into.
pub fn bodyScratch() []u8 {
    return g_body_scratch[0..];
}

/// A fresh slot: a new page, or the same page reloading.
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

/// Stage a request for the page. False when one is still owed, or it does not fit.
pub fn stage(ticket: u32, method: Method, url: []const u8, headers: []const Header, body: []const u8) bool {
    return g_slot.stage(ticket, method, url, headers, body);
}

/// What the page still owes a send, or null when there is nothing pending.
pub fn staged() ?[]const u8 {
    return g_slot.stagedBytes();
}

/// The page confirming it read the request.
pub fn clean() void {
    g_slot.clean();
}

/// The page's answer, from bytes it wrote into the meta and body scratches.
pub fn settle(ticket: u32, meta_len: usize, body_len: usize) bool {
    const meta = g_meta_scratch[0..@min(meta_len, g_meta_scratch.len)];
    const body = g_body_scratch[0..@min(body_len, g_body_scratch.len)];
    return g_slot.settle(ticket, meta, body);
}

/// The page's answer whose body did not fit the block it writes into: the status and headers arrive, the bytes do not.
pub fn settleOverlong(ticket: u32, meta_len: usize) bool {
    return g_slot.settleOverlong(ticket, g_meta_scratch[0..@min(meta_len, g_meta_scratch.len)]);
}

/// The answer once, or null when nothing arrived since the last take.
pub fn takeReply() ?*const Reply {
    return g_slot.takeReply();
}

/// Moves on every settle.
pub fn revision() u32 {
    return g_slot.revision();
}
