/* Metal renderer for the macOS backend.
 *
 * Plain C by design, like shim.h: @cImport never has to survive Objective-C
 * macros or Metal's C++ headers. The Objective-C lives in metal.m.
 *
 * The toolkit builds one interleaved vertex buffer per frame plus the scissor
 * segments that clip it, and hands both here; this file owns the device, the
 * CAMetalLayer, the pipeline and the glyph atlas, and knows nothing about Clay.
 */
#ifndef GLIN_METAL_H
#define GLIN_METAL_H

#include <stddef.h>

typedef struct GlinMetal GlinMetal;

/* A run of vertices sharing one scissor state. Clay interleaves boxes and text,
 * so a scrolled container's clip cannot be a single per-frame rectangle. */
typedef struct {
    int start;      /* first vertex index */
    int count;      /* vertex count */
    int has_scissor;/* 0 = no clip */
    int sx, sy, sw, sh; /* scissor in device pixels, top-left origin */
    unsigned int texture_id; /* 0 = glyph atlas, otherwise an image from glin_metal_set_image */
} GlinSegment;

/* Attach a CAMetalLayer to `nsview` and build the pipeline. NULL when the
 * machine has no Metal device, so the caller can fall back to the CPU path. */
GlinMetal *glin_metal_create(void *nsview);

void glin_metal_destroy(GlinMetal *m);

/* Match the drawable to the view's backing size, in device pixels. */
int glin_metal_resize(GlinMetal *m, int w, int h);

/* Replace the R8 glyph atlas. Called only when the atlas changed. */
void glin_metal_set_atlas(GlinMetal *m, const unsigned char *bytes, int w, int h);

/* Upload an RGBA8 image under `id` (1..GLIN_METAL_MAX_IMAGES). Replaces any texture already stored there. */
#define GLIN_METAL_MAX_IMAGES 32
void glin_metal_set_image(GlinMetal *m, unsigned int image_id, const unsigned char *rgba, int w, int h);

/* Clear to the given colour, draw every segment, present. 0 when there is no
 * drawable this frame (the window is off-screen or minimised). */
int glin_metal_draw(GlinMetal *m, const void *verts,
                    const GlinSegment *segs, int seg_count,
                    double r, double g, double b, double a);

/* Render the same vertices into an offscreen texture and read them back as
 * BGRA bytes, so the GPU output can be compared with the CPU reference. */
unsigned char *glin_metal_offscreen(GlinMetal *m, const void *verts,
                                    const GlinSegment *segs, int seg_count,
                                    int w, int h,
                                    double r, double g, double b, double a);

void glin_metal_free(void *p);

#endif /* GLIN_METAL_H */
