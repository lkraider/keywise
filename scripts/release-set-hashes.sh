#!/bin/sh
# Reads SHA-256 hashes from CI's reproducible-build job and writes them into
# Formula/keywise.rb, Casks/keywise-app.rb and bucket/keywise.json.
#
#   scripts/release-set-hashes.sh            latest successful CI on this branch
#   scripts/release-set-hashes.sh <run-id>   a specific CI run
#
# Needs the gh CLI with read access to the repository.
set -eu

cd "$(cd "$(dirname "$0")/.." && pwd)"

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

job_id=$(gh run view "$run_id" --json jobs \
    --jq '.jobs[] | select(.name == "reproducible-build") | .databaseId')
[ -n "$job_id" ] || { echo "no reproducible-build job in run $run_id" >&2; exit 1; }

# The Compare step prints each archive's hash twice (one per build).
# Extract hash-filename pairs and deduplicate by filename.
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

edit() { sed "$2" "$1" > "$1.tmp" && mv "$1.tmp" "$1"; }

edit Formula/keywise.rb \
    "s/sha256 \"[0-9a-f]*\"/sha256 \"$tar_hash\"/"

edit Casks/keywise-app.rb \
    "s/sha256 \"[0-9a-f]*\"/sha256 \"$app_hash\"/"

# The two hashes appear in file order: 64bit first, arm64 second.
awk -v x64="$win_x64" -v arm="$win_arm" '
    /"hash":/ && !done_x64 { sub(/"hash": "[0-9a-f]+"/, "\"hash\": \"" x64 "\""); done_x64=1 }
    /"hash":/ && done_x64 && !done_arm { sub(/"hash": "[0-9a-f]+"/, "\"hash\": \"" arm "\""); done_arm=1 }
    { print }
' bucket/keywise.json > bucket/keywise.json.tmp && mv bucket/keywise.json.tmp bucket/keywise.json

echo "Formula/keywise.rb        $tar_hash"
echo "Casks/keywise-app.rb      $app_hash"
echo "bucket/keywise.json x64   $win_x64"
echo "bucket/keywise.json arm   $win_arm"

# -- Port distinfo and checksums --

version=$(sed -n 's/^ *\.version = "\([^"]*\)".*/\1/p' build.zig.zon)
lv_commit=$(sed -n 's/.*#\([0-9a-f]\{40\}\)".*/\1/p' build.zig.zon)
lv_hash=$(sed -n '/\.libvaxis/,/}/{s/^ *\.hash = "\([^"]*\)".*/\1/p;}' build.zig.zon)

for v in "$version" "$lv_commit" "$lv_hash"; do
    [ -n "$v" ] || { echo "could not parse build.zig.zon" >&2; exit 1; }
done

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

src_file="$tmpdir/src.tar.gz"
lv_file="$tmpdir/lv.tar.gz"

curl -fsSL "https://github.com/lkraider/keywise/archive/refs/tags/v${version}.tar.gz" \
    -o "$src_file" || { echo "could not download source tarball for v${version}" >&2; exit 1; }
curl -fsSL "https://github.com/rockorager/libvaxis/archive/${lv_commit}.tar.gz" \
    -o "$lv_file" || { echo "could not download libvaxis tarball" >&2; exit 1; }

src_sha256=$(shasum -a 256 "$src_file" | cut -d' ' -f1)
src_size=$(stat -f%z "$src_file")
lv_sha256=$(shasum -a 256 "$lv_file" | cut -d' ' -f1)
lv_size=$(stat -f%z "$lv_file")

src_rmd160=$(openssl dgst -rmd160 "$src_file" | awk '{print $NF}')
lv_rmd160=$(openssl dgst -rmd160 "$lv_file" | awk '{print $NF}')

src_sha256_b64=$(openssl dgst -sha256 -binary "$src_file" | openssl base64 -A)
lv_sha256_b64=$(openssl dgst -sha256 -binary "$lv_file" | openssl base64 -A)

# FreeBSD distinfo
fb_src="lkraider-keywise-${version}_GH0.tar.gz"
cat > ports/freebsd/distinfo <<EOF
TIMESTAMP = $(date +%s)
SHA256 (zig/${fb_src}) = ${src_sha256}
SIZE (zig/${fb_src}) = ${src_size}
SHA256 (zig/${lv_commit}.tar.gz) = ${lv_sha256}
SIZE (zig/${lv_commit}.tar.gz) = ${lv_size}
EOF

# OpenBSD distinfo (base64-encoded SHA256)
cat > ports/openbsd/distinfo <<EOF
SHA256 (keywise-${version}.tar.gz) = ${src_sha256_b64}
SIZE (keywise-${version}.tar.gz) = ${src_size}
SHA256 (${lv_commit}.tar.gz) = ${lv_sha256_b64}
SIZE (${lv_commit}.tar.gz) = ${lv_size}
EOF

# Update libvaxis commit and hash in port Makefiles
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

# MacPorts checksums
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
