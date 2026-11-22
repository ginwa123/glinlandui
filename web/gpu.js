// The browser's GPU renderers: WebGPU first, WebGL2 second, and `null` when the
// page has neither — which is not a failure, because the toolkit's CPU
// rasterizer is the fallback and produces the same picture.
//
// ## This file makes no decisions
//
// The same rule `shim.js` follows, for the same reason: everything that could be
// got subtly wrong is on the Zig side, where a test can reach it. Geometry,
// culling, clipping, the text baseline, the atlas packing, which backend is
// active and what the fallback does all live in `src/web/gpu.zig` and
// `src/web/renderer.zig`. This file translates a buffer of vertices and a buffer
// of segments into draw calls, and nothing else.
//
// ## What it receives, per frame
//
//     { verts, segs, segCount, vertexStride, segmentStride,
//       width, height, clear: [r,g,b,a], atlas, atlasVersion, atlasW, atlasH }
//
// Every byte is already in DEVICE pixels, top-left origin, straight alpha — the
// layout `src/web/shim.h` documents (17 floats per vertex, 9 int32 per segment).
// Both backends therefore differ only in API calls, never in arithmetic, and the
// shaders below are a port of `src/linux/shaders/*` rather than a second design.
//
// ## The one arithmetic difference, stated once
//
// Vulkan's clip space has +y DOWN, which is why `src/linux/shaders/quad.vert`
// needs no flip. WebGPU and WebGL both put +y UP, so both shaders here compute
// `1 - y/res*2`. And a WebGL scissor rectangle is measured from the BOTTOM of
// the framebuffer while Clay's is measured from the top, so the GL backend flips
// that one too. Everything else is identical.

/** Bytes per vertex and per segment, as `glin_web_gpu_vertex_stride()` reports them; used to sanity-check the frame before drawing it. */
const EXPECTED_VERTEX_STRIDE = 68;
const EXPECTED_SEGMENT_STRIDE = 36;

/**
 * Create the best backend this browser can give us.
 *
 * @param {HTMLCanvasElement} canvas
 * @param {{ webgpu?: boolean, webgl2?: boolean }} [options]
 * @returns {Promise<null | {
 *   kind: 1 | 2,
 *   name: string,
 *   draw: (frame: object) => boolean,
 *   destroy: () => void,
 * }>}
 */
export async function createBackend(canvas, options = {}) {
  const allowWebGPU = options.webgpu !== false;
  const allowWebGL2 = options.webgl2 !== false;

  if (allowWebGPU) {
    try {
      const backend = await createWebGPU(canvas);
      if (backend) return backend;
    } catch (err) {
      console.warn("glinlandui: WebGPU unavailable, trying WebGL2", err);
    }
  }
  if (allowWebGL2) {
    try {
      const backend = createWebGL2(canvas);
      if (backend) return backend;
    } catch (err) {
      console.warn("glinlandui: WebGL2 unavailable, using the CPU rasterizer", err);
    }
  }
  return null;
}

// ---------------------------------------------------------------------------
// WebGPU
// ---------------------------------------------------------------------------

/**
 * One WGSL module, two entry points. `vs_main` is shared by both pipelines, so a
 * rect and a glyph sample the same vertex buffer; `fs_rect` evaluates a rounded
 * box SDF in device pixels and `fs_text` samples the 8-bit coverage atlas.
 */
