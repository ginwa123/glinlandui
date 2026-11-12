//! The freestanding C-ABI surface: the symbols `src/web/compat/` declares.
const std = @import("std");

/// The one allocator a wasm module has: it grows linear memory with `memory.grow`, which is exactly what a C heap must do.
const alloc = std.heap.wasm_allocator;

/// Written immediately before every payload, so `free` can recover the length C does not pass.
const Meta = extern struct {
    usable: usize,
    raw_ptr: usize,
    raw_len: usize,
};

fn metaFor(payload: [*]u8) *align(1) Meta {
    return @ptrFromInt(@intFromPtr(payload) - @sizeOf(Meta));
}

/// `malloc`.
fn cAlloc(requested: usize) ?[*]u8 {
    const usable = if (requested == 0) 1 else requested;
    const total = @sizeOf(Meta) + usable;
    const raw = alloc.alloc(u8, total) catch return null;
    const base = @intFromPtr(raw.ptr);
    const payload: [*]u8 = @ptrFromInt(base + @sizeOf(Meta));
    metaFor(payload).* = .{ .usable = usable, .raw_ptr = base, .raw_len = total };
    return payload;
}

fn cFree(ptr: ?[*]u8) void {
    const payload = ptr orelse return;
    const meta = metaFor(payload);
    const raw: [*]u8 = @ptrFromInt(meta.raw_ptr);
    alloc.free(raw[0..meta.raw_len]);
}

/// `realloc`.
fn cRealloc(ptr: ?[*]u8, requested: usize) ?[*]u8 {
    const want = if (requested == 0) 1 else requested;
    const old = ptr orelse return cAlloc(want);
    const next = cAlloc(want) orelse return null;
    // Copy only what both blocks can hold.
    const copy = @min(metaFor(old).usable, want);
    @memcpy(next[0..copy], old[0..copy]);
    cFree(old);
    return next;
}

// ---- allocation ----

export fn malloc(requested: usize) ?*anyopaque {
    const p = cAlloc(requested) orelse return null;
    return @ptrCast(p);
}

export fn calloc(count: usize, size: usize) ?*anyopaque {
    // Overflow-checked, because `calloc(n, size)` in C is defined to fail rather than to wrap — and a wrapped product here would be a heap overflow.
    const total = std.math.mul(usize, count, size) catch return null;
    const p = cAlloc(total) orelse return null;
    @memset(p[0..total], 0);
    return @ptrCast(p);
}

export fn realloc(ptr: ?*anyopaque, requested: usize) ?*anyopaque {
    // `?*anyopaque` is not a payload pointer; unwrap to the byte pointer the heap works in before handing it over.
    const bytes: ?[*]u8 = if (ptr) |p| @ptrCast(p) else null;
    const next = cRealloc(bytes, requested) orelse return null;
    return @ptrCast(next);
}

export fn free(ptr: ?*anyopaque) void {
    const bytes: ?[*]u8 = if (ptr) |p| @ptrCast(p) else null;
    cFree(bytes);
}

// ---- process control ----

/// C's `abort`.
export fn abort() void {
    @trap();
}

/// What `src/web/compat/assert.h` calls.
export fn glin_compat_trap() void {
    @trap();
}

export fn abs(x: c_int) c_int {
    // `-%` rather than `-`: `abs(INT_MIN)` is UB in C, and Zig's plain negation would PANIC (a trap) in a safe build instead of returning the wrapped value.
    return if (x < 0) -%x else x;
}

