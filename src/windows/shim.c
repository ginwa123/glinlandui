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

// The file dialog's half: IFileDialog, COMDLG_FILTERSPEC and the shell item
// namespace. It comes after <windows.h> because shobjidl.h needs the base
// types, and it needs COBJMACROS above to get the method macros rather than
// the vtable layout.
#include <shobjidl.h>

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
    // The per-frame upload target: DEFAULT usage, because uploadSurface uses
    // UpdateSubresource (Map/Unmap is the DYNAMIC pair, not this one).
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
    // DEFAULT, not DYNAMIC: `uploadSurface` uses UpdateSubresource, whose
    // documented pair is a DEFAULT resource. DYNAMIC means Map/Unmap, and
    // UpdateSubresource on a DYNAMIC texture is invalid usage that the debug
    // layer rejects and a strict driver is entitled to punish.
    td.Usage = D3D11_USAGE_DEFAULT;
    td.BindFlags = D3D11_BIND_SHADER_RESOURCE;
    td.CPUAccessFlags = 0;
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

    // LOAD-BEARING: the input assembler's topology defaults to UNDEFINED, and a
    // Draw() with no topology removes the device on the Basic Render Driver /
    // WARP (Present then reports DXGI_ERROR_DEVICE_REMOVED, 0x887A0005), which
    // is exactly the "D3D11 Present failed" fallback to GDI. Every draw sets it.
    ID3D11DeviceContext_IASetPrimitiveTopology(ctx, D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);

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

// Declared here because a pointer event and WM_SIZE both report DEVICE pixels, and the definitions live with the DPI code.
static int glin_win_logical(GlinWinWindow *win, int device_pixels);
static double glin_win_logical_f(GlinWinWindow *win, double device_pixels);

// lParam carries DEVICE pixels while the toolkit lays out in LOGICAL units (see glin_win_content_size), so a pointer must cross the same divider or every hit test sits a scale factor away from the widget under the cursor.
static void emitPointer(GlinWinWindow *w, int kind, int button, int x, int y,
                        int pressed) {
    if (w->on_pointer == NULL) {
        return;
    }
    w->on_pointer(w->user, kind, button, glin_win_logical_f(w, (double)x),
                  glin_win_logical_f(w, (double)y), pressed);
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
            // The swap chain below stays in device pixels; the toolkit lays out in logical units.
            w->on_resize(w->user, glin_win_logical(w, width), glin_win_logical(w, height));
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

    // `w`/`h` are CLIENT pixels, which is the space the toolkit lays out in: the
    // frame is added AROUND them instead of being eaten out of them. Before
    // this, a 960x760 request produced an 804x581 client, so the surface and the
    // window agreed only by accident.
    RECT outer_rect;
    outer_rect.left = 0;
    outer_rect.top = 0;
    outer_rect.right = (LONG)w;
    outer_rect.bottom = (LONG)h;
    AdjustWindowRect(&outer_rect, WS_OVERLAPPEDWINDOW, FALSE);
    int outer_w = (int)(outer_rect.right - outer_rect.left);
    int outer_h = (int)(outer_rect.bottom - outer_rect.top);

    // Centre on the primary monitor's work area, and never place the window off
    // it: a request bigger than the desktop used to be centred on the REQUESTED
    // size, which put the title bar at a negative coordinate on a small screen.
    int x = CW_USEDEFAULT;
    int y = CW_USEDEFAULT;
    RECT area;
    if (SystemParametersInfoW(SPI_GETWORKAREA, 0, &area, 0)) {
        const int area_w = (int)(area.right - area.left);
        const int area_h = (int)(area.bottom - area.top);
        // Shave the CLIENT by the frame before clamping: the frame is part of the
        // window, so a client that filled the work area would push the window off
        // it. `core/window_contract.fitToWorkArea` fits the client to the area;
        // this is the frame's share of that budget.
        if (outer_w > area_w) {
            w -= (outer_w - area_w);
            outer_w = area_w;
        }
        if (outer_h > area_h) {
            h -= (outer_h - area_h);
            outer_h = area_h;
        }
        if (w < 1) {
            w = 1;
        }
        if (h < 1) {
            h = 1;
        }
        x = (int)area.left + (area_w - outer_w) / 2;
        y = (int)area.top + (area_h - outer_h) / 2;
        if (x < (int)area.left) {
            x = (int)area.left;
        }
        if (y < (int)area.top) {
            y = (int)area.top;
        }
    }
    // After the fit, so the upload target and the first swap-chain buffer are the
    // size the client actually ends up.
    win->tex_w = (UINT)w;
    win->tex_h = (UINT)h;

    HWND hwnd = CreateWindowExW(0, kGlinWindowClass, kGlinWindowTitle,
                                WS_OVERLAPPEDWINDOW, x, y, outer_w, outer_h, NULL, NULL,
                                wc.hInstance, NULL);
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
    if (max_frames > 0) {
        // A capped run drives its own frames. A toolkit window repaints only
        // when something invalidates it, so after the first WM_PAINT a loop
        // that waits in GetMessage has nothing to wake it and never reaches
        // the cap — `QS_SETTINGS_TEST_FRAMES=3` hung forever that way.
        while (!win->quit && win->frames < max_frames) {
            while (!win->quit && PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE) != 0) {
                if (msg.message == WM_QUIT) {
                    return;
                }
                TranslateMessage(&msg);
                DispatchMessageW(&msg);
            }
            if (win->quit || win->frames >= max_frames) {
                break;
            }
            // UpdateWindow inside makes this one frame happen synchronously.
            glin_win_invalidate(win);
        }
        return;
    }
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
        char why[192];
        // The device-removed reason is what separates "this driver cannot do
        // it" from "we asked it to do something invalid"; without it both
        // report the same generic 0x887A0005.
        snprintf(why, sizeof(why), "D3D11 Present failed (hr=0x%08lx, removed reason 0x%08lx)",
                 (unsigned long)hr,
                 (unsigned long)ID3D11Device_GetDeviceRemovedReason(win->device));
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

void glin_win_work_area(int *out_w, int *out_h) {
    if (out_w != NULL) {
        *out_w = 0;
    }
    if (out_h != NULL) {
        *out_h = 0;
    }
    RECT area;
    if (!SystemParametersInfoW(SPI_GETWORKAREA, 0, &area, 0)) {
        return;
    }
    // LOGICAL units, the same ones glin_win_content_size and WindowConfig use, so
    // a fit decision compares like with like on a scaled display.
    double scale = 1.0;
    HDC dc = GetDC(NULL);
    if (dc != NULL) {
        int dpi = GetDeviceCaps(dc, LOGPIXELSX);
        ReleaseDC(NULL, dc);
        if (dpi > 0) {
            scale = (double)dpi / 96.0;
        }
    }
    if (out_w != NULL) {
        *out_w = (int)((double)(area.right - area.left) / scale + 0.5);
    }
    if (out_h != NULL) {
        *out_h = (int)((double)(area.bottom - area.top) / scale + 0.5);
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
        *out_w = glin_win_logical(win, (int)(rc.right - rc.left));
    }
    if (out_h != NULL) {
        *out_h = glin_win_logical(win, (int)(rc.bottom - rc.top));
    }
}

