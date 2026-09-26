// glinlandui Windows shim: the Win32 window + the D3D11 present path.
//
// This is the only untestable part of the Windows backend, by design and for
// the same reason mac/shim.m is: it owns exactly two things nobody can unit
// test from Zig — an HWND and a D3D11 device — and nothing else. Every
// decision it would otherwise make lives in `src/windows/` as pure, unit-tested
// Zig: the VK->evdev keycode table, the pointer/button translation, scroll
// clamping, resize coalescing and the RGBA8 hand-off all have their own module
// and their own tests in the cross-platform parity suite.
//
// ## Why D3D11, and what "rendering with D3D11" means here
//
// The window's pixels are composited by the GPU: each frame's CPU surface is
// uploaded into an ID3D11Texture2D and drawn through a fullscreen-quad vertex
// + pixel shader into the DXGI swap chain's back buffer, then presented. That
// is the same ROLE the GLES3 path plays on Linux (linux/present.zig) — the
// difference is that the GLES3 backend also rasterises the UI on the GPU,
// whereas here the shared CPU rasterizer in core/ does the drawing and D3D11
// does the compositing. That split is deliberate: it keeps the untestable
// surface down to a device and a window, and it is why the calculator looks
// identical on all three platforms. See src/README.md.
//
// ## Three details that are load-bearing and easy to get wrong
//
//  1. `COBJMACROS` before <windows.h>. The MinGW headers in this toolchain
//     only declare the COM method macros (ID3D11Device_Release and friends)
//     under it, and the whole file is therefore written in the macro form
//     `ID3D11Device_Release(dev)` rather than `dev->Release()`. This is also
//     why no Direct3D header is exposed through shim.h.
//
//  2. `D3DCompile` returns BYTECODE, not a shader object. Storing the
//     `ID3D10Blob` where an `ID3D11VertexShader` belongs compiles cleanly,
//     links cleanly, and draws nothing at all: the driver is handed a blob
//     pointer as a shader object, answers S_FALSE without writing the output,
//     and the back buffer keeps whatever it was cleared to. The visible
//     symptom is indistinguishable from "the present path is broken", which is
//     why compileInto() below checks the output pointer as well as the HRESULT.
//
//  3. WARP is a first-class path, not a fallback of last resort. A CI runner
//     and a VM both have no hardware D3D11 adapter, and a backend that simply
//     gives up there is a backend nobody can test. WARP is Microsoft's own
//     Direct3D 11 software rasterizer, it honours the identical feature
//     levels and shader model, and it works with no display attached — which
//     is what lets ci/check_windows_colors.sh drive the REAL present path
//     headlessly and compare displayed pixels with written pixels.

#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <d3d11.h>
#include <d3dcompiler.h>
#include <dxgi.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "shim.h"

// MinGW declares COM inheritance only in the vtable LAYOUT, never in the C
// types: ID3D11Texture2D's vtable IS an ID3D11Resource vtable followed by its
// own methods, but the two are unrelated types as far as the compiler is
// concerned. Every API that takes the base interface therefore needs an
// explicit cast. This is the documented MinGW COM idiom, and the cast is
// layout-safe precisely because the inheritance is real in the vtable.
#define GLIN_RES(x) ((ID3D11Resource *)(x))

// ---------------------------------------------------------------------------
// The swap-chain / probe format.
//
// R8G8B8A8_UNORM, and not the "native" B8G8R8A8_UNORM, for one reason: the
// bytes of a texel then arrive in memory order R, G, B, A, which is exactly
// what core/render_software.zig's Surface already holds. Choosing it makes the
// per-frame upload a straight memcpy of the surface — no channel swap on the
// CPU, which is one fewer place for a plausible-but-wrong window to come
// from. windows/present.zig pins the byte order with tests, and
// ci/check_windows_colors.c proves it against real GPU output.
// ---------------------------------------------------------------------------
#define GLIN_DXGI_FORMAT DXGI_FORMAT_R8G8B8A8_UNORM

// The clear colour, in 0..1 float. Matches the CPU rasterizer's clear so a
// resize or a half-drawn frame does not flash a different colour.
static const float kGlinClear[4] = { 0.043f, 0.043f, 0.055f, 1.0f };

// The pipeline draws one big triangle covering the viewport. No vertex buffer
// and no vertex-state object: SV_VertexID is enough, which keeps the entire
// draw to a shader pair, one sampler and a single Draw call.
static const char *const kGlinVS =
    "struct VSOut { float4 pos : SV_POSITION; float2 uv : TEXCOORD0; };\n"
    "VSOut VSMain(uint vid : SV_VertexID) {\n"
    "    VSOut o;\n"
    "    float2 p = float2((vid << 1) & 2, vid & 2);\n"
    "    o.pos = float4(p * float2(2.0f, -2.0f) + float2(-1.0f, 1.0f), 0.0f, 1.0f);\n"
    "    o.uv  = p;\n"
    "    return o;\n"
    "}\n";

static const char *const kGlinPS =
    "Texture2D   g_tex  : register(t0);\n"
    "SamplerState g_samp : register(s0);\n"
    "float4 PSMain(float4 pos : SV_POSITION, float2 uv : TEXCOORD0) : SV_Target {\n"
    "    return g_tex.Sample(g_samp, uv);\n"
    "}\n";

// Pointer event kinds. Same numbering as mac/shim.h so the two shims are
// interchangeable and so windows/input.zig can be read against mac/input.zig.
#define GLIN_PTR_MOTION 0
#define GLIN_PTR_DOWN 1
#define GLIN_PTR_UP 2

// Button numbers, matching NSEvent.buttonNumber.
#define GLIN_BTN_LEFT 0
#define GLIN_BTN_RIGHT 1
#define GLIN_BTN_MIDDLE 2

// One wheel notch. The raw WHEEL_DELTA lives in the high word of wParam, and
// the SDK's GET_WHEEL_DELTA_WPARAM lives in <windowsx.h> — which Zig's MinGW
// copy does not define. Two sign-corrected reads are cheaper than a platform
// check here; see the use sites in wndProc.
#define GLIN_WHEEL_DELTA 120

static const wchar_t *const kGlinWindowClass = L"GlinlanduiWindow";
static const wchar_t *const kGlinWindowTitle = L"glinlandui";

struct GlinWinWindow {
    HWND hwnd;

    GlinWinOnFrame on_frame;
    GlinWinOnPointer on_pointer;
    GlinWinOnScroll on_scroll;
    GlinWinOnKey on_key;
    GlinWinOnResize on_resize;
    GlinWinOnClose on_close;
    void *user;