const WGSL = /* wgsl */ `
struct Uniforms {
  res: vec2f,
  pad: vec2f,
};
@group(0) @binding(0) var<uniform> u: Uniforms;
@group(0) @binding(1) var u_sampler: sampler;
@group(0) @binding(2) var u_texture: texture_2d<f32>;

struct VsOut {
  @builtin(position) pos: vec4f,
  @location(0) local: vec2f,
  @location(1) size: vec2f,
  @location(2) radius: vec4f,
  @location(3) color: vec4f,
  @location(4) mode: f32,
  @location(5) border: f32,
};

@vertex
fn vs_main(
  @location(0) a_pos: vec2f,
  @location(1) a_local: vec2f,
  @location(2) a_size: vec2f,
  @location(3) a_radius: vec4f,
  @location(4) a_color: vec4f,
  @location(5) a_mode: f32,
  @location(6) a_border: f32,
  @location(7) a_kind: f32,
) -> VsOut {
  var out: VsOut;
  // +y is UP in clip space here, and the geometry is top-left origin: the flip.
  let x = a_pos.x / u.res.x * 2.0 - 1.0;
  let y = 1.0 - a_pos.y / u.res.y * 2.0;
  out.pos = vec4f(x, y, 0.0, 1.0);
  out.local = a_local;
  out.size = a_size;
  out.radius = a_radius;
  out.color = a_color;
  out.mode = a_mode;
  out.border = a_border;
  return out;
}

fn sd_round_box(p: vec2f, b: vec2f, r: vec4f) -> f32 {
  let rad = select(select(r.x, r.z, p.y >= 0.0), select(r.y, r.w, p.y >= 0.0), p.x >= 0.0);
  let q = abs(p) - b + rad;
  return length(max(q, vec2f(0.0))) + min(max(q.x, q.y), 0.0) - rad;
}

// One device pixel of coverage band: crisp on a 1px border and on a convex corner.
fn cov(d: f32) -> f32 {
  return clamp(0.5 - d, 0.0, 1.0);
}

@fragment
fn fs_rect(i: VsOut) -> @location(0) vec4f {
  let c = i.size * 0.5;
  let p = i.local - c;
  let m = min(c.x, c.y);
  let r = clamp(i.radius, vec4f(0.0), vec4f(m));
  var a = cov(sd_round_box(p, c, r));
  if (i.mode > 0.5) {
    let ib = max(c - vec2f(i.border), vec2f(0.0));
    let mi = min(ib.x, ib.y);
    let ri = clamp(r - vec4f(i.border), vec4f(0.0), vec4f(mi));
    a = a * (1.0 - cov(sd_round_box(p, ib, ri)));
  }
  if (a <= 0.0) {
    discard;
  }
  return vec4f(i.color.rgb, i.color.a * a);
}

@fragment
fn fs_text(i: VsOut) -> @location(0) vec4f {
  let a = textureSample(u_texture, u_sampler, i.local).r;
  return vec4f(i.color.rgb, i.color.a * a);
}

// An image carries its own colour: the texture IS the output.
@fragment
fn fs_image(i: VsOut) -> @location(0) vec4f {
  return textureSample(u_texture, u_sampler, i.local);
}
`;

/** The vertex layout: 17 floats, the offsets `src/web/shim.h` documents. */
function webgpuVertexLayout(stride) {
  return {
    arrayStride: stride,
    attributes: [
      { shaderLocation: 0, offset: 0, format: "float32x2" },
      { shaderLocation: 1, offset: 8, format: "float32x2" },
      { shaderLocation: 2, offset: 16, format: "float32x2" },
      { shaderLocation: 3, offset: 24, format: "float32x4" },
      { shaderLocation: 4, offset: 40, format: "float32x4" },
      { shaderLocation: 5, offset: 56, format: "float32" },
      { shaderLocation: 6, offset: 60, format: "float32" },
      { shaderLocation: 7, offset: 64, format: "float32" },
    ],
  };
}

/**
 * The WebGPU backend, or null when this browser cannot give us a device.
 *
 * A `null` return is the ordinary case on a browser without WebGPU (Firefox on
 * Linux, Safari before 26, any browser with the flag off), so nothing here logs
 * a failure — `createBackend` moves on to WebGL2.
 */