double glin_win_scale(GlinWinWindow *win) {
    if (win == NULL || win->hwnd == NULL) {
        return 1.0;
    }
    // GetDpiForWindow is Windows 10 1607+; resolving it dynamically keeps the
    // build free of an SDK-version import while still using the per-window value.
    HMODULE user32 = GetModuleHandleW(L"user32.dll");
    if (user32 != NULL) {
        typedef UINT(WINAPI * GlinGetDpiForWindow)(HWND);
        GlinGetDpiForWindow fn = (GlinGetDpiForWindow)(void *)GetProcAddress(user32, "GetDpiForWindow");
        if (fn != NULL) {
            UINT dpi = fn(win->hwnd);
            if (dpi > 0) {
                return (double)dpi / 96.0;
            }
        }
    }
    HDC dc = GetDC(win->hwnd);
    if (dc == NULL) {
        return 1.0;
    }
    int dpi = GetDeviceCaps(dc, LOGPIXELSX);
    ReleaseDC(win->hwnd, dc);
    return (dpi > 0) ? (double)dpi / 96.0 : 1.0;
}

// Device pixels to logical units, so the toolkit's layout never depends on the display density.
static int glin_win_logical(GlinWinWindow *win, int device_pixels) {
    double s = glin_win_scale(win);
    if (s <= 0.0) {
        return device_pixels;
    }
    return (int)((double)device_pixels / s + 0.5);
}

// The same divider with no rounding, for a coordinate rather than a size: a pointer exactly on a widget's edge must stay inside it.
static double glin_win_logical_f(GlinWinWindow *win, double device_pixels) {
    double s = glin_win_scale(win);
    if (s <= 0.0) {
        return device_pixels;
    }
    return device_pixels / s;
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
    // Device selection MIRRORS createDeviceForWindow(): hardware first, WARP
    // second. That symmetry is the entire point of this probe — a check that
    // exercised a different adapter than the window would be measuring
    // something else. (An earlier version put WARP first, on the theory that
    // a software rasterizer is the more predictable target. It is the LESS
    // representative one, and it also made the probe skip on a hosted runner
    // whose hardware device works fine.)
    HRESULT hr = D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, NULL, 0,
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
        hr = D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_WARP, NULL, 0, NULL, 0,
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


/// Wide string -> UTF-8, into a fresh malloc. NULL on failure.
///
/// The caller frees it. Returns NULL rather than a partial string because a
/// half-converted path is a path to a different file.
static char *GlinWideToUtf8(const WCHAR *wide) {
    if (!wide) return NULL;
    int need = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, wide, -1, NULL, 0,
                                   NULL, NULL);
    if (need <= 0) return NULL;
    char *out = (char *)malloc((size_t)need);
    if (!out) return NULL;
    if (WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, wide, -1, out, need, NULL,
                            NULL) <= 0) {
        free(out);
        return NULL;
    }
    return out;
}

/// UTF-8 -> wide, into a fresh malloc. NULL on failure.
static WCHAR *GlinUtf8ToWide(const char *utf8) {
    if (!utf8 || !*utf8) return NULL;
    int need = MultiByteToWideChar(CP_UTF8, 0, utf8, -1, NULL, 0);
    if (need <= 0) return NULL;
    WCHAR *out = (WCHAR *)malloc((size_t)need * sizeof(WCHAR));
    if (!out) return NULL;
    if (MultiByteToWideChar(CP_UTF8, 0, utf8, -1, out, need) <= 0) {
        free(out);
        return NULL;
    }
    return out;
}

/// Hand one selected shell item to the host as a filesystem path.
///
/// SIGDN_FILESYSPATH, not SIGDN_NORMALDISPLAY: the display name is what the
/// dialog SHOWS, and for a virtual item (a OneDrive placeholder, a zip entry)
/// it is a short name that is not a path at all.
static void GlinDeliverItem(IShellItem *item, GlinWinOnPath on_path, void *user) {
    if (!item || !on_path) return;
    WCHAR *wide = NULL;
    HRESULT hr = IShellItem_GetDisplayName(item, SIGDN_FILESYSPATH, &wide);
    if (FAILED(hr) || !wide) return;
    char *utf8 = GlinWideToUtf8(wide);
    // COM allocated it, so COM frees it — CoTaskMemFree, not free(). Using
    // free() here is a heap corruption that shows up much later, in somebody
    // else's allocation.
    CoTaskMemFree(wide);
    if (!utf8) return;
    on_path(user, utf8);
    free(utf8);
}

/// Hand every item of an array to the host, then release the array.
static void GlinDeliverArray(IShellItemArray *items, GlinWinOnPath on_path, void *user) {
    if (!items) return;
    DWORD count = 0;
    if (SUCCEEDED(IShellItemArray_GetCount(items, &count))) {
        for (DWORD i = 0; i < count; i++) {
            IShellItem *item = NULL;
            if (SUCCEEDED(IShellItemArray_GetItemAt(items, i, &item)) && item) {
                GlinDeliverItem(item, on_path, user);
                IShellItem_Release(item);
            }
        }
    }
    IShellItemArray_Release(items);
}