    // D3D11 present path.
    ID3D11Device *device;
    ID3D11DeviceContext *context;
    IDXGISwapChain *swap_chain;
    ID3D11RenderTargetView *back_rtv;
    ID3D11VertexShader *vs;
    ID3D11PixelShader *ps;
    ID3D11SamplerState *sampler;
    // The per-frame upload target: DYNAMIC + CPU_ACCESS_WRITE is the usage
    // pair D3D11 documents for UpdateSubresource out of system memory.
    ID3D11Texture2D *frame_tex;
    ID3D11ShaderResourceView *frame_srv;
    UINT tex_w;
    UINT tex_h;

    const char *adapter_name; // "hardware" | "warp" | "none"
    // GDI fallback. `gdi_dib` is a top-down 32-bit DIB section sized to the
    // current client area, and `gdi_mem_dc` a memory DC that selects it, so a
    // frame is a memcpy into `gdi_bits` followed by one BitBlt into the
    // window's DC. Both are created lazily and only on the first blit.
    HDC window_dc;
    HDC mem_dc;
    HBITMAP gdi_dib;
    HGDIOBJ old_bitmap;
    unsigned char *gdi_bits;
    int gdi_w;
    int gdi_h;
    int gdi; // 1 once the GDI path has taken over
    int min_w;
    int min_h;
    int max_frames;
    int frames;
    int quit;
    int captured;      // a button-down took the mouse capture
    int presented;     // set by glin_win_present, cleared by the paint handler
    int device_failed; // a Present failed; the GPU is gone, stop drawing
};

// ---------------------------------------------------------------------------
// Shader + pipeline setup. Shared by the window and by the headless probe so
// there is exactly one copy of "what D3D11 is being asked to do".
// ---------------------------------------------------------------------------

/// The common shape of ID3D11Device_CreateVertexShader and
/// CreatePixelShader, which differ only in the shader type they fill in.
/// `void **` because there is no shared base interface for the two, and the
/// two calls themselves are macros in this header — hence the wrappers.
typedef HRESULT(ID3D11_SHADER_CREATE_FN)(ID3D11Device *, const void *, SIZE_T, void **);

static HRESULT createVertexShaderShim(ID3D11Device *device, const void *bytecode,
                                      SIZE_T size, void **out) {
    return ID3D11Device_CreateVertexShader(device, bytecode, size, NULL,
                                           (ID3D11VertexShader **)out);
}

static HRESULT createPixelShaderShim(ID3D11Device *device, const void *bytecode,
                                     SIZE_T size, void **out) {
    return ID3D11Device_CreatePixelShader(device, bytecode, size, NULL,
                                          (ID3D11PixelShader **)out);
}

static int compileInto(ID3D11Device *device, const char *src, const char *entry,
                       const char *target, void **out, ID3D11_SHADER_CREATE_FN *create) {
    ID3D10Blob *code = NULL;
    ID3D10Blob *errors = NULL;
    HRESULT hr = D3DCompile(src, strlen(src), "glinlandui", NULL, NULL, entry, target, 0,
                            0, &code, &errors);
    if (errors != NULL) {
        // Never silently swallow a shader error: a backend whose most likely
        // failure mode is "the screen is black" has to be able to say why.
        // stderr rather than OutputDebugA, which WIN32_LEAN_AND_MEAN hides.
        fprintf(stderr, "glinlandui: D3DCompile(%s) failed: %s\n", entry,
                (const char *)ID3D10Blob_GetBufferPointer(errors));
        ID3D10Blob_Release(errors);
    }
    if (FAILED(hr) || code == NULL) {
        return 0;
    }
    const void *bytecode = ID3D10Blob_GetBufferPointer(code);
    const SIZE_T bytecode_size = (SIZE_T)ID3D10Blob_GetBufferSize(code);
    hr = create(device, bytecode, bytecode_size, out);
    ID3D10Blob_Release(code);
    // BOTH the HRESULT and the output pointer are checked. A driver answers
    // S_FALSE ("this shader is already in the device cache") without writing
    // the out parameter, and treating that as success is what leaves the back
    // buffer showing the clear colour and nothing else.
    if (FAILED(hr) || out == NULL || *out == NULL) {
        fprintf(stderr, "glinlandui: %s/%s shader creation failed (hr=0x%08lx)\n", entry,
                target, (unsigned long)hr);
        return 0;
    }
    return 1;
}

// Defined below createPipeline, which uses it to unwind a half-built
// pipeline; the declaration has to come first.
static void releasePipeline(GlinWinWindow *w);

static int createPipeline(GlinWinWindow *w) {
    // 5_0, not 6_0: WARP implements shader model 5_x, and a 6_0 target would
    // make the software-rasterizer path unavailable on exactly the machines
    // that most need to be able to run this.
    if (!compileInto(w->device, kGlinVS, "VSMain", "vs_5_0", (void **)&w->vs,
                     createVertexShaderShim)) {
        return 0;
    }
    if (!compileInto(w->device, kGlinPS, "PSMain", "ps_5_0", (void **)&w->ps,
                     createPixelShaderShim)) {
        ID3D11VertexShader_Release(w->vs);
        w->vs = NULL;
        return 0;
    }

    D3D11_SAMPLER_DESC sd;
    memset(&sd, 0, sizeof(sd));
    sd.AddressU = D3D11_TEXTURE_ADDRESS_CLAMP;
    sd.AddressV = D3D11_TEXTURE_ADDRESS_CLAMP;
    sd.AddressW = D3D11_TEXTURE_ADDRESS_CLAMP;
    sd.ComparisonFunc = D3D11_COMPARISON_NEVER;
    sd.MaxLOD = D3D11_FLOAT32_MAX;
    // LINEAR, not POINT: the client size and the laid-out surface size are
    // independent (a resize adopts a size, and DPI scaling can differ), so
    // the quad is very often drawn at a scale other than 1:1. POINT would
    // make a resized window show dropped pixels instead of the UI.
    sd.Filter = D3D11_FILTER_MIN_MAG_MIP_LINEAR;
    sd.MaxAnisotropy = 1;
    if (FAILED(ID3D11Device_CreateSamplerState(w->device, &sd, &w->sampler))) {
        releasePipeline(w);
        return 0;
    }
    return 1;
}

static void releasePipeline(GlinWinWindow *w) {
    if (w->sampler != NULL) {
        ID3D11SamplerState_Release(w->sampler);
        w->sampler = NULL;
    }
    if (w->vs != NULL) {
        ID3D11VertexShader_Release(w->vs);
        w->vs = NULL;
    }
    if (w->ps != NULL) {
        ID3D11PixelShader_Release(w->ps);
        w->ps = NULL;
    }
}