async function createWebGPU(canvas) {
  if (!("gpu" in navigator) || !navigator.gpu) return null;
  const adapter = await navigator.gpu.requestAdapter({ powerPreference: "high-performance" });
  if (!adapter) return null;
  const device = await adapter.requestDevice();

  const format = navigator.gpu.getPreferredCanvasFormat();
  const module = device.createShaderModule({ code: WGSL, label: "glinlandui" });
  // Everything that can be validated is validated BEFORE the canvas is asked for
  // a context: a canvas hands out one kind of context for its lifetime, so taking
  // `webgpu` and then discovering the pipeline does not build would leave a page
  // that could not fall back to WebGL2 (or even to `2d`).
  const info = await (module.getCompilationInfo ? module.getCompilationInfo() : null);
  if (info && info.messages.some((m) => m.type === "error")) {
    console.warn("glinlandui: the WGSL module did not compile", info.messages);
    device.destroy();
    return null;
  }

  const bindGroupLayout = device.createBindGroupLayout({
    entries: [
      {
        binding: 0,
        visibility: GPUShaderStage.VERTEX | GPUShaderStage.FRAGMENT,
        buffer: { type: "uniform" },
      },
      { binding: 1, visibility: GPUShaderStage.FRAGMENT, sampler: { type: "filtering" } },
      { binding: 2, visibility: GPUShaderStage.FRAGMENT, texture: { sampleType: "float" } },
    ],
  });
  const pipelineLayout = device.createPipelineLayout({ bindGroupLayouts: [bindGroupLayout] });

  const sampler = device.createSampler({
    magFilter: "linear",
    minFilter: "linear",
    addressModeU: "clamp-to-edge",
    addressModeV: "clamp-to-edge",
  });

  // Straight-alpha over, exactly like the Vulkan and Metal pipelines.
  const blend = {
    color: { srcFactor: "src-alpha", dstFactor: "one-minus-src-alpha", operation: "add" },
    alpha: { srcFactor: "one", dstFactor: "one-minus-src-alpha", operation: "add" },
  };

  const uniformBuffer = device.createBuffer({
    size: 16,
    usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST,
    label: "glinlandui-res",
  });

  // A 1x1 white texel is what the rect pipeline binds: its shader never samples,
  // but a bind group needs a texture, and this keeps one layout for all pipelines.
  const whiteTexture = device.createTexture({
    size: [1, 1],
    format: "r8unorm",
    usage: GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST,
  });
  device.queue.writeTexture(
    { texture: whiteTexture },
    new Uint8Array([255]),
    { bytesPerRow: 1 },
    { width: 1, height: 1 },
  );
  const whiteView = whiteTexture.createView();

  let atlasTexture = null;
  let atlasView = null;
  let atlasBindGroup = null;
  let atlasVersion = 0;
  let atlasSize = [0, 0];
  let vertexBuffer = null;
  let configured = [0, 0];
  let lost = false;
  // One GPU texture per image id, with the version that produced it and the bind group that samples it.
  const imageTextures = new Map();

  device.lost.then((info) => {
    lost = true;
    console.warn(`glinlandui: the WebGPU device was lost (${info.reason}): ${info.message}`);
  });

  function buildPipelines() {
    const vertex = { module, entryPoint: "vs_main", buffers: [webgpuVertexLayout(EXPECTED_VERTEX_STRIDE)] };
    const primitive = { topology: "triangle-list" };
    const multisample = { count: 1 };
    const targets = [{ format, blend }];
    const rect = device.createRenderPipeline({
      layout: pipelineLayout,
      vertex,
      fragment: { module, entryPoint: "fs_rect", targets },
      primitive,
      multisample,
      label: "glinlandui-rect",
    });
    const text = device.createRenderPipeline({
      layout: pipelineLayout,
      vertex,
      fragment: { module, entryPoint: "fs_text", targets },
      primitive,
      multisample,
      label: "glinlandui-text",
    });
    const image = device.createRenderPipeline({
      layout: pipelineLayout,
      vertex,
      fragment: { module, entryPoint: "fs_image", targets },
      primitive,
      multisample,
      label: "glinlandui-image",
    });
    const whiteBindGroup = device.createBindGroup({
      layout: bindGroupLayout,
      entries: [
        { binding: 0, resource: { buffer: uniformBuffer } },
        { binding: 1, resource: sampler },
        { binding: 2, resource: whiteView },
      ],
    });
    return { rect, text, image, whiteBindGroup };
  }

  // One error scope around every device object the first frame will use: a
  // validation failure is then a `null` (which falls through to WebGL2) instead
  // of a page that draws nothing.
  device.pushErrorScope("validation");
  const pipelines = buildPipelines();
  const pipelineError = await device.popErrorScope();
  if (pipelineError) {
    console.warn("glinlandui: the WebGPU pipelines did not validate", pipelineError.message);
    device.destroy();
    return null;
  }

  const context = canvas.getContext("webgpu");
  if (!context) {
    device.destroy();
    return null;
  }

  function ensureAtlas(frame) {
    if (!frame.atlas || frame.atlas.length === 0) return;
    const [w, h] = [frame.atlasW | 0, frame.atlasH | 0];
    if (w <= 0 || h <= 0) return;
    if (!atlasTexture || atlasSize[0] !== w || atlasSize[1] !== h) {
      if (atlasTexture) atlasTexture.destroy();
      atlasTexture = device.createTexture({
        size: [w, h],
        format: "r8unorm",
        usage: GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST,
        label: "glinlandui-atlas",
      });
      atlasView = atlasTexture.createView();
      atlasSize = [w, h];
      atlasVersion = 0;
      atlasBindGroup = device.createBindGroup({
        layout: bindGroupLayout,
        entries: [
          { binding: 0, resource: { buffer: uniformBuffer } },
          { binding: 1, resource: sampler },
          { binding: 2, resource: atlasView },
        ],
      });
    }
    if (atlasVersion === frame.atlasVersion) return;
    // A 1024-wide R8 atlas: `bytesPerRow` must be a multiple of 256, which
    // `src/web/gpu.zig`'s atlas size guarantees (and the header states).
    device.queue.writeTexture(
      { texture: atlasTexture },
      frame.atlas,
      { bytesPerRow: w },
      { width: w, height: h },
    );
    atlasVersion = frame.atlasVersion;
  }

  // `writeTexture` wants 256-byte rows; an image's own row rarely is, so pad when it is not.
  function padRows(bytes, row, padded, rows) {
    const out = new Uint8Array(padded * rows);
    for (let y = 0; y < rows; y++) out.set(bytes.subarray(y * row, y * row + row), y * padded);
    return out;
  }

  function ensureImages(frame) {
    for (const img of frame.images ?? []) {
      if (!img.bytes || img.bytes.length === 0 || img.width <= 0 || img.height <= 0) continue;
      const have = imageTextures.get(img.id);
      if (have && have.version === img.version) continue;
      const texture = have
        ? have.texture
        : device.createTexture({
            size: [img.width, img.height],
            format: "rgba8unorm",
            usage: GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST,
            label: `glinlandui-image-${img.id}`,
          });
      const row = img.width * 4;
      const padded = Math.ceil(row / 256) * 256;
      const data = padded === row ? img.bytes : padRows(img.bytes, row, padded, img.height);
      device.queue.writeTexture(
        { texture },
        data,
        { bytesPerRow: padded, rowsPerImage: img.height },
        { width: img.width, height: img.height },
      );
      const view = texture.createView();
      const bindGroup = device.createBindGroup({
        layout: bindGroupLayout,
        entries: [
          { binding: 0, resource: { buffer: uniformBuffer } },
          { binding: 1, resource: sampler },
          { binding: 2, resource: view },
        ],
      });
      imageTextures.set(img.id, { texture, version: img.version, bindGroup });
    }
  }

  return {
    kind: 1,
    name: "WebGPU",

    draw(frame) {
      if (lost) return false;
      const w = frame.width | 0;
      const h = frame.height | 0;
      if (w <= 0 || h <= 0) return false;
      if (frame.vertexStride !== EXPECTED_VERTEX_STRIDE || frame.segmentStride !== EXPECTED_SEGMENT_STRIDE) {
        throw new Error(
          `glinlandui: vertex/segment layout changed (${frame.vertexStride}/${frame.segmentStride}, expected ${EXPECTED_VERTEX_STRIDE}/${EXPECTED_SEGMENT_STRIDE})`,
        );
      }
      if (canvas.width !== w) canvas.width = w;
      if (canvas.height !== h) canvas.height = h;
      if (configured[0] !== w || configured[1] !== h) {
        context.configure({ device, format, alphaMode: "opaque" });
        configured = [w, h];
      }

      ensureAtlas(frame);
      ensureImages(frame);

      device.queue.writeBuffer(uniformBuffer, 0, new Float32Array([w, h, 0, 0]));

      if (!vertexBuffer || vertexBuffer.size < frame.verts.length) {
        if (vertexBuffer) vertexBuffer.destroy();
        vertexBuffer = device.createBuffer({
          size: Math.max(frame.verts.length, 4096),
          usage: GPUBufferUsage.VERTEX | GPUBufferUsage.COPY_DST,
          label: "glinlandui-verts",
        });
      }
      if (frame.verts.length > 0) device.queue.writeBuffer(vertexBuffer, 0, frame.verts);

      const c = frame.clear;
      const encoder = device.createCommandEncoder();
      const pass = encoder.beginRenderPass({
        colorAttachments: [
          {
            view: context.getCurrentTexture().createView(),
            clearValue: { r: c[0], g: c[1], b: c[2], a: c[3] },
            loadOp: "clear",
            storeOp: "store",
          },
        ],
      });

      if (frame.verts.length > 0) {
        pass.setVertexBuffer(0, vertexBuffer);
        const segs = new DataView(frame.segs.buffer, frame.segs.byteOffset, frame.segs.byteLength);
        let pipeline = null;
        let group = null;
        for (let i = 0; i < frame.segCount; i++) {
          const o = i * frame.segmentStride;
          const start = segs.getInt32(o, true);
          const count = segs.getInt32(o + 4, true);
          if (count <= 0) continue;
          const wantsScissor = segs.getInt32(o + 8, true) !== 0;
          const textureId = segs.getUint32(o + 28, true);
          const kind = segs.getInt32(o + 32, true);
          let next;
          let nextGroup;
          if (kind === 2) {
            // An image quad: its own texture, so its own bind group, and the image pipeline.
            const entry = imageTextures.get(textureId);
            if (!entry) continue;
            next = pipelines.image;
            nextGroup = entry.bindGroup;
          } else if (kind === 1) {
            if (!atlasBindGroup) continue; // no atlas yet: nothing to sample
            next = pipelines.text;
            nextGroup = atlasBindGroup;
          } else {
            next = pipelines.rect;
            nextGroup = pipelines.whiteBindGroup;
          }
          if (next !== pipeline) {
            pass.setPipeline(next);
            pipeline = next;
          }
          if (nextGroup !== group) {
            pass.setBindGroup(0, nextGroup);
            group = nextGroup;
          }
          if (wantsScissor) {
            const sx = segs.getInt32(o + 12, true);
            const sy = segs.getInt32(o + 16, true);
            const sw = segs.getInt32(o + 20, true);
            const sh = segs.getInt32(o + 24, true);
            // WebGPU requires the rectangle to lie INSIDE the attachment, so both edges clamp, as vk.c does.
            const x0 = Math.max(0, sx);
            const y0 = Math.max(0, sy);
            const x1 = Math.min(w, sx + sw);
            const y1 = Math.min(h, sy + sh);
            if (x1 <= x0 || y1 <= y0) continue;
            pass.setScissorRect(x0, y0, x1 - x0, y1 - y0);
          } else {
            pass.setScissorRect(0, 0, w, h);
          }
          pass.draw(count, 1, start, 0);
        }
      }

      pass.end();
      device.queue.submit([encoder.finish()]);
      return true;
    },

    destroy() {
      if (vertexBuffer) vertexBuffer.destroy();
      for (const entry of imageTextures.values()) entry.texture.destroy();
      imageTextures.clear();
      if (atlasTexture) atlasTexture.destroy();
      whiteTexture.destroy();
      uniformBuffer.destroy();
      device.destroy();
    },
  };
}