/// C's `strtol`.
export fn strtol(s: [*:0]const u8, endptr: ?*?[*:0]u8, base: c_int) c_long {
    var i: usize = 0;
    // C skips leading whitespace (isspace: space, \t, \n, \v, \f, \r).
    while (s[i] == ' ' or s[i] == '\t' or s[i] == '\n' or
        s[i] == 0x0B or s[i] == 0x0C or s[i] == '\r') : (i += 1)
    {}

    var negative = false;
    if (s[i] == '+' or s[i] == '-') {
        negative = s[i] == '-';
        i += 1;
    }

    // Auto-detect: C says a leading `0x` means hex, a leading `0` means octal, anything else decimal.
    var radix: u32 = if (base == 0) 10 else @intCast(base);
    if (base == 0 and s[i] == '0') {
        if (s[i + 1] == 'x' or s[i + 1] == 'X') {
            radix = 16;
            i += 2;
        } else {
            radix = 8;
        }
    } else if (base == 16 and s[i] == '0' and (s[i + 1] == 'x' or s[i + 1] == 'X')) {
        // An explicit base 16 still accepts the `0x` prefix, as C does.
        i += 2;
    }
    if (radix != 8 and radix != 10 and radix != 16) radix = 10;

    var value: c_long = 0;
    var overflow = false;
    var digits: usize = 0;
    while (true) : (i += 1) {
        const c = s[i];
        const digit: u32 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => break,
        };
        if (digit >= radix) break;
        digits += 1;
        const next = @mulWithOverflow(value, @as(c_long, @intCast(radix)));
        if (next[1] != 0) {
            overflow = true;
            break;
        }
        const added = @addWithOverflow(next[0], @as(c_long, @intCast(digit)));
        if (added[1] != 0) {
            overflow = true;
            break;
        }
        value = added[0];
    }

    if (endptr) |ep| {
        // Point at the first byte that was not consumed.
        const stop: usize = if (digits == 0) 0 else i;
        ep.* = @ptrFromInt(@intFromPtr(s) + stop);
    }

    if (overflow) return if (negative) std.math.minInt(c_long) else std.math.maxInt(c_long);
    return if (negative) -value else value;
}

// ---- strings ---- C's `int` return for the comparison functions is deliberately preserved: the callers do `strcmp(a, b) == 0`, and callers of.

export fn strlen(s: [*:0]const u8) usize {
    var n: usize = 0;
    while (s[n] != 0) n += 1;
    return n;
}

export fn strcmp(a: [*:0]const u8, b: [*:0]const u8) c_int {
    var i: usize = 0;
    while (a[i] == b[i]) : (i += 1) {
        if (a[i] == 0) return 0;
    }
    return @as(c_int, a[i]) - @as(c_int, b[i]);
}

export fn strncmp(a: [*:0]const u8, b: [*:0]const u8, n: usize) c_int {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (a[i] != b[i]) return @as(c_int, a[i]) - @as(c_int, b[i]);
        if (a[i] == 0) return 0;
    }
    return 0;
}

export fn strcpy(dst: [*:0]u8, src: [*:0]const u8) [*:0]u8 {
    var i: usize = 0;
    while (true) : (i += 1) {
        dst[i] = src[i];
        if (src[i] == 0) break;
    }
    return dst;
}

export fn strncpy(dst: [*:0]u8, src: [*:0]const u8, n: usize) [*:0]u8 {
    var i: usize = 0;
    while (i < n and src[i] != 0) : (i += 1) dst[i] = src[i];
    // C's strncpy pads the remainder with NULs; a caller may rely on it.
    while (i < n) : (i += 1) dst[i] = 0;
    return dst;
}

export fn strchr(s: [*:0]const u8, c: c_int) ?[*:0]u8 {
    // C passes the character as an int; only the low byte participates.
    const target: u8 = @truncate(@as(u32, @bitCast(c)));
    var i: usize = 0;
    while (true) : (i += 1) {
        if (s[i] == target) {
            const p: [*:0]u8 = @ptrFromInt(@intFromPtr(s) + i);
            return p;
        }
        if (s[i] == 0) return null;
    }
}

export fn strrchr(s: [*:0]const u8, c: c_int) ?[*:0]u8 {
    const target: u8 = @truncate(@as(u32, @bitCast(c)));
    var found: ?[*:0]u8 = null;
    var i: usize = 0;
    while (true) : (i += 1) {
        if (s[i] == target) {
            const p: [*:0]u8 = @ptrFromInt(@intFromPtr(s) + i);
            found = p;
        }
        if (s[i] == 0) break;
    }
    return found;
}

export fn strstr(haystack: [*:0]const u8, needle: [*:0]const u8) ?[*:0]u8 {
    const nlen = strlen(needle);
    var i: usize = 0;
    while (true) : (i += 1) {
        const h: [*:0]const u8 = @ptrFromInt(@intFromPtr(haystack) + i);
        // With an empty needle this matches immediately, which is what C says (`strstr(x, "") == x`).
        if (strncmp(h, needle, nlen) == 0) {
            const p: [*:0]u8 = @ptrFromInt(@intFromPtr(haystack) + i);
            return p;
        }
        if (haystack[i] == 0) return null;
    }
}