static void releaseFrameTexture(GlinWinWindow *w) {
    if (w->frame_srv != NULL) {
        ID3D11ShaderResourceView_Release(w->frame_srv);
        w->frame_srv = NULL;
    }
    if (w->frame_tex != NULL) {
        ID3D11Texture2D_Release(w->frame_tex);
        w->frame_tex = NULL;
    }
    w->tex_w = 0;
    w->tex_h = 0;
}

static int ensureFrameTexture(GlinWinWindow *w, int width, int height) {
    if (w->frame_tex != NULL && w->tex_w == (UINT)width && w->tex_h == (UINT)height) {
        return 1;
    }
    releaseFrameTexture(w);

    D3D11_TEXTURE2D_DESC td;
    memset(&td, 0, sizeof(td));
    td.Width = (UINT)width;
    td.Height = (UINT)height;
    td.MipLevels = 1;
    td.ArraySize = 1;
    td.Format = GLIN_DXGI_FORMAT;
    td.SampleDesc.Count = 1;
    td.Usage = D3D11_USAGE_DYNAMIC;
    td.BindFlags = D3D11_BIND_SHADER_RESOURCE;
    td.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
    if (FAILED(ID3D11Device_CreateTexture2D(w->device, &td, NULL, &w->frame_tex))) {
        return 0;
    }
    w->tex_w = (UINT)width;
    w->tex_h = (UINT)height;
    return SUCCEEDED(ID3D11Device_CreateShaderResourceView(
        w->device, GLIN_RES(w->frame_tex), NULL, &w->frame_srv));
}

/// Upload a surface into the per-frame texture. `src` is `width` rows of
/// straight R,G,B,A with row 0 the TOP row — `soft.Surface`, unchanged.
/// A D3D11 texture's (0,0) is its top-left texel, so the box below uploads
/// the frame with no vertical flip: row 0 stays row 0. See
/// windows/present.zig.
static void uploadSurface(GlinWinWindow *w, const unsigned char *src, int width,
                          int height) {
    D3D11_BOX box;
    memset(&box, 0, sizeof(box));
    box.left = 0;
    box.top = 0;
    box.right = (UINT)width;
    box.bottom = (UINT)height;
    box.front = 0;
    box.back = 1;
    // DstSubresource is a UINT mip index (0 = mip 0), not a pointer — the
    // `pDstSubresource` parameter name in the SDK's own macro is a leftover.
    ID3D11DeviceContext_UpdateSubresource(w->context, GLIN_RES(w->frame_tex), 0, &box, src,
                                          (UINT)(width * 4), 0);
}

/// The one draw call. `rtv` is the swap chain's back buffer in the window path
/// and an offscreen texture in the probe path — nothing else differs, which is
/// what makes the probe a real check of the window rather than a lookalike.
static void drawQuad(ID3D11DeviceContext *ctx, ID3D11RenderTargetView *rtv,
                     ID3D11VertexShader *vs, ID3D11PixelShader *ps,
                     ID3D11ShaderResourceView *srv, ID3D11SamplerState *sampler,
                     UINT width, UINT height) {
    // Every one of these being NULL means "no pipeline" — and drawing with a
    // NULL vertex shader is a silent no-op that leaves the clear colour on
    // screen, so it is treated as a reason not to draw at all.
    if (rtv == NULL || srv == NULL || sampler == NULL || vs == NULL || ps == NULL ||
        width == 0 || height == 0) {
        return;
    }
    D3D11_VIEWPORT vp;
    memset(&vp, 0, sizeof(vp));
    vp.TopLeftX = 0.0f;
    vp.TopLeftY = 0.0f;
    vp.Width = (float)width;
    vp.Height = (float)height;
    vp.MinDepth = 0.0f;
    vp.MaxDepth = 1.0f;

    ID3D11DeviceContext_OMSetRenderTargets(ctx, 1, &rtv, NULL);
    ID3D11DeviceContext_ClearRenderTargetView(ctx, rtv, kGlinClear);
    ID3D11DeviceContext_RSSetViewports(ctx, 1, &vp);

    ID3D11DeviceContext_VSSetShader(ctx, vs, NULL, 0);
    ID3D11DeviceContext_PSSetShader(ctx, ps, NULL, 0);
    ID3D11DeviceContext_PSSetShaderResources(ctx, 0, 1, &srv);
    ID3D11DeviceContext_PSSetSamplers(ctx, 0, 1, &sampler);

    // Three vertices is the biggest triangle that fits SV_VertexID, and one
    // triangle beats two here: no diagonal seam, no index buffer, no vertex
    // buffer at all.
    ID3D11DeviceContext_Draw(ctx, 3, 0);
}

static void clearOnly(ID3D11DeviceContext *ctx, ID3D11RenderTargetView *rtv) {
    if (ctx == NULL || rtv == NULL) {
        return;
    }
    ID3D11DeviceContext_OMSetRenderTargets(ctx, 1, &rtv, NULL);
    ID3D11DeviceContext_ClearRenderTargetView(ctx, rtv, kGlinClear);
}

// ---------------------------------------------------------------------------
// Device creation: hardware first, WARP second, then nothing.
// ---------------------------------------------------------------------------

static int createDeviceForWindow(GlinWinWindow *w) {
    static const D3D_DRIVER_TYPE order[2] = { D3D_DRIVER_TYPE_HARDWARE,
                                               D3D_DRIVER_TYPE_WARP };
    static const char *const names[2] = { "hardware", "warp" };

    for (int i = 0; i < 2; ++i) {
        DXGI_SWAP_CHAIN_DESC sd;
        memset(&sd, 0, sizeof(sd));
        sd.BufferDesc.Width = w->tex_w;
        sd.BufferDesc.Height = w->tex_h;
        sd.BufferDesc.Format = GLIN_DXGI_FORMAT;
        sd.BufferDesc.RefreshRate.Numerator = 60;
        sd.BufferDesc.RefreshRate.Denominator = 1;
        sd.SampleDesc.Count = 1;
        sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
        sd.BufferCount = 2;
        sd.OutputWindow = w->hwnd;
        sd.Windowed = TRUE;
        // DISCARD, not a flip model. A flip-model swap chain has to be
        // composited by DWM, which is exactly what is missing in a headless CI
        // session, and Present there can block instead of failing. The
        // bit-reversed buffer costs a copy of bytes this toolkit already
        // uploads from the CPU every frame.
        sd.SwapEffect = DXGI_SWAP_EFFECT_DISCARD;

        D3D_FEATURE_LEVEL got = D3D_FEATURE_LEVEL_11_0;
        IDXGISwapChain *sc = NULL;
        HRESULT hr = D3D11CreateDeviceAndSwapChain(NULL, order[i], NULL, 0, NULL, 0,
                                                   D3D11_SDK_VERSION, &sd, &sc,
                                                   &w->device, &got, &w->context);
        if (SUCCEEDED(hr) && sc != NULL && w->device != NULL && w->context != NULL) {
            w->swap_chain = sc;
            w->adapter_name = names[i];
            return 1;
        }
        if (sc != NULL) {
            IDXGISwapChain_Release(sc);
        }
        if (w->device != NULL) {
            ID3D11Device_Release(w->device);
            w->device = NULL;
        }
        if (w->context != NULL) {
            ID3D11DeviceContext_Release(w->context);
            w->context = NULL;
        }
    }
    w->adapter_name = "none";
    return 0;
}

