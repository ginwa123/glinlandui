// glinlandui freestanding C-compile compat: <stdlib.h>
//
// ## What this is
//
// `wasm32-freestanding` has no libc, so `@cImport` of `vendor/stb/...` and the
// two vendored stb TUs would fail on `#include <stdlib.h>` before producing a
// single bit of machine code. This header supplies the DECLARATIONS; the
// definitions live in `src/web/compat_impl.zig` as `export fn`s, because
// allocating in C to satisfy a C compiler is not the point — the point is that
// the symbol exists and that we own its behaviour.
//
// ## Why an include path and not a libc port
//
// The surface is tiny and the linker enumerates it for you: compile, link, and
// every symbol you forgot appears as `undefined symbol: <name>`. That is the
// whole reason this is a bounded job rather than a port. `stb_truetype` and
// `stb_image` between them want malloc/free/realloc, strlen/strcmp, and the
// scalar math functions; Clay wants none of it (it is already built
// `-ffreestanding` and uses only stdint/stdbool/stddef).
//
// ## The include path must be GATED
//
// This directory may only be on the include path of a wasm target. Both
// `src/linux/` and `src/mac/` also expose a header called `shim.h` and rely on
// their include paths being mutually exclusive (src/README.md I4); this is the
// same trap one level down, because an unconditional compat path would let
// `stb_truetype.h`'s `#include <stdlib.h>` resolve to THIS header on a native
// build and silently change what Linux and macOS compile against. Rule R7 in
// `ci/check_layering.sh` watches for it.
//
// ## Not declared here, on purpose
//
// `qsort`, `getenv`, `atoi`, `exit`: nothing in the wasm closure calls them.
// Declaring a function we do not define turns a link error into a runtime trap,
// so the list stays as short as the real dependency set — which the linker is
// happy to correct if this comment is wrong.
#ifndef GLIN_COMPAT_STDLIB_H
#define GLIN_COMPAT_STDLIB_H

#include <stddef.h>

void *malloc(size_t n);
void *calloc(size_t n, size_t size);
void *realloc(void *ptr, size_t n);
void free(void *ptr);

/// C's `abort`: terminate. On wasm that is an unconditional trap, which the host
/// reports as a `RuntimeError: unreachable` — the closest thing a browser has to
/// a core dump.
void abort(void);

int abs(int x);

/// String-to-integer conversion. `stb_image`'s PNM parser calls this (it is the
/// only caller in the wasm closure), and it is the one function here whose
/// behaviour is worth being careful about: C's `strtol` skips leading whitespace,
/// takes an optional sign, and reports where it stopped through `endptr`.
///
/// `base` is honoured for 0 (auto-detect) and 10, which is all stb uses; any other
/// base is treated as 10 rather than silently mis-parsed. `endptr` may be null.
long strtol(const char *s, char **endptr, int base);

#endif // GLIN_COMPAT_STDLIB_H
