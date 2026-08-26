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
