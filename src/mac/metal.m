/* The Metal half of the macOS renderer. See metal.h for the contract.
 *
 * The shaders are compiled from source at start-up rather than shipped as a
 * .metallib, so the build needs no metal toolchain step and the GLSL in
 * linux/renderer.zig has an obvious MSL sibling to compare against.
 */
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

#include <stdlib.h>
#include "metal.h"

/* One vertex. Must stay in step with the struct in `vertex_src` below and with
 * `Vertex` in src/mac/renderer.zig — a mismatch here is a silent mis-draw. */
typedef struct {
    float pos[2];    /* pixel position, top-left origin */
    float local[2];  /* rect: box-local coords; text: atlas uv */
    float size[2];   /* rect: box size */
    float radius[4]; /* TL, TR, BL, BR */
    float color[4];  /* straight alpha, 0..1 */
    float mode;      /* 0 fill, 1 border */
    float border;    /* border width in pixels */
    float kind;      /* 0 rect, 1 text */
} GlinVertex;

struct GlinMetal {
    id<MTLDevice> device;
    id<MTLCommandQueue> queue;
    id<MTLRenderPipelineState> pipeline;
    id<MTLTexture> atlas;
    CAMetalLayer *layer;
    NSView *view;
    int width;
    int height;
    int atlas_w;
    int atlas_h;
};

static const char *vertex_src =
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "/* Arrays, not float2/float4: MSL aligns a float4 to 16 bytes, which would\n"
    " * silently disagree with the C GlinVertex this buffer is built from. */\n"
    "struct VIn {\n"
    "  float pos[2]; float local[2]; float size[2]; float radius[4]; float color[4];\n"
    "  float mode; float border; float kind;\n"
    "};\n"
    "struct VOut {\n"
    "  float4 position [[position]];\n"
    "  float2 local; float2 size; float4 radius; float4 color;\n"
    "  float mode; float border; float kind;\n"
    "};\n"
    "vertex VOut vs_main(const device VIn *verts [[buffer(0)]],\n"
    "                    constant float2 &res [[buffer(1)]],\n"
    "                    uint vid [[vertex_id]]) {\n"
    "  VIn v = verts[vid];\n"
    "  /* Clay's origin is top-left; Metal's clip space is y-up, so y flips. */\n"
    "  float2 clip = float2(v.pos[0] / res.x * 2.0 - 1.0, 1.0 - v.pos[1] / res.y * 2.0);\n"
    "  VOut o;\n"
    "  o.position = float4(clip, 0.0, 1.0);\n"
    "  o.local = float2(v.local[0], v.local[1]); o.size = float2(v.size[0], v.size[1]);\n"
    "  o.radius = float4(v.radius[0], v.radius[1], v.radius[2], v.radius[3]);\n"
    "  o.color = float4(v.color[0], v.color[1], v.color[2], v.color[3]);\n"
    "  o.mode = v.mode; o.border = v.border; o.kind = v.kind;\n"
    "  return o;\n"
    "}\n";

/* The SDF is the same expression as linux/renderer.zig's rect_frag_src, so the
 * two backends agree on coverage rather than merely looking similar. */
static const char *fragment_src =
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "struct VOut {\n"
    "  float4 position [[position]];\n"
    "  float2 local; float2 size; float4 radius; float4 color;\n"
    "  float mode; float border; float kind;\n"
    "};\n"
    "static float sdRoundBox(float2 p, float2 b, float4 r) {\n"
    "  float rad = (p.x < 0.0) ? (p.y < 0.0 ? r.x : r.z) : (p.y < 0.0 ? r.y : r.w);\n"
    "  float2 q = abs(p) - b + rad;\n"
    "  return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - rad;\n"
    "}\n"
    "static float cov(float d) { return clamp(0.5 - d, 0.0, 1.0); }\n"
    "fragment float4 fs_main(VOut in [[stage_in]],\n"
    "                        texture2d<float> atlas [[texture(0)]]) {\n"
    "  if (in.kind > 0.5) {\n"
    "    /* nearest: the CPU path blits one mask texel to one pixel, so any filtering would blur a difference in. */\n"
    "    constexpr sampler s(coord::normalized, filter::nearest, address::clamp_to_edge);\n"
    "    float a = atlas.sample(s, in.local).r;\n"
    "    if (a <= 0.0) discard_fragment();\n"
    "    return float4(in.color.rgb, in.color.a * a);\n"
    "  }\n"
    "  float2 c = in.size * 0.5;\n"
    "  float2 p = in.local - c;\n"
    "  float m = min(c.x, c.y);\n"
    "  float4 r = min(max(in.radius, float4(0.0)), float4(m));\n"
    "  float d = sdRoundBox(p, c, r);\n"
    "  float a = cov(d);\n"
    "  if (in.mode == 1.0) {\n"
    "    float2 ib = max(c - float2(in.border), float2(0.0));\n"
    "    float mi = min(ib.x, ib.y);\n"
    "    float4 ri = min(max(r - float4(in.border), float4(0.0)), float4(mi));\n"
    "    a *= (1.0 - cov(sdRoundBox(p, ib, ri)));\n"
    "  }\n"
    "  if (a <= 0.0) discard_fragment();\n"
    "  return float4(in.color.rgb, in.color.a * a);\n"
    "}\n";