static int ensureBackBufferView(GlinWinWindow *w) {
    ID3D11Texture2D *back = NULL;
    // The IID constants are `extern const IID` in C, not address constants,
    // so they need their address taken.
    if (FAILED(IDXGISwapChain_GetBuffer(w->swap_chain, 0, &IID_ID3D11Texture2D,
                                        (void **)&back))) {
        return 0;
    }
    HRESULT hr =
        ID3D11Device_CreateRenderTargetView(w->device, GLIN_RES(back), NULL, &w->back_rtv);
    ID3D11Texture2D_Release(back);
    return SUCCEEDED(hr);
}

static void releaseD3D(GlinWinWindow *w) {
    if (w->back_rtv != NULL) {
        ID3D11RenderTargetView_Release(w->back_rtv);
        w->back_rtv = NULL;
    }
    releaseFrameTexture(w);
    releasePipeline(w);
    // The immediate context holds references to the shader, the sampler and the
    // SRV, so it has to be unbound before release or the driver keeps them
    // alive past the window's lifetime.
    if (w->context != NULL) {
        ID3D11DeviceContext_ClearState(w->context);
        ID3D11DeviceContext_Flush(w->context);
    }
    if (w->swap_chain != NULL) {
        IDXGISwapChain_Release(w->swap_chain);
        w->swap_chain = NULL;
    }
    if (w->context != NULL) {
        ID3D11DeviceContext_Release(w->context);
        w->context = NULL;
    }
    if (w->device != NULL) {
        ID3D11Device_Release(w->device);
        w->device = NULL;
    }
    w->adapter_name = "none";
}

// ---------------------------------------------------------------------------
// The GDI fallback presenter.
//
// D3D11 is the presenter, and it is what runs wherever the machine has a
// working GPU driver. But a D3D11 device is cheap to create and easy to create
// USELESSLY: a VM, a container, or a machine with a half-initialised driver
// hands back a device, a swap chain and a compiled shader without complaint,
// and then fails the first time a vertex shader actually executes. That failure
// surfaces as DXGI_ERROR_DEVICE_HUNG on the first Present.
//
// Leaving the window blank at that point is the one unacceptable outcome: the
// app is running, the layout is correct, and the user sees nothing. So the shim
// abandons the device permanently and blits the same RGBA8 buffer into the
// window's device context with GDI, which every version of Windows implements in
// the kernel and which needs no driver, no shader and no compositor.
//
// This is not a second architecture. It is the same bytes over the same
// hand-off: the Delegate rendered into `soft.Surface`, and `windows/present.zig`
// already proved that contract is the identity. Only the thing the bytes are
// handed to changes.
// ---------------------------------------------------------------------------

static void releaseGdi(GlinWinWindow *w) {
    if (w->mem_dc != NULL) {
        if (w->old_bitmap != NULL) {
            SelectObject(w->mem_dc, w->old_bitmap);
            w->old_bitmap = NULL;
        }
        DeleteDC(w->mem_dc);
        w->mem_dc = NULL;
    }
    if (w->gdi_dib != NULL) {
        DeleteObject(w->gdi_dib);
        w->gdi_dib = NULL;
    }
    if (w->window_dc != NULL && w->hwnd != NULL) {
        ReleaseDC(w->hwnd, w->window_dc);
    }
    w->window_dc = NULL;
    w->gdi_bits = NULL;
    w->gdi_w = 0;
    w->gdi_h = 0;
}

/// Create (or resize) the DIB section and the memory DC. Returns 0 on failure,
/// in which case the caller simply does not paint — the window stays alive and
/// responsive, which is still better than crashing.
static int ensureGdi(GlinWinWindow *w, int width, int height) {
    if (w->gdi_dib != NULL && w->gdi_w == width && w->gdi_h == height) {
        return 1;
    }
    releaseGdi(w);
    if (w->hwnd == NULL || width <= 0 || height <= 0) {
        return 0;
    }
    BITMAPINFO bi;
    memset(&bi, 0, sizeof(bi));
    bi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    bi.bmiHeader.biWidth = width;
    // NEGATIVE height: a top-down DIB, so its first row is the visual TOP.
    // That is the same row order `soft.Surface` uses, which is why
    // windows/present.zig's identity claim survives the move from a D3D11
    // texture to a DIB. A positive height would silently mirror the whole UI,
    // which is the exact bug the D3D11 path is guarded against.
    bi.bmiHeader.biHeight = -height;
    bi.bmiHeader.biPlanes = 1;
    bi.bmiHeader.biBitCount = 32;
    bi.bmiHeader.biCompression = BI_RGB;

    void *bits = NULL;
    // GetDC first: CreateDIBSection takes a DEVICE CONTEXT, not a window.
    w->window_dc = GetDC(w->hwnd);
    if (w->window_dc == NULL) {
        releaseGdi(w);
        return 0;
    }
    w->gdi_dib = CreateDIBSection(w->window_dc, &bi, DIB_RGB_COLORS, &bits, NULL, 0);
    if (w->gdi_dib == NULL || bits == NULL) {
        releaseGdi(w);
        return 0;
    }
    w->gdi_bits = (unsigned char *)bits;
    w->mem_dc = CreateCompatibleDC(w->window_dc);
    if (w->mem_dc == NULL) {
        releaseGdi(w);
        return 0;
    }
    w->old_bitmap = SelectObject(w->mem_dc, w->gdi_dib);
    w->gdi_w = width;
    w->gdi_h = height;
    return 1;
}

