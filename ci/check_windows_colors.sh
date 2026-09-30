#!/usr/bin/env bash
# glinlandui Windows D3D11 colour hand-off check.
#
# The Windows counterpart of ci/check_macos_colors.sh, and it exists for the
# same reason. windows/present.zig documents that handing `soft.Surface` to the
# D3D11 pipeline is the IDENTITY — no channel swap, no vertical flip — and the
# tests in that file can only compare the upload buffer against the surface it
# came from, i.e. against the module's own idea of the answer.
#
# What actually goes wrong lives in src/windows/shim.c: the swap-chain format,
# the texture's row order, the shader's sampling. A wrong choice there renders
# the whole window in the wrong colours (or upside down) while every Zig test
# stays green. So this check drives the REAL D3D11 path — it calls
# glin_win_probe_color(), which runs the same createPipeline()/drawQuad() the
# window runs, into a target in the same format as the swap chain — and
# compares the DISPLAYED colour with the colour that was written.
#
# It needs no window, no swap chain, no display and no interactive session,
# because WARP is a Direct3D 11 software rasterizer. That makes it safe on a
# stock GitHub Actions windows-2022 runner, where there is no hardware GPU at
# all and only the WARP path is available.
#
# ## Why "skipped" is a real outcome, and why it is not the same as passing
#
# A D3D11 device is cheap to create and easy to create uselessly: a VM, a
# container, or a machine with a half-initialised driver hands back a device and
# a compiled shader without complaint and then fails the first time a vertex
# shader actually executes. On such a host the probe reports that it could not
# run, and this script SKIPS — loudly, with the reason, and non-zero only for a
# genuine mismatch. A check that silently passed on a host where it never
# measured anything would be worse than no check at all; a check that FAILED
# for an unrelated reason would make the job red on machines nobody can fix
# from the log.
#
# Exits 0 when every probe colour survives the hand-off OR the host cannot run
# D3D11 at all, 1 when it runs and a colour is wrong.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
shim="$root/src/windows/shim.c"
src="$root/ci/check_windows_colors.c"

case "$(uname -s 2>/dev/null || echo unknown)" in
  MINGW*|MSYS*|CYGWIN*|Windows_NT) ;;
  *)
    echo "windows-colors: skipped (not Windows)"
    exit 0
    ;;
esac

if ! command -v zig >/dev/null 2>&1; then
  echo "windows-colors: FAILED — zig not found" >&2
  exit 1
fi

# The real shim TU is compiled in, not a copy of the draw path. That is the
# whole point: a lookalike could drift from what the window does, and then this
# check would be asserting that a lookalike works. shim.c owns its own
# COBJMACROS (it has to — the macro must be defined before any header is read),
# so no extra flags are needed here.
echo "windows-colors: compiling the real shim (src/windows/shim.c) + the probe"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

zig cc -O1 -o "$tmp/check.exe" "$src" "$shim" \
    -ld3d11 -ldxgi -ld3dcompiler_47 -luser32 -lgdi32 -lshell32 -lole32

"$tmp/check.exe"