static id<MTLRenderPipelineState> build_pipeline(GlinMetal *m, MTLPixelFormat format) {
    NSError *err = nil;
    id<MTLLibrary> vlib = [m->device newLibraryWithSource:[NSString stringWithUTF8String:vertex_src]
                                                  options:nil
                                                    error:&err];
    if (vlib == nil) {
        NSLog(@"glinlandui metal: vertex library failed: %@", err);
        return nil;
    }
    id<MTLLibrary> flib = [m->device newLibraryWithSource:[NSString stringWithUTF8String:fragment_src]
                                                  options:nil
                                                    error:&err];
    if (flib == nil) {
        NSLog(@"glinlandui metal: fragment library failed: %@", err);
        return nil;
    }

    MTLRenderPipelineDescriptor *d = [[MTLRenderPipelineDescriptor alloc] init];
    d.vertexFunction = [vlib newFunctionWithName:@"vs_main"];
    d.fragmentFunction = [flib newFunctionWithName:@"fs_main"];
    d.colorAttachments[0].pixelFormat = format;

    /* Straight-alpha source-over with the alpha channel kept saturated, exactly
     * as the GLES3 backend's glBlendFuncSeparate does. */
    MTLRenderPipelineColorAttachmentDescriptor *a = d.colorAttachments[0];
    a.blendingEnabled = YES;
    a.rgbBlendOperation = MTLBlendOperationAdd;
    a.alphaBlendOperation = MTLBlendOperationAdd;
    a.sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
    a.destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    a.sourceAlphaBlendFactor = MTLBlendFactorOne;
    a.destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;

    id<MTLRenderPipelineState> p = [m->device newRenderPipelineStateWithDescriptor:d error:&err];
    if (p == nil) {
        NSLog(@"glinlandui metal: pipeline failed: %@", err);
    }
    return p;
}

GlinMetal *glin_metal_create(void *nsview) {
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    if (dev == nil) {
        return NULL;
    }
    GlinMetal *m = (GlinMetal *)calloc(1, sizeof(GlinMetal));
    if (m == NULL) {
        return NULL;
    }
    m->device = dev;
    m->queue = [dev newCommandQueue];

    CAMetalLayer *layer = [CAMetalLayer layer];
    layer.device = dev;
    layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    layer.framebufferOnly = YES;
    layer.opaque = YES;
    m->layer = layer;

    NSView *view = (NSView *)nsview;
    if (view != nil) {
        // A SUBLAYER, not view.layer: replacing the view's own layer stops AppKit
        // calling drawRect:, which is what drives the frame loop.
        view.wantsLayer = YES;
        m->view = view;
        layer.frame = view.bounds;
        layer.contentsScale = view.window.backingScaleFactor;
        [view.layer addSublayer:layer];
    }

    m->pipeline = build_pipeline(m, MTLPixelFormatBGRA8Unorm);
    if (m->pipeline == nil) {
        free(m);
        return NULL;
    }
    return m;
}

void glin_metal_destroy(GlinMetal *m) {
    if (m == NULL) {
        return;
    }
    m->pipeline = nil;
    m->atlas = nil;
    [m->layer removeFromSuperlayer];
    m->layer = nil;
    m->view = nil;
    m->queue = nil;
    m->device = nil;
    free(m);
}

int glin_metal_resize(GlinMetal *m, int w, int h) {
    if (m == NULL || w <= 0 || h <= 0) {
        return 0;
    }
    m->width = w;
    m->height = h;
    if (m->view != nil) {
        m->layer.frame = m->view.bounds;
        m->layer.contentsScale = m->view.window.backingScaleFactor;
    }
    m->layer.drawableSize = CGSizeMake((CGFloat)w, (CGFloat)h);
    return 1;
}

void glin_metal_set_atlas(GlinMetal *m, const unsigned char *bytes, int w, int h) {
    if (m == NULL || bytes == NULL || w <= 0 || h <= 0) {
        return;
    }
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm
                                                                                 width:(NSUInteger)w
                                                                                height:(NSUInteger)h
                                                                             mipmapped:NO];
    d.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> t = [m->device newTextureWithDescriptor:d];
    if (t == nil) {
        return;
    }
    [t replaceRegion:MTLRegionMake2D(0, 0, (NSUInteger)w, (NSUInteger)h)
         mipmapLevel:0
           withBytes:bytes
         bytesPerRow:(NSUInteger)w];
    m->atlas = t;
    m->atlas_w = w;
    m->atlas_h = h;
}

