//! A C-compatible heap — the arithmetic behind `malloc`/`free`/`realloc`.
//!
//! ## Why this file is separate from the `export fn`s
//!
//! `src/web/compat_impl.zig` is the C-ABI surface the linker needs, and it is
//! **wasm-only**: it names `std.heap.wasm_allocator`, whose methods lower to
//! `@wasmMemoryGrow` and therefore cannot even be analysed on a native target.
//!
//! This file is everything in that surface which can be wrong in an interesting
//! way — a header written at the wrong offset, a copy length off by a word, a
//! `free` that cannot reconstruct the block it was handed. So it is generic over
//! any `std.mem.Allocator` and is unit-tested in the **cross-platform parity
//! suite**, which is the same discipline the rest of the repository follows for
//! its untestable shims: push every decision into pure Zig, and leave the shim
//! forwarding.
//!
//! ## The C constraint that shapes all of it
//!
//! `free(void*)` carries no length, and Zig's `Allocator.free` requires one. So
//! every block gets a header, written immediately before the payload. That is
//! the whole trick, and it is the only part of an allocator this project owns:
//! the actual memory management is `std.heap.wasm_allocator`'s, which already
//! grows linear memory correctly.
//!
//! ## Alignment
//!
//! The backing allocator hands back 16-byte-aligned memory, but a header of
//! `3 * @sizeOf(usize)` = 24 bytes sits in front of the payload, which would
//! leave the payload 8-mod-16 aligned. C callers are entitled to assume
//! `max_align_t`, and `stbtt_fontinfo` reads `uint32`/`float` fields out of the
//! font buffer, so the payload is aligned FORWARD to `max_align` and the header
//! records the raw base and raw length so `free` can still hand the backing
//! allocator exactly what it gave out.
const std = @import("std");

/// Max alignment the C surface honours. 16 is the conventional `max_align_t`;
/// Clay and stb need at most 8, so this is deliberate slack.
pub const max_align = 16;

/// Written immediately before every payload. Each word earns its place:
///
///   - `usable` — what the caller asked for. `realloc` copies at most this much,
///     and nothing may write past it, so it is also the bounds a later check
///     would use.
///   - `raw_ptr` — the exact base the backing allocator returned. It cannot be
///     recovered from the payload, because the payload is aligned forward from
///     it.
///   - `raw_len` — the exact length the backing allocator was given, which is
///     what its `free` contract requires.
pub const Meta = extern struct {
    usable: usize,
    raw_ptr: usize,
    raw_len: usize,
};

/// The header belonging to a payload. `align(1)` so reading it never assumes
/// alignment the forward-align step did not promise.
pub fn metaFor(payload: [*]u8) *align(1) Meta {
    return @ptrFromInt(@intFromPtr(payload) - @sizeOf(Meta));
}

/// `malloc`. Returns an aligned payload of at least `requested` usable bytes, or
/// null on failure — C's contract, including the quirk that a request of 0 still
/// yields a unique, freeable pointer (callers assume they may free it, and a
/// null return would be indistinguishable from failure).
pub fn cAlloc(alloc: std.mem.Allocator, requested: usize) ?[*]u8 {
    const usable = if (requested == 0) 1 else requested;
    // Reserve the header, the worst-case alignment slack, and the payload, so
    // the aligned payload plus its header is guaranteed to fit.
    const total = @sizeOf(Meta) + max_align + usable;
    const raw = alloc.alloc(u8, total) catch return null;
    const base = @intFromPtr(raw.ptr);
    const payload: [*]u8 = @ptrFromInt(std.mem.alignForward(usize, base + @sizeOf(Meta), max_align));
    metaFor(payload).* = .{ .usable = usable, .raw_ptr = base, .raw_len = total };
    return payload;
}

/// `free`. Null is a no-op, as C requires, because `free(NULL)` is legal and
/// common in cleanup paths.
pub fn cFree(alloc: std.mem.Allocator, ptr: ?[*]u8) void {
    const payload = ptr orelse return;
    const meta = metaFor(payload);
    const raw: [*]u8 = @ptrFromInt(meta.raw_ptr);
    alloc.free(raw[0..meta.raw_len]);
}

/// `realloc`. A null pointer allocates (C's contract). A failing grow returns
/// null and leaves the original block ALONE and still valid — the detail most
/// hand-written reallocs get wrong, and the one that turns a temporary
/// allocation failure into a leak or a double-free.
pub fn cRealloc(alloc: std.mem.Allocator, ptr: ?[*]u8, requested: usize) ?[*]u8 {
    const want = if (requested == 0) 1 else requested;
    const old = ptr orelse return cAlloc(alloc, want);
    const next = cAlloc(alloc, want) orelse return null;
    // Copy only what both blocks can hold: min(old usable, new usable). Reading
    // the OLD length is why the header records `usable` rather than `raw_len`.
    const copy = @min(metaFor(old).usable, want);
    @memcpy(next[0..copy], old[0..copy]);
    cFree(alloc, old);
    return next;
}

