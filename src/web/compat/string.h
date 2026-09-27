// glinlandui freestanding C-compile compat: <string.h>
//
// Split in two, and the split matters:
//
//   - `memcpy`, `memmove`, `memset`, `memcmp` are DECLARED ONLY. Zig's
//     compiler_rt already defines them for a freestanding target — Zig itself
//     lowers `@memcpy` and `@memset` into calls to them — so defining them here
//     as well would be a duplicate symbol at link time. Declaring them is
//     enough for the C TUs that call them.
//   - the `str*` family is DECLARED AND DEFINED in `src/web/compat_impl.zig`.
//     compiler_rt does not provide it, and prioritising "small and correct" over
//     "gratuitously clever" that is a 30-line Zig file rather than a port of
//     musl's optimised versions.
//
// If the split is wrong, the linker says so: a missed declaration shows up as
// `undefined symbol: <name>` and a duplicated definition as a redefinition
// error. Both are one-line fixes, which is what makes this a bounded job.
#ifndef GLIN_COMPAT_STRING_H
#define GLIN_COMPAT_STRING_H

#include <stddef.h>

// Provided by Zig's compiler_rt — declared, never defined here.
void *memcpy(void *dst, const void *src, size_t n);
void *memmove(void *dst, const void *src, size_t n);
void *memset(void *dst, int byte, size_t n);
int memcmp(const void *a, const void *b, size_t n);

// Provided by src/web/compat_impl.zig.
size_t strlen(const char *s);
int strcmp(const char *a, const char *b);
int strncmp(const char *a, const char *b, size_t n);
char *strcpy(char *dst, const char *src);
char *strncpy(char *dst, const char *src, size_t n);
char *strchr(const char *s, int c);
char *strrchr(const char *s, int c);
char *strstr(const char *haystack, const char *needle);

#endif // GLIN_COMPAT_STRING_H
