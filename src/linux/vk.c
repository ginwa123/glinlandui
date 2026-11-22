/* Vulkan renderer for the Linux backend — the implementation of vk.h.
 *
 * Every decision is made in Zig; this file owns the Vulkan objects and
 * nothing else. That is the same split mac/metal.m uses, and it is the reason
 * this compiles as plain C: @cImport only ever sees vk.h, so the Vulkan
 * headers (and their macros) never have to survive translation.
 *
 * The drawing model is deliberately small: one vertex buffer per frame, one
 * draw call per segment, three pipelines (rect, text, image) chosen by
 * GlinSegment.kind, and a fixed table of textures addressed by id. The
 * geometry, the caches and the clip arithmetic all live in Zig.
 */

#define VK_USE_PLATFORM_WAYLAND_KHR

#include <vulkan/vulkan.h>

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "vk.h"

#define GLIN_VK_MAX_FRAMES 2
#define GLIN_VK_MAX_SWAP 8
// The offscreen target is always RGBA8, whatever the swapchain format is, so a readback is a byte copy.
#define GLIN_VK_OFF_FORMAT VK_FORMAT_R8G8B8A8_UNORM
#define GLIN_VK_VERTEX_SIZE 68
#define GLIN_VK_INITIAL_VERTS (64 * 1024)

static char g_error[256];

const char *glin_vk_last_error(void) {
    return g_error;
}

static int fail(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(g_error, sizeof g_error, fmt, ap);
    va_end(ap);
    return -1;
}

typedef struct {
    VkImage image;
    VkDeviceMemory memory;
    VkImageView view;
    VkDescriptorSet set;
    int w, h, channels, live;
} Tex;

typedef struct {
    VkBuffer buffer;
    VkDeviceMemory memory;
    void *map;
    VkDeviceSize cap;
    VkCommandBuffer cmd;
    VkFence fence;
    VkSemaphore sem_image;
    VkSemaphore sem_done;
} Frame;

struct GlinVk {
    VkInstance instance;
    VkSurfaceKHR surface;
    int has_surface;

    VkPhysicalDevice phys;
    VkPhysicalDeviceMemoryProperties mem_props;
    VkDevice dev;
    uint32_t queue_family;
    VkQueue queue;
    char name[256];

    VkSwapchainKHR sc;
    VkFormat sc_format;
    VkExtent2D sc_extent;
    uint32_t sc_count;
    VkImage sc_image[GLIN_VK_MAX_SWAP];
    VkImageView sc_view[GLIN_VK_MAX_SWAP];
    VkFramebuffer sc_fb[GLIN_VK_MAX_SWAP];
    VkRenderPass sc_pass;

    VkRenderPass off_pass;
    VkImage off_image;
    VkDeviceMemory off_memory;
    VkImageView off_view;
    VkFramebuffer off_fb;
    int off_w, off_h;
    VkBuffer read_buffer;
    VkDeviceMemory read_memory;
    void *read_map;
    VkDeviceSize read_cap;

    VkDescriptorSetLayout dsl;
    VkDescriptorPool dpool;
    VkPipelineLayout playout;
    VkRenderPass pipes_pass;
    VkPipeline pipe_rect;
    VkPipeline pipe_text;
    VkPipeline pipe_image;
    VkShaderModule vs;
    VkShaderModule fs_rect;
    VkShaderModule fs_text;
    VkShaderModule fs_image;
    VkSampler samp_nearest;
    VkSampler samp_linear;

    Tex tex[GLIN_VK_MAX_TEXTURES];

    Frame frames[GLIN_VK_MAX_FRAMES];
    uint32_t frame_index;
    VkCommandPool pool;
};

const char *glin_vk_device_name(GlinVk *v) {
    return v ? v->name : "";
}

// ---- Small helpers -----------------------------------------------------------------------------------------------------

static uint32_t mem_type_index(GlinVk *v, uint32_t bits, VkMemoryPropertyFlags want) {
    uint32_t i;
    for (i = 0; i < v->mem_props.memoryTypeCount; i++) {
        if ((bits & (1u << i)) && (v->mem_props.memoryTypes[i].propertyFlags & want) == want) return i;
    }
    return UINT32_MAX;
}

