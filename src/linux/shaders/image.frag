// An image quad: the decoded pixels carry their own colour, so the texture is the output.
#version 450

layout(location = 0) in vec2 v_local;

layout(binding = 0) uniform sampler2D u_tex;

layout(location = 0) out vec4 o_color;

void main() {
    o_color = texture(u_tex, v_local);
}
