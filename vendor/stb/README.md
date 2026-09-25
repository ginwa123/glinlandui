# Vendored stb headers

These unmodified headers are vendored from the system `stb` package so Linux
and macOS CI compile the same `stb_truetype` and `stb_image` code without
relying on a distribution's include layout or header version.

- `stb_truetype.h` — public domain (see header)
- `stb_image.h` — public domain / MIT dual license (see header)
- `stb_image_resize2.h` — public domain (see header)

They are used only by the Linux GLES3 backend. CPU-only platform builds never
compile the stb implementation translation units.
