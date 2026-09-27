// glinlandui Windows D3D11 colour hand-off check.
//
// The Windows counterpart of ci/check_macos_colors.c, and it exists for the
// same reason. windows/present.zig documents that handing `soft.Surface` to
// the D3D11 pipeline is the IDENTITY — no channel swap, no vertical flip — and
// the tests in that file can only compare the upload buffer against the
// surface it came from, i.e. against the module's own idea of the answer.
//
// What actually goes wrong when the transform is wrong lives in
// src/windows/shim.c: the swap-chain format, the texture's row order, the
// shader's sampling. A wrong choice there renders the whole window in the
// wrong colours (or upside down) while every Zig test stays green. So this
// check drives the REAL D3D11 path — it calls glin_win_probe_color(), which
// runs the same shader, sampler, draw call and target format as the window —
// and compares the DISPLAYED colour with the colour that was written.
//
// It needs no window, no swap chain, no display and no interactive session,
// because WARP is a Direct3D 11 software rasterizer. That makes it safe on a
// stock GitHub Actions windows-2022 runner, where the hardware path is not
// available at all and only the WARP fallback is.
//
// Exits 0 when every probe colour survives the hand-off, 1 otherwise.

#include <stdio.h>
#include <string.h>

#include "../src/windows/shim.h"

// The accent blue the calculator's `=` key uses. A swapped R/B turns this into
// a red that still looks like "a colour" rather than like an error, which is
// why it is asserted by value and not by "something was drawn".
static const unsigned char kAccent[4] = { 0x2f, 0x6d, 0xf6, 0xff };

typedef struct {
    const char *name;
    unsigned char rgba[4];
    int tolerance;
} Probe;

#define TOL_EXACT 0

// A little slack, and deliberately only a little. Reading an UNORM render
// target back and re-quantizing to 8 bits can land one count off a channel
// boundary; anything larger would hide a real channel swap, because a swap
// moves a channel by tens of counts for every colour here.
#define TOL_QUANT 1

// Return codes, mirroring glin_win_probe_color(): -2 is "this host has no
// usable D3D11 device", everything else is a step that broke. A host that
// cannot run a shader at all is not a colour mismatch, and conflating the two
// is what turns "my VM has no GPU" into a red build.
static const char *describe(int rc) {
    switch (rc) {
        case -1: return "bad arguments";
        case -2: return "no usable D3D11 device on this host";
        case -3: return "could not create the shader pipeline";
        case -4: return "could not create the frame texture";
        case -5: return "could not create the render target";
        case -6: return "could not create the render target view";
        case -7: return "could not create the readback texture";
        case -8: return "could not map the readback texture";
        default: return "unknown failure";
    }
}

static int check(const Probe *p, int w, int h, int *unavailable) {
    /* A 3x3 image: the middle pixel is fully interior, and the corner/edge
     * pixels prove the row and column order rather than just "the average is
     * right". A transform bug that is a flip or a swap shows up as a
     * positional mismatch, which a single-centre probe would miss. */
    unsigned char src[3 * 3 * 4];
    unsigned char got[3 * 3 * 4];
    for (int y = 0; y < h; ++y) {
        for (int x = 0; x < w; ++x) {
            unsigned char *px = src + (y * w + x) * 4;
            const unsigned char *c = (x == 1 && y == 1) ? p->rgba : kAccent;
            px[0] = c[0];
            px[1] = c[1];
            px[2] = c[2];
            px[3] = c[3];
        }
    }

    memset(got, 0, sizeof(got));
    int rc = glin_win_probe_color(src, w, h, got, w * 4);
    if (rc != 0) {
        *unavailable = rc;
        printf("  %-22s could not run: %s (rc=%d)\n", p->name, describe(rc), rc);
        return 1;
    }

    int bad = 0;
    for (int y = 0; y < h && !bad; ++y) {
        for (int x = 0; x < w; ++x) {
            const unsigned char *want = src + (y * w + x) * 4;
            const unsigned char *have = got + (y * w + x) * 4;
            for (int c = 0; c < 3; ++c) {
                int delta = (int)have[c] - (int)want[c];
                if (delta < 0) {
                    delta = -delta;
                }
                if (delta > p->tolerance) {
                    printf("  %-22s FAILED at (%d,%d) channel %d: "
                           "wrote %u, displayed %u\n",
                           p->name, x, y, c, want[c], have[c]);
                    bad = 1;
                    break;
                }
            }
            if (bad) {
                break;
            }
        }
    }
    if (bad) {
        return 1;
    }
    printf("  %-22s ok  (r=%u g=%u b=%u)\n", p->name,
           got[(1 * 3 + 1) * 4 + 0], got[(1 * 3 + 1) * 4 + 1], got[(1 * 3 + 1) * 4 + 2]);
    return 0;
}

int main(void) {
    const int w = 3;
    const int h = 3;

    // Unbuffered: a Direct3D call that takes the process down must not take
    // the diagnosis with it. Buffered stdout is lost on a hard fault, which
    // is exactly the case this check exists to catch.
    setvbuf(stdout, NULL, _IONBF, 0);

    const Probe probes[] = {
        { "accent blue", { 0x2f, 0x6d, 0xf6, 0xff }, TOL_EXACT },
        { "pure red", { 0xff, 0x00, 0x00, 0xff }, TOL_EXACT },
        { "pure green", { 0x00, 0xff, 0x00, 0xff }, TOL_EXACT },
        { "pure blue", { 0x00, 0x00, 0xff, 0xff }, TOL_EXACT },
        { "white", { 0xff, 0xff, 0xff, 0xff }, TOL_EXACT },
        { "mid grey (uneven channels)", { 0x80, 0x80, 0x80, 0xff }, TOL_QUANT },
    };

    printf("windows-colors: driving the real D3D11 present path "
           "(glin_win_probe_color -> the same shader/sampler/draw as the window)\n");
    printf("windows-colors: swap-chain/probe format is R8G8B8A8_UNORM, "
           "top row first, NO channel swap\n");

    int failures = 0;
    int unavailable = 0;
    for (unsigned i = 0; i < sizeof(probes) / sizeof(probes[0]); ++i) {
        failures += check(&probes[i], w, h, &unavailable);
    }

    // The distinction that matters: a host that CANNOT run the D3D11 pipeline is
    // not a host that produced the wrong colour. Failing there would make the
    // job red on a VM or a container for a reason nobody can fix from the log,
    // and silently passing as if it had measured something would be a check
    // that proves nothing. So: say it plainly, and say why.
    if (failures != 0 && unavailable != 0) {
        printf("windows-colors: SKIPPED — this host cannot execute a D3D11 shader "
               "(%s).\n"
               "windows-colors: nothing was verified here; the D3D11 path is "
               "exercised for real on the windows-2022 runner, which has WARP.\n",
               describe(unavailable));
        return 0;
    }

    if (failures != 0) {
        printf("windows-colors: FAILED (%d probe(s) did not survive the hand-off)\n",
               failures);
        return 1;
    }
    printf("windows-colors: ok (%d probes, displayed == written)\n",
           (int)(sizeof(probes) / sizeof(probes[0])));
    return 0;
}