int glin_win_file_dialog(const GlinWinFileRequest *request,
                        GlinWinOnPath on_path, void *user) {
    if (!request || !on_path) return -2;

    IFileDialog *dialog = NULL;

    // The class is the KIND: a save target is the only one that is a
    // FileSaveDialog. Everything else is an option on FileOpenDialog.
    CLSID clsid = (request->kind == 2) ? CLSID_FileSaveDialog : CLSID_FileOpenDialog;
    HRESULT hr = CoCreateInstance(&clsid, NULL, CLSCTX_INPROC_SERVER, &IID_IFileDialog,
                                  (void **)&dialog);
    if (FAILED(hr) || !dialog) return -2;

    // Get EVERYTHING through IFileOpenDialog, which the same object implements.
    //
    // This is the part of the Windows file dialog that has to be got right,
    // and it is worth saying why, because the obvious version does not work:
    // `IFileDialog` has `GetResult` — SINGULAR. There is no `GetResults` on it.
    // A dialog shown with FOS_ALLOWMULTISELECT returns an array, and the
    // interface that can produce one is `IFileOpenDialog`, which derives from
    // `IFileDialog` and adds `GetResults`. Calling `GetResult` on a
    // multi-select dialog gets the first file and silently drops the rest —
    // the worst shape a file dialog bug can take, because the user selects
    // five files and the application acts on one.
    IFileOpenDialog *as_open = NULL;
    hr = IFileDialog_QueryInterface(dialog, &IID_IFileOpenDialog, (void **)&as_open);
    if (FAILED(hr) || !as_open) {
        // No IFileOpenDialog: a single selection is still available, because
        // that is all IFileDialog itself can answer.
        as_open = NULL;
    }

    // Options, computed by the model. SetOptions rather than OR-ing by hand:
    // several of these are mutually exclusive and the model is where that is
    // stated and tested.
    IFileDialog_SetOptions(dialog, (FILEOPENDIALOGOPTIONS)request->options);

    // SetFileTypes, or not at all. An empty array installs a filter that
    // matches nothing and the dialog then refuses to open anything, so the
    // COUNT is what gates the call.
    if (request->filters && request->filter_count > 0) {
        // One wide blob for every name and spec, because COMDLG_FILTERSPEC
        // holds LPCWSTR and the array has to outlive the call.
        size_t total_wchars = 0;
        for (int i = 0; i < request->filter_count; i++) {
            const char *n = request->filters[i].name;
            const char *sp = request->filters[i].spec;
            if (n) total_wchars += (size_t)MultiByteToWideChar(CP_UTF8, 0, n, -1, NULL, 0);
            if (sp) total_wchars += (size_t)MultiByteToWideChar(CP_UTF8, 0, sp, -1, NULL, 0);
        }
        WCHAR *blob = total_wchars ? (WCHAR *)calloc(total_wchars, sizeof(WCHAR)) : NULL;
        COMDLG_FILTERSPEC *spec_array =
            (COMDLG_FILTERSPEC *)calloc((size_t)request->filter_count,
                                         sizeof(COMDLG_FILTERSPEC));
        if (blob && spec_array) {
            WCHAR *cursor = blob;
            size_t left = total_wchars;
            for (int i = 0; i < request->filter_count; i++) {
                const char *n = request->filters[i].name;
                const char *sp = request->filters[i].spec;
                if (n && *n) {
                    int wrote = MultiByteToWideChar(CP_UTF8, 0, n, -1, cursor, (int)left);
                    spec_array[i].pszName = cursor;
                    cursor += (wrote > 0) ? wrote : 0;
                    left -= (wrote > 0) ? (size_t)wrote : 0;
                } else {
                    spec_array[i].pszName = L"";
                }
                if (sp && *sp) {
                    int wrote = MultiByteToWideChar(CP_UTF8, 0, sp, -1, cursor, (int)left);
                    spec_array[i].pszSpec = cursor;
                    cursor += (wrote > 0) ? wrote : 0;
                    left -= (wrote > 0) ? (size_t)wrote : 0;
                } else {
                    spec_array[i].pszSpec = L"*";
                }
            }
            IFileDialog_SetFileTypes(dialog, (UINT)request->filter_count, spec_array);
            // 1-based, and 0 means "leave it to the platform". Passing 0 would
            // select the FIRST filter instead of no filter, which is the
            // off-by-one the model exists to prevent.
            if (request->file_type_index > 0) {
                IFileDialog_SetFileTypeIndex(dialog, request->file_type_index);
            }
        }
        free(blob);
        free(spec_array);
    }

    if (request->title && *request->title) {
        WCHAR *wide = GlinUtf8ToWide(request->title);
        if (wide) {
            IFileDialog_SetTitle(dialog, wide);
            free(wide);
        }
    }
    if (request->accept_label && *request->accept_label) {
        WCHAR *wide = GlinUtf8ToWide(request->accept_label);
        if (wide) {
            IFileDialog_SetOkButtonLabel(dialog, wide);
            free(wide);
        }
    }
    // The starting folder. SetFolder takes an IShellItem, NOT a path — the two
    // are not interchangeable, and a folder that does not resolve (an
    // unmounted share) is normal, so a failure here is ignored and the dialog
    // opens where the shell would have opened it.
    if (request->current_folder && *request->current_folder) {
        WCHAR *wide = GlinUtf8ToWide(request->current_folder);
        if (wide) {
            IShellItem *folder = NULL;
            if (SUCCEEDED(SHCreateItemFromParsingName(wide, NULL, &IID_IShellItem,
                                                      (void **)&folder)) &&
                folder) {
                IFileDialog_SetFolder(dialog, folder);
                IShellItem_Release(folder);
            }
            free(wide);
        }
    }
    // The pre-filled name, and it IS a file name this time — that is what
    // SetFileName is for. (The folder above deliberately did NOT use it: on a
    // multi-selection dialog SetFileName types the text into the box, and the
    // box is not a folder browser.)
    if (request->current_name && *request->current_name) {
        WCHAR *wide = GlinUtf8ToWide(request->current_name);
        if (wide) {
            IFileDialog_SetFileName(dialog, wide);
            free(wide);
        }
    }

    // Show() takes the owner HWND. A dialog with no owner is still modal to the
    // thread, but it is not a child of our window: it can be moved
    // independently and does not disable the window behind it, which is the
    // difference between "modal" and "modal-looking".
    HWND owner = (HWND)(uintptr_t)request->owner_hwnd;
    hr = IFileDialog_Show(dialog, owner);

    int result = 0;
    if (hr == HRESULT_FROM_WIN32(ERROR_CANCELLED)) {
        result = -1;
    } else if (FAILED(hr)) {
        result = -3;
    } else if (as_open) {
        // Every item, whether there is one or twenty.
        IShellItemArray *items = NULL;
        if (SUCCEEDED(IFileOpenDialog_GetResults(as_open, &items))) {
            GlinDeliverArray(items, on_path, user);
        } else {
            IShellItem *item = NULL;
            if (SUCCEEDED(IFileDialog_GetResult(dialog, &item)) && item) {
                GlinDeliverItem(item, on_path, user);
                IShellItem_Release(item);
            }
        }
    } else {
        // No IFileOpenDialog on this host: the single item, and nothing else.
        IShellItem *item = NULL;
        if (SUCCEEDED(IFileDialog_GetResult(dialog, &item)) && item) {
            GlinDeliverItem(item, on_path, user);
            IShellItem_Release(item);
        }
    }

    if (as_open) IFileOpenDialog_Release(as_open);
    IFileDialog_Release(dialog);
    return result;
}

// ---- Clipboard: CF_UNICODETEXT in, UTF-8 out (and back) -------------------------------------------
//
// Win32's clipboard is UTF-16 and, for anything bigger than a pointer, a HANDLE into global memory that the
// window station owns. The caller's buffer is UTF-8, so this is where the conversion happens: doing it here
// keeps the Zig side a two-line port and means a truncated read costs nothing (there is no allocation at all
// on the read path).
//
// `OpenClipboard(NULL)` fails when another process has the clipboard open. That is a normal, transient state
// during a copy, so it reads as "no text" instead of an error the app would have to explain to a user.

int glin_win_clipboard_read(char *buf, int cap) {
    if (!buf || cap <= 0) return 0;
    if (!OpenClipboard(NULL)) return 0;

    int written = 0;
    HANDLE handle = GetClipboardData(CF_UNICODETEXT);
    if (handle) {
        const wchar_t *text = (const wchar_t *)GlobalLock(handle);
        if (text) {
            // Bound the conversion by the caller's buffer in UTF-16 units: a unit is never more than 3 UTF-8
            // bytes for BMP text and a surrogate pair is 2 units for 4 bytes, so `units <= cap` always fits.
            int units = 0;
            while (text[units] != 0 && units < cap) units++;
            if (units > 0) {
                const int got = WideCharToMultiByte(CP_UTF8, 0, text, units, buf, cap, NULL, NULL);
                if (got > 0) written = got;
            }
            GlobalUnlock(handle);
        }
    }
    CloseClipboard();
    return written;
}