/// Blit one RGBA8 frame into the window. Row 0 is the top on both sides, so the
/// copy is a straight memcpy row by row; 32bpp BI_RGB puts the bytes on screen
/// as B,G,R,A, which is the order a 32-bit DIB reads — the same order the
/// software rasterizer wrote them in.
static int gdiBlit(GlinWinWindow *w, const unsigned char *rgba, int width, int height) {
    if (rgba == NULL || width <= 0 || height <= 0) {
        return 0;
    }
    if (!ensureGdi(w, width, height)) {
        return 0;
    }
    const size_t row_bytes = (size_t)width * 4u;
    for (int y = 0; y < height; ++y) {
        memcpy(w->gdi_bits + (size_t)y * row_bytes, rgba + (size_t)y * row_bytes, row_bytes);
    }
    if (BitBlt(w->window_dc, 0, 0, width, height, w->mem_dc, 0, 0, SRCCOPY) == 0) {
        return 0;
    }
    // NO InvalidateRect/UpdateWindow here. This function is called from inside
    // glin_win_present(), which the WM_PAINT handler calls, and UpdateWindow
    // dispatches WM_PAINT SYNCHRONOUSLY — so re-invalidating here re-enters this
    // whole path, which re-invalidates again, and the process spins in unbounded
    // recursion instead of ever returning to the message loop. Blitting to the
    // window's DC between BeginPaint and EndPaint is already the correct GDI
    // way to paint; nothing else is needed.
    return 1;
}

/// Permanently give up on Direct3D and take over with GDI. Safe to call more
/// than once; the message is printed only the first time.
static void degradeToGdi(GlinWinWindow *w, const char *why) {
    if (w->gdi) {
        return;
    }
    w->gdi = 1;
    releaseD3D(w);
    fprintf(stderr,
            "glinlandui: %s; abandoning the D3D11 device and presenting with GDI "
            "instead (the window still works, composited by the CPU)\n",
            why);
}

// ---------------------------------------------------------------------------
// Win32 plumbing
// ---------------------------------------------------------------------------

static void emitPointer(GlinWinWindow *w, int kind, int button, int x, int y,
                        int pressed) {
    if (w->on_pointer == NULL) {
        return;
    }
    w->on_pointer(w->user, kind, button, (double)x, (double)y, pressed);
}

/// Map one of the four Win32 button messages to the shim's button numbering.
/// XBUTTON1 is the extra button under the right-hand pair, so it maps to
/// "right" and XBUTTON2 to "middle" — that keeps the numbering identical to
/// NSEvent.buttonNumber, so one ABI serves both shims and the host needs no
/// per-platform knowledge.
static int buttonFor(UINT msg, WPARAM wp) {
    if (msg == WM_RBUTTONDOWN || msg == WM_RBUTTONUP) {
        return GLIN_BTN_RIGHT;
    }
    if (msg == WM_MBUTTONDOWN || msg == WM_MBUTTONUP) {
        return GLIN_BTN_MIDDLE;
    }
    if (msg == WM_XBUTTONDOWN || msg == WM_XBUTTONUP) {
        return ((unsigned short)LOWORD(wp) == XBUTTON1) ? GLIN_BTN_RIGHT
                                                       : GLIN_BTN_MIDDLE;
    }
    return GLIN_BTN_LEFT;
}

static LRESULT CALLBACK wndProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    GlinWinWindow *w = (GlinWinWindow *)GetWindowLongPtrW(hwnd, GWLP_USERDATA);
    if (w == NULL) {
        // WM_NCCREATE and WM_CREATE land here: the user-data pointer is not
        // attached until CreateWindowExW returns.
        return DefWindowProcW(hwnd, msg, wp, lp);
    }

    switch (msg) {
    case WM_SIZE: {
        int width = (int)(short)LOWORD(lp);
        int height = (int)(short)HIWORD(lp);
        if (w->on_resize != NULL) {
            // A minimised window reports 0x0. The host ignores that, and so
            // must the swap chain, or ResizeBuffers below gets a degenerate
            // size and every later Present fails.
            w->on_resize(w->user, width, height);
        }
        if (w->back_rtv != NULL) {
            ID3D11DeviceContext_OMSetRenderTargets(w->context, 0, NULL, NULL);
            ID3D11RenderTargetView_Release(w->back_rtv);
            w->back_rtv = NULL;
        }
        if (w->swap_chain != NULL && width > 0 && height > 0) {
            IDXGISwapChain_ResizeBuffers(w->swap_chain, 0, (UINT)width, (UINT)height,
                                         DXGI_FORMAT_UNKNOWN, 0);
        }
        glin_win_invalidate(w);
        return 0;
    }

    case WM_GETMINMAXINFO: {
        MINMAXINFO *mmi = (MINMAXINFO *)lp;
        if (w->min_w > 0) {
            mmi->ptMinTrackSize.x = (LONG)w->min_w;
        }
        if (w->min_h > 0) {
            mmi->ptMinTrackSize.y = (LONG)w->min_h;
        }
        return 0;
    }

    case WM_ERASEBKGND:
        // Returning 1 without painting is the documented way to say "I will
        // paint this myself": it stops the window flickering white between
        // the erase and the first D3D11 present.
        return 1;

    case WM_PAINT: {
        PAINTSTRUCT ps;
        BeginPaint(hwnd, &ps);
        w->presented = 0;
        if (w->on_frame != NULL) {
            // The host renders and calls glin_win_present() from inside this.
            w->on_frame(w->user);
        }
        if (!w->presented) {
            // Nothing was handed to us. On D3D11 that means clearing; on GDI it
            // means there is no DIB to paint and the window simply keeps
            // whatever it last showed.
            if (w->context != NULL) {
                if (w->back_rtv == NULL) {
                    ensureBackBufferView(w);
                }
                clearOnly(w->context, w->back_rtv);
                if (w->swap_chain != NULL) {
                    IDXGISwapChain_Present(w->swap_chain, 0, 0);
                }
            }
        }
        EndPaint(hwnd, &ps);
        return 0;
    }

    case WM_MOUSEMOVE: {
        // lParam packs the client coordinates in its low and high words. The
        // origin is already TOP-LEFT, which is the toolkit's convention, so
        // there is nothing to flip here — see windows/adapter.zig, which exists
        // to pin exactly that difference from AppKit.
        int held = (wp & MK_LBUTTON) ? 1 : 0;
        emitPointer(w, GLIN_PTR_MOTION, GLIN_BTN_LEFT, (int)(short)LOWORD(lp),
                    (int)(short)HIWORD(lp), held);
        return 0;
    }

    case WM_LBUTTONDOWN:
    case WM_RBUTTONDOWN:
    case WM_MBUTTONDOWN:
    case WM_XBUTTONDOWN: {
        int button = buttonFor(msg, wp);
        // Without the capture, a drag that leaves the window stops delivering
        // motion and a release outside the window is lost entirely — which
        // leaves the toolkit's press state stuck down forever.
        SetCapture(hwnd);
        w->captured = 1;
        emitPointer(w, GLIN_PTR_DOWN, button, (int)(short)LOWORD(lp),
                    (int)(short)HIWORD(lp), 1);
        return 0;
    }

    case WM_LBUTTONUP:
    case WM_RBUTTONUP:
    case WM_MBUTTONUP:
    case WM_XBUTTONUP: {
        int button = buttonFor(msg, wp);
        if (w->captured) {
            ReleaseCapture();
            w->captured = 0;
        }
        emitPointer(w, GLIN_PTR_UP, button, (int)(short)LOWORD(lp),
                    (int)(short)HIWORD(lp), 0);
        return 0;
    }

    case WM_CAPTURECHANGED:
        // Something else took the capture (an alt-tab, a modal dialog). Forget
        // it rather than leaving ReleaseCapture aimed at another window.
        w->captured = 0;
        return 0;

    case WM_MOUSEWHEEL: {
        // The wheel delta lives in the high word of wParam, sign-extended as
        // 16 bits. Positive is "rotated away from the user", i.e. scroll UP,
        // which is the opposite of the toolkit's convention — so the sign is
        // flipped here and the host only has to clamp.
        double dy = -(double)(short)HIWORD(wp) / (double)GLIN_WHEEL_DELTA;
        if (w->on_scroll != NULL) {
            w->on_scroll(w->user, 0.0, dy);
        }
        return 0;
    }

    case WM_MOUSEHWHEEL: {
        double dx = (double)(short)HIWORD(wp) / (double)GLIN_WHEEL_DELTA;
        if (w->on_scroll != NULL) {
            w->on_scroll(w->user, dx, 0.0);
        }
        return 0;
    }

    case WM_KEYDOWN:
    case WM_SYSKEYDOWN:
    case WM_KEYUP:
    case WM_SYSKEYUP: {
        if (w->on_key != NULL) {
            int pressed = (msg == WM_KEYDOWN || msg == WM_SYSKEYDOWN) ? 1 : 0;
            w->on_key(w->user, (int)wp, pressed);
        }
        // WM_CHAR is deliberately NOT forwarded: the toolkit derives characters
        // from evdev codes through components.input.keyChar, and forwarding
        // both would type every key twice.
        return 0;
    }

    case WM_CLOSE: {
        if (w->on_close != NULL) {
            w->on_close(w->user);
        }
        w->quit = 1;
        DestroyWindow(hwnd);
        return 0;
    }

    case WM_DESTROY:
        PostQuitMessage(0);
        return 0;

    default:
        break;
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
}

