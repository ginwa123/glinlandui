// Rounded-box fill and border outline, one SDF in device pixels.
#version 450

layout(location = 0) in vec2 v_local;
layout(location = 1) in vec2 v_size;
layout(location = 2) in vec4 v_radius;
layout(location = 3) in vec4 v_color;
layout(location = 4) in float v_mode;
layout(location = 5) in float v_border;

layout(location = 0) out vec4 o_color;

float sdRoundBox(vec2 p, vec2 b, vec4 r) {
    float rad = (p.x < 0.0) ? (p.y < 0.0 ? r.x : r.z) : (p.y < 0.0 ? r.y : r.w);
    vec2 q = abs(p) - b + rad;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - rad;
}

// Pixel coverage of a signed distance, banded to ONE device pixel: 1.0 at
// half a pixel inside the edge, 0.0 half a pixel outside. Geometry arrives in
// device pixels, so the band is density-independent without a scale uniform.
// A 2px smoothstep band used to blur a 1px border across two pixels and erode
// convex corners; a 1px clamp is crisp.
float cov(float d) {
    return clamp(0.5 - d, 0.0, 1.0);
}

void main() {
    vec2 c = v_size * 0.5;
    vec2 p = v_local - c;
    float m = min(c.x, c.y);
    vec4 r = min(max(v_radius, vec4(0.0)), vec4(m));
    float d = sdRoundBox(p, c, r);
    float a = cov(d);
    if (v_mode > 0.5) {
        vec2 ib = max(c - vec2(v_border), vec2(0.0));
        float mi = min(ib.x, ib.y);
        vec4 ri = min(max(r - vec4(v_border), vec4(0.0)), vec4(mi));
        float d2 = sdRoundBox(p, ib, ri);
        float a2 = cov(d2);
        a *= (1.0 - a2);
    }
    if (a <= 0.0) discard;
    o_color = vec4(v_color.rgb, v_color.a * a);
}
