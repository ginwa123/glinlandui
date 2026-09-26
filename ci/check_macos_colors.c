// glinlandui macOS colour hand-off check.
//
// WHY THIS EXISTS, AND WHY IT IS NOT A ZIG TEST
// ----------------------------------------------
// `mac/present.zig` has a full suite of tests for the blit transform, and
// every one of them passes while the macOS window renders in the wrong
// colours. They all have the same blind spot: they compare the blit buffer
// against the surface it was copied from, i.e. against the implementation's
// own idea of the answer. The thing that was actually wrong — how
// CoreGraphics DECODES those bytes — lives in `mac/shim.m`, and it cannot be
// reached from `zig build test` because that suite must stay
// platform-neutral (`platform.zig` selects `core/window_portable.zig` under
// `builtin.is_test`, which is what keeps the Linux and macOS test counts
// identical).
//
// So this check reproduces the display path for real and measures the
// DISPLAYED colour:
//
//   1. build a bitmap with EXACTLY the `CGBitmapInfo` from `mac/shim.m`
//      (`GLIN_CHECK_BITMAP_INFO` is injected by `zig build`, so the constant
//      under test is the one in the shim, not a copy of it),
//   2. memcpy in a known RGBA8 pattern,
//   3. `CGBitmapContextCreateImage` + `CGContextDrawImage`, exactly as
//      `-drawRect:` does,
//   4. draw the result into a second bitmap whose format we choose
//      (`kCGImageAlphaNoneSkipLast | kCGBitmapByteOrder32Big` == plain
//      R,G,B,A in memory), which lets us read what the user would see.
//
// That last step is the whole point: it needs no window server, no GUI
// session and no Screen Recording permission, and it is exact rather than
// eyeballed.
//
// THE BUG IT GUARDS
// -----------------
// `kCGBitmapByteOrder32Little` reverses the component order of a 32-bit
// pixel on a little-endian host. Combined with `kCGImageAlphaPremultipliedLast`
// the memory bytes are therefore A, B, G, R — so a source pixel (R,G,B,A) is
// DISPLAYED as (A,B,G,R). The calculator's 0x101014 background came out as
// bright red (255,20,16) and the `=` key's accent blue 0x2f6df6 came out as
// yellow (255,246,109). No crash, no warning, no failing test.
//
// Build (see check_macos_colors.sh) and run: exits 0 when every probe colour
// survives the round trip, 1 otherwise.

// CoreGraphics only: every call used here is plain C, so this stays a `.c`
// translation unit (no Foundation, no ObjC, no ARC).
#include <CoreGraphics/CoreGraphics.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifndef GLIN_CHECK_BITMAP_INFO
#error "GLIN_CHECK_BITMAP_INFO must be defined to the same value shim.m uses"
#endif
#ifndef GLIN_CHECK_BYTE_ORDER
#error "GLIN_CHECK_BYTE_ORDER must name the byte-order flag shim.m uses"
#endif

/// One probe: an RGBA8 pixel we push in, and what we read back out.
typedef struct {
    unsigned char r, g, b, a;
    const char *name;
} Probe;

