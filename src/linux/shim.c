// glinlandui pangocairo implementation TU. Compiled with the system C
// compiler (not Zig's @cImport translator), so including pango/cairo/glib
// headers is safe here. Zig only ever sees shim.h (plain C types).
#include "shim.h"

#include <string.h>
#include <cairo/cairo.h>
#include <pango/pango.h>
#include <pango/pangocairo.h>

bool glinlandui_text_measure(const char *text, int len, const char *font_desc, int *w_out, int *h_out) {
    if (!text || !font_desc || !w_out || !h_out) return false;
    if (len <= 0 || len > 4095) return false;

    PangoFontMap *fontmap = pango_cairo_font_map_get_default();
    if (!fontmap) return false;
    PangoContext *ctx = pango_font_map_create_context(fontmap);
    if (!ctx) return false;

    PangoLayout *layout = pango_layout_new(ctx);
    g_object_unref(ctx);
    if (!layout) return false;

    PangoFontDescription *desc = pango_font_description_from_string(font_desc);
    if (!desc) {
        g_object_unref(layout);
        return false;
    }
    pango_layout_set_font_description(layout, desc);
    pango_font_description_free(desc);

    pango_layout_set_text(layout, text, len);
    int w = 0, h = 0;
    pango_layout_get_pixel_size(layout, &w, &h);
    g_object_unref(layout);
    if (w < 0 || h <= 0) return false;
    *w_out = w;
    *h_out = h;
    return true;
}

void *glinlandui_text_render(int w, int h, const char *text, int len, const char *font_desc, double r, double g, double b, double a, int *stride_out) {
    if (w <= 0 || h <= 0 || w > 2048 || h > 256) return NULL;
    if (!text || !font_desc || len <= 0 || len > 4095) return NULL;

    cairo_surface_t *surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, w, h);
    if (!surface || cairo_surface_status(surface) != CAIRO_STATUS_SUCCESS) {
        if (surface) cairo_surface_destroy(surface);
        return NULL;
    }
    cairo_t *cr = cairo_create(surface);
    if (!cr || cairo_status(cr) != CAIRO_STATUS_SUCCESS) {
        if (cr) cairo_destroy(cr);
        cairo_surface_destroy(surface);
        return NULL;
    }

    cairo_set_source_rgba(cr, r, g, b, a);
    PangoLayout *layout = pango_cairo_create_layout(cr);
    if (!layout) {
        cairo_destroy(cr);
        cairo_surface_destroy(surface);
        return NULL;
    }
    PangoFontDescription *desc = pango_font_description_from_string(font_desc);
    if (!desc) {
        g_object_unref(layout);
        cairo_destroy(cr);
        cairo_surface_destroy(surface);
        return NULL;
    }
    pango_layout_set_font_description(layout, desc);
    pango_font_description_free(desc);
    pango_layout_set_text(layout, text, len);
    pango_cairo_show_layout(cr, layout);
    bool ok = cairo_status(cr) == CAIRO_STATUS_SUCCESS;
    g_object_unref(layout);
    cairo_destroy(cr);
    if (!ok) {
        cairo_surface_destroy(surface);
        return NULL;
    }
    cairo_surface_flush(surface);
    if (stride_out) *stride_out = cairo_image_surface_get_stride(surface);
    return (void *)surface;
}

unsigned char *glinlandui_surface_data(void *surface) {
    if (!surface) return NULL;
    return cairo_image_surface_get_data((cairo_surface_t *)surface);
}

int glinlandui_surface_stride(void *surface) {
    if (!surface) return 0;
    return cairo_image_surface_get_stride((cairo_surface_t *)surface);
}

void glinlandui_surface_destroy(void *surface) {
    if (!surface) return;
    cairo_surface_destroy((cairo_surface_t *)surface);
}
