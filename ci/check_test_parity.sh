#!/usr/bin/env bash
# Cross-platform test-count parity gate.
#
# `zig build test` compiles a FIXED, platform-independent set of test roots
# (see src/root.zig), so Linux and macOS must report the SAME total. This
# script extracts the total from `zig build test --summary all` output and
# compares it against tests.lock.
#
# If a test is added or removed, this fails on BOTH platforms until the lock
# is updated in the same commit — that is what makes parity enforced in CI
# rather than assumed.
set -euo pipefail

EXPECTED="$(tr -d '[:space:]' < tests.lock)"
OUT="$(zig build test --summary all 2>&1)"
echo "$OUT" | grep -E "tests passed" || true

# `zig build --summary all` appends a ` (N skipped)` suffix when any test
# opted out (e.g. the glyph tests no-op without an installed font), so the
# total must be read with a trailing-anything match. The captured group is the
# TOTAL, not the pass count: tests.lock locks the size of the test set, and a
# skip is a legitimate outcome of the same set.
ACTUAL="$(printf '%s' "$OUT" | sed -nE 's#^Build Summary: [0-9]+/[0-9]+ steps succeeded; ([0-9]+)/([0-9]+) tests passed.*$#\2#p' | head -n1)"

if [ -z "$ACTUAL" ]; then
  echo "parity: could not parse test count from build summary" >&2
  printf '%s\n' "$OUT" >&2
  exit 1
fi

if [ "$ACTUAL" != "$EXPECTED" ]; then
  echo "parity: test count $ACTUAL != expected $EXPECTED (tests.lock)" >&2
  echo "update tests.lock in the same commit that changes the test set" >&2
  exit 1
fi

echo "parity: $ACTUAL tests (matches tests.lock)"
