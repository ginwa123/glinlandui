//! A C-compatible heap — the arithmetic behind `malloc`/`free`/`realloc`.
const std = @import("std");

/// Max alignment the C surface honours.
pub const max_align = 16;

/// Written immediately before every payload.
pub const Meta = extern struct {
    usable: usize,
    raw_ptr: usize,
    raw_len: usize,
};

/// The header belonging to a payload.
pub fn metaFor(payload: [*]u8) *align(1) Meta {
    return @ptrFromInt(@intFromPtr(payload) - @sizeOf(Meta));
}

/// `malloc`.
pub fn cAlloc(alloc: std.mem.Allocator, requested: usize) ?[*]u8 {
    const usable = if (requested == 0) 1 else requested;
    // Reserve the header, the worst-case alignment slack, and the payload, so the aligned payload plus its header is guaranteed to fit.
    const total = @sizeOf(Meta) + max_align + usable;
    const raw = alloc.alloc(u8, total) catch return null;
    const base = @intFromPtr(raw.ptr);
    const payload: [*]u8 = @ptrFromInt(std.mem.alignForward(usize, base + @sizeOf(Meta), max_align));
    metaFor(payload).* = .{ .usable = usable, .raw_ptr = base, .raw_len = total };
    return payload;
}

/// `free`.
pub fn cFree(alloc: std.mem.Allocator, ptr: ?[*]u8) void {
    const payload = ptr orelse return;
    const meta = metaFor(payload);
    const raw: [*]u8 = @ptrFromInt(meta.raw_ptr);
    alloc.free(raw[0..meta.raw_len]);
}

/// `realloc`.
pub fn cRealloc(alloc: std.mem.Allocator, ptr: ?[*]u8, requested: usize) ?[*]u8 {
    const want = if (requested == 0) 1 else requested;
    const old = ptr orelse return cAlloc(alloc, want);
    const next = cAlloc(alloc, want) orelse return null;
    // Copy only what both blocks can hold: min(old usable, new usable).
    const copy = @min(metaFor(old).usable, want);
    @memcpy(next[0..copy], old[0..copy]);
    cFree(alloc, old);
    return next;
}

/// `calloc`.
pub fn cCalloc(alloc: std.mem.Allocator, count: usize, size: usize) ?[*]u8 {
    const total = std.math.mul(usize, count, size) catch return null;
    const p = cAlloc(alloc, total) orelse return null;
    // Zero the REQUESTED bytes only.
    @memset(p[0..total], 0);
    return p;
}

// ===================== tests (parity suite — every platform) ===================== `std.testing.allocator` is the backing store here, which is what.

test "cAlloc returns a payload aligned to max_align for every size class" {
    // The header sits before the payload, so a naive layout leaves the payload 24 bytes off a 16-byte boundary.
    for ([_]usize{ 1, 2, 7, 8, 15, 16, 17, 24, 31, 32, 33, 63, 64, 100, 4096 }) |n| {
        const p = cAlloc(std.testing.allocator, n) orelse return error.OutOfMemory;
        defer cFree(std.testing.allocator, p);
        try std.testing.expectEqual(@as(usize, 0), @intFromPtr(p) % max_align);
        try std.testing.expectEqual(n, metaFor(p).usable);
    }
}

test "the whole usable range is writable and reads back" {
    // Proves the reservation is not off by one: writing `usable` bytes must fit inside the backing allocation, and the byte after it must not be needed.
    for ([_]usize{ 1, 8, 24, 25, 100, 1000 }) |n| {
        const p = cAlloc(std.testing.allocator, n) orelse return error.OutOfMemory;
        defer cFree(std.testing.allocator, p);
        for (0..n) |i| p[i] = @truncate(i *% 31 + 7);
        for (0..n) |i| try std.testing.expectEqual(@as(u8, @truncate(i *% 31 + 7)), p[i]);
    }
}

test "cAlloc(0) is a unique, freeable block rather than null" {
    // C callers free the result of malloc(0) without checking, and treat null as failure.
    const a = cAlloc(std.testing.allocator, 0) orelse return error.OutOfMemory;
    const b = cAlloc(std.testing.allocator, 0) orelse return error.OutOfMemory;
    defer cFree(std.testing.allocator, a);
    defer cFree(std.testing.allocator, b);
    try std.testing.expect(a != b);
    try std.testing.expectEqual(@as(usize, 1), metaFor(a).usable);
}

test "cFree tolerates null, because free(NULL) is legal C" {
    cFree(std.testing.allocator, null);
}