GlinWinWindow *glin_win_window_create(const char *title, int w, int h, int min_w,
                                      int min_h) {
    if (w <= 0 || h <= 0) {
        return NULL;
    }
    // A toolkit that never asks for DPI awareness gets a blurry, mis-sized
    // window on a 125%/150% display. Best-effort: it fails harmlessly when
    // the process (or its manifest) already decided.
    SetProcessDPIAware();

    WNDCLASSEXW wc;
    memset(&wc, 0, sizeof(wc));
    wc.cbSize = sizeof(wc);
    wc.style = CS_HREDRAW | CS_VREDRAW | CS_DBLCLKS;
    wc.lpfnWndProc = wndProc;
    wc.hInstance = GetModuleHandleW(NULL);
    // IDC_ARROW is MAKEINTRESOURCE, and MakeIntResource yields the same
    // low-valued pointer in the ANSI and Unicode forms — the cast is a
    // formality, needed only because this file compiles as C.
    wc.hCursor = LoadCursorW(NULL, (LPCWSTR)IDC_ARROW);
    wc.hbrBackground = NULL;
    wc.lpszClassName = kGlinWindowClass;
    // Tolerate ERROR_CLASS_ALREADY_EXISTS: two windows in one process (the
    // demo plus a test) must not stop the second one from opening.
    if (RegisterClassExW(&wc) == 0 && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) {
        return NULL;
    }

    GlinWinWindow *win = (GlinWinWindow *)calloc(1, sizeof(GlinWinWindow));
    if (win == NULL) {
        return NULL;
    }
    win->min_w = min_w;
    win->min_h = min_h;
    win->adapter_name = "none";
    win->tex_w = (UINT)w;
    win->tex_h = (UINT)h;

    // Centre on the primary monitor's work area, so a window is never created
    // off-screen on a multi-monitor setup.
    int x = CW_USEDEFAULT;
    int y = CW_USEDEFAULT;
    RECT area;
    if (SystemParametersInfoW(SPI_GETWORKAREA, 0, &area, 0)) {
        x = area.left + ((area.right - area.left) - w) / 2;
        y = area.top + ((area.bottom - area.top) - h) / 2;
    }

    HWND hwnd = CreateWindowExW(0, kGlinWindowClass, kGlinWindowTitle,
                                WS_OVERLAPPEDWINDOW, x, y, w, h, NULL, NULL, wc.hInstance,
                                NULL);
    if (hwnd == NULL) {
        free(win);
        return NULL;
    }
    win->hwnd = hwnd;
    SetWindowLongPtrW(hwnd, GWLP_USERDATA, (LONG_PTR)win);

    // The title is applied after the handle exists because the window has to
    // carry SOMETHING for WM_NCCREATE. The config title is already a
    // NUL-terminated UTF-8 string, and UTF-8 is what this call converts from.
    if (title != NULL && title[0] != '\0') {
        int n = MultiByteToWideChar(CP_UTF8, 0, title, -1, NULL, 0);
        if (n > 1) {
            wchar_t *wide = (wchar_t *)calloc((size_t)n, sizeof(wchar_t));
            if (wide != NULL) {
                MultiByteToWideChar(CP_UTF8, 0, title, -1, wide, n);
                SetWindowTextW(hwnd, wide);
                free(wide);
            }
        }
    }

    // A D3D11 failure is NOT a window failure. The window still opens, the app
    // still runs, and glin_win_adapter_name() reports "none" so the host can
    // say so out loud instead of leaving the user with a black rectangle.
    (void)createDeviceForWindow(win);
    if (win->device != NULL) {
        if (!createPipeline(win) || !ensureFrameTexture(win, w, h) ||
            !ensureBackBufferView(win)) {
            releaseD3D(win);
        }
    }

    ShowWindow(hwnd, SW_SHOW);
    // Invalidate, do NOT UpdateWindow. The two are not interchangeable here:
    //
    //   - UpdateWindow dispatches WM_PAINT SYNCHRONOUSLY, i.e. right now, in
    //     the middle of create. glin_win_window_run() has not been given the
    //     frame cap yet, so that frame could never count towards it and a
    //     capped run never terminated.
    //   - Leaving the window un-invalidated means NO WM_PAINT is ever posted,
    //     the message loop blocks in GetMessage, and the window stays blank.
    //
    // InvalidateRect posts the paint, so the loop dispatches it — and the loop
    // has the frame cap by then.
    InvalidateRect(hwnd, NULL, TRUE);
    return win;
}