int main(void) {
    {
        // Chosen to catch every plausible mis-decode, not just a swap:
        //  - greys, where a red/blue swap is invisible,
        //  - the calculator's real background / panel / key / accent colours,
        //  - saturated primaries, where any channel rotation is obvious.
        const Probe probes[] = {
            {0x10, 0x10, 0x14, 0xff, "root background 0x101014"},
            {0x1b, 0x1b, 0x21, 0xff, "display panel    0x1b1b21"},
            {0x26, 0x26, 0x2e, 0xff, "digit key        0x26262e"},
            {0x3a, 0x3a, 0x46, 0xff, "operator key     0x3a3a46"},
            {0x2f, 0x6d, 0xf6, 0xff, "'=' accent blue  0x2f6df6"},
            {0xf0, 0xf0, 0xf5, 0xff, "label foreground 0xf0f0f5"},
            {0xff, 0x6b, 0x6b, 0xff, "error red        0xff6b6b"},
            {0x10, 0x10, 0x14, 0xff, "grey (swap-blind)"},
            {0x80, 0x80, 0x80, 0xff, "mid grey (swap-blind)"},
            {0xff, 0x00, 0x00, 0xff, "pure red"},
            {0x00, 0xff, 0x00, 0xff, "pure green"},
            {0x00, 0x00, 0xff, 0xff, "pure blue"},
        };
        const size_t n = sizeof(probes) / sizeof(probes[0]);
        const int w = (int)n, h = 1;
        const size_t bytes = (size_t)w * h * 4;

        unsigned char *src = calloc(1, bytes);
        for (size_t i = 0; i < n; i++) {
            src[i * 4 + 0] = probes[i].r;
            src[i * 4 + 1] = probes[i].g;
            src[i * 4 + 2] = probes[i].b;
            src[i * 4 + 3] = probes[i].a;
        }

        // --- 1. the shim's own bitmap info, on the shim's own buffer ---
        unsigned char *px = calloc(1, bytes);
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGContextRef bmp = CGBitmapContextCreate(px, w, h, 8, (size_t)w * 4, cs,
                                                 (CGBitmapInfo)GLIN_CHECK_BITMAP_INFO);
        CGColorSpaceRelease(cs);
        if (!bmp) {
            fprintf(stderr,
                    "FAIL: CGBitmapContextCreate rejected the shim's bitmap info "
                    "(%s)\n", GLIN_CHECK_BYTE_ORDER);
            free(src); free(px);
            return 1;
        }
        memcpy(px, src, bytes);

        // --- 2/3. exactly what -drawRect: does ---
        CGImageRef img = CGBitmapContextCreateImage(bmp);
        if (!img) {
            fprintf(stderr, "FAIL: CGBitmapContextCreateImage returned NULL\n");
            CGContextRelease(bmp); free(src); free(px);
            return 1;
        }

        // --- 4. read the DISPLAYED colour into a format we control ---
        unsigned char *out = calloc(1, bytes);
        CGColorSpaceRef cs2 = CGColorSpaceCreateDeviceRGB();
        CGContextRef rd = CGBitmapContextCreate(out, w, h, 8, (size_t)w * 4, cs2,
                                                kCGImageAlphaNoneSkipLast |
                                                kCGBitmapByteOrder32Big);
        CGColorSpaceRelease(cs2);
        if (!rd) {
            fprintf(stderr, "FAIL: could not build the read-back context\n");
            CGImageRelease(img); CGContextRelease(bmp); free(src); free(px); free(out);
            return 1;
        }
        CGContextSetRGBFillColor(rd, 0, 0, 0, 1);
        CGContextFillRect(rd, CGRectMake(0, 0, w, h));
        CGContextDrawImage(rd, CGRectMake(0, 0, w, h), img);

        int bad = 0;
        printf("macOS colour hand-off (%s)\n", GLIN_CHECK_BYTE_ORDER);
        printf("  %-26s %-12s %-12s %s\n", "probe", "source", "displayed", "");
        for (size_t i = 0; i < n; i++) {
            unsigned char *o = out + i * 4;
            int ok = o[0] == probes[i].r && o[1] == probes[i].g &&
                     o[2] == probes[i].b && o[3] == probes[i].a;
            if (!ok) bad++;
            printf("  %-26s %02x%02x%02x%02x     %02x%02x%02x%02x     %s\n",
                   probes[i].name, probes[i].r, probes[i].g, probes[i].b, probes[i].a,
                   o[0], o[1], o[2], o[3], ok ? "ok" : "MISMATCH");
        }

        CGImageRelease(img);
        CGContextRelease(bmp);
        CGContextRelease(rd);
        free(src); free(px); free(out);

        if (bad) {
            fprintf(stderr,
                    "\nFAIL: %d of %zu probe colours are not displayed as they are "
                    "written.\n"
                    "  kCGBitmapByteOrder32Little reverses a 32-bit pixel's component "
                    "order on a\n"
                    "  little-endian host, so with kCGImageAlphaPremultipliedLast the "
                    "memory bytes\n"
                    "  are A,B,G,R and every pixel is DISPLAYED as (A,B,G,R) — the "
                    "alpha lands in\n"
                    "  the red channel and the whole window turns red. mac/present.zig "
                    "produces plain\n"
                    "  R,G,B,A, so mac/shim.m needs kCGBitmapByteOrder32Big.\n",
                    bad, n);
            return 1;
        }
        printf("\nPASS: all %zu probe colours survive the CoreGraphics hand-off "
               "unchanged.\n", n);
        return 0;
    }
}
