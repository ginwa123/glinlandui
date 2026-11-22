/* Vulkan renderer for the Linux backend.
 *
 * Plain C by design, like mac/metal.h: Zig's @cImport only ever sees this
 * file, so the Vulkan headers never have to survive translation. The
 * implementation lives in vk.c.
 *
 * The split of responsibility is the one every backend here uses:
 *   - Zig owns ALL logic. Layout, geometry, the text and image caches, clip
 *     arithmetic, the Delegate contract, keycode translation.
 *   - This shim owns ONLY the VkInstance, the device, the swapchain, the
 *     pipelines and the texture table. It makes no decisions.
 *
 * The toolkit builds ONE interleaved vertex buffer per frame plus the scissor
 * segments that clip it, and hands both here; what comes back on screen is
 * whatever the shaders make of them.
 */
#ifndef GLIN_VK_H
#define GLIN_VK_H

#include <stddef.h>

typedef struct GlinVk GlinVk;

/* One vertex, 17 tightly packed floats (68 bytes). The same layout
 * mac/metal.h declares, so a renderer port between backends is a change of
 * call site and nothing else.
 *
 * The fields are float ARRAYS, never a float4: an array has no alignment
 * requirement beyond its element, so the input layout in vk.c can spell every
 * offset out and nothing depends on a compiler's idea of packing.
 */
typedef struct {
    float pos[2];    /* device pixels, top-left origin */
    float local[2];  /* rect: box-local px; text/image: normalized uv */
    float size[2];   /* rect box size in device px; 0 for text/image */
    float radius[4]; /* rect corner radii TL, TR, BL, BR in device px */
    float color[4];  /* straight (non-premultiplied) 0..1 RGBA */
    float mode;      /* rect: 0 fill, 1 border outline */
    float border;    /* rect: border width in device px */
    float kind;      /* 0 rect, 1 text coverage, 2 image */
} GlinVkVertex;

/* A run of vertices sharing one scissor state and one texture. Clay
 * interleaves boxes and text, so a scrolled container's clip cannot be a
 * single per-frame rectangle. */
typedef struct {
    int start;      /* first vertex index */
    int count;      /* vertex count */
    int has_scissor;/* 0 = no clip */
    int sx, sy, sw, sh; /* scissor in device pixels, top-left origin */
    unsigned int texture_id; /* 0 = no texture (rects) */
    int kind;       /* 0 rect, 1 text, 2 image — picks the pipeline */
} GlinSegment;

/* Create the renderer for a Wayland surface (`wl_display *` / `wl_surface *`),
 * or headless when `wl_surface` is NULL. `w`/`h` are the initial device-pixel
 * size. The four SPIR-V blobs are the shaders; passing them from Zig is what
 * keeps the binaries out of C.
 *
 * NULL when this machine has no Vulkan device (or no wayland surface could be
 * created from it); glin_vk_last_error() then says why. */
GlinVk *glin_vk_create(void *wl_display, void *wl_surface, int w, int h,
                       const unsigned char *vert_spv, size_t vert_len,
                       const unsigned char *rect_frag_spv, size_t rect_len,
                       const unsigned char *text_frag_spv, size_t text_len,
                       const unsigned char *image_frag_spv, size_t image_len);

void glin_vk_destroy(GlinVk *v);

/* Match the swapchain to the surface's device-pixel size. 0 when the
 * swapchain is (now) the requested size, negative when it could not be. */
int glin_vk_resize(GlinVk *v, int w, int h);

/* Upload `bytes` as texture `id` (1..GLIN_VK_MAX_TEXTURES-1). `channels` is 1
 * for an 8-bit coverage mask (text) or 4 for RGBA8 (images). Replaces whatever
 * was stored under that id. 0 on success.
 *
 * This waits for the device, because the common case is a cache miss that
 * allocates a texture while nothing is being drawn. */
#define GLIN_VK_MAX_TEXTURES 128
int glin_vk_set_texture(GlinVk *v, unsigned int id,
                        const unsigned char *bytes, int w, int h, int channels);

/* Clear to the given colour, draw every segment, present. 0 when a frame was
 * presented, negative when there is no usable surface right now (minimised,
 * out of date, no swapchain). */
int glin_vk_draw(GlinVk *v, const GlinVkVertex *verts, int nverts,
                 const GlinSegment *segs, int nsegs,
                 float r, float g, float b, float a);

/* Render the same vertices into an offscreen RGBA8 target and write the
 * displayed bytes into `out` (w*h*4, row 0 = top row), so the GPU output can
 * be compared against the CPU reference. Needs no window and no display.
 * 0 on success. */
int glin_vk_offscreen(GlinVk *v, const GlinVkVertex *verts, int nverts,
                      const GlinSegment *segs, int nsegs, int w, int h,
                      float r, float g, float b, float a,
                      unsigned char *out);

/* The physical device's name, for a log line ("llvmpipe (LLVM ...)" on
 * lavapipe). Empty before a device is created. */
const char *glin_vk_device_name(GlinVk *v);

/* Why the last glin_vk_create / glin_vk_resize / glin_vk_draw failed. Static
 * storage, valid until the next call. */
const char *glin_vk_last_error(void);

#endif /* GLIN_VK_H */
