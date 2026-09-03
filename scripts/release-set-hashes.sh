#!/bin/sh
# Reads hashes from CI and writes them into every packaging file:
# Formula/, Casks/, bucket/ (binary hashes from the CI log) and
# ports/ (source + libvaxis hashes from the release-hashes artifact).
#
#   scripts/release-set-hashes.sh            latest successful CI on this branch
#   scripts/release-set-hashes.sh <run-id>   a specific CI run
#
# Needs the gh CLI with read access to the repository.
set -eu

cd "$(cd "$(dirname "$0")/.." && pwd)"

edit() { sed "$2" "$1" > "$1.tmp" && mv "$1.tmp" "$1"; }

if [ $# -gt 0 ]; then
    run_id="$1"
else
    run_id=$(gh run list --workflow ci.yml --branch "$(git branch --show-current)" \
        --limit 5 --json databaseId,status,conclusion \
        --jq '[.[] | select(.status == "completed" and .conclusion == "success")][0].databaseId')
    [ -n "$run_id" ] || { echo "no successful CI run on this branch" >&2; exit 1; }

    run_commit=$(gh run view "$run_id" --json headSha --jq '.headSha')
    head_commit=$(git rev-parse HEAD)
    if [ "$run_commit" != "$head_commit" ]; then
        printf "CI run built %.7s, HEAD is %.7s\n" "$run_commit" "$head_commit" >&2
        echo "push first, then wait for CI to finish" >&2
        exit 1
    fi
fi

echo "CI run $run_id"

# --- binary hashes from CI log ---

job_id=$(gh run view "$run_id" --json jobs \
    --jq '.jobs[] | select(.name == "reproducible-build") | .databaseId')
[ -n "$job_id" ] || { echo "no reproducible-build job in run $run_id" >&2; exit 1; }

hashes=$(gh run view "$run_id" --log --job "$job_id" 2>/dev/null \
    | grep "Compare" | grep -oE '[0-9a-f]{64}  [^ ]+' | sort -u -k2,2)

pick() { echo "$hashes" | awk -v pat="$1" '$2 ~ pat {print $1; exit}'; }

tar_hash=$(pick 'keywise-aarch64-macos\.tar\.gz$')
app_hash=$(pick '-macos\.zip$')
win_x64=$(pick '-windows-x86_64\.zip$')
win_arm=$(pick '-windows-arm64\.zip$')

for v in "$tar_hash" "$app_hash" "$win_x64" "$win_arm"; do
    [ -n "$v" ] || { echo "could not parse all hashes from CI log" >&2; exit 1; }
done

edit Formula/keywise.rb \
    "s/sha256 \"[0-9a-f]*\"/sha256 \"$tar_hash\"/"

edit Casks/keywise-app.rb \
    "s/sha256 \"[0-9a-f]*\"/sha256 \"$app_hash\"/"

awk -v x64="$win_x64" -v arm="$win_arm" '
    /"hash":/ && !done_x64 { sub(/"hash": "[0-9a-f]+"/, "\"hash\": \"" x64 "\""); done_x64=1 }
    /"hash":/ && done_x64 && !done_arm { sub(/"hash": "[0-9a-f]+"/, "\"hash\": \"" arm "\""); done_arm=1 }
    { print }
' bucket/keywise.json > bucket/keywise.json.tmp && mv bucket/keywise.json.tmp bucket/keywise.json

echo "Formula/keywise.rb        $tar_hash"
echo "Casks/keywise-app.rb      $app_hash"
echo "bucket/keywise.json x64   $win_x64"
echo "bucket/keywise.json arm   $win_arm"

# --- port hashes from CI artifact ---

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

gh run download "$run_id" -n release-hashes -D "$tmpdir"

# CI writes KEY=VALUE pairs with the src_ and lv_ prefixes.
. "$tmpdir/src-hashes.env"
. "$tmpdir/lv-hashes.env"

version=$(sed -n 's/^ *\.version = "\([^"]*\)".*/\1/p' build.zig.zon)
lv_hash=$(sed -n '/\.libvaxis/,/}/{s/^ *\.hash = "\([^"]*\)".*/\1/p;}' build.zig.zon)

cat > ports/freebsd/distinfo <<EOF
TIMESTAMP = $(date +%s)
SHA256 (zig/keywise-${version}-source.tar.gz) = ${src_sha256}
SIZE (zig/keywise-${version}-source.tar.gz) = ${src_size}
SHA256 (zig/${lv_commit}.tar.gz) = ${lv_sha256}
SIZE (zig/${lv_commit}.tar.gz) = ${lv_size}
EOF

cat > ports/openbsd/distinfo <<EOF
SHA256 (keywise-${version}-source.tar.gz) = ${src_sha256_b64}
SIZE (keywise-${version}-source.tar.gz) = ${src_size}
SHA256 (${lv_commit}.tar.gz) = ${lv_sha256_b64}
SIZE (${lv_commit}.tar.gz) = ${lv_size}
EOF

edit ports/freebsd/Makefile \
    "s|ZIG_TUPLE=.*|ZIG_TUPLE=\tlibvaxis:github.com/rockorager/libvaxis/archive/${lv_commit}.tar.gz:${lv_hash}|"
edit ports/openbsd/Makefile \
    "s/^\(LV_COMMIT =[[:space:]]*\).*/\1${lv_commit}/"
edit ports/openbsd/Makefile \
    "s/^\(LV_HASH =[[:space:]]*\).*/\1${lv_hash}/"
edit ports/macports/Portfile \
    "s/^set lv_commit.*/set lv_commit       ${lv_commit}/"
edit ports/macports/Portfile \
    "s/^set lv_hash.*/set lv_hash         ${lv_hash}/"

awk -v src_name='${distname}${extract.suffix}' \
    -v src_rmd="$src_rmd160" -v src_sha="$src_sha256" -v src_sz="$src_size" \
    -v lv_name='${lv_commit}.tar.gz' \
    -v lv_rmd="$lv_rmd160" -v lv_sha="$lv_sha256" -v lv_sz="$lv_size" '
/^checksums/ {
    printf "checksums           %s \\\n", src_name
    printf "                    rmd160  %s \\\n", src_rmd
    printf "                    sha256  %s \\\n", src_sha
    printf "                    size    %s \\\n", src_sz
    printf "                    %s \\\n", lv_name
    printf "                    rmd160  %s \\\n", lv_rmd
    printf "                    sha256  %s \\\n", lv_sha
    printf "                    size    %s\n", lv_sz
    if ($0 ~ /\\[[:space:]]*$/) {
        while ((getline line) > 0 && line ~ /\\[[:space:]]*$/) {}
    }
    next
}
{ print }
' ports/macports/Portfile > ports/macports/Portfile.tmp \
        && mv ports/macports/Portfile.tmp ports/macports/Portfile

echo "ports/freebsd/distinfo    updated"
echo "ports/openbsd/distinfo    updated"
echo "ports/macports/Portfile   checksums updated"
