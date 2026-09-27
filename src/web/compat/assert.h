// glinlandui freestanding C-compile compat: <assert.h>
//
// `stb_truetype` routes `STBTT_assert` through C's `assert`, and it uses it on
// the table directory and on `numGlyphs > 0`. That is exactly the machinery that
// made `Font.fromBytes` on arbitrary bytes abort rather than return 0 (see the
// measured note there), so this macro has to be a real trap in a debug build,
// not a no-op:
//
//   - with assertions ON, a malformed header trips `glin_compat_trap`, the
//     browser reports `RuntimeError: unreachable`, and the failure is loud.
//   - with `-DNDEBUG` (a release webapp) the check compiles away, which is what
//     makes the artifact small. `Font.fromBytes` does NOT depend on it: its own
//     signature guard is unconditional, so the trap is a backstop rather than
//     the defence.
//
// On a browser there is no stderr to print `__FILE__`/`__LINE__` to, so the
// macro deliberately drops them rather than pretending to report. A debug build
// gets the trap and a stack trace from the browser's own debugger.
#ifndef GLIN_COMPAT_ASSERT_H
#define GLIN_COMPAT_ASSERT_H

#ifdef __cplusplus
extern "C" {
#endif

/// Unconditional trap. Defined in `src/web/compat_impl.zig`.
void glin_compat_trap(void);

#ifdef __cplusplus
}
#endif

#ifdef NDEBUG
#define assert(expression) ((void)0)
#else
#define assert(expression) ((expression) ? (void)0 : glin_compat_trap())
#endif

// Some C code reaches for the glibc spelling directly.
#ifndef NDEBUG
#define __assert_fail(expr, file, line, fn) glin_compat_trap()
#endif

#endif // GLIN_COMPAT_ASSERT_H