void glin_win_window_destroy(GlinWinWindow *win) {
    if (win == NULL) {
        return;
    }
    if (win->captured) {
        ReleaseCapture();
        win->captured = 0;
    }
    releaseGdi(win);
    releaseD3D(win);
    if (win->hwnd != NULL) {
        SetWindowLongPtrW(win->hwnd, GWLP_USERDATA, 0);
        DestroyWindow(win->hwnd);
        win->hwnd = NULL;
    }
    free(win);
}

void glin_win_window_set_callbacks(GlinWinWindow *win, GlinWinOnFrame on_frame,
                                   GlinWinOnPointer on_pointer, GlinWinOnScroll on_scroll,
                                   GlinWinOnKey on_key, GlinWinOnResize on_resize,
                                   GlinWinOnClose on_close, void *user) {
    if (win == NULL) {
        return;
    }
    win->on_frame = on_frame;
    win->on_pointer = on_pointer;
    win->on_scroll = on_scroll;
    win->on_key = on_key;
    win->on_resize = on_resize;
    win->on_close = on_close;
    win->user = user;
}

void glin_win_invalidate(GlinWinWindow *win) {
    if (win == NULL || win->hwnd == NULL) {
        return;
    }
    // InvalidateRect alone is not enough: without a matching UpdateWindow the
    // WM_PAINT is deferred until the message queue is idle, and a queue that
    // never goes idle (a drag, a live resize) never paints at all.
    InvalidateRect(win->hwnd, NULL, FALSE);
    UpdateWindow(win->hwnd);
}

void glin_win_quit(GlinWinWindow *win) {
    if (win == NULL) {
        return;
    }
    win->quit = 1;
    // Unblock a GetMessage that is already waiting.
    PostQuitMessage(0);
}

void glin_win_window_run(GlinWinWindow *win, int max_frames) {
    if (win == NULL || win->hwnd == NULL) {
        return;
    }
    win->max_frames = max_frames;
    MSG msg;
    while (!win->quit && GetMessageW(&msg, NULL, 0, 0) > 0) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
}

void glin_win_present(GlinWinWindow *win, const unsigned char *rgba, int w, int h) {
    if (win == NULL) {
        return;
    }
    // Set even on every early return below: the paint handler uses this to
    // tell "the host composited this paint" from "the host did nothing", and a
    // no-GPU host that still counts as composited must not be double-cleared.
    win->presented = 1;
    if (rgba == NULL || w <= 0 || h <= 0) {
        return;
    }
    if (win->gdi) {
        // GDI has already taken over. Blit and count the frame so the cap can
        // still terminate the run.
        (void)gdiBlit(win, rgba, w, h);
        win->frames += 1;
        if (win->max_frames > 0 && win->frames >= win->max_frames) {
            glin_win_quit(win);
        }
        return;
    }
    if (win->swap_chain == NULL) {
        // No device at all (created with none available, or the host has
        // already reported one unusable). Go straight to GDI rather than
        // leaving the window blank.
        degradeToGdi(win, "no D3D11 swap chain was created");
        (void)gdiBlit(win, rgba, w, h);
        win->frames += 1;
        return;
    }
    if (win->back_rtv == NULL && !ensureBackBufferView(win)) {
        return;
    }
    if (!ensureFrameTexture(win, w, h)) {
        return;
    }
    uploadSurface(win, rgba, w, h);

    DXGI_SWAP_CHAIN_DESC desc;
    memset(&desc, 0, sizeof(desc));
    IDXGISwapChain_GetDesc(win->swap_chain, &desc);
    drawQuad(win->context, win->back_rtv, win->vs, win->ps, win->frame_srv, win->sampler,
             desc.BufferDesc.Width, desc.BufferDesc.Height);

    // Sync interval 0 — NOT 1. A vsync wait blocks on `Present` until the
    // display signals a refresh, and a machine with no display source (a
    // service session, a container, a VM with no active output) never signals
    // one, so a sync-interval-1 Present hangs the message loop forever with a
    // perfectly laid-out frame sitting in a texture. A redraw-on-demand GUI has
    // no frame pacing to protect anyway: it draws when something changed, not
    // sixty times a second, so there is nothing to tear.
    HRESULT hr = IDXGISwapChain_Present(win->swap_chain, 0, 0);
    if (FAILED(hr)) {
        // A failed Present is a LOST DEVICE, not a bug: it is what a driver
        // reset, a TDR, or a GPU that cannot actually execute a shader looks
        // like. The window is already open and the frame is already laid out,
        // so the only unacceptable response is to go blank — hand the same
        // bytes to GDI instead and carry on. The frame is still counted, so the
        // frame cap can terminate a capped run.
        char why[160];
        snprintf(why, sizeof(why), "D3D11 Present failed (hr=0x%08lx)", (unsigned long)hr);
        degradeToGdi(win, why);
        (void)gdiBlit(win, rgba, w, h);
        win->frames += 1;
        if (win->max_frames > 0 && win->frames >= win->max_frames) {
            glin_win_quit(win);
        }
        return;
    }
    win->frames += 1;
    // The frame cap is enforced HERE rather than in the message loop, because
    // this is the only place that knows a frame actually reached the screen —
    // a loop-side counter would stop on a paint that produced nothing.
    if (win->max_frames > 0 && win->frames >= win->max_frames) {
        glin_win_quit(win);
    }
}

void glin_win_content_size(GlinWinWindow *win, int *out_w, int *out_h) {
    if (out_w != NULL) {
        *out_w = 0;
    }
    if (out_h != NULL) {
        *out_h = 0;
    }
    if (win == NULL || win->hwnd == NULL) {
        return;
    }
    RECT rc;
    if (!GetClientRect(win->hwnd, &rc)) {
        return;
    }
    if (out_w != NULL) {
        *out_w = (int)(rc.right - rc.left);
    }
    if (out_h != NULL) {
        *out_h = (int)(rc.bottom - rc.top);
    }
}

int glin_win_d3d11_active(GlinWinWindow *win) {
    // A device that failed a Present is reported as inactive even though the
    // swap chain object still exists, so the host can fall back and SAY SO
    // rather than claiming a GPU path it no longer has.
    return (win != NULL && win->swap_chain != NULL && !win->device_failed) ? 1 : 0;
}

const char *glin_win_adapter_name(GlinWinWindow *win) {
    return win != NULL ? win->adapter_name : "none";
}

const char *glin_win_present_mode(GlinWinWindow *win) {
    if (win == NULL) {
        return "none";
    }
    return win->gdi ? "gdi" : "d3d11";
}

