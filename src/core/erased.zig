// The one file under `src/core` that erases a type: `zginlint/no-anyopaque` bans the token here and allows exactly this file.

const std = @import("std");

// A callback's target with its type erased: one word, and `of`/`get` are the pair that writes it and reads it back typed.
pub const Ctx = struct {
    ptr: ?*anyopaque = null,

    // No target at all: what a prop carries before an app fills it in, and what a handler that needs nothing is given.
    pub const none: Ctx = .{};

    // `target` as an erased value. A null `target` makes a `Ctx` that only `getOrNull` answers.
    pub fn of(comptime T: type, target: ?*T) Ctx {
        const erased: ?*anyopaque = if (target) |p| @ptrCast(p) else null;
        return .{ .ptr = erased };
    }

    // The short door: `Ctx.from(&model)` erases a pointer the compiler already typed, optional pointers included.
    pub fn from(target: anytype) Ctx {
        const Pointer = @TypeOf(target);
        const is_optional = @typeInfo(Pointer) == .optional;
        const Single = if (is_optional) @typeInfo(Pointer).optional.child else Pointer;
        if (@typeInfo(Single) != .pointer) @compileError("Ctx.from wants a single pointer, optional or not");
        const erased: ?*anyopaque = if (is_optional) blk: {
            const raw = target orelse break :blk null;
            break :blk @ptrCast(@constCast(raw));
        } else @ptrCast(@constCast(target));
        return .{ .ptr = erased };
    }

    // The same, for a target an app only reads — a stateless singleton, or a `const` model.
    pub fn ofConst(comptime T: type, target: ?*const T) Ctx {
        const erased: ?*anyopaque = if (target) |p| @ptrCast(@constCast(p)) else null;
        return .{ .ptr = erased };
    }

    // The target as `T`. Naming a type the ctx was not built from is a bug in the caller, not a condition to handle.
    pub fn get(self: Ctx, comptime T: type) *T {
        return @ptrCast(@alignCast(self.ptr.?));
    }

    // The target as `T` when there is one, and null when the prop was left unfilled — for a handler that is optional.
    pub fn getOrNull(self: Ctx, comptime T: type) ?*T {
        const raw = self.ptr orelse return null;
        return @ptrCast(@alignCast(raw));
    }

    // The target as `T`, only read.
    pub fn getConst(self: Ctx, comptime T: type) *const T {
        return @ptrCast(@alignCast(self.ptr.?));
    }

    pub fn isNone(self: Ctx) bool {
        return self.ptr == null;
    }

    // True when both name the same target; a `Ctx` built from a different type is never equal, which is what a compare is for.
    pub fn eql(a: Ctx, b: Ctx) bool {
        return a.ptr == b.ptr;
    }
};

// The type a callback target points at, so a props constructor can derive it from the pointer the app hands over.

pub fn pointeeOf(comptime P: type) type {
    const inner = if (@typeInfo(P) == .optional) @typeInfo(P).optional.child else P;
    if (@typeInfo(inner) != .pointer) @compileError("a callback target must be one pointer, optional or not");
    return @typeInfo(inner).pointer.child;
}

// ---- typed handlers as erased ones ----

// A handler that takes its target typed, as one that takes it erased: the comptime thunk an app never writes.

pub fn call0(comptime T: type, comptime handler: fn (*T) void) *const fn (Ctx) void {
    return struct {
        fn trampoline(c: Ctx) void {
            handler(c.get(T));
        }
    }.trampoline;
}

pub fn call0Bool(comptime T: type, comptime handler: fn (*T) bool) *const fn (Ctx) bool {
    return struct {
        fn trampoline(c: Ctx) bool {
            return handler(c.get(T));
        }
    }.trampoline;
}

pub fn call0Ret(comptime T: type, comptime R: type, comptime handler: fn (*T) R) *const fn (Ctx) R {
    return struct {
        fn trampoline(c: Ctx) R {
            return handler(c.get(T));
        }
    }.trampoline;
}

pub fn call1(comptime T: type, comptime A: type, comptime handler: fn (*T, A) void) *const fn (Ctx, A) void {
    return struct {
        fn trampoline(c: Ctx, a: A) void {
            handler(c.get(T), a);
        }
    }.trampoline;
}

