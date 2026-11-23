//! A route as a value: intent in, the current address out, the same on every backend — the browser mirrors it into the URL.
const std = @import("std");
const frame = @import("frame.zig");

/// The longest address a route holds, in bytes: a screen name plus a couple of segments, with room to spare.
pub const max_path: usize = 120;

/// How far back a reader can walk: a fixed ring, so the router allocates nothing and runs in wasm and in a test alike.
pub const max_entries: usize = 16;

/// The characters a normalised address never contains: a route that differs only in these is the same route.
pub fn normalise(dst: []u8, raw: []const u8) []const u8 {
    var n: usize = 0;
    var pending_sep = false;
    var i: usize = 0;
    while (i < raw.len and n < dst.len) : (i += 1) {
        const ch = raw[i];
        // A query belongs to the host, not to the screen: `#buttons?x=1` addresses `buttons`.
        if (ch == '?') break;
        // Whitespace is not part of an address, and a typed one carries it at both ends.
        if (ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r') continue;
        if (ch == '/' or ch == '#') {
            pending_sep = n > 0;
            continue;
        }
        if (pending_sep) {
            if (n + 1 >= dst.len) break;
            dst[n] = '/';
            n += 1;
            pending_sep = false;
        }
        dst[n] = ch;
        n += 1;
    }
    return dst[0..n];
}

/// One address, as a value with its own bytes: `Route.of("#text-field")` and `Route.of("text-field")` are the same route.
pub const Route = struct {
    buf: [max_path]u8 = .{0} ** max_path,
    len: usize = 0,

    pub fn of(raw: []const u8) Route {
        var r: Route = .{};
        const n = normalise(&r.buf, raw);
        r.len = n.len;
        return r;
    }

    /// The address as the bytes it holds: valid until this value goes away.
    pub fn path(self: *const Route) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn isEmpty(self: *const Route) bool {
        return self.len == 0;
    }

    /// Whether this route addresses `want`, compared the same way every route was normalised.
    pub fn is(self: *const Route, want: []const u8) bool {
        return Route.of(want).eql(self.*);
    }

    pub fn eql(a: Route, b: Route) bool {
        return std.mem.eql(u8, a.path(), b.path());
    }

    /// Segment `index` of the address, or an empty slice past the end: `text-field/4` has two.
    pub fn segment(self: *const Route, index: usize) []const u8 {
        var it = std.mem.splitScalar(u8, self.path(), '/');
        var i: usize = 0;
        while (it.next()) |s| : (i += 1) {
            if (i == index) return s;
        }
        return "";
    }

    /// The first segment: the screen, when a route names one.
    pub fn head(self: *const Route) []const u8 {
        return self.segment(0);
    }

    /// This address with `name` appended: the child-screen idiom, without formatting a string at the call site.
    pub fn child(self: *const Route, name: []const u8) Route {
        var r: Route = .{};
        const base = self.path();
        var n: usize = 0;
        if (base.len > 0 and base.len + 1 < r.buf.len) {
            @memcpy(r.buf[0..base.len], base);
            n = base.len;
            r.buf[n] = '/';
            n += 1;
        }
        const tail = normalise(r.buf[n..], name);
        r.len = n + tail.len;
        return r;
    }
};

/// The address the window is showing.
var here: Route = .{};

/// Where the reader has been, and which entry `here` is.
var entries: [max_entries]Route = .{Route{}} ** max_entries;
var count: usize = 0;
var at: usize = 0;

/// Bumped by every change, so a backend (or an app) can tell that the address moved without comparing strings.
var generation_count: u32 = 1;

/// A fresh window starts with an empty address; the backend then says where the app is and the app writes its first screen.
pub fn reset() void {
    here = .{};
    count = 0;
    at = 0;
    generation_count +%= 1;
}

// A new address is a new screen: the loop has to draw it, and no input event may be coming to carry it.
fn announce() void {
    generation_count +%= 1;
    frame.requestFrame();
}

pub fn current() Route {
    return here;
}

/// The live address's bytes, from the router's own buffer, so it survives the call that produced it.
pub fn address() []const u8 {
    return here.path();
}

pub fn generation() u32 {
    return generation_count;
}

pub fn historyLen() usize {
    return count;
}

pub fn historyAt(index: usize) Route {
    if (index >= count) return .{};
    return entries[index];
}

pub fn canBack() bool {
    return at > 0 and count > 0;
}

pub fn canForward() bool {
    return count > 0 and at + 1 < count;
}

/// The app's first screen, or a deep link the backend read before the first frame: this is the whole history so far.
pub fn start(path: []const u8) void {
    const next = Route.of(path);
    if (next.eql(here) and count > 0) return;
    entries[0] = next;
    count = 1;
    at = 0;
    here = next;
    announce();
}

/// The backend saying the address moved (a back button, an edited URL): it replaces the entry, it never pushes one.
pub fn adopt(path: []const u8) void {
    const next = Route.of(path);
    if (next.eql(here)) return;
    if (count == 0) {
        entries[0] = next;
        count = 1;
        at = 0;
    } else {
        entries[at] = next;
    }
    here = next;
    announce();
}

/// An intent: the app is going somewhere, and the backend should hear about it.
pub fn navigate(path: []const u8) void {
    const next = Route.of(path);
    if (next.eql(here)) return;
    if (count == 0) {
        entries[0] = next;
        count = 1;
        at = 0;
    } else if (at + 1 < max_entries) {
        at += 1;
        entries[at] = next;
        count = at + 1;
    } else {
        // The history is full, so the OLDEST entry goes: a reader keeps walking, and the address never stops working.
        std.mem.copyForwards(Route, entries[0 .. max_entries - 1], entries[1..max_entries]);
        entries[max_entries - 1] = next;
        at = max_entries - 1;
        count = max_entries;
    }
    here = next;
    announce();
}

/// The same navigation with no new history entry: what a redirect or a first screen wants.
pub fn replace(path: []const u8) void {
    const next = Route.of(path);
    if (next.eql(here)) return;
    if (count == 0) {
        entries[0] = next;
        count = 1;
        at = 0;
    } else {
        entries[at] = next;
    }
    here = next;
    announce();
}

/// Walk the history. Returns false when there is nowhere to go, so a caller can fall through to something else.
pub fn back() bool {
    if (!canBack()) return false;
    at -= 1;
    here = entries[at];
    announce();
    return true;
}

pub fn forward() bool {
    if (!canForward()) return false;
    at += 1;
    here = entries[at];
    announce();
    return true;
}

// ---- tests ---------------------------------------------------------------------------------------------------

const testing = std.testing;

test "an address is normalised once, so a route and its path compare" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("buttons", normalise(&buf, "#buttons"));
    try testing.expectEqualStrings("buttons", normalise(&buf, "/buttons"));
    try testing.expectEqualStrings("buttons", normalise(&buf, "//buttons//"));
    try testing.expectEqualStrings("a/b", normalise(&buf, "#a#b"));
    try testing.expectEqualStrings("a/b", normalise(&buf, " a / b "));
    try testing.expectEqualStrings("a", normalise(&buf, "a?x=1"));
    try testing.expectEqualStrings("", normalise(&buf, "#"));
    try testing.expectEqualStrings("", normalise(&buf, ""));
}