static int make_image(GlinVk *v, int w, int h, VkFormat fmt, VkImageUsageFlags usage,
                      VkImage *out_image, VkDeviceMemory *out_memory) {
    VkImageCreateInfo ci;
    memset(&ci, 0, sizeof ci);
    ci.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
    ci.imageType = VK_IMAGE_TYPE_2D;
    ci.format = fmt;
    ci.extent.width = (uint32_t)w;
    ci.extent.height = (uint32_t)h;
    ci.extent.depth = 1;
    ci.mipLevels = 1;
    ci.arrayLayers = 1;
    ci.samples = VK_SAMPLE_COUNT_1_BIT;
    ci.tiling = VK_IMAGE_TILING_OPTIMAL;
    ci.usage = usage;
    ci.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    ci.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;

    VkImage image = VK_NULL_HANDLE;
    if (vkCreateImage(v->dev, &ci, NULL, &image) != VK_SUCCESS) return fail("vkCreateImage failed (%dx%d)", w, h);

    VkMemoryRequirements req;
    vkGetImageMemoryRequirements(v->dev, image, &req);
    uint32_t type = mem_type_index(v, req.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
    if (type == UINT32_MAX) type = mem_type_index(v, req.memoryTypeBits, 0);
    if (type == UINT32_MAX) {
        vkDestroyImage(v->dev, image, NULL);
        return fail("no memory type for a %dx%d image", w, h);
    }

    VkMemoryAllocateInfo ai;
    memset(&ai, 0, sizeof ai);
    ai.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    ai.allocationSize = req.size;
    ai.memoryTypeIndex = type;
    VkDeviceMemory memory = VK_NULL_HANDLE;
    if (vkAllocateMemory(v->dev, &ai, NULL, &memory) != VK_SUCCESS) {
        vkDestroyImage(v->dev, image, NULL);
        return fail("vkAllocateMemory failed for a %dx%d image", w, h);
    }
    if (vkBindImageMemory(v->dev, image, memory, 0) != VK_SUCCESS) {
        vkDestroyImage(v->dev, image, NULL);
        vkFreeMemory(v->dev, memory, NULL);
        return fail("vkBindImageMemory failed");
    }
    *out_image = image;
    *out_memory = memory;
    return 0;
}

static int make_host_buffer(GlinVk *v, VkDeviceSize size, VkBufferUsageFlags usage,
                            VkBuffer *out_buffer, VkDeviceMemory *out_memory, void **out_map) {
    VkBufferCreateInfo ci;
    memset(&ci, 0, sizeof ci);
    ci.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
    ci.size = size;
    ci.usage = usage;
    ci.sharingMode = VK_SHARING_MODE_EXCLUSIVE;

    VkBuffer buffer = VK_NULL_HANDLE;
    if (vkCreateBuffer(v->dev, &ci, NULL, &buffer) != VK_SUCCESS) return fail("vkCreateBuffer failed (%llu bytes)", (unsigned long long)size);

    VkMemoryRequirements req;
    vkGetBufferMemoryRequirements(v->dev, buffer, &req);
    uint32_t type = mem_type_index(v, req.memoryTypeBits,
                                   VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
    if (type == UINT32_MAX) {
        vkDestroyBuffer(v->dev, buffer, NULL);
        return fail("no host-visible memory type (%llu bytes)", (unsigned long long)size);
    }

    VkMemoryAllocateInfo ai;
    memset(&ai, 0, sizeof ai);
    ai.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    ai.allocationSize = req.size;
    ai.memoryTypeIndex = type;
    VkDeviceMemory memory = VK_NULL_HANDLE;
    if (vkAllocateMemory(v->dev, &ai, NULL, &memory) != VK_SUCCESS) {
        vkDestroyBuffer(v->dev, buffer, NULL);
        return fail("vkAllocateMemory failed for a host buffer");
    }
    if (vkBindBufferMemory(v->dev, buffer, memory, 0) != VK_SUCCESS) {
        vkDestroyBuffer(v->dev, buffer, NULL);
        vkFreeMemory(v->dev, memory, NULL);
        return fail("vkBindBufferMemory failed");
    }
    void *map = NULL;
    if (vkMapMemory(v->dev, memory, 0, VK_WHOLE_SIZE, 0, &map) != VK_SUCCESS) {
        vkDestroyBuffer(v->dev, buffer, NULL);
        vkFreeMemory(v->dev, memory, NULL);
        return fail("vkMapMemory failed");
    }
    *out_buffer = buffer;
    *out_memory = memory;
    *out_map = map;
    return 0;
}

static VkShaderModule make_shader(GlinVk *v, const unsigned char *bytes, size_t len) {
    if (len == 0 || (len % 4) != 0) {
        fail("shader blob is %zu bytes (must be SPIR-V)", len);
        return VK_NULL_HANDLE;
    }
    VkShaderModuleCreateInfo ci;
    memset(&ci, 0, sizeof ci);
    ci.sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
    ci.codeSize = len;
    ci.pCode = (const uint32_t *)bytes;
    VkShaderModule module = VK_NULL_HANDLE;
    if (vkCreateShaderModule(v->dev, &ci, NULL, &module) != VK_SUCCESS) {
        fail("vkCreateShaderModule failed (%zu bytes)", len);
        return VK_NULL_HANDLE;
    }
    return module;
}

// A one-shot command buffer: begin, record, submit, wait. Texture uploads are cache misses, so the stall is not on a hot path.
static int oneshot_begin(GlinVk *v, VkCommandBuffer *out) {
    VkCommandBufferAllocateInfo ai;
    memset(&ai, 0, sizeof ai);
    ai.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
    ai.commandPool = v->pool;
    ai.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    ai.commandBufferCount = 1;
    VkCommandBuffer cb = VK_NULL_HANDLE;
    if (vkAllocateCommandBuffers(v->dev, &ai, &cb) != VK_SUCCESS) return fail("vkAllocateCommandBuffers failed");

    VkCommandBufferBeginInfo bi;
    memset(&bi, 0, sizeof bi);
    bi.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
    bi.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    if (vkBeginCommandBuffer(cb, &bi) != VK_SUCCESS) {
        vkFreeCommandBuffers(v->dev, v->pool, 1, &cb);
        return fail("vkBeginCommandBuffer failed");
    }
    *out = cb;
    return 0;
}

static void oneshot_end(GlinVk *v, VkCommandBuffer cb) {
    VkSubmitInfo si;
    memset(&si, 0, sizeof si);
    si.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
    si.commandBufferCount = 1;
    si.pCommandBuffers = &cb;
    vkEndCommandBuffer(cb);
    vkQueueSubmit(v->queue, 1, &si, VK_NULL_HANDLE);
    vkQueueWaitIdle(v->queue);
    vkFreeCommandBuffers(v->dev, v->pool, 1, &cb);
}

static void barrier_image(VkCommandBuffer cb, VkImage image, VkImageLayout from, VkImageLayout to,
                          VkAccessFlags src_access, VkAccessFlags dst_access,
                          VkPipelineStageFlags src_stage, VkPipelineStageFlags dst_stage) {
    VkImageMemoryBarrier b;
    memset(&b, 0, sizeof b);
    b.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
    b.oldLayout = from;
    b.newLayout = to;
    b.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    b.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    b.image = image;
    b.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
    b.subresourceRange.levelCount = 1;
    b.subresourceRange.layerCount = 1;
    b.srcAccessMask = src_access;
    b.dstAccessMask = dst_access;
    vkCmdPipelineBarrier(cb, src_stage, dst_stage, 0, 0, NULL, 0, NULL, 1, &b);
}

static VkRenderPass make_pass(GlinVk *v, VkFormat fmt, VkImageLayout final_layout) {
    VkAttachmentDescription att;
    memset(&att, 0, sizeof att);
    att.format = fmt;
    att.samples = VK_SAMPLE_COUNT_1_BIT;
    att.loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR;
    att.storeOp = VK_ATTACHMENT_STORE_OP_STORE;
    att.stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE;
    att.stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE;
    // UNDEFINED even for an acquired swapchain image: that is what licenses the driver's PRESENT_SRC -> COLOR transition.
    att.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    att.finalLayout = final_layout;

    VkAttachmentReference ref;
    memset(&ref, 0, sizeof ref);
    ref.attachment = 0;
    ref.layout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;

    VkSubpassDescription sub;
    memset(&sub, 0, sizeof sub);
    sub.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS;
    sub.colorAttachmentCount = 1;
    sub.pColorAttachments = &ref;

    VkSubpassDependency dep;
    memset(&dep, 0, sizeof dep);
    dep.srcSubpass = VK_SUBPASS_EXTERNAL;
    dep.dstSubpass = 0;
    dep.srcStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    dep.srcAccessMask = 0;
    dep.dstStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    dep.dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;

    VkRenderPassCreateInfo ci;
    memset(&ci, 0, sizeof ci);
    ci.sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO;
    ci.attachmentCount = 1;
    ci.pAttachments = &att;
    ci.subpassCount = 1;
    ci.pSubpasses = &sub;
    ci.dependencyCount = 1;
    ci.pDependencies = &dep;

    VkRenderPass pass = VK_NULL_HANDLE;
    if (vkCreateRenderPass(v->dev, &ci, NULL, &pass) != VK_SUCCESS) {
        fail("vkCreateRenderPass failed");
        return VK_NULL_HANDLE;
    }
    return pass;
}

// ---- Pipelines ---------------------------------------------------------------------------------------------------------

static void destroy_pipes(GlinVk *v) {
    if (v->pipe_rect) vkDestroyPipeline(v->dev, v->pipe_rect, NULL);
    if (v->pipe_text) vkDestroyPipeline(v->dev, v->pipe_text, NULL);
    if (v->pipe_image) vkDestroyPipeline(v->dev, v->pipe_image, NULL);
    v->pipe_rect = VK_NULL_HANDLE;
    v->pipe_text = VK_NULL_HANDLE;
    v->pipe_image = VK_NULL_HANDLE;
    v->pipes_pass = VK_NULL_HANDLE;
}

// Pipelines are tied to the render pass they were created against, so the three of them are rebuilt whenever the pass changes (swapchain format, offscreen).
static int ensure_pipes(GlinVk *v, VkRenderPass pass) {
    if (pass == VK_NULL_HANDLE) return fail("no render pass to build pipelines for");
    if (v->pipes_pass == pass && v->pipe_rect != VK_NULL_HANDLE) return 0;
    destroy_pipes(v);

    VkPipelineShaderStageCreateInfo stages[2];
    memset(stages, 0, sizeof stages);
    stages[0].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    stages[0].stage = VK_SHADER_STAGE_VERTEX_BIT;
    stages[0].module = v->vs;
    stages[0].pName = "main";
    stages[1].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    stages[1].stage = VK_SHADER_STAGE_FRAGMENT_BIT;
    stages[1].pName = "main";

    VkVertexInputBindingDescription bind;
    memset(&bind, 0, sizeof bind);
    bind.binding = 0;
    bind.stride = GLIN_VK_VERTEX_SIZE;
    bind.inputRate = VK_VERTEX_INPUT_RATE_VERTEX;

    VkVertexInputAttributeDescription attrs[8];
    memset(attrs, 0, sizeof attrs);
    // The offsets spell out the 17-float layout in vk.h; nothing here depends on struct packing.
    attrs[0].location = 0; attrs[0].format = VK_FORMAT_R32G32_SFLOAT;       attrs[0].offset = 0;   // pos
    attrs[1].location = 1; attrs[1].format = VK_FORMAT_R32G32_SFLOAT;       attrs[1].offset = 8;   // local / uv
    attrs[2].location = 2; attrs[2].format = VK_FORMAT_R32G32_SFLOAT;       attrs[2].offset = 16;  // size
    attrs[3].location = 3; attrs[3].format = VK_FORMAT_R32G32B32A32_SFLOAT; attrs[3].offset = 24;  // radius
    attrs[4].location = 4; attrs[4].format = VK_FORMAT_R32G32B32A32_SFLOAT; attrs[4].offset = 40;  // color
    attrs[5].location = 5; attrs[5].format = VK_FORMAT_R32_SFLOAT;          attrs[5].offset = 56;  // mode
    attrs[6].location = 6; attrs[6].format = VK_FORMAT_R32_SFLOAT;          attrs[6].offset = 60;  // border
    attrs[7].location = 7; attrs[7].format = VK_FORMAT_R32_SFLOAT;          attrs[7].offset = 64;  // kind (declared, unused)

    VkPipelineVertexInputStateCreateInfo vin;
    memset(&vin, 0, sizeof vin);
    vin.sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;
    vin.vertexBindingDescriptionCount = 1;
    vin.pVertexBindingDescriptions = &bind;
    vin.vertexAttributeDescriptionCount = 8;
    vin.pVertexAttributeDescriptions = attrs;

    VkPipelineInputAssemblyStateCreateInfo ia;
    memset(&ia, 0, sizeof ia);
    ia.sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO;
    ia.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;

    VkPipelineViewportStateCreateInfo vp;
    memset(&vp, 0, sizeof vp);
    vp.sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO;
    vp.viewportCount = 1;
    vp.scissorCount = 1;

    VkPipelineRasterizationStateCreateInfo rs;
    memset(&rs, 0, sizeof rs);
    rs.sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO;
    rs.polygonMode = VK_POLYGON_MODE_FILL;
    rs.cullMode = VK_CULL_MODE_NONE;
    rs.frontFace = VK_FRONT_FACE_COUNTER_CLOCKWISE;
    rs.lineWidth = 1.0f;

    VkPipelineMultisampleStateCreateInfo ms;
    memset(&ms, 0, sizeof ms);
    ms.sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO;
    ms.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT;

    VkPipelineColorBlendAttachmentState cb;
    memset(&cb, 0, sizeof cb);
    cb.blendEnable = VK_TRUE;
    cb.srcColorBlendFactor = VK_BLEND_FACTOR_SRC_ALPHA;
    cb.dstColorBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;
    cb.colorBlendOp = VK_BLEND_OP_ADD;
    // The window is opaque, so keep the destination alpha saturated — the old GL state's separate alpha funcs.
    cb.srcAlphaBlendFactor = VK_BLEND_FACTOR_ONE;
    cb.dstAlphaBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;
    cb.alphaBlendOp = VK_BLEND_OP_ADD;
    cb.colorWriteMask = VK_COLOR_COMPONENT_R_BIT | VK_COLOR_COMPONENT_G_BIT |
                        VK_COLOR_COMPONENT_B_BIT | VK_COLOR_COMPONENT_A_BIT;

    VkPipelineColorBlendStateCreateInfo blend;
    memset(&blend, 0, sizeof blend);
    blend.sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO;
    blend.attachmentCount = 1;
    blend.pAttachments = &cb;

    VkDynamicState dyn[2] = { VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR };
    VkPipelineDynamicStateCreateInfo dsi;
    memset(&dsi, 0, sizeof dsi);
    dsi.sType = VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO;
    dsi.dynamicStateCount = 2;
    dsi.pDynamicStates = dyn;

    VkGraphicsPipelineCreateInfo ci;
    memset(&ci, 0, sizeof ci);
    ci.sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO;
    ci.stageCount = 2;
    ci.pStages = stages;
    ci.pVertexInputState = &vin;
    ci.pInputAssemblyState = &ia;
    ci.pViewportState = &vp;
    ci.pRasterizationState = &rs;
    ci.pMultisampleState = &ms;
    ci.pColorBlendState = &blend;
    ci.pDynamicState = &dsi;
    ci.layout = v->playout;
    ci.renderPass = pass;
    ci.subpass = 0;

    stages[1].module = v->fs_rect;
    if (vkCreateGraphicsPipelines(v->dev, VK_NULL_HANDLE, 1, &ci, NULL, &v->pipe_rect) != VK_SUCCESS)
        return fail("vkCreateGraphicsPipelines failed (rect)");

    stages[1].module = v->fs_text;
    if (vkCreateGraphicsPipelines(v->dev, VK_NULL_HANDLE, 1, &ci, NULL, &v->pipe_text) != VK_SUCCESS)
        return fail("vkCreateGraphicsPipelines failed (text)");

    stages[1].module = v->fs_image;
    if (vkCreateGraphicsPipelines(v->dev, VK_NULL_HANDLE, 1, &ci, NULL, &v->pipe_image) != VK_SUCCESS)
        return fail("vkCreateGraphicsPipelines failed (image)");

    v->pipes_pass = pass;
    return 0;
}

// ---- Swapchain ---------------------------------------------------------------------------------------------------------

static void destroy_swapchain(GlinVk *v) {
    uint32_t i;
    if (v->dev == VK_NULL_HANDLE) return;
    vkDeviceWaitIdle(v->dev);
    destroy_pipes(v);
    for (i = 0; i < v->sc_count; i++) {
        if (v->sc_fb[i]) vkDestroyFramebuffer(v->dev, v->sc_fb[i], NULL);
        if (v->sc_view[i]) vkDestroyImageView(v->dev, v->sc_view[i], NULL);
        v->sc_fb[i] = VK_NULL_HANDLE;
        v->sc_view[i] = VK_NULL_HANDLE;
    }
    v->sc_count = 0;
    if (v->sc_pass) vkDestroyRenderPass(v->dev, v->sc_pass, NULL);
    v->sc_pass = VK_NULL_HANDLE;
    if (v->sc) vkDestroySwapchainKHR(v->dev, v->sc, NULL);
    v->sc = VK_NULL_HANDLE;
    v->sc_extent.width = 0;
    v->sc_extent.height = 0;
}

static int choose_swap_format(GlinVk *v, VkSurfaceFormatKHR *out) {
    uint32_t n = 0;
    uint32_t i;
    VkSurfaceFormatKHR fmts[32];
    VkFormat want[2];
    int w;

    if (vkGetPhysicalDeviceSurfaceFormatsKHR(v->phys, v->surface, &n, NULL) != VK_SUCCESS || n == 0)
        return fail("surface reports no formats");
    if (n > 32) n = 32;
    vkGetPhysicalDeviceSurfaceFormatsKHR(v->phys, v->surface, &n, fmts);

    // A single UNDEFINED entry means "any format you like".
    if (n == 1 && fmts[0].format == VK_FORMAT_UNDEFINED) {
        out->format = VK_FORMAT_B8G8R8A8_UNORM;
        out->colorSpace = fmts[0].colorSpace;
        return 0;
    }
    // UNORM, never _SRGB: the GLES3 default framebuffer did no gamma conversion, and the parity checks compare bytes.
    want[0] = VK_FORMAT_B8G8R8A8_UNORM;
    want[1] = VK_FORMAT_R8G8B8A8_UNORM;
    for (w = 0; w < 2; w++) {
        for (i = 0; i < n; i++) {
            if (fmts[i].format == want[w]) {
                out->format = fmts[i].format;
                out->colorSpace = fmts[i].colorSpace;
                return 0;
            }
        }
    }
    out->format = fmts[0].format;
    out->colorSpace = fmts[0].colorSpace;
    return 0;
}

static int create_swapchain(GlinVk *v, int w, int h) {
    VkSurfaceCapabilitiesKHR caps;
    VkSurfaceFormatKHR fmt;
    VkSwapchainCreateInfoKHR ci;
    VkExtent2D ext;
    VkCompositeAlphaFlagBitsKHR alpha;
    uint32_t count;
    uint32_t i;

    if (!v->has_surface) return 0;
    memset(&fmt, 0, sizeof fmt);
    if (vkGetPhysicalDeviceSurfaceCapabilitiesKHR(v->phys, v->surface, &caps) != VK_SUCCESS)
        return fail("vkGetPhysicalDeviceSurfaceCapabilitiesKHR failed");
    if (choose_swap_format(v, &fmt) != 0) return -1;

    if (caps.currentExtent.width != UINT32_MAX) {
        ext = caps.currentExtent;
    } else {
        ext.width = (uint32_t)w;
        ext.height = (uint32_t)h;
        if (ext.width < caps.minImageExtent.width) ext.width = caps.minImageExtent.width;
        if (ext.width > caps.maxImageExtent.width) ext.width = caps.maxImageExtent.width;
        if (ext.height < caps.minImageExtent.height) ext.height = caps.minImageExtent.height;
        if (ext.height > caps.maxImageExtent.height) ext.height = caps.maxImageExtent.height;
    }
    // A zero extent is a minimised surface, not an error: keep what we have and try again on the next resize.
    if (ext.width == 0 || ext.height == 0) return 1;

    count = caps.minImageCount + 1;
    if (caps.maxImageCount > 0 && count > caps.maxImageCount) count = caps.maxImageCount;

    alpha = VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR;
    if (!(caps.supportedCompositeAlpha & alpha)) {
        alpha = VK_COMPOSITE_ALPHA_INHERIT_BIT_KHR;
        if (!(caps.supportedCompositeAlpha & alpha)) alpha = VK_COMPOSITE_ALPHA_PRE_MULTIPLIED_BIT_KHR;
    }

    memset(&ci, 0, sizeof ci);
    ci.sType = VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR;
    ci.surface = v->surface;
    ci.minImageCount = count;
    ci.imageFormat = fmt.format;
    ci.imageColorSpace = fmt.colorSpace;
    ci.imageExtent = ext;
    ci.imageArrayLayers = 1;
    ci.imageUsage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
    ci.imageSharingMode = VK_SHARING_MODE_EXCLUSIVE;
    ci.preTransform = caps.currentTransform;
    ci.compositeAlpha = alpha;
    // FIFO is the only mode every implementation must support, and it is the compositor-friendly one (vsync, like the old EGL swap).
    ci.presentMode = VK_PRESENT_MODE_FIFO_KHR;
    ci.clipped = VK_TRUE;
    ci.oldSwapchain = VK_NULL_HANDLE;

    if (vkCreateSwapchainKHR(v->dev, &ci, NULL, &v->sc) != VK_SUCCESS) return fail("vkCreateSwapchainKHR failed");

    v->sc_format = fmt.format;
    v->sc_extent = ext;
    v->sc_count = 0;
    if (vkGetSwapchainImagesKHR(v->dev, v->sc, &v->sc_count, NULL) != VK_SUCCESS) return fail("vkGetSwapchainImagesKHR failed (count)");
    if (v->sc_count > GLIN_VK_MAX_SWAP) return fail("swapchain has %u images (max %d)", v->sc_count, GLIN_VK_MAX_SWAP);
    if (vkGetSwapchainImagesKHR(v->dev, v->sc, &v->sc_count, v->sc_image) != VK_SUCCESS) return fail("vkGetSwapchainImagesKHR failed");

    v->sc_pass = make_pass(v, v->sc_format, VK_IMAGE_LAYOUT_PRESENT_SRC_KHR);
    if (v->sc_pass == VK_NULL_HANDLE) return -1;

    for (i = 0; i < v->sc_count; i++) {
        VkImageViewCreateInfo vi;
        memset(&vi, 0, sizeof vi);
        vi.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
        vi.image = v->sc_image[i];
        vi.viewType = VK_IMAGE_VIEW_TYPE_2D;
        vi.format = v->sc_format;
        vi.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        vi.subresourceRange.levelCount = 1;
        vi.subresourceRange.layerCount = 1;
        if (vkCreateImageView(v->dev, &vi, NULL, &v->sc_view[i]) != VK_SUCCESS) return fail("vkCreateImageView failed (swapchain)");

        VkFramebufferCreateInfo fi;
        memset(&fi, 0, sizeof fi);
        fi.sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
        fi.renderPass = v->sc_pass;
        fi.attachmentCount = 1;
        fi.pAttachments = &v->sc_view[i];
        fi.width = ext.width;
        fi.height = ext.height;
        fi.layers = 1;
        if (vkCreateFramebuffer(v->dev, &fi, NULL, &v->sc_fb[i]) != VK_SUCCESS) return fail("vkCreateFramebuffer failed (swapchain)");
    }
    return ensure_pipes(v, v->sc_pass);
}

// ---- Device creation ---------------------------------------------------------------------------------------------------

static int pick_physical_device(GlinVk *v) {
    uint32_t n = 0;
    uint32_t i;
    VkPhysicalDevice devices[16];
    int best = -1;
    uint32_t best_family = 0;
    int best_score = -1;

    if (vkEnumeratePhysicalDevices(v->instance, &n, NULL) != VK_SUCCESS || n == 0)
        return fail("this machine has no Vulkan device");
    if (n > 16) n = 16;
    vkEnumeratePhysicalDevices(v->instance, &n, devices);

    for (i = 0; i < n; i++) {
        uint32_t f = 0;
        uint32_t fam_count = 0;
        VkQueueFamilyProperties fams[16];
        int family = -1;
        int score = 0;
        VkPhysicalDeviceProperties props;

        vkGetPhysicalDeviceQueueFamilyProperties(devices[i], &fam_count, NULL);
        if (fam_count > 16) fam_count = 16;
        vkGetPhysicalDeviceQueueFamilyProperties(devices[i], &fam_count, fams);

        for (f = 0; f < fam_count; f++) {
            VkBool32 present = VK_FALSE;
            if (!(fams[f].queueFlags & VK_QUEUE_GRAPHICS_BIT)) continue;
            // One family for both draws and presents: a swapchain shared across two families needs concurrent sharing, and no driver here requires it.
            if (v->has_surface &&
                (vkGetPhysicalDeviceSurfaceSupportKHR(devices[i], f, v->surface, &present) != VK_SUCCESS || !present))
                continue;
            family = (int)f;
            break;
        }
        if (family < 0) continue;

        vkGetPhysicalDeviceProperties(devices[i], &props);
        score = 1;
        if (props.deviceType == VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU) score += 10;
        if (score > best_score) {
            best = (int)i;
            best_family = (uint32_t)family;
            best_score = score;
        }
    }
    if (best < 0) return fail("no Vulkan queue family can draw%s", v->has_surface ? " and present" : "");

    v->phys = devices[best];
    v->queue_family = best_family;
    {
        VkPhysicalDeviceProperties props;
        vkGetPhysicalDeviceProperties(v->phys, &props);
        snprintf(v->name, sizeof v->name, "%s", props.deviceName);
    }
    vkGetPhysicalDeviceMemoryProperties(v->phys, &v->mem_props);
    return 0;
}

static int create_device(GlinVk *v) {
    float prio = 1.0f;
    VkDeviceQueueCreateInfo qi;
    VkDeviceCreateInfo ci;
    const char *exts[1];
    uint32_t n_exts = 0;

    memset(&qi, 0, sizeof qi);
    qi.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
    qi.queueFamilyIndex = v->queue_family;
    qi.queueCount = 1;
    qi.pQueuePriorities = &prio;

    if (v->has_surface) exts[n_exts++] = VK_KHR_SWAPCHAIN_EXTENSION_NAME;

    memset(&ci, 0, sizeof ci);
    ci.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
    ci.queueCreateInfoCount = 1;
    ci.pQueueCreateInfos = &qi;
    ci.enabledExtensionCount = n_exts;
    ci.ppEnabledExtensionNames = exts;

    if (vkCreateDevice(v->phys, &ci, NULL, &v->dev) != VK_SUCCESS)
        return fail("vkCreateDevice failed on '%s'", v->name);
    vkGetDeviceQueue(v->dev, v->queue_family, 0, &v->queue);
    return 0;
}

static int create_frame(GlinVk *v, Frame *f) {
    VkCommandBufferAllocateInfo ai;
    VkFenceCreateInfo fi;
    VkSemaphoreCreateInfo si;

    if (make_host_buffer(v, GLIN_VK_INITIAL_VERTS, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
                         &f->buffer, &f->memory, &f->map) != 0)
        return -1;
    f->cap = GLIN_VK_INITIAL_VERTS;

    memset(&ai, 0, sizeof ai);
    ai.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
    ai.commandPool = v->pool;
    ai.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    ai.commandBufferCount = 1;
    if (vkAllocateCommandBuffers(v->dev, &ai, &f->cmd) != VK_SUCCESS) return fail("vkAllocateCommandBuffers failed");

    memset(&fi, 0, sizeof fi);
    fi.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
    // Signalled, so the first frame's wait returns instead of hanging.
    fi.flags = VK_FENCE_CREATE_SIGNALED_BIT;
    if (vkCreateFence(v->dev, &fi, NULL, &f->fence) != VK_SUCCESS) return fail("vkCreateFence failed");

    memset(&si, 0, sizeof si);
    si.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
    if (vkCreateSemaphore(v->dev, &si, NULL, &f->sem_image) != VK_SUCCESS) return fail("vkCreateSemaphore failed");
    if (vkCreateSemaphore(v->dev, &si, NULL, &f->sem_done) != VK_SUCCESS) return fail("vkCreateSemaphore failed");
    return 0;
}

static int grow_vertex_buffer(GlinVk *v, Frame *f, VkDeviceSize need) {
    VkDeviceSize cap = f->cap;
    VkBuffer buffer;
    VkDeviceMemory memory;
    void *map;

    while (cap < need) cap *= 2;
    vkDeviceWaitIdle(v->dev);
    if (make_host_buffer(v, cap, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT, &buffer, &memory, &map) != 0) return -1;
    vkUnmapMemory(v->dev, f->memory);
    vkDestroyBuffer(v->dev, f->buffer, NULL);
    vkFreeMemory(v->dev, f->memory, NULL);
    f->buffer = buffer;
    f->memory = memory;
    f->map = map;
    f->cap = cap;
    return 0;
}

GlinVk *glin_vk_create(void *wl_display, void *wl_surface, int w, int h,
                       const unsigned char *vert_spv, size_t vert_len,
                       const unsigned char *rect_frag_spv, size_t rect_len,
                       const unsigned char *text_frag_spv, size_t text_len,
                       const unsigned char *image_frag_spv, size_t image_len) {
    GlinVk *v;
    VkApplicationInfo app;
    VkInstanceCreateInfo ici;
    const char *exts[2];
    uint32_t n_exts = 0;
    VkCommandPoolCreateInfo pci;
    VkDescriptorSetLayoutBinding b;
    VkDescriptorSetLayoutCreateInfo dli;
    VkDescriptorPoolSize psize;
    VkDescriptorPoolCreateInfo dpi;
    VkPushConstantRange pcr;
    VkPipelineLayoutCreateInfo pli;
    VkSamplerCreateInfo sci;
    uint32_t i;

    g_error[0] = '\0';
    v = (GlinVk *)calloc(1, sizeof *v);
    if (!v) {
        fail("out of memory");
        return NULL;
    }

    memset(&app, 0, sizeof app);
    app.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO;
    app.pApplicationName = "glinlandui";
    app.apiVersion = VK_API_VERSION_1_0;

    exts[n_exts++] = VK_KHR_SURFACE_EXTENSION_NAME;
    if (wl_display && wl_surface) exts[n_exts++] = VK_KHR_WAYLAND_SURFACE_EXTENSION_NAME;

    memset(&ici, 0, sizeof ici);
    ici.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
    ici.pApplicationInfo = &app;
    ici.enabledExtensionCount = n_exts;
    ici.ppEnabledExtensionNames = exts;
    if (vkCreateInstance(&ici, NULL, &v->instance) != VK_SUCCESS) {
        fail("vkCreateInstance failed (no Vulkan loader / ICD?)");
        free(v);
        return NULL;
    }

    if (wl_display && wl_surface) {
        VkWaylandSurfaceCreateInfoKHR sci2;
        memset(&sci2, 0, sizeof sci2);
        sci2.sType = VK_STRUCTURE_TYPE_WAYLAND_SURFACE_CREATE_INFO_KHR;
        sci2.display = (struct wl_display *)wl_display;
        sci2.surface = (struct wl_surface *)wl_surface;
        if (vkCreateWaylandSurfaceKHR(v->instance, &sci2, NULL, &v->surface) == VK_SUCCESS && v->surface != VK_NULL_HANDLE)
            v->has_surface = 1;
    }

    if (pick_physical_device(v) != 0 || create_device(v) != 0) {
        glin_vk_destroy(v);
        return NULL;
    }

    memset(&pci, 0, sizeof pci);
    pci.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
    // One at a time, reset per frame: the pool is only ever used from the thread that owns the window.
    pci.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
    pci.queueFamilyIndex = v->queue_family;
    if (vkCreateCommandPool(v->dev, &pci, NULL, &v->pool) != VK_SUCCESS) {
        fail("vkCreateCommandPool failed");
        glin_vk_destroy(v);
        return NULL;
    }

    for (i = 0; i < GLIN_VK_MAX_FRAMES; i++) {
        if (create_frame(v, &v->frames[i]) != 0) {
            glin_vk_destroy(v);
            return NULL;
        }
    }

    // One combined image sampler per texture id, rewritten in place when a cache slot is reused.
    memset(&b, 0, sizeof b);
    b.binding = 0;
    b.descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
    b.descriptorCount = 1;
    b.stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT;
    memset(&dli, 0, sizeof dli);
    dli.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
    dli.bindingCount = 1;
    dli.pBindings = &b;
    if (vkCreateDescriptorSetLayout(v->dev, &dli, NULL, &v->dsl) != VK_SUCCESS) {
        fail("vkCreateDescriptorSetLayout failed");
        glin_vk_destroy(v);
        return NULL;
    }

    memset(&psize, 0, sizeof psize);
    psize.type = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
    psize.descriptorCount = GLIN_VK_MAX_TEXTURES;
    memset(&dpi, 0, sizeof dpi);
    dpi.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
    dpi.maxSets = GLIN_VK_MAX_TEXTURES;
    dpi.poolSizeCount = 1;
    dpi.pPoolSizes = &psize;
    if (vkCreateDescriptorPool(v->dev, &dpi, NULL, &v->dpool) != VK_SUCCESS) {
        fail("vkCreateDescriptorPool failed");
        glin_vk_destroy(v);
        return NULL;
    }

    memset(&pcr, 0, sizeof pcr);
    pcr.stageFlags = VK_SHADER_STAGE_VERTEX_BIT;
    pcr.size = 8; // vec2 u_res
    memset(&pli, 0, sizeof pli);
    pli.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
    pli.setLayoutCount = 1;
    pli.pSetLayouts = &v->dsl;
    pli.pushConstantRangeCount = 1;
    pli.pPushConstantRanges = &pcr;
    if (vkCreatePipelineLayout(v->dev, &pli, NULL, &v->playout) != VK_SUCCESS) {
        fail("vkCreatePipelineLayout failed");
        glin_vk_destroy(v);
        return NULL;
    }

    memset(&sci, 0, sizeof sci);
    sci.sType = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO;
    sci.magFilter = VK_FILTER_NEAREST;
    sci.minFilter = VK_FILTER_NEAREST;
    sci.mipmapMode = VK_SAMPLER_MIPMAP_MODE_NEAREST;
    sci.addressModeU = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
    sci.addressModeV = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
    sci.addressModeW = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
    if (vkCreateSampler(v->dev, &sci, NULL, &v->samp_nearest) != VK_SUCCESS) {
        fail("vkCreateSampler failed");
        glin_vk_destroy(v);
        return NULL;
    }
    sci.magFilter = VK_FILTER_LINEAR;
    sci.minFilter = VK_FILTER_LINEAR;
    sci.mipmapMode = VK_SAMPLER_MIPMAP_MODE_LINEAR;
    if (vkCreateSampler(v->dev, &sci, NULL, &v->samp_linear) != VK_SUCCESS) {
        fail("vkCreateSampler failed");
        glin_vk_destroy(v);
        return NULL;
    }

    v->vs = make_shader(v, vert_spv, vert_len);
    v->fs_rect = make_shader(v, rect_frag_spv, rect_len);
    v->fs_text = make_shader(v, text_frag_spv, text_len);
    v->fs_image = make_shader(v, image_frag_spv, image_len);
    if (!v->vs || !v->fs_rect || !v->fs_text || !v->fs_image) {
        glin_vk_destroy(v);
        return NULL;
    }

    if (v->has_surface && create_swapchain(v, w, h) < 0) {
        glin_vk_destroy(v);
        return NULL;
    }

    // Texture id 0 is a white pixel: rects sample it and ignore the result, so one pipeline layout serves all three fragments.
    {
        unsigned char white[4] = { 255, 255, 255, 255 };
        if (glin_vk_set_texture(v, 0, white, 1, 1, 4) != 0) {
            glin_vk_destroy(v);
            return NULL;
        }
    }
    return v;
}

void glin_vk_destroy(GlinVk *v) {
    uint32_t i;
    if (!v) return;
    if (v->dev != VK_NULL_HANDLE) {
        vkDeviceWaitIdle(v->dev);
        destroy_swapchain(v);
        if (v->off_fb) vkDestroyFramebuffer(v->dev, v->off_fb, NULL);
        if (v->off_view) vkDestroyImageView(v->dev, v->off_view, NULL);
        if (v->off_image) vkDestroyImage(v->dev, v->off_image, NULL);
        if (v->off_memory) vkFreeMemory(v->dev, v->off_memory, NULL);
        if (v->off_pass) vkDestroyRenderPass(v->dev, v->off_pass, NULL);
        if (v->read_buffer) {
            if (v->read_map) vkUnmapMemory(v->dev, v->read_memory);
            vkDestroyBuffer(v->dev, v->read_buffer, NULL);
            vkFreeMemory(v->dev, v->read_memory, NULL);
        }
        for (i = 0; i < GLIN_VK_MAX_TEXTURES; i++) {
            Tex *t = &v->tex[i];
            if (t->view) vkDestroyImageView(v->dev, t->view, NULL);
            if (t->image) vkDestroyImage(v->dev, t->image, NULL);
            if (t->memory) vkFreeMemory(v->dev, t->memory, NULL);
        }
        for (i = 0; i < GLIN_VK_MAX_FRAMES; i++) {
            Frame *f = &v->frames[i];
            if (f->sem_image) vkDestroySemaphore(v->dev, f->sem_image, NULL);
            if (f->sem_done) vkDestroySemaphore(v->dev, f->sem_done, NULL);
            if (f->fence) vkDestroyFence(v->dev, f->fence, NULL);
            if (f->buffer) vkDestroyBuffer(v->dev, f->buffer, NULL);
            if (f->memory) {
                if (f->map) vkUnmapMemory(v->dev, f->memory);
                vkFreeMemory(v->dev, f->memory, NULL);
            }
        }
        if (v->pool) vkDestroyCommandPool(v->dev, v->pool, NULL);
        if (v->dpool) vkDestroyDescriptorPool(v->dev, v->dpool, NULL);
        if (v->dsl) vkDestroyDescriptorSetLayout(v->dev, v->dsl, NULL);
        if (v->playout) vkDestroyPipelineLayout(v->dev, v->playout, NULL);
        if (v->samp_nearest) vkDestroySampler(v->dev, v->samp_nearest, NULL);
        if (v->samp_linear) vkDestroySampler(v->dev, v->samp_linear, NULL);
        if (v->vs) vkDestroyShaderModule(v->dev, v->vs, NULL);
        if (v->fs_rect) vkDestroyShaderModule(v->dev, v->fs_rect, NULL);
        if (v->fs_text) vkDestroyShaderModule(v->dev, v->fs_text, NULL);
        if (v->fs_image) vkDestroyShaderModule(v->dev, v->fs_image, NULL);
        vkDestroyDevice(v->dev, NULL);
    }
    if (v->surface) vkDestroySurfaceKHR(v->instance, v->surface, NULL);
    if (v->instance) vkDestroyInstance(v->instance, NULL);
    free(v);
}

int glin_vk_resize(GlinVk *v, int w, int h) {
    int r;
    if (!v || !v->has_surface) return 0;
    if (w <= 0 || h <= 0) return 0;
    if (v->sc != VK_NULL_HANDLE && (int)v->sc_extent.width == w && (int)v->sc_extent.height == h) return 0;
    destroy_swapchain(v);
    r = create_swapchain(v, w, h);
    return r < 0 ? -1 : 0;
}

// ---- Textures ----------------------------------------------------------------------------------------------------------

int glin_vk_set_texture(GlinVk *v, unsigned int id,
                        const unsigned char *bytes, int w, int h, int channels) {
    Tex *t;
    VkFormat fmt;
    VkDeviceSize size;
    VkBuffer stage;
    VkDeviceMemory stage_mem;
    void *stage_map;
    VkCommandBuffer cb;
    VkBufferImageCopy copy;
    VkDescriptorImageInfo dii;
    cb = VK_NULL_HANDLE;
    VkWriteDescriptorSet wr;

    if (!v || id >= GLIN_VK_MAX_TEXTURES || !bytes || w <= 0 || h <= 0) return fail("bad texture request");
    if (channels != 1 && channels != 4) return fail("texture %u: %d channels (want 1 or 4)", id, channels);

    fmt = (channels == 1) ? VK_FORMAT_R8_UNORM : VK_FORMAT_R8G8B8A8_UNORM;
    t = &v->tex[id];

    // A cache slot keeps its id across eviction, so a changed shape means a new image but the SAME descriptor set.
    if (t->live && (t->w != w || t->h != h || t->channels != channels)) {
        vkDeviceWaitIdle(v->dev);
        vkDestroyImageView(v->dev, t->view, NULL);
        vkDestroyImage(v->dev, t->image, NULL);
        vkFreeMemory(v->dev, t->memory, NULL);
        t->view = VK_NULL_HANDLE;
        t->image = VK_NULL_HANDLE;
        t->memory = VK_NULL_HANDLE;
        t->live = 0;
    }
    if (!t->live) {
        if (make_image(v, w, h, fmt, VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT,
                       &t->image, &t->memory) != 0)
            return -1;
        {
            VkImageViewCreateInfo vi;
            memset(&vi, 0, sizeof vi);
            vi.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
            vi.image = t->image;
            vi.viewType = VK_IMAGE_VIEW_TYPE_2D;
            vi.format = fmt;
            vi.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
            vi.subresourceRange.levelCount = 1;
            vi.subresourceRange.layerCount = 1;
            if (vkCreateImageView(v->dev, &vi, NULL, &t->view) != VK_SUCCESS) return fail("vkCreateImageView failed (texture %u)", id);
        }
    }

    size = (VkDeviceSize)w * (VkDeviceSize)h * (VkDeviceSize)channels;
    if (make_host_buffer(v, size, VK_BUFFER_USAGE_TRANSFER_SRC_BIT, &stage, &stage_mem, &stage_map) != 0) return -1;
    memcpy(stage_map, bytes, (size_t)size);

    if (oneshot_begin(v, &cb) != 0) {
        vkDestroyBuffer(v->dev, stage, NULL);
        vkFreeMemory(v->dev, stage_mem, NULL);
        return -1;
    }
    barrier_image(cb, t->image, VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                  0, VK_ACCESS_TRANSFER_WRITE_BIT,
                  VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT);
    memset(&copy, 0, sizeof copy);
    copy.imageSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
    copy.imageSubresource.layerCount = 1;
    copy.imageExtent.width = (uint32_t)w;
    copy.imageExtent.height = (uint32_t)h;
    copy.imageExtent.depth = 1;
    vkCmdCopyBufferToImage(cb, stage, t->image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &copy);
    barrier_image(cb, t->image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
                  VK_ACCESS_TRANSFER_WRITE_BIT, VK_ACCESS_SHADER_READ_BIT,
                  VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT);
    oneshot_end(v, cb);

    vkDestroyBuffer(v->dev, stage, NULL);
    vkFreeMemory(v->dev, stage_mem, NULL);

    if (t->set == VK_NULL_HANDLE) {
        VkDescriptorSetAllocateInfo ai;
        memset(&ai, 0, sizeof ai);
        ai.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
        ai.descriptorPool = v->dpool;
        ai.descriptorSetCount = 1;
        ai.pSetLayouts = &v->dsl;
        if (vkAllocateDescriptorSets(v->dev, &ai, &t->set) != VK_SUCCESS) return fail("vkAllocateDescriptorSets failed (texture %u)", id);
    }

    memset(&dii, 0, sizeof dii);
    dii.sampler = (channels == 1) ? v->samp_nearest : v->samp_linear;
    dii.imageView = t->view;
    dii.imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
    memset(&wr, 0, sizeof wr);
    wr.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
    wr.dstSet = t->set;
    wr.descriptorCount = 1;
    wr.descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
    wr.pImageInfo = &dii;
    vkUpdateDescriptorSets(v->dev, 1, &wr, 0, NULL);

    // A descriptor set rewritten while an earlier frame still samples it is the one hazard here; uploads are cache misses.
    vkDeviceWaitIdle(v->dev);
    t->w = w;
    t->h = h;
    t->channels = channels;
    t->live = 1;
    return 0;
}

// ---- Drawing -----------------------------------------------------------------------------------------------------------

static void record_draws(GlinVk *v, VkCommandBuffer cb, VkExtent2D extent,
                         const GlinSegment *segs, int nsegs) {
    VkViewport vp;
    int i;

    vp.x = 0.0f;
    vp.y = 0.0f;
    vp.width = (float)extent.width;
    vp.height = (float)extent.height;
    vp.minDepth = 0.0f;
    vp.maxDepth = 1.0f;
    vkCmdSetViewport(cb, 0, 1, &vp);
    // The resolution goes to the vertex shader once: all three pipelines share the layout, so it survives every bind.
    {
        float res[2];
        res[0] = (float)extent.width;
        res[1] = (float)extent.height;
        vkCmdPushConstants(cb, v->playout, VK_SHADER_STAGE_VERTEX_BIT, 0, sizeof res, res);
    }

    for (i = 0; i < nsegs; i++) {
        const GlinSegment *s = &segs[i];
        VkPipeline pipe;
        VkRect2D sc;
        int x0, y0, x1, y1;

        if (s->count <= 0) continue;
        if (s->kind == 1) pipe = v->pipe_text;
        else if (s->kind == 2) pipe = v->pipe_image;
        else pipe = v->pipe_rect;
        if (pipe == VK_NULL_HANDLE) continue;

        if (s->has_scissor) {
            // Vulkan requires the rectangle to lie inside the framebuffer, so clamp BOTH edges (GL only clamped the origin).
            x0 = s->sx;
            y0 = s->sy;
            x1 = s->sx + s->sw;
            y1 = s->sy + s->sh;
            if (x0 < 0) x0 = 0;
            if (y0 < 0) y0 = 0;
            if (x1 > (int)extent.width) x1 = (int)extent.width;
            if (y1 > (int)extent.height) y1 = (int)extent.height;
            if (x1 <= x0 || y1 <= y0) continue;
            sc.offset.x = x0;
            sc.offset.y = y0;
            sc.extent.width = (uint32_t)(x1 - x0);
            sc.extent.height = (uint32_t)(y1 - y0);
        } else {
            sc.offset.x = 0;
            sc.offset.y = 0;
            sc.extent = extent;
        }
        vkCmdSetScissor(cb, 0, 1, &sc);
        vkCmdBindPipeline(cb, VK_PIPELINE_BIND_POINT_GRAPHICS, pipe);
        if (s->kind != 0 && s->texture_id < GLIN_VK_MAX_TEXTURES && v->tex[s->texture_id].set != VK_NULL_HANDLE)
            vkCmdBindDescriptorSets(cb, VK_PIPELINE_BIND_POINT_GRAPHICS, v->playout, 0, 1,
                                    &v->tex[s->texture_id].set, 0, NULL);
        else
            vkCmdBindDescriptorSets(cb, VK_PIPELINE_BIND_POINT_GRAPHICS, v->playout, 0, 1,
                                    &v->tex[0].set, 0, NULL);
        vkCmdDraw(cb, (uint32_t)s->count, 1, (uint32_t)s->start, 0);
    }
}

static void begin_clear_pass(VkCommandBuffer cb, VkRenderPass pass, VkFramebuffer fb,
                             VkExtent2D extent, float r, float g, float b, float a) {
    VkClearValue clear;
    VkRenderPassBeginInfo bi;
    memset(&clear, 0, sizeof clear);
    clear.color.float32[0] = r;
    clear.color.float32[1] = g;
    clear.color.float32[2] = b;
    clear.color.float32[3] = a;
    memset(&bi, 0, sizeof bi);
    bi.sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
    bi.renderPass = pass;
    bi.framebuffer = fb;
    bi.renderArea.extent = extent;
    bi.clearValueCount = 1;
    bi.pClearValues = &clear;
    vkCmdBeginRenderPass(cb, &bi, VK_SUBPASS_CONTENTS_INLINE);
}

int glin_vk_draw(GlinVk *v, const GlinVkVertex *verts, int nverts,
                 const GlinSegment *segs, int nsegs,
                 float r, float g, float b, float a) {
    Frame *f;
    uint32_t image_index = 0;
    VkResult ar;
    VkCommandBuffer cb;
    VkCommandBufferBeginInfo bi;
    VkSubmitInfo si;
    VkPresentInfoKHR pi;
    VkSemaphore wait_sem;
    VkPipelineStageFlags wait_stage = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    VkDeviceSize need;

    if (!v || !v->has_surface || v->sc == VK_NULL_HANDLE) return -1;
    f = &v->frames[v->frame_index];

    if (vkWaitForFences(v->dev, 1, &f->fence, VK_TRUE, UINT64_MAX) != VK_SUCCESS) return fail("vkWaitForFences failed");
    ar = vkAcquireNextImageKHR(v->dev, v->sc, UINT64_MAX, f->sem_image, VK_NULL_HANDLE, &image_index);
    if (ar == VK_ERROR_OUT_OF_DATE_KHR) {
        // Not an error: the surface moved on, and the next frame rebuilds the swapchain at the new size.
        return -2;
    }
    if (ar != VK_SUCCESS && ar != VK_SUBOPTIMAL_KHR) {
        vkResetFences(v->dev, 1, &f->fence);
        return fail("vkAcquireNextImageKHR failed (%d)", (int)ar);
    }
    if (image_index >= v->sc_count) {
        vkResetFences(v->dev, 1, &f->fence);
        return fail("acquired image %u of %u", image_index, v->sc_count);
    }

    need = (VkDeviceSize)nverts * GLIN_VK_VERTEX_SIZE;
    if (need > f->cap && grow_vertex_buffer(v, f, need) != 0) {
        vkResetFences(v->dev, 1, &f->fence);
        return -1;
    }
    if (need > 0 && verts) memcpy(f->map, verts, (size_t)need);

    vkResetCommandBuffer(f->cmd, 0);
    memset(&bi, 0, sizeof bi);
    bi.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
    bi.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    if (vkBeginCommandBuffer(f->cmd, &bi) != VK_SUCCESS) {
        vkResetFences(v->dev, 1, &f->fence);
        return fail("vkBeginCommandBuffer failed");
    }
    cb = f->cmd;

    begin_clear_pass(cb, v->sc_pass, v->sc_fb[image_index], v->sc_extent, r, g, b, a);
    if (nverts > 0 && nsegs > 0 && verts) {
        VkDeviceSize offset = 0;
        vkCmdBindVertexBuffers(cb, 0, 1, &f->buffer, &offset);
        record_draws(v, cb, v->sc_extent, segs, nsegs);
    }
    vkCmdEndRenderPass(cb);
    vkEndCommandBuffer(cb);

    vkResetFences(v->dev, 1, &f->fence);
    memset(&si, 0, sizeof si);
    si.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
    wait_sem = f->sem_image;
    si.waitSemaphoreCount = 1;
    si.pWaitSemaphores = &wait_sem;
    si.pWaitDstStageMask = &wait_stage;
    si.commandBufferCount = 1;
    si.pCommandBuffers = &cb;
    si.signalSemaphoreCount = 1;
    si.pSignalSemaphores = &f->sem_done;
    if (vkQueueSubmit(v->queue, 1, &si, f->fence) != VK_SUCCESS) return fail("vkQueueSubmit failed");

    memset(&pi, 0, sizeof pi);
    pi.sType = VK_STRUCTURE_TYPE_PRESENT_INFO_KHR;
    pi.waitSemaphoreCount = 1;
    pi.pWaitSemaphores = &f->sem_done;
    pi.swapchainCount = 1;
    pi.pSwapchains = &v->sc;
    pi.pImageIndices = &image_index;
    ar = vkQueuePresentKHR(v->queue, &pi);
    if (ar == VK_ERROR_OUT_OF_DATE_KHR) {
        // The frame did reach the screen queue; the next one rebuilds the swapchain.
        v->frame_index = (v->frame_index + 1) % GLIN_VK_MAX_FRAMES;
        return 0;
    }
    if (ar != VK_SUCCESS && ar != VK_SUBOPTIMAL_KHR) {
        v->frame_index = (v->frame_index + 1) % GLIN_VK_MAX_FRAMES;
        return fail("vkQueuePresentKHR failed (%d)", (int)ar);
    }
    v->frame_index = (v->frame_index + 1) % GLIN_VK_MAX_FRAMES;
    return 0;
}

// ---- Offscreen (the GPU-vs-CPU parity test) ----------------------------------------------------------------------------

static int ensure_offscreen(GlinVk *v, int w, int h) {
    if (v->off_pass == VK_NULL_HANDLE) {
        v->off_pass = make_pass(v, GLIN_VK_OFF_FORMAT, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL);
        if (v->off_pass == VK_NULL_HANDLE) return -1;
    }
    if (v->off_fb != VK_NULL_HANDLE && v->off_w == w && v->off_h == h) {
        VkDeviceSize need = (VkDeviceSize)w * (VkDeviceSize)h * 4;
        if (v->read_cap < need) {
            vkDeviceWaitIdle(v->dev);
            if (v->read_buffer) {
                vkUnmapMemory(v->dev, v->read_memory);
                vkDestroyBuffer(v->dev, v->read_buffer, NULL);
                vkFreeMemory(v->dev, v->read_memory, NULL);
                v->read_buffer = VK_NULL_HANDLE;
                v->read_memory = VK_NULL_HANDLE;
                v->read_map = NULL;
                v->read_cap = 0;
            }
            if (make_host_buffer(v, need, VK_BUFFER_USAGE_TRANSFER_DST_BIT,
                                 &v->read_buffer, &v->read_memory, &v->read_map) != 0)
                return -1;
            v->read_cap = need;
        }
        return 0;
    }

    vkDeviceWaitIdle(v->dev);
    if (v->off_fb) vkDestroyFramebuffer(v->dev, v->off_fb, NULL);
    if (v->off_view) vkDestroyImageView(v->dev, v->off_view, NULL);
    if (v->off_image) vkDestroyImage(v->dev, v->off_image, NULL);
    if (v->off_memory) vkFreeMemory(v->dev, v->off_memory, NULL);
    v->off_fb = VK_NULL_HANDLE;
    v->off_view = VK_NULL_HANDLE;
    v->off_image = VK_NULL_HANDLE;
    v->off_memory = VK_NULL_HANDLE;

    if (make_image(v, w, h, GLIN_VK_OFF_FORMAT,
                   VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT,
                   &v->off_image, &v->off_memory) != 0)
        return -1;
    {
        VkImageViewCreateInfo vi;
        memset(&vi, 0, sizeof vi);
        vi.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
        vi.image = v->off_image;
        vi.viewType = VK_IMAGE_VIEW_TYPE_2D;
        vi.format = GLIN_VK_OFF_FORMAT;
        vi.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        vi.subresourceRange.levelCount = 1;
        vi.subresourceRange.layerCount = 1;
        if (vkCreateImageView(v->dev, &vi, NULL, &v->off_view) != VK_SUCCESS) return fail("vkCreateImageView failed (offscreen)");
    }
    {
        VkFramebufferCreateInfo fi;
        memset(&fi, 0, sizeof fi);
        fi.sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
        fi.renderPass = v->off_pass;
        fi.attachmentCount = 1;
        fi.pAttachments = &v->off_view;
        fi.width = (uint32_t)w;
        fi.height = (uint32_t)h;
        fi.layers = 1;
        if (vkCreateFramebuffer(v->dev, &fi, NULL, &v->off_fb) != VK_SUCCESS) return fail("vkCreateFramebuffer failed (offscreen)");
    }
    v->off_w = w;
    v->off_h = h;

    {
        VkDeviceSize need = (VkDeviceSize)w * (VkDeviceSize)h * 4;
        if (v->read_cap < need) {
            if (v->read_buffer) {
                vkUnmapMemory(v->dev, v->read_memory);
                vkDestroyBuffer(v->dev, v->read_buffer, NULL);
                vkFreeMemory(v->dev, v->read_memory, NULL);
                v->read_buffer = VK_NULL_HANDLE;
                v->read_memory = VK_NULL_HANDLE;
                v->read_map = NULL;
                v->read_cap = 0;
            }
            if (make_host_buffer(v, need, VK_BUFFER_USAGE_TRANSFER_DST_BIT,
                                 &v->read_buffer, &v->read_memory, &v->read_map) != 0)
                return -1;
            v->read_cap = need;
        }
    }
    return ensure_pipes(v, v->off_pass);
}

int glin_vk_offscreen(GlinVk *v, const GlinVkVertex *verts, int nverts,
                      const GlinSegment *segs, int nsegs, int w, int h,
                      float r, float g, float b, float a,
                      unsigned char *out) {
    Frame *f;
    VkCommandBuffer cb;
    VkCommandBufferBeginInfo bi;
    VkSubmitInfo si;
    VkBufferImageCopy copy;
    VkDeviceSize need;
    VkExtent2D extent;

    if (!v || !out || w <= 0 || h <= 0) return fail("bad offscreen request");
    if (ensure_offscreen(v, w, h) != 0) return -1;

    f = &v->frames[0];
    vkWaitForFences(v->dev, 1, &f->fence, VK_TRUE, UINT64_MAX);

    need = (VkDeviceSize)nverts * GLIN_VK_VERTEX_SIZE;
    if (need > f->cap && grow_vertex_buffer(v, f, need) != 0) return -1;
    if (need > 0 && verts) memcpy(f->map, verts, (size_t)need);

    vkResetCommandBuffer(f->cmd, 0);
    memset(&bi, 0, sizeof bi);
    bi.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
    bi.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    if (vkBeginCommandBuffer(f->cmd, &bi) != VK_SUCCESS) return fail("vkBeginCommandBuffer failed");
    cb = f->cmd;

    extent.width = (uint32_t)w;
    extent.height = (uint32_t)h;
    begin_clear_pass(cb, v->off_pass, v->off_fb, extent, r, g, b, a);
    if (nverts > 0 && nsegs > 0 && verts) {
        VkDeviceSize offset = 0;
        vkCmdBindVertexBuffers(cb, 0, 1, &f->buffer, &offset);
        record_draws(v, cb, extent, segs, nsegs);
    }
    vkCmdEndRenderPass(cb);

    memset(&copy, 0, sizeof copy);
    copy.imageSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
    copy.imageSubresource.layerCount = 1;
    copy.imageExtent.width = (uint32_t)w;
    copy.imageExtent.height = (uint32_t)h;
    copy.imageExtent.depth = 1;
    vkCmdCopyImageToBuffer(cb, v->off_image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, v->read_buffer, 1, &copy);
    vkEndCommandBuffer(cb);

    vkResetFences(v->dev, 1, &f->fence);
    memset(&si, 0, sizeof si);
    si.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
    si.commandBufferCount = 1;
    si.pCommandBuffers = &cb;
    if (vkQueueSubmit(v->queue, 1, &si, f->fence) != VK_SUCCESS) return fail("vkQueueSubmit failed (offscreen)");
    if (vkWaitForFences(v->dev, 1, &f->fence, VK_TRUE, UINT64_MAX) != VK_SUCCESS) return fail("vkWaitForFences failed (offscreen)");

    memcpy(out, v->read_map, (size_t)w * (size_t)h * 4);
    return 0;
}
