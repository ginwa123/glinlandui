#pragma once
// glinlandui pangocairo shim — Zig @cImport parses ONLY this file.
// Real pango/cairo/glib headers stay inside pango_text.c (compiled with
// GCC, not Zig's translator) so we never hit G_GNUC_BEGIN_IGNORE_DEPRECATIONS
// translation failures. All glib types (PangoLayout, GObject) are opaque
// void* here.
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// Measure `text` (len bytes, may contain UTF-8, not necessarily NUL) with
// `font_desc` like "FiraCode Nerd Font Mono 18". Returns true on success,
// writes pixel w/h. Never crashes (false on any null/failure).
bool glinlandui_text_measure(const char *text, int len, const char *font_desc, int *w_out, int *h_out);

// Render `text` into a new ARGB32 cairo image surface of exactly w*h
// (w/h from measure). Draws in rgba color. Returns NULL on failure.
// Caller must call glinlandui_surface_destroy(). stride via out param.
void *glinlandui_text_render(int w, int h, const char *text, int len, const char *font_desc, double r, double g, double b, double a, int *stride_out);

// Accessors for the opaque surface (NULL-safe: null -> null/0).
unsigned char *glinlandui_surface_data(void *surface);
int glinlandui_surface_stride(void *surface);
void glinlandui_surface_destroy(void *surface);

#ifdef __cplusplus
}
#endif
