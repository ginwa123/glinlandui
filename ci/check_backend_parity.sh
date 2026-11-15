#!/usr/bin/env bash
# glinlandui backend-parity gate.
#
# `src/platform.zig` picks a backend per OS for five seams: window, renderer,
# file dialog, clipboard and text. The app code above them is identical, so a
# backend that forgets one public name compiles fine on its own machine and
# breaks the app on the one OS nobody built.
#
# This reads every backend FILE (it does not compile them), so a single job on
# one runner covers all five platforms. `src/core/backend_contract_test.zig`
# checks the type-level shape through the composition root on each leg; this
# covers the per-OS modules that a test binary cannot import without dragging
# Wayland/D3D11/Cocoa objects into the link.
#
# `ci/backend_parity.expected` lists `os seam name` triples that are KNOWN to be
# missing. The gate is a ratchet: an unlisted miss fails (regression) and a
# listed name that now exists also fails (stale entry), so the list only shrinks.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
baseline="$root/ci/backend_parity.expected"

# seam | os | file | required public names (space separated)
entries=(
  "window|mac|src/mac/window.zig|Window WindowConfig Delegate renderHeadless clampSize computePlacement keyToClose parseTestFrames pointerPosChanged"
  "window|linux|src/linux/window.zig|Window WindowConfig Delegate renderHeadless clampSize computePlacement keyToClose parseTestFrames pointerPosChanged"
  "window|windows|src/windows/window.zig|Window WindowConfig Delegate renderHeadless clampSize computePlacement keyToClose parseTestFrames pointerPosChanged"
  "window|web|src/web/window.zig|Window WindowConfig Delegate renderHeadless clampSize computePlacement keyToClose parseTestFrames pointerPosChanged"
  "window|portable|src/core/window_portable.zig|Window WindowConfig Delegate renderHeadless clampSize computePlacement keyToClose parseTestFrames pointerPosChanged"

  "render|mac|src/mac/renderer.zig|Renderer Surface"
  "render|linux|src/linux/renderer.zig|Renderer"
  "render|windows|src/windows/renderer.zig|Renderer Surface"
  "render|web|src/web/renderer.zig|Renderer Surface"
  "render|portable|src/core/render_software.zig|Renderer Surface"

  "file_dialog|mac|src/mac/file_dialog.zig|Kind Rule Filter Options Status Selection Error available openFile openFolder saveFile"
  "file_dialog|linux|src/linux/file_dialog.zig|Kind Rule Filter Options Status Selection Error available openFile openFolder saveFile"
  "file_dialog|windows|src/windows/file_dialog.zig|Kind Rule Filter Options Status Selection Error available openFile openFolder saveFile"
  "file_dialog|portable|src/core/file_dialog_portable.zig|Kind Rule Filter Options Status Selection Error available openFile openFolder saveFile"

  "clipboard|mac|src/mac/clipboard.zig|max_bytes read write"
  "clipboard|linux|src/linux/clipboard.zig|max_bytes read write"
  "clipboard|windows|src/windows/clipboard.zig|max_bytes read write"
  "clipboard|portable|src/core/clipboard_portable.zig|max_bytes read write"

  "devtools|linux|src/linux/devtools_service.zig|Handle open request socketPath"
  "devtools|portable|src/core/devtools_service_portable.zig|Handle open request"

  "text|linux|src/linux/text.zig|TextExtent ResolveFontError resolveFont fontCandidates readFontBytes estimatorExtent hashMeasureKey extentCacheReset measureText"
  "text|mac|src/mac/text.zig|TextExtent ResolveFontError resolveFont fontCandidates readFontBytes estimatorExtent hashMeasureKey extentCacheReset measureText"
  "text|windows|src/windows/text.zig|TextExtent ResolveFontError resolveFont fontCandidates readFontBytes estimatorExtent hashMeasureKey extentCacheReset measureText"
  "text|web|src/web/text.zig|TextExtent ResolveFontError resolveFont fontCandidates readFontBytes estimatorExtent hashMeasureKey extentCacheReset measureText"
  "text|portable|src/core/text_portable.zig|TextExtent ResolveFontError resolveFont fontCandidates readFontBytes estimatorExtent hashMeasureKey extentCacheReset measureText"
)

if [[ ! -f "$baseline" ]]; then
    echo "backend-parity: FAILED — missing $baseline" >&2
    echo "  create it (comments and blank lines allowed) listing known gaps as: <os> <seam> <name>" >&2
    exit 1
fi

# known gaps, as "os seam name"
gaps=()
while IFS= read -r line; do
    line="${line%%#*}"
    line="$(echo "$line" | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//')"
    [[ -n "$line" ]] && gaps+=("$line")
done < "$baseline"

fail=0
checked=0
reported=()

for entry in "${entries[@]}"; do
    IFS='|' read -r seam os file names <<<"$entry"
    path="$root/$file"
    if [[ ! -f "$path" ]]; then
        echo "backend-parity: FAILED — $seam/$os: $file does not exist" >&2
        fail=1
        continue
    fi
    for name in $names; do
        checked=$((checked + 1))
        if grep -qE "^[[:space:]]*pub (const|fn) ${name}\b" "$path"; then
            # Present but listed as a gap => the baseline is stale and must shrink.
            for g in "${gaps[@]:-}"; do
                if [[ "$g" == "$os $seam $name" ]]; then
                    echo "backend-parity: FAILED — $seam/$os declares '$name' now, but $baseline still lists it." >&2
                    echo "  delete the '$os $seam $name' line: the ratchet only turns one way." >&2
                    fail=1
                fi
            done
        else
            listed=0
            for g in "${gaps[@]:-}"; do
                [[ "$g" == "$os $seam $name" ]] && listed=1
            done
            if [[ "$listed" -eq 1 ]]; then
                reported+=("$seam/$os $name")
            else
                echo "backend-parity: FAILED — $seam/$os is missing 'pub const $name' / 'pub fn $name' in $file" >&2
                echo "  the app compiles on the other platforms and breaks on this one. Add it, or record '$os $seam $name' in $baseline." >&2
                fail=1
            fi
        fi
    done
done

if [[ "$fail" -ne 0 ]]; then
    echo "" >&2
    echo "backend-parity: every module src/platform.zig can select must expose the same public surface." >&2
    exit 1
fi

echo "backend-parity: $checked declaration(s) checked across ${#entries[@]} backend file(s)"
if [[ "${#reported[@]}" -gt 0 ]]; then
    echo "backend-parity: ${#reported[@]} known gap(s) recorded in ci/backend_parity.expected: ${reported[*]}"
fi
exit 0