void glin_win_clipboard_write(const char *text_utf8, int len) {
    if (!text_utf8 || len < 0) return;

    // Two-pass: ask how many UTF-16 units the text needs, then convert into one global block that the
    // clipboard takes ownership of. `+ 1` is the terminator Win32 requires.
    const int units = MultiByteToWideChar(CP_UTF8, 0, text_utf8, len, NULL, 0);
    if (units <= 0) return;
    HGLOBAL mem = GlobalAlloc(GMEM_MOVEABLE, ((SIZE_T)units + 1) * sizeof(wchar_t));
    if (!mem) return;
    wchar_t *dst = (wchar_t *)GlobalLock(mem);
    if (!dst) {
        GlobalFree(mem);
        return;
    }
    MultiByteToWideChar(CP_UTF8, 0, text_utf8, len, dst, units);
    dst[units] = 0;
    GlobalUnlock(mem);

    if (!OpenClipboard(NULL)) {
        GlobalFree(mem);
        return;
    }
    EmptyClipboard();
    // On success the system owns `mem`; freeing it here would corrupt the clipboard.
    if (!SetClipboardData(CF_UNICODETEXT, mem)) GlobalFree(mem);
    CloseClipboard();
}

// ---------------------------------------------------------------------------
// The GPU renderer. This is the Windows counterpart of mac/metal.m: vertices
// in (already in DEVICE pixels), one Draw per segment, and the same coverage
// maths core/render_software.zig uses so the two agree pixel for pixel.
//
// Everything a frame needs is created once, here, and reused: the pipeline,
// the states, the two samplers, one growable vertex buffer, the glyph atlas
// and the image slots. The frame path only maps the vertex buffer, sets the
// constant buffer and issues the draws — no COM object is created while
// drawing, which is what keeps a D3D11 frame close to the cost of the draws
// themselves.
// ---------------------------------------------------------------------------

// One vertex. MUST stay byte-for-byte in step with `GlinVertex` in shim.h and
// with `Vertex` in src/windows/renderer.zig: 17 floats, 68 bytes, no padding.
// The fields are plain floats and the input layout below spells every offset
// out, so a compiler is never asked to agree about packing.
static const char *const kGpuVS =
    "cbuffer Frame : register(b0) { float2 res; float2 pad; };\\n"
    "struct VIn {\\n"
    "  float2 pos : POSITION;\\n"
    "  float2 uv : TEXCOORD0;\\n"
    "  float2 size : TEXCOORD1;\\n"
    "  float4 radius : TEXCOORD2;\\n"
    "  float4 color : TEXCOORD3;\\n"
    "  float mode : TEXCOORD4;\\n"
    "  float border : TEXCOORD5;\\n"
    "  float kind : TEXCOORD6;\\n"
    "};\\n"
    "struct VOut {\\n"
    "  float4 pos : SV_POSITION;\\n"
    "  float2 uv : TEXCOORD0;\\n"
    "  float2 size : TEXCOORD1;\\n"
    "  float4 radius : TEXCOORD2;\\n"
    "  float4 color : TEXCOORD3;\\n"
    "  float mode : TEXCOORD4;\\n"
    "  float border : TEXCOORD5;\\n"
    "  float kind : TEXCOORD6;\\n"
    "};\\n"
    "VOut VSMain(VIn v) {\\n"
    "  VOut o;\\n"
    // y is flipped HERE, like Metal: D3D11's NDC is y-up and the viewport's top row is +1, so a
    // top-left device position needs 1 - 2*y/h. GL negates instead; copying that inverts the UI.
    "  float2 clip = float2(v.pos.x / res.x * 2.0 - 1.0, 1.0 - v.pos.y / res.y * 2.0);\\n"
    "  o.pos = float4(clip, 0.0, 1.0);\\n"
    "  o.uv = v.uv; o.size = v.size; o.radius = v.radius; o.color = v.color;\\n"
    "  o.mode = v.mode; o.border = v.border; o.kind = v.kind;\\n"
    "  return o;\\n"
    "}\\n";

// The fragment half: sdRoundBox + cov transcribed from core/render_software.zig
// (33-88), which is the reference the parity gate compares against. Do not
// "improve" any expression here — a change that is nicer on the GPU and
// different from the CPU is a parity failure, and the CPU is the definition.
static const char *const kGpuPS =
    "Texture2D tex0 : register(t0);\\n"
    "SamplerState smp_point : register(s0);\\n"
    "SamplerState smp_linear : register(s1);\\n"
    "float sdRoundBox(float2 p, float2 b, float4 r) {\\n"
    "  float rad = (p.x < 0.0) ? (p.y < 0.0 ? r.x : r.z) : (p.y < 0.0 ? r.y : r.w);\\n"
    "  float2 q = abs(p) - b + rad;\\n"
    "  return length(max(q, float2(0.0, 0.0))) + min(max(q.x, q.y), 0.0) - rad;\\n"
    "}\\n"
    "float cov(float d) { return clamp(0.5 - d, 0.0, 1.0); }\\n"
    "struct VOut {\\n"
    "  float4 pos : SV_POSITION;\\n"
    "  float2 uv : TEXCOORD0;\\n"
    "  float2 size : TEXCOORD1;\\n"
    "  float4 radius : TEXCOORD2;\\n"
    "  float4 color : TEXCOORD3;\\n"
    "  float mode : TEXCOORD4;\\n"
    "  float border : TEXCOORD5;\\n"
    "  float kind : TEXCOORD6;\\n"
    "};\\n"
    "float4 PSMain(VOut i) : SV_Target {\\n"
    "  if (i.kind > 1.5) {\\n"
    "    float4 c = tex0.Sample(smp_linear, i.uv);\\n"
    "    if (c.a <= 0.0) discard;\\n"
    "    return c;\\n"
    "  }\\n"
    "  if (i.kind > 0.5) {\\n"
    "    float a = tex0.Sample(smp_point, i.uv).r;\\n"
    "    if (a <= 0.0) discard;\\n"
    "    return float4(i.color.rgb, i.color.a * a);\\n"
    "  }\\n"
    "  float2 c = i.size * 0.5;\\n"
    "  float2 p = i.uv - c;\\n"
    "  float m = min(c.x, c.y);\\n"
    "  float4 r = min(max(i.radius, float4(0.0, 0.0, 0.0, 0.0)), float4(m, m, m, m));\\n"
    "  float a = cov(sdRoundBox(p, c, r));\\n"
    "  if (i.mode > 0.5) {\\n"
    "    float2 ib = max(c - i.border, float2(0.0, 0.0));\\n"
    "    float mi = min(ib.x, ib.y);\\n"
    "    float4 ri = min(max(r - i.border, float4(0.0, 0.0, 0.0, 0.0)), float4(mi, mi, mi, mi));\\n"
    "    a *= (1.0 - cov(sdRoundBox(p, ib, ri)));\\n"
    "  }\\n"
    "  if (a <= 0.0) discard;\\n"
    "  return float4(i.color.rgb, i.color.a * a);\\n"
    "}\\n";

