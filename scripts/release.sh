#!/bin/sh
set -eu

version="${1:?usage: release.sh <version> <tag-message-file>}"
tag="v${version}"
message_file="$(cd "$(dirname "${2:?usage: release.sh <version> <tag-message-file>}")" && pwd)/$(basename "$2")"

cd "$(cd "$(dirname "$0")/.." && pwd)"

[ -f "$message_file" ] || { echo "file not found: $message_file" >&2; exit 1; }

echo "==> setting version to ${version}"
scripts/release-set-version.sh "$version"

if ! git diff --quiet || ! git diff --cached --quiet; then
    git add -u
    git commit -m "chore: bump version to ${version}"
fi

if [ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main 2>/dev/null)" ]; then
    echo "==> pushing"
    git push
fi

echo "==> waiting for CI"
head_sha=$(git rev-parse HEAD)
run_id=""
attempts=0
while [ -z "$run_id" ]; do
    run_id=$(gh run list --workflow ci.yml --commit "$head_sha" \
        --limit 1 --json databaseId --jq '.[0].databaseId' 2>/dev/null || true)
    if [ -z "$run_id" ]; then
        attempts=$((attempts + 1))
        [ "$attempts" -lt 30 ] || { echo "CI did not start after 5 minutes" >&2; exit 1; }
        printf "  waiting for CI on %.7s (%s/30)\n" "$head_sha" "$attempts"
        sleep 10
    fi
done
gh run watch "$run_id" --exit-status

echo "==> collecting CI hashes"
scripts/release-set-hashes.sh "$run_id"

if ! git diff --quiet Formula/ Casks/ bucket/; then
    git add Formula/ Casks/ bucket/
    git commit -m "chore: update hashes for ${tag}"
fi

if ! git tag -l "$tag" | grep -q .; then
    echo "==> tagging ${tag}"
    git tag -a "$tag" -F "$message_file"
fi

echo "==> pushing ${tag}"
git push --atomic origin main "$tag"

echo "==> collecting port distinfo"
scripts/release-set-hashes.sh ports

if ! git diff --quiet ports/; then
    git add ports/
    git commit -m "chore: update port distinfo for ${tag}"
    git push
fi

echo "https://github.com/lkraider/keywise/releases/tag/${tag}"