pub fn call1Ret(comptime T: type, comptime A: type, comptime R: type, comptime handler: fn (*T, A) R) *const fn (Ctx, A) R {
    return struct {
        fn trampoline(c: Ctx, a: A) R {
            return handler(c.get(T), a);
        }
    }.trampoline;
}

pub fn call2(comptime T: type, comptime A: type, comptime B: type, comptime handler: fn (*T, A, B) void) *const fn (Ctx, A, B) void {
    return struct {
        fn trampoline(c: Ctx, a: A, b: B) void {
            handler(c.get(T), a, b);
        }
    }.trampoline;
}

pub fn call3(comptime T: type, comptime A: type, comptime B: type, comptime C: type, comptime handler: fn (*T, A, B, C) void) *const fn (Ctx, A, B, C) void {
    return struct {
        fn trampoline(c: Ctx, a: A, b: B, cc: C) void {
            handler(c.get(T), a, b, cc);
        }
    }.trampoline;
}

// ---- tests ----

const testing = std.testing;

const Model = struct {
    clicks: usize = 0,
    last_index: usize = 0,
    last_text: []const u8 = "",
    took: bool = false,

    fn onClick(self: *Model) void {
        self.clicks += 1;
    }

    fn onRow(self: *Model, index: usize) void {
        self.clicks += 1;
        self.last_index = index;
    }

    fn onSubmit(self: *Model, text: []const u8) bool {
        self.last_text = text;
        return self.took;
    }

    fn always(self: *Model) bool {
        return self.took;
    }
};

test "Ctx: a target erased and read back is the same target" {
    var model = Model{};
    const c = Ctx.of(Model, &model);
    try testing.expect(!c.isNone());
    try testing.expectEqual(&model, c.get(Model));
    try testing.expectEqual(&model, c.getOrNull(Model).?);
}

test "Ctx: of(null) is a ctx nothing answers for, not a crash" {
    const c = Ctx.of(Model, null);
    try testing.expect(c.isNone());
    try testing.expectEqual(@as(?*Model, null), c.getOrNull(Model));
    try testing.expect(Ctx.none.isNone());
    try testing.expect(Ctx.eql(Ctx.none, Ctx.of(Model, null)));
}

test "Ctx: from() erases a pointer the compiler already typed, optional or not" {
    var model = Model{ .clicks = 3 };
    try testing.expectEqual(&model, Ctx.from(&model).get(Model));
    const maybe: ?*Model = &model;
    try testing.expectEqual(&model, Ctx.from(maybe).get(Model));
    try testing.expect(Ctx.from(@as(?*Model, null)).isNone());
    const frozen = Model{ .clicks = 4 };
    try testing.expectEqual(@as(usize, 4), Ctx.from(&frozen).getConst(Model).clicks);
}

test "Ctx: a const target reads back as its own type" {
    const singleton = Model{ .clicks = 7 };
    const c = Ctx.ofConst(Model, &singleton);
    try testing.expectEqual(@as(usize, 7), c.getConst(Model).clicks);
}

test "call0: the erased handler reaches the model a typed one names" {
    var model = Model{};
    const f = call0(Model, Model.onClick);
    f(Ctx.of(Model, &model));
    f(Ctx.of(Model, &model));
    try testing.expectEqual(@as(usize, 2), model.clicks);
}

test "call1: the argument travels with the erased target" {
    var model = Model{};
    call1(Model, usize, Model.onRow)(Ctx.of(Model, &model), 5);
    try testing.expectEqual(@as(usize, 1), model.clicks);
    try testing.expectEqual(@as(usize, 5), model.last_index);
}

test "call1Ret: a handler's answer comes back through the thunk" {
    var model = Model{ .took = true };
    const f = call1Ret(Model, []const u8, bool, Model.onSubmit);
    try testing.expect(f(Ctx.of(Model, &model), "hi"));
    try testing.expectEqualStrings("hi", model.last_text);
}

test "call0Bool: a predicate over the erased target" {
    var model = Model{ .took = true };
    try testing.expect(call0Bool(Model, Model.always)(Ctx.of(Model, &model)));
    model.took = false;
    try testing.expect(!call0Bool(Model, Model.always)(Ctx.of(Model, &model)));
}

test "Ctx: a callback pair is one word of storage, so a props struct stays cheap" {
    try testing.expectEqual(@sizeOf(usize), @sizeOf(Ctx));
}