/// The vertex-input slots, by byte offset. Written out rather than derived
/// from a struct so that `GlinVertex` is the ONLY definition of the layout.
static const D3D11_INPUT_ELEMENT_DESC kGpuInput[] = {
    { "POSITION", 0, DXGI_FORMAT_R32G32_FLOAT, 0, 0, D3D11_INPUT_PER_VERTEX_DATA, 0 },
    { "TEXCOORD", 0, DXGI_FORMAT_R32G32_FLOAT, 0, 8, D3D11_INPUT_PER_VERTEX_DATA, 0 },
    { "TEXCOORD", 1, DXGI_FORMAT_R32G32_FLOAT, 0, 16, D3D11_INPUT_PER_VERTEX_DATA, 0 },
    { "TEXCOORD", 2, DXGI_FORMAT_R32G32B32A32_FLOAT, 0, 24, D3D11_INPUT_PER_VERTEX_DATA, 0 },
    { "TEXCOORD", 3, DXGI_FORMAT_R32G32B32A32_FLOAT, 0, 40, D3D11_INPUT_PER_VERTEX_DATA, 0 },
    { "TEXCOORD", 4, DXGI_FORMAT_R32_FLOAT, 0, 56, D3D11_INPUT_PER_VERTEX_DATA, 0 },
    { "TEXCOORD", 5, DXGI_FORMAT_R32_FLOAT, 0, 60, D3D11_INPUT_PER_VERTEX_DATA, 0 },
    { "TEXCOORD", 6, DXGI_FORMAT_R32_FLOAT, 0, 64, D3D11_INPUT_PER_VERTEX_DATA, 0 },
};

/// The vertex buffer never shrinks and grows by doubling: a frame that crosses
/// the current size pays one re-create, not one per frame around a boundary.
#define GLIN_GPU_VBUF_FLOOR (65536u)

struct GlinWinGpu {
    ID3D11Device *device;
    ID3D11DeviceContext *context;
    /// The window this draws into, or NULL for the offscreen (parity) path.
    GlinWinWindow *win;
    ID3D11VertexShader *vs;
    ID3D11PixelShader *ps;
    ID3D11InputLayout *input_layout;
    ID3D11Buffer *cbuf;
    ID3D11BlendState *blend;
    ID3D11RasterizerState *raster;
    ID3D11SamplerState *smp_point;
    ID3D11SamplerState *smp_linear;
    ID3D11Buffer *vbuf;
    UINT vbuf_bytes;
    ID3D11Texture2D *atlas;
    ID3D11ShaderResourceView *atlas_srv;
    UINT atlas_w;
    UINT atlas_h;
    /// 1..GLIN_MAX_IMAGES-1 are usable, exactly as the Metal backend and
    /// `glin_metal_set_image` number them; 0 always means the glyph atlas.
    ID3D11Texture2D *img_tex[GLIN_MAX_IMAGES];
    ID3D11ShaderResourceView *img_srv[GLIN_MAX_IMAGES];
    UINT img_w[GLIN_MAX_IMAGES];
    UINT img_h[GLIN_MAX_IMAGES];
    /// 1 when this object created the device itself (the offscreen path).
    int own_device;
    ID3D11Texture2D *rt;
    ID3D11RenderTargetView *rtv;
    UINT width;
    UINT height;
    int frames;
};

static void gpuReleaseImages(GlinWinGpu *g) {
    for (int i = 0; i < GLIN_MAX_IMAGES; ++i) {
        if (g->img_srv[i] != NULL) {
            ID3D11ShaderResourceView_Release(g->img_srv[i]);
            g->img_srv[i] = NULL;
        }
        if (g->img_tex[i] != NULL) {
            ID3D11Texture2D_Release(g->img_tex[i]);
            g->img_tex[i] = NULL;
        }
        g->img_w[i] = 0;
        g->img_h[i] = 0;
    }
}

static void gpuRelease(GlinWinGpu *g) {
    if (g == NULL) return;
    gpuReleaseImages(g);
    if (g->atlas_srv != NULL) ID3D11ShaderResourceView_Release(g->atlas_srv);
    if (g->atlas != NULL) ID3D11Texture2D_Release(g->atlas);
    if (g->vbuf != NULL) ID3D11Buffer_Release(g->vbuf);
    if (g->smp_point != NULL) ID3D11SamplerState_Release(g->smp_point);
    if (g->smp_linear != NULL) ID3D11SamplerState_Release(g->smp_linear);
    if (g->raster != NULL) ID3D11RasterizerState_Release(g->raster);
    if (g->blend != NULL) ID3D11BlendState_Release(g->blend);
    if (g->cbuf != NULL) ID3D11Buffer_Release(g->cbuf);
    if (g->input_layout != NULL) ID3D11InputLayout_Release(g->input_layout);
    if (g->ps != NULL) ID3D11PixelShader_Release(g->ps);
    if (g->vs != NULL) ID3D11VertexShader_Release(g->vs);
    if (g->rtv != NULL) ID3D11RenderTargetView_Release(g->rtv);
    if (g->rt != NULL) ID3D11Texture2D_Release(g->rt);
    if (g->own_device) {
        if (g->context != NULL) ID3D11DeviceContext_Release(g->context);
        if (g->device != NULL) ID3D11Device_Release(g->device);
    }
    free(g);
}