/* Shared by the on-screen and offscreen paths so the two cannot drift. */
static void encode_segments(GlinMetal *m, id<MTLRenderCommandEncoder> enc, const void *verts,
                            int total_verts, const GlinSegment *segs, int seg_count) {
    if (m->atlas != nil) {
        [enc setFragmentTexture:m->atlas atIndex:0];
    }
    if (verts == NULL || segs == NULL || seg_count <= 0) {
        return;
    }
    [enc setVertexBytes:verts length:(NSUInteger)total_verts * sizeof(GlinVertex) atIndex:0];
    float res[2] = { (float)m->width, (float)m->height };
    [enc setVertexBytes:res length:sizeof(res) atIndex:1];

    for (int i = 0; i < seg_count; i++) {
        const GlinSegment *s = &segs[i];
        if (s->count <= 0) {
            continue;
        }
        /* MTLScissorRect is a plain struct; there is no Make function. */
        MTLScissorRect rect;
        if (s->has_scissor) {
            rect = (MTLScissorRect){ (NSUInteger)(s->sx < 0 ? 0 : s->sx),
                                     (NSUInteger)(s->sy < 0 ? 0 : s->sy),
                                     (NSUInteger)(s->sw < 0 ? 0 : s->sw),
                                     (NSUInteger)(s->sh < 0 ? 0 : s->sh) };
        } else {
            rect = (MTLScissorRect){ 0, 0, (NSUInteger)m->width, (NSUInteger)m->height };
        }
        [enc setScissorRect:rect];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle
                vertexStart:(NSUInteger)s->start
                vertexCount:(NSUInteger)s->count];
    }
}

int glin_metal_draw(GlinMetal *m, const void *verts,
                    const GlinSegment *segs, int seg_count,
                    double r, double g, double b, double a) {
    if (m == NULL || m->layer == nil || m->pipeline == nil) {
        return 0;
    }
    @autoreleasepool {
        id<CAMetalDrawable> drawable = [m->layer nextDrawable];
        if (drawable == nil) {
            return 0;
        }
        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = drawable.texture;
        pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        pass.colorAttachments[0].clearColor = MTLClearColorMake(r, g, b, a);

        int total = (seg_count > 0) ? (segs[seg_count - 1].start + segs[seg_count - 1].count) : 0;

        id<MTLCommandBuffer> cb = [m->queue commandBuffer];
        id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:pass];
        [enc setRenderPipelineState:m->pipeline];
        encode_segments(m, enc, verts, total, segs, seg_count);
        [enc endEncoding];
        [cb presentDrawable:drawable];
        [cb commit];
    }
    return 1;
}

unsigned char *glin_metal_offscreen(GlinMetal *m, const void *verts,
                                    const GlinSegment *segs, int seg_count,
                                    int w, int h,
                                    double r, double g, double b, double a) {
    if (m == NULL || m->pipeline == nil || w <= 0 || h <= 0) {
        return NULL;
    }
    int saved_w = m->width;
    int saved_h = m->height;
    m->width = w;
    m->height = h;

    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                 width:(NSUInteger)w
                                                                                height:(NSUInteger)h
                                                                             mipmapped:NO];
    d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    d.storageMode = MTLStorageModeManaged;
    id<MTLTexture> tex = [m->device newTextureWithDescriptor:d];
    if (tex == nil) {
        m->width = saved_w;
        m->height = saved_h;
        return NULL;
    }

    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = tex;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(r, g, b, a);

    int total = (seg_count > 0) ? (segs[seg_count - 1].start + segs[seg_count - 1].count) : 0;

    id<MTLCommandBuffer> cb = [m->queue commandBuffer];
    id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:pass];
    [enc setRenderPipelineState:m->pipeline];
    encode_segments(m, enc, verts, total, segs, seg_count);
    [enc endEncoding];
    /* A managed texture's GPU writes are not visible to the CPU until a blit
     * synchronises them; without this getBytes returns stale zeros. */
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    [blit synchronizeResource:tex];
    [blit endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    if (cb.error != nil) {
        NSLog(@"glinlandui metal: offscreen command buffer failed: %@", cb.error);
    }

    NSUInteger len = (NSUInteger)w * (NSUInteger)h * 4;
    unsigned char *out = (unsigned char *)malloc(len);
    if (out != NULL) {
        [tex getBytes:out
            bytesPerRow:(NSUInteger)w * 4
             fromRegion:MTLRegionMake2D(0, 0, (NSUInteger)w, (NSUInteger)h)
            mipmapLevel:0];
    }
    m->width = saved_w;
    m->height = saved_h;
    return out;
}

void glin_metal_free(void *p) {
    free(p);
}
