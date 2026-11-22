#!/bin/sh
# Compile the Linux shaders to SPIR-V.
#
# The .spv files are COMMITTED next to their sources, because the library
# build must never need a shader compiler: `zig build` for Linux also runs on
# macOS hosts and on CI images we do not own, and @embedFile wants bytes that
# exist. This script is how they are regenerated, and it is the only thing here
# that needs glslang installed.
#
#   sh tools/build_shaders.sh            # Debian/Ubuntu: apt install glslang-tools
#
# Vulkan 1.0 is the target on purpose: the render pass is classic (no dynamic
# rendering), so the binary runs on a 1.0 device and on lavapipe.
set -eu

here="$(cd "$(dirname "$0")/.." && pwd)"
shaders="$here/src/linux/shaders"

if ! command -v glslangValidator >/dev/null 2>&1; then
    echo "build_shaders: glslangValidator not found (apt install glslang-tools)" >&2
    exit 1
fi

for src in quad.vert rect.frag text.frag image.frag; do
    glslangValidator -V --target-env vulkan1.0 -o "$shaders/$src.spv" "$shaders/$src"
done

# Validate what was just written, so a broken build fails here and not at a
# pipeline creation three layers away.
if command -v spirv-val >/dev/null 2>&1; then
    for spv in "$shaders"/*.spv; do
        spirv-val --target-env vulkan1.0 "$spv"
    done
fi

ls -l "$shaders"/*.spv
