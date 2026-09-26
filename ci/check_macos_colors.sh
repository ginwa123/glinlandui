#!/usr/bin/env bash
# glinlandui macOS colour hand-off check.
#
# Compiles ci/check_macos_colors.c with the EXACT CGBitmapInfo that
# src/mac/shim.m uses — the flags are read out of the shim rather than
# duplicated here, so editing the shim edits what is tested — and runs it.
# The check reproduces the CoreGraphics display path and compares the
# DISPLAYED colour against the colour that was written.
#
# Needs no window server, no GUI session and no Screen Recording permission,
# so it is safe to run on every macOS build machine and in CI.
#
# Exits 0 when every probe colour survives the hand-off, 1 otherwise.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
shim="$root/src/mac/shim.m"
src="$root/ci/check_macos_colors.c"

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "macos-colors: skipped (not macOS)"
    exit 0
fi
if ! command -v clang >/dev/null 2>&1; then
    echo "macos-colors: FAILED — clang not found" >&2
    exit 1
fi

# Pull the two flags out of the shim's kGlinBitmapInfo definition, so the
# check can never drift from what the window actually uses.
info_line="$(grep -A2 'static const CGBitmapInfo kGlinBitmapInfo' "$shim" \
             | tr '\n' ' ' | sed 's/  */ /g')"
alpha="$(sed -n 's/.*(CGBitmapInfo)\(kCGImageAlpha[A-Za-z]*\).*/\1/p' <<<"$info_line" | head -1)"
order="$(sed -n 's/.*\(kCGBitmapByteOrder[A-Za-z0-9]*\).*/\1/p' <<<"$info_line" | head -1)"

if [[ -z "$alpha" || -z "$order" ]]; then
    echo "macos-colors: FAILED — could not read kGlinBitmapInfo from $shim" >&2
    echo "  expected a line like:" >&2
    echo "    static const CGBitmapInfo kGlinBitmapInfo =" >&2
    echo "        (CGBitmapInfo)kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big;" >&2
    exit 1
fi

echo "macos-colors: testing $alpha | $order (read from src/mac/shim.m)"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

clang -O1 -o "$tmp/check" \
    -DGLIN_CHECK_BITMAP_INFO="$alpha | $order" \
    -DGLIN_CHECK_BYTE_ORDER="\"$alpha | $order\"" \
    -framework CoreGraphics \
    "$src"

"$tmp/check"
