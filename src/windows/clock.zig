//! The monotonic clock on Windows: the performance counter, which ticks at a constant 10 MHz on every machine Windows supports.
const std = @import("std");
const Ctx = @import("../core/erased.zig").Ctx;
const ntdll = std.os.windows.ntdll;
const LARGE_INTEGER = std.os.windows.LARGE_INTEGER;

/// Ticks per millisecond, read once: asking the kernel on every pointer event would cost a syscall per motion.
var ticks_per_ms: i64 = 0;

pub fn monoMs(_: Ctx) i64 {
    if (ticks_per_ms == 0) {
        var frequency: LARGE_INTEGER = undefined;
        if (!ntdll.RtlQueryPerformanceFrequency(&frequency).toBool() or frequency <= 0) return 0;
        ticks_per_ms = @max(@divTrunc(frequency, std.time.ms_per_s), 1);
    }
    var ticks: LARGE_INTEGER = undefined;
    if (!ntdll.RtlQueryPerformanceCounter(&ticks).toBool()) return 0;
    return @divTrunc(ticks, ticks_per_ms);
}