test "two live blocks do not alias and free independently" {
    const a = cAlloc(std.testing.allocator, 32) orelse return error.OutOfMemory;
    const b = cAlloc(std.testing.allocator, 32) orelse return error.OutOfMemory;
    defer cFree(std.testing.allocator, b);
    // `b` is NOT zeroed by `cAlloc` — only `cCalloc` zeroes, exactly as in C.
    const b_before = b[0];
    @memset(a[0..32], 0xAA);
    try std.testing.expectEqual(b_before, b[0]);
    try std.testing.expectEqual(@as(u8, 0xAA), a[0]);
    cFree(std.testing.allocator, a);
    // Freeing `a` must leave `b` intact and still freeable.
    try std.testing.expectEqual(b_before, b[0]);
}

test "cRealloc grows, preserves the old contents, and frees the old block" {
    const p = cAlloc(std.testing.allocator, 16) orelse return error.OutOfMemory;
    for (0..16) |i| p[i] = @intCast(i);
    const q = cRealloc(std.testing.allocator, p, 64) orelse return error.OutOfMemory;
    defer cFree(std.testing.allocator, q);
    // Contents survive the move...
    for (0..16) |i| try std.testing.expectEqual(@as(u8, @intCast(i)), q[i]);
    // ...and the new tail is ours to write.
    for (16..64) |i| q[i] = 0xFF;
    // A leak here would be reported by std.testing.allocator on exit; an unfreed old block would show up as one.
    try std.testing.expectEqual(@as(usize, 64), metaFor(q).usable);
}

test "cRealloc shrinks and copies only what both blocks hold" {
    // The copy length must be min(old, new).
    const p = cAlloc(std.testing.allocator, 100) orelse return error.OutOfMemory;
    for (0..100) |i| p[i] = @intCast(i % 251);
    const q = cRealloc(std.testing.allocator, p, 10) orelse return error.OutOfMemory;
    defer cFree(std.testing.allocator, q);
    try std.testing.expectEqual(@as(usize, 10), metaFor(q).usable);
    for (0..10) |i| try std.testing.expectEqual(@as(u8, @intCast(i)), q[i]);
}

test "cRealloc with a null pointer allocates, like C" {
    const p = cRealloc(std.testing.allocator, null, 48) orelse return error.OutOfMemory;
    defer cFree(std.testing.allocator, p);
    for (0..48) |i| p[i] = 1;
    try std.testing.expectEqual(@as(u8, 1), p[47]);
}

test "cRealloc(ptr, 0) still returns a live block to free" {
    const p = cAlloc(std.testing.allocator, 8) orelse return error.OutOfMemory;
    const q = cRealloc(std.testing.allocator, p, 0) orelse return error.OutOfMemory;
    defer cFree(std.testing.allocator, q);
    try std.testing.expectEqual(@as(usize, 1), metaFor(q).usable);
}

test "cCalloc zeroes every requested byte across an alignment boundary" {
    // 0 is the value `stb_image` expects for a freshly decoded-but-untouched buffer, and a partially zeroed block is the kind of bug that only shows up as.
    for ([_]usize{ 1, 17, 33, 129, 777 }) |n| {
        const p = cCalloc(std.testing.allocator, n, 1) orelse return error.OutOfMemory;
        defer cFree(std.testing.allocator, p);
        for (0..n) |i| try std.testing.expectEqual(@as(u8, 0), p[i]);
        try std.testing.expectEqual(n, metaFor(p).usable);
    }
}

test "cCalloc applies its count and size factors" {
    const p = cCalloc(std.testing.allocator, 10, 24) orelse return error.OutOfMemory;
    defer cFree(std.testing.allocator, p);
    try std.testing.expectEqual(@as(usize, 240), metaFor(p).usable);
    for (0..240) |i| try std.testing.expectEqual(@as(u8, 0), p[i]);
}

test "cCalloc fails on an overflowing product instead of wrapping" {
    // calloc(n, size) is defined to fail rather than wrap.
    try std.testing.expect(cCalloc(std.testing.allocator, std.math.maxInt(usize), 2) == null);
    try std.testing.expect(cCalloc(std.testing.allocator, std.math.maxInt(usize) / 2 + 1, 4) == null);
}

test "the header round-trips the exact raw block the backing allocator gave" {
    // This is what makes `free` correct: it must hand the backing allocator the SAME base and length it was given, because the payload is aligned forward.
    const p = cAlloc(std.testing.allocator, 300) orelse return error.OutOfMemory;
    defer cFree(std.testing.allocator, p);
    const meta = metaFor(p);
    try std.testing.expect(meta.raw_len >= meta.usable);
    try std.testing.expect(meta.raw_ptr != 0);
    try std.testing.expect(meta.raw_ptr + meta.raw_len >= @intFromPtr(p) + meta.usable);
    // The payload starts inside the raw block, after the header.
    try std.testing.expect(@intFromPtr(p) >= meta.raw_ptr + @sizeOf(Meta));
}