/// Build every object a frame needs. Returns 0 on success; on failure the
/// half-built object is released and nothing is left for the caller to undo.
static int gpuBuild(GlinWinGpu *g) {
    ID3D10Blob *vs_code = NULL;
    ID3D10Blob *ps_code = NULL;
    ID3D10Blob *errors = NULL;
    HRESULT hr = D3DCompile(kGpuVS, strlen(kGpuVS), "glinlandui-gpu-vs", NULL, NULL, "VSMain",
                            "vs_5_0", 0, 0, &vs_code, &errors);
    if (errors != NULL) {
        fprintf(stderr, "glinlandui: D3DCompile(VSMain) failed: %s\n",
                (const char *)ID3D10Blob_GetBufferPointer(errors));
        ID3D10Blob_Release(errors);
        errors = NULL;
    }
    if (FAILED(hr) || vs_code == NULL) return 0;
    hr = D3DCompile(kGpuPS, strlen(kGpuPS), "glinlandui-gpu-ps", NULL, NULL, "PSMain", "ps_5_0",
                    0, 0, &ps_code, &errors);
    if (errors != NULL) {
        fprintf(stderr, "glinlandui: D3DCompile(PSMain) failed: %s\n",
                (const char *)ID3D10Blob_GetBufferPointer(errors));
        ID3D10Blob_Release(errors);
        errors = NULL;
    }
    if (FAILED(hr) || ps_code == NULL) {
        ID3D10Blob_Release(vs_code);
        return 0;
    }

    hr = ID3D11Device_CreateVertexShader(g->device,
                                         ID3D10Blob_GetBufferPointer(vs_code),
                                         ID3D10Blob_GetBufferSize(vs_code), NULL, &g->vs);
    if (SUCCEEDED(hr)) {
        hr = ID3D11Device_CreatePixelShader(g->device,
                                            ID3D10Blob_GetBufferPointer(ps_code),
                                            ID3D10Blob_GetBufferSize(ps_code), NULL, &g->ps);
    }
    if (SUCCEEDED(hr)) {
        hr = ID3D11Device_CreateInputLayout(g->device, kGpuInput,
                                            (UINT)(sizeof(kGpuInput) / sizeof(kGpuInput[0])),
                                            ID3D10Blob_GetBufferPointer(vs_code),
                                            ID3D10Blob_GetBufferSize(vs_code), &g->input_layout);
    }
    ID3D10Blob_Release(vs_code);
    ID3D10Blob_Release(ps_code);
    if (FAILED(hr)) {
        fprintf(stderr, "glinlandui: d3d11 renderer: shader/layout creation failed (hr=0x%08lx)\n",
                (unsigned long)hr);
        return 0;
    }

    // 16 bytes: `res` is 8, and a constant buffer below 16 is rejected.
    D3D11_BUFFER_DESC cb;
    memset(&cb, 0, sizeof(cb));
    cb.ByteWidth = 16;
    cb.Usage = D3D11_USAGE_DEFAULT;
    cb.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
    if (FAILED(ID3D11Device_CreateBuffer(g->device, &cb, NULL, &g->cbuf))) return 0;

    // The CPU rasterizer's blend, factor for factor: straight-alpha source-over, with the destination
    // alpha kept saturated because the window is opaque.
    D3D11_BLEND_DESC bd;
    memset(&bd, 0, sizeof(bd));
    bd.RenderTarget[0].BlendEnable = TRUE;
    bd.RenderTarget[0].SrcBlend = D3D11_BLEND_SRC_ALPHA;
    bd.RenderTarget[0].DestBlend = D3D11_BLEND_INV_SRC_ALPHA;
    bd.RenderTarget[0].BlendOp = D3D11_BLEND_OP_ADD;
    bd.RenderTarget[0].SrcBlendAlpha = D3D11_BLEND_ONE;
    bd.RenderTarget[0].DestBlendAlpha = D3D11_BLEND_INV_SRC_ALPHA;
    bd.RenderTarget[0].BlendOpAlpha = D3D11_BLEND_OP_ADD;
    bd.RenderTarget[0].RenderTargetWriteMask = D3D11_COLOR_WRITE_ENABLE_ALL;
    if (FAILED(ID3D11Device_CreateBlendState(g->device, &bd, &g->blend))) return 0;

    // ScissorEnable is FALSE by default, which silently turns every scissor rect into a no-op; and
    // CullMode defaults to BACK, which would drop every quad because the y flip inverts the winding.
    D3D11_RASTERIZER_DESC rd;
    memset(&rd, 0, sizeof(rd));
    rd.FillMode = D3D11_FILL_SOLID;
    rd.CullMode = D3D11_CULL_NONE;
    rd.ScissorEnable = TRUE;
    rd.DepthClipEnable = TRUE;
    if (FAILED(ID3D11Device_CreateRasterizerState(g->device, &rd, &g->raster))) return 0;

    // Two samplers, because the shader cannot declare one: glyphs are read from the R8 atlas 1:1
    // (NEAREST), images are scaled (LINEAR). Both clamp.
    D3D11_SAMPLER_DESC sd;
    memset(&sd, 0, sizeof(sd));
    sd.AddressU = D3D11_TEXTURE_ADDRESS_CLAMP;
    sd.AddressV = D3D11_TEXTURE_ADDRESS_CLAMP;
    sd.AddressW = D3D11_TEXTURE_ADDRESS_CLAMP;
    sd.ComparisonFunc = D3D11_COMPARISON_NEVER;
    sd.Filter = D3D11_FILTER_MIN_MAG_MIP_POINT;
    sd.MaxLOD = D3D11_FLOAT32_MAX;
    if (FAILED(ID3D11Device_CreateSamplerState(g->device, &sd, &g->smp_point))) return 0;
    sd.Filter = D3D11_FILTER_MIN_MAG_MIP_LINEAR;
    if (FAILED(ID3D11Device_CreateSamplerState(g->device, &sd, &g->smp_linear))) return 0;

    return 1;
}

static int gpuEnsureVerts(GlinWinGpu *g, UINT bytes) {
    if (bytes <= g->vbuf_bytes) return 1;
    UINT want = g->vbuf_bytes == 0 ? GLIN_GPU_VBUF_FLOOR : g->vbuf_bytes;
    while (want < bytes) want *= 2;
    if (g->vbuf != NULL) {
        ID3D11Buffer_Release(g->vbuf);
        g->vbuf = NULL;
        g->vbuf_bytes = 0;
    }
    D3D11_BUFFER_DESC vb;
    memset(&vb, 0, sizeof(vb));
    vb.ByteWidth = want;
    vb.Usage = D3D11_USAGE_DYNAMIC;
    vb.BindFlags = D3D11_BIND_VERTEX_BUFFER;
    vb.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
    if (FAILED(ID3D11Device_CreateBuffer(g->device, &vb, NULL, &g->vbuf))) return 0;
    g->vbuf_bytes = want;
    return 1;
}

void glin_win_gpu_set_atlas(GlinWinGpu *g, const unsigned char *r8, int w, int h) {
    if (g == NULL || r8 == NULL || w <= 0 || h <= 0) return;
    const UINT uw = (UINT)w;
    const UINT uh = (UINT)h;
    if (g->atlas == NULL || g->atlas_w != uw || g->atlas_h != uh) {
        if (g->atlas_srv != NULL) {
            ID3D11ShaderResourceView_Release(g->atlas_srv);
            g->atlas_srv = NULL;
        }
        if (g->atlas != NULL) {
            ID3D11Texture2D_Release(g->atlas);
            g->atlas = NULL;
        }
        D3D11_TEXTURE2D_DESC td;
        memset(&td, 0, sizeof(td));
        td.Width = uw;
        td.Height = uh;
        td.MipLevels = 1;
        td.ArraySize = 1;
        td.Format = DXGI_FORMAT_R8_UNORM;
        td.SampleDesc.Count = 1;
        td.Usage = D3D11_USAGE_DEFAULT;
        td.BindFlags = D3D11_BIND_SHADER_RESOURCE;
        if (FAILED(ID3D11Device_CreateTexture2D(g->device, &td, NULL, &g->atlas))) return;
        if (FAILED(ID3D11Device_CreateShaderResourceView(g->device, GLIN_RES(g->atlas), NULL,
                                                        &g->atlas_srv))) {
            ID3D11Texture2D_Release(g->atlas);
            g->atlas = NULL;
            return;
        }
        g->atlas_w = uw;
        g->atlas_h = uh;
    }
    // Whole-atlas upload: the CPU side only reports "dirty", so there is no rect to narrow it to yet.
    ID3D11DeviceContext_UpdateSubresource(g->context, GLIN_RES(g->atlas), 0, NULL, r8, uw, 0);
}

