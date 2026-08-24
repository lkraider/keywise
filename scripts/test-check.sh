#!/usr/bin/env bash
set -eo pipefail

ZIG="${ZIG:-zig}"
cd "$(dirname "$0")/.."

no_oracle=false
steps=()
for arg in "$@"; do
    case "$arg" in
        --no-oracle) no_oracle=true ;;
        *) steps+=("$arg") ;;
    esac
done

authored=$(find core/ tui/ win/ -name '*.zig' -exec grep -c '^test[ "{]' {} + \
    | awk -F: '{sum += $NF} END {print sum}')

if [ "$no_oracle" = true ]; then
    oracle_count=$(grep -c '^test[ "{]' core/test/oracle.zig)
    authored=$((authored - oracle_count))
fi

output=$("$ZIG" build test "${steps[@]}" --summary line -Dtest-run-always 2>&1) || true

clause=$(echo "$output" | grep -oE '[0-9]+/[0-9]+ tests passed' || true)
if [ -z "$clause" ]; then
    echo "FAIL: no 'tests passed' clause in the build summary" >&2
    echo "$output" >&2
    exit 1
fi

passed=$(echo "$clause" | cut -d/ -f1)
total=$(echo "$clause" | cut -d/ -f2 | cut -d' ' -f1)

if [ "$passed" != "$total" ]; then
    echo "FAIL: $passed of $total tests passed" >&2
    echo "$output" >&2
    exit 1
fi

if [ "$total" != "$authored" ]; then
    echo "FAIL: ran $total tests, authored $authored" >&2
    exit 1
fi

if echo "$output" | grep -qi 'skipped'; then
    echo "FAIL: tests were skipped" >&2
    echo "$output" >&2
    exit 1
fi

echo "OK: $total/$authored tests passed"
