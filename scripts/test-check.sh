#!/usr/bin/env bash
set -eo pipefail

ZIG="${ZIG:-zig}"
cd "$(dirname "$0")/.."

no_oracle=false
steps=()
for arg in "$@"; do
    case "$arg" in
        --no-oracle) no_oracle=true; steps+=("-Doracle=false") ;;
        *) steps+=("$arg") ;;
    esac
done

# -- Formatting --

find core/src tui/src win/src -name '*.zig' | xargs "$ZIG" fmt --check

# -- Coverage: every file with tests must be reachable from a test root --

roots=$(mktemp)
reachable=$(mktemp)
trap 'rm -f "$roots" "$reachable" "${reachable}.snap"' EXIT

cat > "$roots" <<'ROOTS'
core/src/tests.zig
tui/src/args.zig
win/src/args.zig
core/src/export.zig
tui/src/model.zig
win/src/model.zig
win/src/ids.zig
win/src/text.zig
ROOTS
if [ "$no_oracle" = false ]; then
    echo "core/test/oracle.zig" >> "$roots"
fi

# Every root path must appear as a quoted string in build.zig.
while IFS= read -r root; do
    if ! grep -qF "\"$root\"" build.zig; then
        echo "FAIL: test root $root is listed in test-check.sh but missing from build.zig" >&2
        exit 1
    fi
done < "$roots"

cp "$roots" "$reachable"

# BFS: follow @import("file.zig") from each root. Named module imports
# (@import("core"), @import("std")) contain no dot and the regex skips them.
changed=true
while [ "$changed" = true ]; do
    changed=false
    cp "$reachable" "${reachable}.snap"
    while IFS= read -r file; do
        [ -f "$file" ] || continue
        dir=$(dirname "$file")
        for imp in $(grep -oE '@import\("[^"]+\.zig"\)' "$file" 2>/dev/null \
            | sed 's/@import("//;s/")//'); do
            resolved="$dir/$imp"
            [ -f "$resolved" ] || continue
            if ! grep -qxF "$resolved" "$reachable"; then
                echo "$resolved" >> "$reachable"
                changed=true
            fi
        done
    done < "${reachable}.snap"
done

# Derive search directories from the reachable set.
search_dirs=""
while IFS= read -r f; do
    d=$(dirname "$f")
    case " $search_dirs " in
        *" $d "*) ;;
        *) search_dirs="$search_dirs $d" ;;
    esac
done < "$reachable"

# Every .zig file with test blocks must appear in the reachable set.
# Also count the authored tests for the floor check below.
authored=0
gaps=""
while IFS=: read -r file count; do
    [ "$count" -gt 0 ] || continue
    if grep -qxF "$file" "$reachable"; then
        authored=$((authored + count))
    else
        gaps="${gaps}  ${file} (${count} tests)"$'\n'
    fi
done < <(find $search_dirs -name '*.zig' -exec grep -c '^test[ "{]' {} +)

if [ -n "$gaps" ]; then
    printf "FAIL: test files not compiled by any test root:\n%s" "$gaps" >&2
    exit 1
fi

# -- Run tests --

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

if echo "$output" | grep -qi 'skipped'; then
    echo "FAIL: tests were skipped" >&2
    echo "$output" >&2
    exit 1
fi

# The runner executes tests from transitively imported files in each
# binary, so its total is always >= the authored count. A drop below
# that floor means a test binary disappeared from the build.
if [ "$total" -lt "$authored" ]; then
    echo "FAIL: runner executed $total tests but $authored are authored in the source" >&2
    exit 1
fi

echo "OK: $total tests passed, $authored authored"
