#!/usr/bin/env bash
# glinlandui render-scale gate.
#
# The invariant: a window that is W x H logical points on a display with backing
# scale S must rasterize W*S x H*S device pixels. A backend that skips this
# renders a 1x image and lets the compositor upscale it, which is exactly the
# blur this gate exists to prevent (macOS is sharp because it renders at 2x;
# Linux, Windows and the browser are not).
#
# A backend counts as wired when its window file calls `setRenderScale(`. That
# is the only way the toolkit learns the display density, so its absence is a
# reliable proxy for the bug and needs no GPU, no window server and no CI
# matrix of displays.
#
# `ci/render_scale.expected` lists the backends that are KNOWN to be unwired.
# The gate is a ratchet in both directions:
#   - a backend that becomes unwired and is not listed  => FAIL (regression)
#   - a backend that is listed but is now wired         => FAIL (stale entry)
# so the list can only shrink, and deleting a line is the proof a fix landed.
#
# Exits 0 when the tree matches the baseline, 1 otherwise.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
baseline="$root/ci/render_scale.expected"

# backend:window file. Keep this list in step with `platform.window` in src/platform.zig.
backends=(
    "mac:src/mac/window.zig"
    "windows:src/windows/window.zig"
    "linux:src/linux/window.zig"
    "web:src/web/window.zig"
)

if [[ ! -f "$baseline" ]]; then
    echo "render-scale: FAILED — missing $baseline" >&2
    echo "  create it listing the backends that are not yet wired (one name per line)," >&2
    echo "  or an empty file when every backend honours the display scale." >&2
    exit 1
fi

# Read the baseline: strip comments and blank lines.
known_unwired=()
while IFS= read -r line; do
    line="${line%%#*}"
    line="$(echo "$line" | tr -d '[:space:]')"
    [[ -n "$line" ]] && known_unwired+=("$line")
done < "$baseline"

fail=0
wired_list=()
gap_list=()

for entry in "${backends[@]}"; do
    name="${entry%%:*}"
    file="${entry#*:}"
    path="$root/$file"

    if [[ ! -f "$path" ]]; then
        echo "render-scale: FAILED — $name backend file $file not found" >&2
        fail=1
        continue
    fi

    # A call, not a mention: the doc comment talks about it too.
    if grep -qE '^[^/]*setRenderScale\(' "$path"; then
        wired_list+=("$name")
        # Wired but still listed => the baseline is stale and must shrink.
        for k in "${known_unwired[@]:-}"; do
            if [[ "$k" == "$name" ]]; then
                echo "render-scale: FAILED — $name is wired now, but $baseline still lists it." >&2
                echo "  delete the '$name' line: the ratchet only turns one way." >&2
                fail=1
            fi
        done
    else
        listed=0
        for k in "${known_unwired[@]:-}"; do
            [[ "$k" == "$name" ]] && listed=1
        done
        if [[ "$listed" -eq 1 ]]; then
            gap_list+=("$name")
        else
            echo "render-scale: FAILED — $name does not call setRenderScale(), so it renders at 1x and the compositor upscales it (blurry)." >&2
            echo "  fix $file, or add '$name' to $baseline to record the gap deliberately." >&2
            fail=1
        fi
    fi
done

if [[ "$fail" -ne 0 ]]; then
    echo "" >&2
    echo "render-scale: the invariant is W*S x H*S device pixels for a W x H logical window at scale S." >&2
    echo "  src/core/scale.zig owns the one definition; src/core/render_software.zig applies it." >&2
    exit 1
fi

echo "render-scale: ${#wired_list[@]} backend(s) honour the display scale: ${wired_list[*]:-none}"
if [[ "${#gap_list[@]}" -gt 0 ]]; then
    echo "render-scale: ${#gap_list[@]} known gap(s) recorded in ci/render_scale.expected: ${gap_list[*]}"
fi
exit 0