void glin_win_gpu_set_image(GlinWinGpu *g, int slot, const unsigned char *rgba, int w, int h) {
    if (g == NULL || slot <= 0 || slot >= GLIN_MAX_IMAGES) return;
    if (g->img_srv[slot] != NULL) {
        ID3D11ShaderResourceView_Release(g->img_srv[slot]);
        g->img_srv[slot] = NULL;
    }
    if (g->img_tex[slot] != NULL) {
        ID3D11Texture2D_Release(g->img_tex[slot]);
        g->img_tex[slot] = NULL;
    }
    g->img_w[slot] = 0;
    g->img_h[slot] = 0;
    if (rgba == NULL || w <= 0 || h <= 0) return;

    D3D11_TEXTURE2D_DESC td;
    memset(&td, 0, sizeof(td));
    td.Width = (UINT)w;
    td.Height = (UINT)h;
    td.MipLevels = 1;
    td.ArraySize = 1;
    td.Format = GLIN_DXGI_FORMAT;
    td.SampleDesc.Count = 1;
    td.Usage = D3D11_USAGE_DEFAULT;
    td.BindFlags = D3D11_BIND_SHADER_RESOURCE;
    D3D11_SUBRESOURCE_DATA init;
    memset(&init, 0, sizeof(init));
    init.pSysMem = rgba;
    init.SysMemPitch = (UINT)w * 4u;
    if (FAILED(ID3D11Device_CreateTexture2D(g->device, &td, &init, &g->img_tex[slot]))) return;
    if (FAILED(ID3D11Device_CreateShaderResourceView(g->device, GLIN_RES(g->img_tex[slot]), NULL,
                                                    &g->img_srv[slot]))) {
        ID3D11Texture2D_Release(g->img_tex[slot]);
        g->img_tex[slot] = NULL;
        return;
    }
    g->img_w[slot] = (UINT)w;
    g->img_h[slot] = (UINT)h;
}