test "routes carry their own bytes, and child appends a segment" {
    const root = Route.of("text-field");
    try testing.expect(root.is("text-field"));
    try testing.expect(root.is("#/text-field"));
    try testing.expect(!root.is("buttons"));
    try testing.expectEqualStrings("text-field", root.head());
    try testing.expectEqualStrings("", root.segment(1));
    const child = root.child("4");
    try testing.expect(child.is("text-field/4"));
    try testing.expectEqualStrings("4", child.segment(1));
    const bare = Route{};
    try testing.expect(bare.isEmpty());
    try testing.expect(bare.child("overview").is("overview"));
}

test "navigate pushes, back and forward walk it, and the generation moves with the address" {
    reset();
    const first = generation();
    navigate("a");
    try testing.expect(generation() != first);
    navigate("b");
    try testing.expect(current().is("b"));
    try testing.expectEqual(@as(usize, 2), historyLen());
    try testing.expect(canBack());
    try testing.expect(!canForward());
    try testing.expect(back());
    try testing.expect(current().is("a"));
    try testing.expect(canForward());
    try testing.expect(forward());
    try testing.expect(current().is("b"));
    try testing.expect(!forward());
    // The same address again is not a new entry: a click on the section the reader is already reading is a no-op.
    const gen = generation();
    navigate("b");
    try testing.expectEqual(gen, generation());
    try testing.expectEqual(@as(usize, 2), historyLen());
}

test "navigating after going back drops the entries the reader had left" {
    reset();
    navigate("a");
    navigate("b");
    navigate("c");
    try testing.expect(back());
    try testing.expect(canForward());
    navigate("d");
    try testing.expect(!canForward());
    try testing.expectEqual(@as(usize, 3), historyLen());
    try testing.expect(historyAt(0).is("a"));
    try testing.expect(historyAt(1).is("b"));
    try testing.expect(historyAt(2).is("d"));
}

test "adopting the backend's address replaces the entry instead of pushing one" {
    reset();
    navigate("a");
    navigate("b");
    const entries_before = historyLen();
    // A browser's back button has ALREADY moved the page; pushing here would make the next Back go nowhere.
    adopt("c");
    try testing.expect(current().is("c"));
    try testing.expectEqual(entries_before, historyLen());
    try testing.expect(historyAt(1).is("c"));
    // An address the reader is already on is not a change at all.
    const gen = generation();
    adopt("#c");
    try testing.expectEqual(gen, generation());
}

test "a full history drops its oldest entry and keeps walking" {
    reset();
    var buf: [16]u8 = undefined;
    var i: usize = 0;
    while (i < max_entries + 4) : (i += 1) {
        navigate(std.fmt.bufPrint(&buf, "s{d}", .{i}) catch @panic("a two-digit index fits a 16-byte buffer"));
    }
    try testing.expectEqual(max_entries, historyLen());
    try testing.expect(!canForward());
    try testing.expect(current().is(std.fmt.bufPrint(&buf, "s{d}", .{max_entries + 3}) catch @panic("a short index formats")));
    try testing.expect(back());
    try testing.expect(current().is(std.fmt.bufPrint(&buf, "s{d}", .{max_entries + 2}) catch @panic("a short index formats")));
}

test "reset gives a window an empty address and a fresh generation" {
    reset();
    navigate("a");
    const gen = generation();
    reset();
    try testing.expect(current().isEmpty());
    try testing.expectEqual(@as(usize, 0), historyLen());
    try testing.expect(!canBack());
    try testing.expect(generation() != gen);
    // A first screen is then one entry, and it is where Back stops.
    start("overview");
    try testing.expect(current().is("overview"));
    try testing.expectEqual(@as(usize, 1), historyLen());
    try testing.expect(!canBack());
}
