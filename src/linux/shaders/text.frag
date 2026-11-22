// One text run: an 8-bit coverage bitmap tinted with the ink colour.
#version 450

layout(location = 0) in vec2 v_local;
layout(location = 3) in vec4 v_color;

layout(binding = 0) uniform sampler2D u_tex;

layout(location = 0) out vec4 o_color;

void main() {
    float a = texture(u_tex, v_local).r;
    o_color = vec4(v_color.rgb, v_color.a * a);
}
