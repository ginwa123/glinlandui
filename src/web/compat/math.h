// glinlandui freestanding C-compile compat: <math.h>
//
// DECLARATIONS ONLY — and here that is a deliberate bet, not laziness.
//
// Zig's compiler_rt ships a musl-derived scalar libm for freestanding targets
// (the same source tree that gives you `memcpy`), which is why these are not
// reimplemented in `compat_impl.zig`: a second `sqrt` would be a duplicate
// symbol, and hand-rolling `acot`-adjacent float math to avoid a dependency we
// already have would be the wrong trade. If that bet is wrong the linker says so
// with `undefined symbol: floor` and the fix is to add a `@floor`-backed
// definition in `compat_impl.zig` — one function, one line.
//
// These are the functions reachable from the wasm closure:
//
//   stb_truetype  floor, ceil, sqrt, pow, fmod, cos, acos, fabs
//                 (STBTT_ifloor/iceil, STBTT_sqrt/pow, STBTT_fmod, STBTT_cos,
//                  STBTT_fabs — see stb_truetype.h's #ifndef blocks)
//   stb_image     ldexp, pow, fabs, sqrt, floor, ceil, cos, sin, exp, log, frexp
//   Clay          none (it only wants stdint/stdbool/stddef)
//
// The `f`-suffixed variants are declared as well because stb_image_resize2 uses
// them when it is not compiled with `-DSTBIR_NO_SIMD=1` (which the wasm build
// sets — see `stbFlags` in build.zig).
#ifndef GLIN_COMPAT_MATH_H
#define GLIN_COMPAT_MATH_H

double floor(double x);
double ceil(double x);
double trunc(double x);
double round(double x);
double sqrt(double x);
double pow(double x, double y);
double fmod(double x, double y);
double fabs(double x);
double cos(double x);
double sin(double x);
double acos(double x);
double exp(double x);
double log(double x);
double ldexp(double x, int e);
double frexp(double x, int *e);
double hypot(double x, double y);
double fmin(double x, double y);
double fmax(double x, double y);

float floorf(float x);
float ceilf(float x);
float truncf(float x);
float roundf(float x);
float sqrtf(float x);
float powf(float x, float y);
float fmodf(float x, float y);
float fabsf(float x);
float cosf(float x);
float sinf(float x);
float acosf(float x);
float expf(float x);
float logf(float x);
float ldexpf(float x, int e);
float frexpf(float x, int *e);
float hypotf(float x, float y);
float fminf(float x, float y);
float fmaxf(float x, float y);

// Macros a libc <math.h> would provide. Builtins rather than literals so the
// compiler folds them into the right bit pattern for each type.
#define INFINITY (__builtin_inff())
#define NAN (__builtin_nanf(""))
#define HUGE_VAL (__builtin_huge_val())
#define HUGE_VALF (__builtin_huge_valf())

#endif // GLIN_COMPAT_MATH_H
