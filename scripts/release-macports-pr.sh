#!/bin/sh
# Opens a PR against macports/macports-ports with the current Portfile.
#
#   scripts/macports-pr.sh
#
# Reads the version from ports/macports/Portfile. Syncs the fork's master
# with upstream, creates a branch, copies the Portfile, commits, and
# opens the PR.
#
# Requires the gh CLI with push access to the fork.
set -eu

cd "$(cd "$(dirname "$0")/.." && pwd)"

fork=lkraider/macports-ports
upstream=macports/macports-ports
portfile=ports/macports/Portfile
dest=security/keywise/Portfile

version=$(sed -n 's/^github\.setup.*keywise \([^ ]*\) v/\1/p' "$portfile")
[ -n "$version" ] || { echo "cannot read version from $portfile" >&2; exit 1; }

branch="keywise-${version}"

existing=$(gh pr list --repo "$upstream" --head "$fork:$branch" \
    --json number --jq '.[0].number' 2>/dev/null || true)
if [ -n "$existing" ]; then
    echo "PR already open: https://github.com/$upstream/pull/$existing"
    exit 0
fi

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

echo "==> cloning fork"
gh repo sync "$fork" --branch master 2>/dev/null || true
git clone --depth 1 "git@github.com:${fork}.git" "$tmpdir/repo"

echo "==> creating branch $branch"
git -C "$tmpdir/repo" checkout -b "$branch"

mkdir -p "$tmpdir/repo/security/keywise"
cp "$portfile" "$tmpdir/repo/$dest"

git -C "$tmpdir/repo" add "$dest"
git -C "$tmpdir/repo" commit -m "keywise: update to ${version}"

echo "==> pushing"
git -C "$tmpdir/repo" push -u origin "$branch"

echo "==> opening PR"
gh pr create --repo "$upstream" --head "${fork%%/*}:${branch}" \
    --title "keywise: update to ${version}" \
    --body "$(cat <<EOF
#### Description
Update [keywise](https://github.com/lkraider/keywise) to ${version}.

###### Type(s)
- [ ] bugfix
- [x] enhancement
- [ ] security fix

###### Verification
Have you

- [x] followed our [Commit Message Guidelines](https://trac.macports.org/wiki/CommitMessages)?
- [x] squashed and [minimized your commits](https://guide.macports.org/#project.github)?
- [x] checked that there aren't other open [pull requests](https://github.com/macports/macports-ports/pulls) for the same change?
- [ ] referenced existing tickets on [Trac](https://trac.macports.org/wiki/Tickets) with full URL in commit message?
- [x] checked your Portfile with \`port lint\`?
- [ ] tried existing tests with \`sudo port test\`?
- [x] tried a full install with \`sudo port -vst install\`?
- [x] tested basic functionality of all binary files?
- [ ] checked that the Portfile's most important [variants](https://trac.macports.org/wiki/Variants) haven't been broken?
EOF
)"
