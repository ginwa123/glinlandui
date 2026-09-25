// stb_image implementation TU (mirrors stb_truetype_impl.c): exactly one
// TU defines the implementations. System headers (/usr/include/stb/)
// resolve via the default system include path — no extra flags needed.
// resize2 gives thumbnail downscaling (stbir_resize_uint8_linear).
#define STB_IMAGE_IMPLEMENTATION
#include "stb/stb_image.h"
#define STB_IMAGE_RESIZE_IMPLEMENTATION
#include "stb/stb_image_resize2.h"