/// Upload the frame's vertices and draw the segments into `rtv`. Shared by the
/// window path and the parity path, so the two can never disagree about what
/// "drawing a frame" means.
static int gpuDrawFrame(GlinWinGpu *g, ID3D11RenderTargetView *rtv, UINT w, UINT h,
                        const GlinVertex *verts, int vertex_count, const GlinSegment *segs,
                        int seg_count, const float clear[4]) {
    if (g == NULL || rtv == NULL || w == 0 || h == 0) return 0;
    ID3D11DeviceContext_ClearRenderTargetView(g->context, rtv, clear);
    if (vertex_count <= 0 || seg_count <= 0) return 1;

    if (!gpuEnsureVerts(g, (UINT)vertex_count * (UINT)sizeof(GlinVertex))) return 0;
    D3D11_MAPPED_SUBRESOURCE mapped;
    memset(&mapped, 0, sizeof(mapped));
    if (FAILED(ID3D11DeviceContext_Map(g->context, GLIN_RES(g->vbuf), 0, D3D11_MAP_WRITE_DISCARD,
                                       0, &mapped))) {
        return 0;
    }
    memcpy(mapped.pData, verts, (size_t)vertex_count * sizeof(GlinVertex));
    ID3D11DeviceContext_Unmap(g->context, GLIN_RES(g->vbuf), 0);

    struct {
        float res[2];
        float pad[2];
    } frame = { { (float)w, (float)h }, { 0.0f, 0.0f } };
    ID3D11DeviceContext_UpdateSubresource(g->context, GLIN_RES(g->cbuf), 0, NULL, &frame, 0, 0);

    D3D11_VIEWPORT vp;
    memset(&vp, 0, sizeof(vp));
    vp.TopLeftX = 0;
    vp.TopLeftY = 0;
    vp.Width = (float)w;
    vp.Height = (float)h;
    vp.MinDepth = 0.0f;
    vp.MaxDepth = 1.0f;
    ID3D11DeviceContext_RSSetViewports(g->context, 1, &vp);

    ID3D11DeviceContext_OMSetRenderTargets(g->context, 1, &rtv, NULL);
    ID3D11DeviceContext_OMSetBlendState(g->context, g->blend, NULL, 0xFFFFFFFFu);
    ID3D11DeviceContext_RSSetState(g->context, g->raster);
    // A Draw with no topology set removes the device on WARP, so this is not optional.
    ID3D11DeviceContext_IASetPrimitiveTopology(g->context, D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    ID3D11DeviceContext_IASetInputLayout(g->context, g->input_layout);
    const UINT stride = (UINT)sizeof(GlinVertex);
    const UINT offset = 0;
    ID3D11DeviceContext_IASetVertexBuffers(g->context, 0, 1, &g->vbuf, &stride, &offset);
    ID3D11DeviceContext_VSSetShader(g->context, g->vs, NULL, 0);
    ID3D11DeviceContext_VSSetConstantBuffers(g->context, 0, 1, &g->cbuf);
    ID3D11DeviceContext_PSSetShader(g->context, g->ps, NULL, 0);

    for (int i = 0; i < seg_count; ++i) {
        const GlinSegment *s = &segs[i];
        if (s->count <= 0 || s->start < 0) continue;

        // Top-left origin, and D3D11 scissor rects are top-left too — no flip, unlike GL. An
        // out-of-range rect is invalid, so it is intersected with the target here rather than
        // trusted (the CPU side only clamps at 0).
        D3D11_RECT rect;
        if (s->has_scissor) {
            int left = s->sx < 0 ? 0 : s->sx;
            int top = s->sy < 0 ? 0 : s->sy;
            int right = s->sx + s->sw;
            int bottom = s->sy + s->sh;
            if (right > (int)w) right = (int)w;
            if (bottom > (int)h) bottom = (int)h;
            if (right <= left || bottom <= top) continue;
            rect.left = left;
            rect.top = top;
            rect.right = right;
            rect.bottom = bottom;
        } else {
            rect.left = 0;
            rect.top = 0;
            rect.right = (LONG)w;
            rect.bottom = (LONG)h;
        }
        ID3D11DeviceContext_RSSetScissorRects(g->context, 1, &rect);

        const int id = s->texture_id;
        ID3D11ShaderResourceView *srv = g->atlas_srv;
        ID3D11SamplerState *smp = g->smp_point;
        if (id > 0 && id < GLIN_MAX_IMAGES && g->img_srv[id] != NULL) {
            srv = g->img_srv[id];
            smp = g->smp_linear;
        }
        if (srv == NULL) continue;
        ID3D11DeviceContext_PSSetShaderResources(g->context, 0, 1, &srv);
        ID3D11DeviceContext_PSSetSamplers(g->context, 0, 1, &smp);
        ID3D11DeviceContext_Draw(g->context, (UINT)s->count, (UINT)s->start);
    }

    // Unbind, so the next target bind or texture update is not fighting a live reference.
    ID3D11DeviceContext_PSSetShaderResources(g->context, 0, 0, NULL);
    ID3D11DeviceContext_OMSetRenderTargets(g->context, 0, NULL, NULL);
    g->frames += 1;
    return 1;
}

GlinWinGpu *glin_win_gpu_create(GlinWinWindow *win) {
    if (win == NULL || win->device == NULL || win->context == NULL) return NULL;
    GlinWinGpu *g = (GlinWinGpu *)calloc(1, sizeof(GlinWinGpu));
    if (g == NULL) return NULL;
    g->device = win->device;
    g->context = win->context;
    g->win = win;
    if (!gpuBuild(g)) {
        gpuRelease(g);
        return NULL;
    }
    return g;
}

void glin_win_gpu_destroy(GlinWinGpu *g) {
    gpuRelease(g);
}

int glin_win_gpu_active(GlinWinGpu *g) {
    return g != NULL;
}

int glin_win_gpu_presented_frames(GlinWinGpu *g) {
    return g != NULL ? g->frames : 0;
}

int glin_win_gpu_draw(GlinWinGpu *g, const GlinVertex *verts, int vertex_count,
                      const GlinSegment *segs, int seg_count, float r, float gr, float b, float a) {
    if (g == NULL || g->win == NULL) return 0;
    GlinWinWindow *win = g->win;
    if (win->gdi || win->device_failed) return 0;
    if (!ensureBackBufferView(win)) return 0;
    const UINT w = g->width != 0 ? g->width : 0;
    (void)w;
    int cw = 0;
    int ch = 0;
    glin_win_content_size(win, &cw, &ch);
    if (cw <= 0 || ch <= 0) return 0;
    // The swap chain's back buffer is in DEVICE pixels; the surface the layout was measured in is
    // logical, so the target size is the window's own device client rect, not the logical one.
    const UINT tw = (UINT)((double)cw * glin_win_scale(win) + 0.5);
    const UINT th = (UINT)((double)ch * glin_win_scale(win) + 0.5);
    const float clear[4] = { r, gr, b, a };
    if (!gpuDrawFrame(g, win->back_rtv, tw, th, verts, vertex_count, segs, seg_count, clear)) {
        return 0;
    }
    win->presented = 1;
    win->frames += 1;
    HRESULT hr = IDXGISwapChain_Present(win->swap_chain, 0, 0);
    if (FAILED(hr)) {
        degradeToGdi(win, "Present failed after a GPU frame");
        return 0;
    }
    if (win->max_frames > 0 && win->frames >= win->max_frames) glin_win_quit(win);
    return 1;
}

unsigned char *glin_win_gpu_offscreen(const GlinVertex *verts, int vertex_count,
                                      const GlinSegment *segs, int seg_count, int w, int h,
                                      float r, float gr, float b, float a,
                                      const unsigned char *atlas, int atlas_w, int atlas_h) {
    if (w <= 0 || h <= 0) return NULL;
    GlinWinGpu *g = (GlinWinGpu *)calloc(1, sizeof(GlinWinGpu));
    if (g == NULL) return NULL;
    D3D_FEATURE_LEVEL got = D3D_FEATURE_LEVEL_11_0;
    // Same device selection as the window (hardware, then WARP), so this probe measures the
    // pipeline the window actually runs.
    HRESULT hr = D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, NULL, 0,
                                   D3D11_SDK_VERSION, &g->device, &got, &g->context);
    if (FAILED(hr) || g->device == NULL || g->context == NULL) {
        if (g->device != NULL) ID3D11Device_Release(g->device);
        if (g->context != NULL) ID3D11DeviceContext_Release(g->context);
        g->device = NULL;
        g->context = NULL;
        hr = D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_WARP, NULL, 0, NULL, 0, D3D11_SDK_VERSION,
                               &g->device, &got, &g->context);
    }
    if (FAILED(hr) || g->device == NULL || g->context == NULL) {
        gpuRelease(g);
        return NULL;
    }
    g->own_device = 1;
    if (!gpuBuild(g)) {
        gpuRelease(g);
        return NULL;
    }
    // The parity path renders glyphs too, so it needs the same atlas the window path uploads.
    if (atlas != NULL && atlas_w > 0 && atlas_h > 0) {
        glin_win_gpu_set_atlas(g, atlas, atlas_w, atlas_h);
    }

    D3D11_TEXTURE2D_DESC td;
    D3D11_TEXTURE2D_DESC read_desc;
    memset(&td, 0, sizeof(td));
    td.Width = (UINT)w;
    td.Height = (UINT)h;
    td.MipLevels = 1;
    td.ArraySize = 1;
    td.Format = GLIN_DXGI_FORMAT;
    td.SampleDesc.Count = 1;
    td.Usage = D3D11_USAGE_DEFAULT;
    td.BindFlags = D3D11_BIND_RENDER_TARGET;
    read_desc = td;
    read_desc.Usage = D3D11_USAGE_STAGING;
    read_desc.BindFlags = 0;
    read_desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;

    unsigned char *out = NULL;
    ID3D11Texture2D *readback = NULL;
    if (SUCCEEDED(ID3D11Device_CreateTexture2D(g->device, &td, NULL, &g->rt)) &&
        SUCCEEDED(ID3D11Device_CreateRenderTargetView(g->device, GLIN_RES(g->rt), NULL, &g->rtv)) &&
        SUCCEEDED(ID3D11Device_CreateTexture2D(g->device, &read_desc, NULL, &readback))) {
        const float clear[4] = { r, gr, b, a };
        if (gpuDrawFrame(g, g->rtv, (UINT)w, (UINT)h, verts, vertex_count, segs, seg_count, clear)) {
            ID3D11DeviceContext_CopyResource(g->context, GLIN_RES(readback), GLIN_RES(g->rt));
            D3D11_MAPPED_SUBRESOURCE mapped;
            memset(&mapped, 0, sizeof(mapped));
            if (SUCCEEDED(ID3D11DeviceContext_Map(g->context, GLIN_RES(readback), 0, D3D11_MAP_READ,
                                                  0, &mapped))) {
                out = (unsigned char *)malloc((size_t)w * (size_t)h * 4u);
                if (out != NULL) {
                    for (int y = 0; y < h; ++y) {
                        memcpy(out + (size_t)y * (size_t)w * 4u,
                               (const unsigned char *)mapped.pData +
                                   (size_t)y * (size_t)mapped.RowPitch,
                               (size_t)w * 4u);
                    }
                }
                ID3D11DeviceContext_Unmap(g->context, GLIN_RES(readback), 0);
            }
        }
    }
    if (readback != NULL) ID3D11Texture2D_Release(readback);
    gpuRelease(g);
    return out;
}

void glin_win_gpu_free(void *p) {
    free(p);
}