int glin_win_presented_frames(GlinWinWindow *win) {
    return win != NULL ? win->frames : 0;
}

// ---------------------------------------------------------------------------
// The headless colour probe.
//
// This is the Windows answer to the question ci/check_macos_colors.c asks on
// macOS: "is the colour that comes OUT of the API the colour that went IN?".
// It creates its own D3D11 device (hardware, else WARP), runs the very same
// shader, sampler and drawQuad the window runs, into an offscreen target
// created in the same format as the swap chain, and reads the result back.
//
// Deliberately NOT a reimplementation: it calls createPipeline() and
// drawQuad() above, so a change to the shader or the format cannot drift away
// from what the window actually does. That is the only reason to trust it.
//
// Return codes are per-step so a caller can say WHICH link broke:
//   -1 bad arguments   -2 no D3D11 device   -3 pipeline   -4 frame texture
//   -5 target texture  -6 target view       -7 readback   -8 map
// ---------------------------------------------------------------------------

int glin_win_probe_color(const unsigned char *rgba, int w, int h, unsigned char *out,
                         int out_stride) {
    if (rgba == NULL || out == NULL || w <= 0 || h <= 0 || out_stride < w * 4) {
        return -1;
    }

    GlinWinWindow tmp;
    memset(&tmp, 0, sizeof(tmp));
    tmp.adapter_name = "none";

    ID3D11Device *device = NULL;
    ID3D11DeviceContext *context = NULL;
    D3D_FEATURE_LEVEL got = D3D_FEATURE_LEVEL_11_0;
    // WARP first, and deliberately: this probe runs a full draw, and a
    // hardware adapter that is present but not actually able to rasterize
    // (a VM, a remote session, a driver that has half-initialised) answers
    // DXGI_ERROR_DEVICE_HUNG on the first real draw. WARP is Microsoft's own
    // software rasterizer, it implements the identical feature levels and
    // shader model, and it cannot half-work — so the probe measures the
    // PRESENT PATH, which is what it is for, rather than the health of
    // whatever GPU the build machine happens to have.
    HRESULT hr = D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_WARP, NULL, 0, NULL, 0,
                                   D3D11_SDK_VERSION, &device, &got, &context);
    if (FAILED(hr) || device == NULL || context == NULL) {
        if (device != NULL) {
            ID3D11Device_Release(device);
        }
        if (context != NULL) {
            ID3D11DeviceContext_Release(context);
        }
        device = NULL;
        context = NULL;
        hr = D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, NULL, 0,
                               D3D11_SDK_VERSION, &device, &got, &context);
    }
    if (FAILED(hr) || device == NULL || context == NULL) {
        if (device != NULL) {
            ID3D11Device_Release(device);
        }
        if (context != NULL) {
            ID3D11DeviceContext_Release(context);
        }
        return -2;
    }
    tmp.device = device;
    tmp.context = context;

    D3D11_TEXTURE2D_DESC rt_desc;
    D3D11_TEXTURE2D_DESC read_desc;
    memset(&rt_desc, 0, sizeof(rt_desc));
    rt_desc.Width = (UINT)w;
    rt_desc.Height = (UINT)h;
    rt_desc.MipLevels = 1;
    rt_desc.ArraySize = 1;
    rt_desc.Format = GLIN_DXGI_FORMAT; // the SAME format as the swap chain
    rt_desc.SampleDesc.Count = 1;
    rt_desc.Usage = D3D11_USAGE_DEFAULT;
    rt_desc.BindFlags = D3D11_BIND_RENDER_TARGET;
    read_desc = rt_desc;
    read_desc.Usage = D3D11_USAGE_STAGING;
    read_desc.BindFlags = 0;
    read_desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;

    ID3D11Texture2D *rt = NULL;
    ID3D11Texture2D *readback = NULL;
    ID3D11RenderTargetView *rtv = NULL;
    int rc;

    if (!createPipeline(&tmp)) {
        rc = -3;
    } else if (!ensureFrameTexture(&tmp, w, h)) {
        rc = -4;
    } else if (FAILED(ID3D11Device_CreateTexture2D(device, &rt_desc, NULL, &rt))) {
        rc = -5;
    } else if (FAILED(
                   ID3D11Device_CreateRenderTargetView(device, GLIN_RES(rt), NULL, &rtv))) {
        rc = -6;
    } else if (FAILED(
                   ID3D11Device_CreateTexture2D(device, &read_desc, NULL, &readback))) {
        rc = -7;
    } else {
        uploadSurface(&tmp, rgba, w, h);
        drawQuad(context, rtv, tmp.vs, tmp.ps, tmp.frame_srv, tmp.sampler, (UINT)w,
                 (UINT)h);
        // Unbind before the copy. `rt` is still the active render target and
        // frame_srv is still on the pixel shader; CopyResource across a still-
        // bound resource is the case that ends in DXGI_ERROR_DEVICE_HUNG.
        ID3D11DeviceContext_OMSetRenderTargets(context, 0, NULL, NULL);
        ID3D11DeviceContext_PSSetShaderResources(context, 0, 0, NULL);
        ID3D11DeviceContext_CopyResource(context, GLIN_RES(readback), GLIN_RES(rt));

        D3D11_MAPPED_SUBRESOURCE mapped;
        memset(&mapped, 0, sizeof(mapped));
        HRESULT map_hr = ID3D11DeviceContext_Map(context, GLIN_RES(readback), 0,
                                                 D3D11_MAP_READ, 0, &mapped);
        if (SUCCEEDED(map_hr)) {
            for (int y = 0; y < h; ++y) {
                memcpy(out + (size_t)y * (size_t)out_stride,
                       (const unsigned char *)mapped.pData +
                           (size_t)y * (size_t)mapped.RowPitch,
                       (size_t)w * 4u);
            }
            ID3D11DeviceContext_Unmap(context, GLIN_RES(readback), 0);
            rc = 0;
        } else {
            fprintf(stderr, "glinlandui: d3d11 probe: Map(readback) failed (hr=0x%08lx)\n",
                    (unsigned long)map_hr);
            rc = -8;
        }
    }

    if (rc != 0) {
        fprintf(stderr, "glinlandui: d3d11 colour probe failed at step %d\n", rc);
    }
    if (readback != NULL) {
        ID3D11Texture2D_Release(readback);
    }
    if (rtv != NULL) {
        ID3D11RenderTargetView_Release(rtv);
    }
    if (rt != NULL) {
        ID3D11Texture2D_Release(rt);
    }
    releaseFrameTexture(&tmp);
    releasePipeline(&tmp);
    ID3D11DeviceContext_Release(context);
    ID3D11Device_Release(device);
    return rc;
}
