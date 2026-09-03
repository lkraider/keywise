# Releasing

Steps to ship a version. Run each step in order.

## 1. Write the changelog

Edit `CHANGELOG.md`. Replace the `[Unreleased]` heading with the new version
and today's date. List the changes under it. Add the `[Unreleased]` heading
first if it is missing.

Group entries under `### Fixed`, `### Added`, and `### Changed`.

Each entry describes the effect a user, packager, or contributor sees. Lead with
what was wrong or what is new. Keep implementation details (function names, data
structures, writer types) out of the first sentence. Add them in a second
sentence when a contributor needs them to find the relevant code.

Good: "A search that ran out of memory on Windows showed no feedback. The status
bar reports the failure now."

Too internal: "`setStatus` in the Win32 model used `bufPrint` and returned the
full buffer length on overflow. It uses a truncating writer now."

Use `### Changed` for internal refactors that alter the code a contributor reads,
even when a user sees no difference. State what the code looks like now.

## 2. Set the version

```sh
scripts/release-set-version.sh X.Y.Z
```

This writes the version into `build.zig.zon`, `macos/Info.plist`, `win/app.rc`,
`CHANGELOG.md`, `Formula/keywise.rb`, `Casks/keywise-app.rb`,
`bucket/keywise.json`, and the three port files under `ports/`. It prints `ok`
for each file.

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
`Formula/keywise.rb`, `Casks/keywise-app.rb`, and `bucket/keywise.json`.

It also downloads the source and libvaxis tarballs, computes their checksums,
and writes `ports/freebsd/distinfo`, `ports/openbsd/distinfo`, and the
MacPorts `checksums` block in `ports/macports/Portfile`.

The script verifies that the CI run built the same commit as HEAD. Pass a run ID
as an argument to skip that check:

```sh
scripts/release-set-hashes.sh <run-id>
```

## 5. Commit and push the hashes

```sh
git add Formula/ Casks/ bucket/ ports/
git commit -m "chore: update hashes for vX.Y.Z"
git push
```

Wait for CI to pass. The hash files do not change between this push and step 6,
so CI confirms the committed hashes still match.

## 6. Tag and push the tag

Write the tag message in Markdown. It lands verbatim in the GitHub release
body. Use backticks for commands, flags, and file names. Use Markdown links
where useful.

Explain the key changes in short paragraphs. End with a link to the
changelog at that tag:
`[CHANGELOG.md](https://github.com/lkraider/keywise/blob/vX.Y.Z/CHANGELOG.md) lists every change.`

See `git tag -v v2.3.0` for an example.

```sh
git tag -a vX.Y.Z
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