// ---------------------------------------------------------------------------
// WebGL2
// ---------------------------------------------------------------------------

/** The shared vertex shader: identical to the WGSL one, minus the bind group. */
const GLSL_VERTEX = `#version 300 es
layout(location = 0) in vec2 a_pos;
layout(location = 1) in vec2 a_local;
layout(location = 2) in vec2 a_size;
layout(location = 3) in vec4 a_radius;
layout(location = 4) in vec4 a_color;
layout(location = 5) in float a_mode;
layout(location = 6) in float a_border;
layout(location = 7) in float a_kind;
uniform vec2 u_res;
out vec2 v_local;
out vec2 v_size;
out vec4 v_radius;
out vec4 v_color;
out float v_mode;
out float v_border;
void main() {
  vec2 ndc = vec2(a_pos.x / u_res.x * 2.0 - 1.0, 1.0 - a_pos.y / u_res.y * 2.0);
  gl_Position = vec4(ndc, 0.0, 1.0);
  v_local = a_local;
  v_size = a_size;
  v_radius = a_radius;
  v_color = a_color;
  v_mode = a_mode;
  v_border = a_border;
}
`;

/** The rounded-box fill and border outline: the same SDF as `src/linux/shaders/rect.frag`. */
const GLSL_RECT = `#version 300 es
precision highp float;
in vec2 v_local;
in vec2 v_size;
in vec4 v_radius;
in vec4 v_color;
in float v_mode;
in float v_border;
out vec4 o_color;
float sdRoundBox(vec2 p, vec2 b, vec4 r) {
  float rad = (p.x < 0.0) ? (p.y < 0.0 ? r.x : r.z) : (p.y < 0.0 ? r.y : r.w);
  vec2 q = abs(p) - b + rad;
  return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - rad;
}
float cov(float d) {
  return clamp(0.5 - d, 0.0, 1.0);
}
void main() {
  vec2 c = v_size * 0.5;
  vec2 p = v_local - c;
  float m = min(c.x, c.y);
  vec4 r = min(max(v_radius, vec4(0.0)), vec4(m));
  float a = cov(sdRoundBox(p, c, r));
  if (v_mode > 0.5) {
    vec2 ib = max(c - vec2(v_border), vec2(0.0));
    float mi = min(ib.x, ib.y);
    vec4 ri = min(max(r - vec4(v_border), vec4(0.0)), vec4(mi));
    a *= (1.0 - cov(sdRoundBox(p, ib, ri)));
  }
  if (a <= 0.0) discard;
  o_color = vec4(v_color.rgb, v_color.a * a);
}
`;

