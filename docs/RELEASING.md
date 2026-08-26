# Releasing

Steps to ship a version. Run each step in order.

## 1. Write the changelog

Edit `CHANGELOG.md`. Replace the `[Unreleased]` heading with the new version
and today's date. List the changes under it.

## 2. Set the version

```sh
scripts/release-set-version.sh X.Y.Z
```

This writes the version into `build.zig.zon`, `macos/Info.plist`, `win/app.rc`,
`CHANGELOG.md`, `Formula/keywise.rb`, `Casks/keywise-app.rb` and
`bucket/keywise.json`. It prints `ok` for each file.

## 3. Commit and push

```sh
git add -A
git commit -m "chore: bump version to X.Y.Z"
git push
```

Wait for `ci.yml` to finish on this push.

## 4. Update the artifact hashes

```sh
scripts/release-set-hashes.sh
```

The script reads SHA-256 hashes from the `reproducible-build` job in the latest
successful CI run on the current branch. It writes them into
`Formula/keywise.rb`, `Casks/keywise-app.rb` and `bucket/keywise.json`.

The script verifies that the CI run built the same commit as HEAD. Pass a run ID
as an argument to skip that check:

```sh
scripts/release-set-hashes.sh <run-id>
```

## 5. Commit and push the hashes

```sh
git add Formula/keywise.rb Casks/keywise-app.rb bucket/keywise.json
git commit -m "chore: point the formula and the cask at vX.Y.Z's hashes"
git push
```

Wait for CI to pass. The hash files do not change between this push and step 6,
so CI confirms the committed hashes still match.

## 6. Tag and push the tag

```sh
git tag vX.Y.Z
git push origin vX.Y.Z
```

`release.yml` runs on the tag push. It:

1. Runs `release-set-version.sh --check` against the tag. A file at the wrong
   version stops the release.
2. Builds and packages every artifact on a `macos-15` runner.
3. Compares the Formula and Cask SHA-256 hashes against the assets it built. A
   mismatch stops the release before the upload.
4. Creates the GitHub release and uploads the assets.

## 7. Verify

Check the release page. Download one artifact and compare its SHA-256 against
`SHA256SUMS` in the release.

## What can go wrong

**Hash mismatch in step 6.** The release runner's macOS SDK changed between the
CI run in step 4 and the release build. The `LC_UUID` in the Swift binary
depends on the installed SDK. Re-run CI on the same commit and update the hashes
again with step 4.

**Version check fails in step 6.** A file still holds the old version. Run
`release-set-version.sh --check X.Y.Z` locally to find it. Fix, commit, push,
delete the tag, and retag.
