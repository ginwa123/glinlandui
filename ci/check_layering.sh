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
#
# Two folders when this rule was written, three now (web/ joined for the browser
# backend), so the two pairwise greps became a loop over all three: no backend
# may import another. The loop is what makes a fourth platform a one-line change
# rather than a set of scans someone will forget to add.
#
# A backend reaching a sibling is the same bug class as core/ reaching a
# platform, one level down: it would make one platform's build depend on
# another's C headers, its `shim.h` (which is the reason the platform include
# paths are mutually exclusive — see I4), or its windowing system.
# ---------------------------------------------------------------------------
for backend in linux mac web; do
  for other in linux mac web; do
    if [ "$backend" = "$other" ]; then continue; fi
    scan "src/$backend" "$SOURCE_GLOB" "@import\(\"\.\./(\.\./)?$other/" \
      "R4 violated: src/$backend/** imports src/$other/"
  done
done

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
         src/linux/keymap.zig src/linux/input.zig src/linux/adapter.zig \
         src/web/present.zig src/web/keymap.zig src/web/adapter.zig src/web/input.zig \
         src/web/renderer.zig src/web/text.zig src/web/compat_heap.zig; do
  # Match the CALL, not a mention: these files legitimately discuss @cImport in
  # their doc comments ("this module needs no @cImport"), and a rule that cannot
  # tell a comment from a call would forbid explaining the rule.
  #
  # Note what is ABSENT from the web list: web/window.zig and web/compat_impl.zig.
  # They are not in the parity suite — they name `std.heap.wasm_allocator`, whose
  # methods lower to `@wasmMemoryGrow` and cannot be analysed on a native target
  # — so R6 does not apply to them. R8 below does, because it is scoped by FOLDER
  # rather than by suite membership. The two rules are deliberately
  # complementary: R6 says "this file is compiled on every OS, so keep it pure",
  # R8 says "this folder is compiled for wasm, so keep it freestanding".
  if [ -f "$f" ] && rg -q '@cImport[[:space:]]*\(' "$f"; then
    echo "R6 violated: $f is in the parity suite but cImports" >&2
    fail=1
  fi
done

# ---------------------------------------------------------------------------
# R7 — the freestanding C-compile compat headers may only reach a WASM build's
# include path.
#
# This is the same trap as I4's two `shim.h` files, one level down: `stb_truetype.h`
# does `#include <stdlib.h>`, and if `src/web/compat` were ever on a native
# include path that would silently resolve to OUR declaration-only header,
# changing what the Linux and macOS backends compile against — with no error and
# no way to notice from a test.
#
# Two halves, and only one of them is greppable:
#
#   (a) GREPPED HERE: no source file may NAME the compat directory as an include
#       target. Sources reach it through `#include <stdlib.h>` and the gated
#       include path, never by path, so a mention under src/ means someone has
#       bypassed the gate.
#
#       The pattern matches an INCLUDE, not a bare mention, for the same reason
#       R6 matches the `@cImport(` call: the compat headers legitimately explain
#       themselves in prose ("the definitions live in `src/web/compat_impl.zig`"),
#       and a rule that cannot tell a comment from an include would forbid
#       documenting the rule. The three forms that would actually bypass the gate
#       are a C `#include` by path, a Zig `@cInclude` by path, and a hand-written
#       `-I` flag — all three are matched, and all three were verified to FAIL
#       this script before it was trusted (see the note at the end of this file).
#   (b) GREPPED HERE TOO: the primary gate must actually be there — the compat
#       include path has to appear within a few lines of `if (is_wasm) {`.
#   (c) NOT GREPPABLE: that the second site (`makeWebModule`) is reached only for
#       a wasm target. Grep cannot see call nesting. It is proven by the native
#       build: `zig build` and `zig build test` in CI would either fail or change
#       behaviour if a compat header shadowed a system one. That is a weaker
#       guarantee than a grep, and it is stated here rather than implied.
# ---------------------------------------------------------------------------
R7_LEAK="$(rg -n --glob "$SOURCE_GLOB" \
  -e '#include[[:space:]]*"src/web/compat' \
  -e '@cInclude\([[:space:]]*"src/web/compat' \
  -e '-I[[:space:]]*src/web/compat' \
  src 2>/dev/null || true)"
if [ -n "$R7_LEAK" ]; then
  echo "R7 violated: a source file includes src/web/compat by path instead of through the gated include path" >&2
  printf '%s\n' "$R7_LEAK" >&2
  fail=1
fi

if [ -f build.zig ]; then
  R7_GATE="$(rg -n -A4 -e 'if \(is_wasm\) \{' build.zig 2>/dev/null | rg -e 'src/web/compat' || true)"
  if [ -z "$R7_GATE" ]; then
    echo "R7 violated: the compat include path is not inside an \`if (is_wasm)\` block" >&2
    fail=1
  fi
fi

# ---------------------------------------------------------------------------
# R8 — src/web/** is compiled for wasm, so it must stay freestanding.
#
# The property that makes the folder compilable at all: no blocking I/O, no
# filesystem, no threads. A browser has none of them, and `std.Io.Threaded` — the
# reactor `core/text_portable.zig` uses to probe font paths — cannot even be
# ANALYSED for a freestanding target, so a convenience call added here breaks the
# wasm build rather than failing at runtime.
#
# The pattern matches the CALL (`std.Io.Dir`, `std.fs.File`, `std.Thread.Mutex`,
# `std.process.exit`) and not a bare mention, for the same reason R6 does: these
# files legitimately discuss the rules in their headers — web/text.zig explains at
# length WHY a browser cannot use `std.Io` — and a rule that cannot tell a comment
# from a call would forbid explaining it.
#
# Scope note: this covers `src/web/**`, not `src/web_main.zig`. The entry point is
# where `std.heap.wasm_allocator` and `std_options` are named, so it is allowed
# `std.heap` — and it is small enough to read.
# ---------------------------------------------------------------------------
scan src/web "$SOURCE_GLOB" 'std\.(Io|fs|Thread|process)\.' \
  "R8 violated: src/web/** uses std.Io/std.fs/std.Thread/std.process, which has no meaning in a wasm module"

if [ "$fail" -ne 0 ]; then
  echo "layering: FAILED" >&2
  exit 1
fi
echo "layering: ok"
