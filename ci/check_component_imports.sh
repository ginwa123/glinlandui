#!/usr/bin/env bash
# The component façade gate. See src/core/component.zig and src/README.md §"The public surface".
#
# A widget is reached ONE way: through `src/core/component.zig`. That is the module an app gets as
# `glinlandui.components`, and it is the list of what the toolkit can draw. There are three ways to
# break the rule, and each one has a rule here:
#
#   C1  a file outside src/core/components/ imports components/<name>.zig directly
#       (a `*_test.zig` beside a component is that component's TEST file, not a widget, so a suite
#        may still import it)
#   C2  a component in the folder is missing from the façade (so an app cannot reach it at all)
#   C3  a component in the folder imports the façade, which is a loop back into itself
#
# Rule C2 is what makes the façade a LIST rather than a best effort: a new widget that nobody
# exports is invisible to every app, and nothing else in the repo would notice.
set -euo pipefail
fail=0

SOURCE_GLOB='*.zig'

# Which search tool to use: `rg` when present, `grep -rE` otherwise, exactly like check_layering.sh.
if command -v rg >/dev/null 2>&1; then
  HAVE_RG=1
else
  HAVE_RG=0
  echo "component-imports: note: ripgrep not found; falling back to grep -rE" >&2
fi

search() {
  local path="$1" pattern="$2"
  if [ "$HAVE_RG" = "1" ]; then
    rg -n --glob "$SOURCE_GLOB" -e "$pattern" "$path" 2>/dev/null || true
  else
    grep -rnE --include='*.zig' -e "$pattern" "$path" 2>/dev/null || true
  fi
}

# ---- C1: no import may name a file in the folder from outside it ----------------------------------
# The façade itself is the one importer that is allowed to: importing is its whole job.
matches="$(search src '@import\("[^"]*components/[a-z_0-9]+\.zig"\)' | grep -v '^src/core/components/' | grep -v '^src/core/component\.zig:' | grep -v 'components/[a-z_0-9]*_test\.zig' || true)"
if [ -n "$matches" ]; then
  echo "component-imports: C1 — a component must be imported from src/core/component.zig, not by file:" >&2
  printf '%s\n' "$matches" >&2
  fail=1
fi
# The examples get the toolkit as a module, so the same rule is expressed as a file path.
matches="$(search examples '@import\("[^"]*core/components/[a-z_0-9]+\.zig"\)' | grep -v '_test\.zig' || true)"
if [ -n "$matches" ]; then
  echo "component-imports: C1 — an example must use the module (glinlandui.components), not a core file:" >&2
  printf '%s\n' "$matches" >&2
  fail=1
fi

# ---- C2: every component in the folder is exported by the façade ----------------------------------
for file in src/core/components/*.zig; do
  name="$(basename "$file" .zig)"
  # A test file is not a component: it is the tests of one, and it has no business in the façade.
  case "$name" in
    *_test) continue ;;
  esac
  if ! grep -q "pub const ${name} = @import(\"components/${name}.zig\");" src/core/component.zig; then
    echo "component-imports: C2 — ${file} is not exported by src/core/component.zig" >&2
    fail=1
  fi
done

# ---- C3: a component must not import the façade (a loop through it) -------------------------------
matches="$(search src/core/components '@import\("(\.\./)?component\.zig"\)' || true)"
if [ -n "$matches" ]; then
  echo "component-imports: C3 — a component may not import the façade; import the sibling you need:" >&2
  printf '%s\n' "$matches" >&2
  fail=1
fi

if [ "$fail" = "0" ]; then
  echo "component-imports: ok ($(ls src/core/components/*.zig | grep -vc '_test\.zig$') component(s) through the façade)"
fi
exit "$fail"