/** One text run: an 8-bit coverage bitmap tinted with the ink colour. */
const GLSL_TEXT = `#version 300 es
precision highp float;
in vec2 v_local;
in vec4 v_color;
uniform sampler2D u_tex;
out vec4 o_color;
void main() {
  float a = texture(u_tex, v_local).r;
  o_color = vec4(v_color.rgb, v_color.a * a);
}
`;

/** An image quad: the decoded pixels carry their own colour, so the texture is the output. */
const GLSL_IMAGE = `#version 300 es
precision highp float;
in vec2 v_local;
uniform sampler2D u_tex;
out vec4 o_color;
void main() {
  o_color = texture(u_tex, v_local);
}
`;

/** Compile one program, with the driver's own log in the error rather than a bare `false`. */
function glProgram(gl, vertexSource, fragmentSource, label) {
  const compile = (type, source) => {
    const shader = gl.createShader(type);
    gl.shaderSource(shader, source);
    gl.compileShader(shader);
    if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) {
      const log = gl.getShaderInfoLog(shader);
      gl.deleteShader(shader);
      throw new Error(`glinlandui: ${label} shader did not compile: ${log}`);
    }
    return shader;
  };
  const vs = compile(gl.VERTEX_SHADER, vertexSource);
  const fs = compile(gl.FRAGMENT_SHADER, fragmentSource);
  const program = gl.createProgram();
  gl.attachShader(program, vs);
  gl.attachShader(program, fs);
  gl.linkProgram(program);
  gl.deleteShader(vs);
  gl.deleteShader(fs);
  if (!gl.getProgramParameter(program, gl.LINK_STATUS)) {
    const log = gl.getProgramInfoLog(program);
    gl.deleteProgram(program);
    throw new Error(`glinlandui: ${label} program did not link: ${log}`);
  }
  return program;
}