/// `calloc`. Overflow-checked, because `calloc(n, size)` in C is defined to fail
/// rather than to wrap — and a wrapped product here would be a heap overflow.
pub fn cCalloc(alloc: std.mem.Allocator, count: usize, size: usize) ?[*]u8 {
    const total = std.math.mul(usize, count, size) catch return null;
    const p = cAlloc(alloc, total) orelse return null;
    // Zero the REQUESTED bytes only. The alignment slack before the payload is
    // ours and must not be touched; zeroing past `usable` would still be inside
    // the backing allocation, but doing it would hide a bug in the arithmetic.
    @memset(p[0..total], 0);
    return p;
}

// ===================== tests (parity suite — every platform) =====================
//
// `std.testing.allocator` is the backing store here, which is what makes these
// tests worth more than a smoke test: it reports any leak on exit and catches a
// free that does not match its allocation. Every property below is one the wasm
// exports depend on, and none of them can be observed in a browser.

test "cAlloc returns a payload aligned to max_align for every size class" {
    // The header sits before the payload, so a naive layout leaves the payload
    // 24 bytes off a 16-byte boundary. Walk sizes across several alignment
    // periods rather than testing one lucky value.
    for ([_]usize{ 1, 2, 7, 8, 15, 16, 17, 24, 31, 32, 33, 63, 64, 100, 4096 }) |n| {
        const p = cAlloc(std.testing.allocator, n) orelse return error.OutOfMemory;
        defer cFree(std.testing.allocator, p);
        try std.testing.expectEqual(@as(usize, 0), @intFromPtr(p) % max_align);
        try std.testing.expectEqual(n, metaFor(p).usable);
    }
}

test "the whole usable range is writable and reads back" {
    // Proves the reservation is not off by one: writing `usable` bytes must fit
    // inside the backing allocation, and the byte after it must not be needed.
    for ([_]usize{ 1, 8, 24, 25, 100, 1000 }) |n| {
        const p = cAlloc(std.testing.allocator, n) orelse return error.OutOfMemory;
        defer cFree(std.testing.allocator, p);
        for (0..n) |i| p[i] = @truncate(i *% 31 + 7);
        for (0..n) |i| try std.testing.expectEqual(@as(u8, @truncate(i *% 31 + 7)), p[i]);
    }
}

test "cAlloc(0) is a unique, freeable block rather than null" {
    // C callers free the result of malloc(0) without checking, and treat null as
    // failure. Returning null here would make a legitimate zero-length request
    // look like an out-of-memory.
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
    // `b` is NOT zeroed by `cAlloc` — only `cCalloc` zeroes, exactly as in C. So
    // the assertion is that writing `a` does not disturb `b`, which is what
    // "do not alias" means. (An earlier version of this test expected `b[0] == 0`
    // and was wrong: it was asserting `calloc`'s contract on `malloc`.)
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
    // A leak here would be reported by std.testing.allocator on exit; an
    // unfreed old block would show up as one.
    try std.testing.expectEqual(@as(usize, 64), metaFor(q).usable);
}

test "cRealloc shrinks and copies only what both blocks hold" {
    // The copy length must be min(old, new). Reading the NEW length would read
    // past the old block; reading raw_len would read the alignment slack.
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
    // 0 is the value `stb_image` expects for a freshly decoded-but-untouched
    // buffer, and a partially zeroed block is the kind of bug that only shows up
    // as a stray pixel.
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
    // calloc(n, size) is defined to fail rather than wrap. A wrapped product is
    // a heap overflow — the single worst bug an allocator shim can have.
    try std.testing.expect(cCalloc(std.testing.allocator, std.math.maxInt(usize), 2) == null);
    try std.testing.expect(cCalloc(std.testing.allocator, std.math.maxInt(usize) / 2 + 1, 4) == null);
}

test "the header round-trips the exact raw block the backing allocator gave" {
    // This is what makes `free` correct: it must hand the backing allocator the
    // SAME base and length it was given, because the payload is aligned forward
    // from that base and therefore cannot recover it.
    const p = cAlloc(std.testing.allocator, 300) orelse return error.OutOfMemory;
    defer cFree(std.testing.allocator, p);
    const meta = metaFor(p);
    try std.testing.expect(meta.raw_len >= meta.usable);
    try std.testing.expect(meta.raw_ptr != 0);
    try std.testing.expect(meta.raw_ptr + meta.raw_len >= @intFromPtr(p) + meta.usable);
    // The payload starts inside the raw block, after the header.
    try std.testing.expect(@intFromPtr(p) >= meta.raw_ptr + @sizeOf(Meta));
}
