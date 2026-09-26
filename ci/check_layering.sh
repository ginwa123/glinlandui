#!/usr/bin/env bash
# Layering gate for the core/ + linux/ + mac/ split. See src/README.md §2 and
# REFACTOR_PLAN.md §5.
#
# The whole point of the split is that the platform-agnostic half of the library
# cannot accidentally depend on a platform. That is a structural property, and a
# structural property is best held by a grep: each rule says "this token does not
# appear in this subtree", which is exactly the invariant. The rules are also the
# documentation.
#
#   R1  no file under src/core/** may import a platform backend (linux/ or mac/)
#   R2  only src/core/select.zig may import ../platform.zig
#   R3  src/core/** must be OS-blind and free of platform C imports
#   R4  the linux/ and mac/ backends are siblings and must not import each other
#   R5  only src/platform.zig may branch on builtin.os.tag
#   R6  every module in the parity suite must stay pure Zig (no @cImport call)
#
# NOTE ON SCOPE: every rule scans SOURCE files only. The docs legitimately
# discuss these rules — this file, src/README.md and the module headers all
# mention `builtin.os.tag`, `@cImport` and the folder names — and a rule that
# cannot tell a comment from code would forbid explaining itself.
set -euo pipefail
fail=0

# Files a rule can apply to. Markdown is deliberately excluded: it describes the
# rules rather than participating in them.
SOURCE_GLOB='*.{zig,c,h,m}'

# scan <search-path> <glob> <regex> <message>
# An empty result (including "no such file yet") is a pass, not a violation.
# The search PATH is an argument rather than a `--glob`, because ripgrep ORs
# multiple include globs — `--glob 'src/core/**' --glob '*.zig'` would match every
# .zig in the tree. Path + one glob is what expresses "these rules, these files".
scan() {
  local matches
  matches="$(rg -n --glob "$2" -e "$3" "$1" 2>/dev/null || true)"
  if [ -n "$matches" ]; then
    echo "$4" >&2
    printf '%s\n' "$matches" >&2
    fail=1
  fi
}

# ---------------------------------------------------------------------------
# R1 — core must not reach a platform backend.
# ---------------------------------------------------------------------------
scan src/core "$SOURCE_GLOB" '@import\("\.\./(\.\./)?(linux|mac)/' \
  "R1 violated: src/core/** imports a platform backend"

# ---------------------------------------------------------------------------
# R2 — exactly one bridge from core to the composition root.
# ---------------------------------------------------------------------------
R2_HITS="$(rg -n --glob "$SOURCE_GLOB" -e '@import\("\.\./platform\.zig"\)' src/core 2>/dev/null || true)"
R2_BAD="$(printf '%s' "$R2_HITS" | grep -v '^src/core/select\.zig:')" || true
if [ -n "$R2_BAD" ]; then
  echo "R2 violated: only src/core/select.zig may import ../platform.zig" >&2
  printf '%s\n' "$R2_BAD" >&2
  fail=1
fi

# ---------------------------------------------------------------------------
# R3 — core must not know the OS, nor import a platform C header.
# ---------------------------------------------------------------------------
# Matches `os.tag`, not `builtin.os.tag`: the literal form is trivially evaded by
# `const b = @import("builtin"); … b.os.tag`, and nothing outside platform.zig
# legitimately reads `os.tag` at all. `builtin.is_test` is NOT an OS branch and
# stays allowed (core/window_portable.zig and core/frame.zig use it to no-op the
# real presentation path under test).
scan src/core "$SOURCE_GLOB" 'os\.tag' \
  "R3 violated: src/core/** branches on the target OS (os.tag)"

# Vendored stb is allowed: it is byte-identical on every host and build.zig adds
# its include path unconditionally. Everything else names a platform.
scan src/core "$SOURCE_GLOB" '@cInclude\("(EGL|GLES|pango|cocoa|wayland)' \
  "R3 violated: src/core/** includes a platform C header"

# ---------------------------------------------------------------------------
# R4 — the backends are siblings, not a hierarchy.
# ---------------------------------------------------------------------------
scan src/linux "$SOURCE_GLOB" '@import\("\.\./(\.\./)?mac/' \
  "R4 violated: src/linux/** imports mac/"
scan src/mac "$SOURCE_GLOB" '@import\("\.\./(\.\./)?linux/' \
  "R4 violated: src/mac/** imports linux/"

# ---------------------------------------------------------------------------
# R5 — one OS switch, in the composition root, and nowhere else.
# ---------------------------------------------------------------------------
R5_HITS="$(rg -n --glob "$SOURCE_GLOB" --glob '!src/platform.zig' \
  -e 'os\.tag' src 2>/dev/null || true)"
if [ -n "$R5_HITS" ]; then
  echo "R5 violated: the OS is chosen outside src/platform.zig (os.tag)" >&2
  printf '%s\n' "$R5_HITS" >&2
  fail=1
fi

# ---------------------------------------------------------------------------
# R6 — every module pulled into the PARITY test suite (see the aggregate `test`
# block in src/root.zig) must stay pure Zig: no @cImport. That is the property
# that lets the suite compile the SAME file set on Linux and macOS, which is what
# proves the macOS translations are right without a Mac — and, equally, that a
# typo in the Linux event translation fails on both platforms rather than only in
# CI's Linux leg. Backends that legitimately cImport are kept OUT of the suite:
# linux/window.zig, linux/present.zig, mac/window.zig.
# ---------------------------------------------------------------------------
for f in src/mac/present.zig src/mac/keymap.zig src/mac/adapter.zig src/mac/input.zig \
         src/mac/renderer.zig src/mac/text.zig \
         src/linux/keymap.zig src/linux/input.zig src/linux/adapter.zig; do
  # Match the CALL, not a mention: these files legitimately discuss @cImport in
  # their doc comments ("this module needs no @cImport"), and a rule that cannot
  # tell a comment from a call would forbid explaining the rule.
  if [ -f "$f" ] && rg -q '@cImport[[:space:]]*\(' "$f"; then
    echo "R6 violated: $f is in the parity suite but cImports" >&2
    fail=1
  fi
done

if [ "$fail" -ne 0 ]; then
  echo "layering: FAILED" >&2
  exit 1
fi
echo "layering: ok"
