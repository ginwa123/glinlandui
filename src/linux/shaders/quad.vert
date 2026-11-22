// One vertex shader for every pipeline: the rect, text and image fragments differ, the geometry does not.
#version 450

layout(location = 0) in vec2 a_pos;
layout(location = 1) in vec2 a_local;
layout(location = 2) in vec2 a_size;
layout(location = 3) in vec4 a_radius;
layout(location = 4) in vec4 a_color;
layout(location = 5) in float a_mode;
layout(location = 6) in float a_border;

// The viewport in device pixels. Push constants, so a frame costs one 64-bit write per pipeline layout.
layout(push_constant) uniform Push {
    vec2 u_res;
} pc;

layout(location = 0) out vec2 v_local;
layout(location = 1) out vec2 v_size;
layout(location = 2) out vec4 v_radius;
layout(location = 3) out vec4 v_color;
layout(location = 4) out float v_mode;
layout(location = 5) out float v_border;

void main() {
    // Vulkan's NDC y points down, exactly like Clay's top-left boxes, so the pixel->clip map needs no flip.
    vec2 ndc = (a_pos / pc.u_res) * 2.0 - 1.0;
    gl_Position = vec4(ndc, 0.0, 1.0);
    v_local = a_local;
    v_size = a_size;
    v_radius = a_radius;
    v_color = a_color;
    v_mode = a_mode;
    v_border = a_border;
}
