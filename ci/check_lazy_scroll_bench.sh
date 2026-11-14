#!/usr/bin/env bash
# Gate the lazy-scroll benchmark: the WORK must be identical on every CI platform, and the TIMINGS must fit one shared budget.
#
# The bench itself is headless (`--bench`, no window, no vsync), so the same binary runs on Linux, macOS and Windows and reports the same kind of number.
# What it must also report is the same *amount* of work: rows, frames, size, scale, how many rows were declared, and the offset the run ended at. Those
# are comparable across platforms because the scroll path is driven by the frame count, not by the wall clock. Timing is not comparable, which is why it
# is checked against a ceiling rather than against another platform's number.
#
# Usage: ci/check_lazy_scroll_bench.sh <bench-log> [expected-file]
# The expected file defaults to ci/lazy_scroll_bench.expected.
set -euo pipefail

log="${1:-}"
expected="${2:-$(dirname "$0")/lazy_scroll_bench.expected}"

if [ -z "$log" ] || [ ! -f "$log" ]; then
    echo "usage: $0 <bench-log> [expected-file]" >&2
    exit 2
fi
if [ ! -f "$expected" ]; then
    echo "missing expected file: $expected" >&2
    exit 2
fi

fail() {
    echo "::error::$*"
    echo "RESULT: FAIL — $*"
    exit 1
}

# The one machine-readable line the example prints at the end of `bench()`. CRLF is stripped so a Windows log parses like the other two.
line="$(tr -d '\r' <"$log" | grep -m1 '^BENCH ' || true)"
if [ -z "$line" ]; then
    echo "--- bench log ---"
    tr -d '\r' <"$log"
    echo "-----------------"
    fail "no 'BENCH ' line in $log (the example did not reach the end of bench())"
fi

# One value out of that line, by key.
get() {
    printf '%s\n' "$line" | tr ' ' '\n' | sed -n "s/^$1=//p" | head -n1
}

# Float comparison, so a budget can be written as 12.00 and compared with 11.999.
le() {
    awk -v a="$1" -v b="$2" 'BEGIN { exit !(a + 0 <= b + 0) }'
}

echo "LAZY-SCROLL BENCH GATE"
echo "  host:     $(uname -s) $(uname -m)"
echo "  bench:    $line"
echo

status=0

# ---- the work: must match the expected file exactly ----
echo "  work (identical on every platform):"
for key in rows frames size scale declared scroll_y; do
    want="$(sed -n "s/^$key=//p" "$expected" | head -n1)"
    got="$(get "$key")"
    if [ -z "$want" ]; then
        fail "$key is missing from $expected"
    fi
    if [ -z "$got" ]; then
        fail "$key is missing from the BENCH line"
    fi
    if [ "$got" != "$want" ]; then
        echo "    $key: got '$got', expected '$want'  MISMATCH"
        status=1
    else
        echo "    $key: $got  OK"
    fi
done

# ---- the timing: must fit the budget, not match another machine ----
echo
echo "  timing (ceiling for a shared runner, not a speed target):"
budget_avg="$(sed -n 's/^budget_avg_ms=//p' "$expected" | head -n1)"
budget_p95="$(sed -n 's/^budget_p95_ms=//p' "$expected" | head -n1)"
avg="$(get avg_ms)"
p95="$(get p95_ms)"
max="$(get max_ms)"

if [ -z "$avg" ] || [ -z "$p95" ]; then
    fail "avg_ms / p95_ms missing from the BENCH line"
fi

if le "$avg" "$budget_avg"; then
    echo "    avg_ms: $avg <= $budget_avg  OK"
else
    echo "    avg_ms: $avg > $budget_avg  OVER BUDGET"
    status=1
fi

if le "$p95" "$budget_p95"; then
    echo "    p95_ms: $p95 <= $budget_p95  OK"
else
    echo "    p95_ms: $p95 > $budget_p95  OVER BUDGET"
    status=1
fi

# Reported, never gated: a single slow frame on a shared runner is scheduler noise, and failing on it teaches nobody anything.
echo "    max_ms: $max  (reported, not gated)"
echo

if [ "$status" -ne 0 ]; then
    fail "the bench no longer does the same work, or no longer fits the budget"
fi

echo "RESULT: PASS"