/**
 * The WebGL2 backend, or null when the browser has no WebGL2.
 *
 * WebGL2 is OpenGL ES 3.0, which is the API this toolkit's Linux renderer used
 * before the Vulkan port — so the shaders here are a near-verbatim port of the
 * GLSL that shipped then, and of the committed Vulkan ones.
 */
function createWebGL2(canvas) {
  const gl = canvas.getContext("webgl2", {
    alpha: false,
    antialias: false,
    depth: false,
    stencil: false,
    premultipliedAlpha: false,
    preserveDrawingBuffer: false,
  });
  if (!gl) return null;

  const rectProgram = glProgram(gl, GLSL_VERTEX, GLSL_RECT, "rect");
  const textProgram = glProgram(gl, GLSL_VERTEX, GLSL_TEXT, "text");
  const imageProgram = glProgram(gl, GLSL_VERTEX, GLSL_IMAGE, "image");
  const uniforms = new Map();
  const uniformOf = (program, name) => {
    if (!uniforms.has(program)) uniforms.set(program, new Map());
    const per = uniforms.get(program);
    if (!per.has(name)) per.set(name, gl.getUniformLocation(program, name));
    return per.get(name);
  };
  // One texture per image id, with the version that produced it.
  const imageTextures = new Map();

  const vao = gl.createVertexArray();
  const vbo = gl.createBuffer();
  let vboBytes = 0;
  let vboStride = 0;

  const atlas = gl.createTexture();
  gl.bindTexture(gl.TEXTURE_2D, atlas);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
  // An 8-bit single-channel atlas has no 4-byte row guarantee; without this a
  // width that is not a multiple of 4 reads one row shifted.
  gl.pixelStorei(gl.UNPACK_ALIGNMENT, 1);
  gl.texImage2D(gl.TEXTURE_2D, 0, gl.R8, 1, 1, 0, gl.RED, gl.UNSIGNED_BYTE, new Uint8Array([255]));
  let atlasSize = [0, 0];
  let atlasVersion = 0;

  let lost = false;
  canvas.addEventListener("webglcontextlost", (event) => {
    event.preventDefault();
    lost = true;
  });

  function bindAttributes(stride) {
    if (vboStride === stride) return;
    vboStride = stride;
    gl.bindVertexArray(vao);
    gl.bindBuffer(gl.ARRAY_BUFFER, vbo);
    // Offsets are BYTES into the 68-byte vertex, exactly as `src/web/shim.h` lists them.
    const attrs = [
      [0, 2, 0],
      [1, 2, 8],
      [2, 2, 16],
      [3, 4, 24],
      [4, 4, 40],
      [5, 1, 56],
      [6, 1, 60],
      [7, 1, 64],
    ];
    for (const [location, size, offset] of attrs) {
      gl.enableVertexAttribArray(location);
      gl.vertexAttribPointer(location, size, gl.FLOAT, false, stride, offset);
    }
    gl.bindVertexArray(null);
  }

  return {
    kind: 2,
    name: "WebGL2",

    draw(frame) {
      if (lost || gl.isContextLost()) return false;
      const w = frame.width | 0;
      const h = frame.height | 0;
      if (w <= 0 || h <= 0) return false;
      if (frame.vertexStride !== EXPECTED_VERTEX_STRIDE || frame.segmentStride !== EXPECTED_SEGMENT_STRIDE) {
        throw new Error(
          `glinlandui: vertex/segment layout changed (${frame.vertexStride}/${frame.segmentStride}, expected ${EXPECTED_VERTEX_STRIDE}/${EXPECTED_SEGMENT_STRIDE})`,
        );
      }
      if (canvas.width !== w) canvas.width = w;
      if (canvas.height !== h) canvas.height = h;

      if (frame.atlas && frame.atlas.length > 0) {
        const [aw, ah] = [frame.atlasW | 0, frame.atlasH | 0];
        if (aw > 0 && ah > 0) {
          gl.bindTexture(gl.TEXTURE_2D, atlas);
          const sizeChanged = atlasSize[0] !== aw || atlasSize[1] !== ah;
          if (sizeChanged) {
            atlasSize = [aw, ah];
            atlasVersion = 0;
          }
          if (atlasVersion !== frame.atlasVersion) {
            gl.texImage2D(gl.TEXTURE_2D, 0, gl.R8, aw, ah, 0, gl.RED, gl.UNSIGNED_BYTE, frame.atlas);
            atlasVersion = frame.atlasVersion;
          }
        }
      }

      for (const img of frame.images ?? []) {
        if (!img.bytes || img.bytes.length === 0 || img.width <= 0 || img.height <= 0) continue;
        const have = imageTextures.get(img.id);
        if (have && have.version === img.version) continue;
        const texture = have ? have.texture : gl.createTexture();
        gl.bindTexture(gl.TEXTURE_2D, texture);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
        gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, img.width, img.height, 0, gl.RGBA, gl.UNSIGNED_BYTE, img.bytes);
        imageTextures.set(img.id, { texture, version: img.version });
      }

      const c = frame.clear;
      gl.bindFramebuffer(gl.FRAMEBUFFER, null);
      gl.viewport(0, 0, w, h);
      // The clear must not be clipped by the previous frame's scissor.
      gl.disable(gl.SCISSOR_TEST);
      gl.clearColor(c[0], c[1], c[2], c[3]);
      gl.clear(gl.COLOR_BUFFER_BIT);
      gl.enable(gl.SCISSOR_TEST);
      gl.enable(gl.BLEND);
      gl.blendFuncSeparate(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA, gl.ONE, gl.ONE_MINUS_SRC_ALPHA);
      gl.blendEquation(gl.FUNC_ADD);

      if (frame.verts.length > 0) {
        bindAttributes(frame.vertexStride);
        gl.bindVertexArray(vao);
        gl.bindBuffer(gl.ARRAY_BUFFER, vbo);
        if (vboBytes < frame.verts.length) {
          vboBytes = frame.verts.length;
          gl.bufferData(gl.ARRAY_BUFFER, vboBytes, gl.DYNAMIC_DRAW);
        }
        gl.bufferSubData(gl.ARRAY_BUFFER, 0, frame.verts);

        const segs = new DataView(frame.segs.buffer, frame.segs.byteOffset, frame.segs.byteLength);
        let program = null;
        for (let i = 0; i < frame.segCount; i++) {
          const o = i * frame.segmentStride;
          const start = segs.getInt32(o, true);
          const count = segs.getInt32(o + 4, true);
          if (count <= 0) continue;
          const wantsScissor = segs.getInt32(o + 8, true) !== 0;
          const textureId = segs.getUint32(o + 28, true);
          const kind = segs.getInt32(o + 32, true);
          let next;
          let bound;
          if (kind === 2) {
            const entry = imageTextures.get(textureId);
            if (!entry) continue;
            next = imageProgram;
            bound = entry.texture;
          } else if (kind === 1) {
            if (atlasSize[0] === 0) continue; // no atlas yet: nothing to sample
            next = textProgram;
            bound = atlas;
          } else {
            next = rectProgram;
            bound = atlas;
          }
          if (next !== program) {
            gl.useProgram(next);
            gl.uniform1i(uniformOf(next, "u_tex"), 0);
            program = next;
          }
          gl.uniform2f(uniformOf(program, "u_res"), w, h);
          gl.activeTexture(gl.TEXTURE0);
          gl.bindTexture(gl.TEXTURE_2D, bound);
          if (wantsScissor) {
            const sx = segs.getInt32(o + 12, true);
            const sy = segs.getInt32(o + 16, true);
            const sw = segs.getInt32(o + 20, true);
            const sh = segs.getInt32(o + 24, true);
            // GL clamps too, and its scissor origin is the BOTTOM-left: the one flip this backend needs.
            const x0 = Math.max(0, sx);
            const y0 = Math.max(0, sy);
            const x1 = Math.min(w, sx + sw);
            const y1 = Math.min(h, sy + sh);
            if (x1 <= x0 || y1 <= y0) continue;
            gl.scissor(x0, h - y1, x1 - x0, y1 - y0);
          } else {
            gl.scissor(0, 0, w, h);
          }
          gl.drawArrays(gl.TRIANGLES, start, count);
        }
        gl.bindVertexArray(null);
      }

      gl.flush();
      // A GL error is not thrown by the API: without this check a broken draw
      // call leaves the clear colour on screen and reports success.
      const err = gl.getError();
      if (err !== gl.NO_ERROR) throw new Error(`glinlandui: WebGL2 error 0x${err.toString(16)} while presenting`);
      return true;
    },

    destroy() {
      gl.deleteBuffer(vbo);
      gl.deleteVertexArray(vao);
      for (const entry of imageTextures.values()) gl.deleteTexture(entry.texture);
      imageTextures.clear();
      gl.deleteTexture(atlas);
      gl.deleteProgram(rectProgram);
      gl.deleteProgram(textProgram);
      gl.deleteProgram(imageProgram);
      const lose = gl.getExtension("WEBGL_lose_context");
      if (lose) lose.loseContext();
    },
  };
}
