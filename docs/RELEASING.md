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

## 2. Write the tag message

Write the tag message in a file. The text lands verbatim in the GitHub release
body. Use backticks for commands, flags, and file names. Use Markdown links
where useful.

Explain the key changes in short paragraphs. End with a link to the changelog
at that tag:
`[CHANGELOG.md](https://github.com/lkraider/keywise/blob/vX.Y.Z/CHANGELOG.md) lists every change.`

See `git show v2.3.0` for an example.

## 3. Run the release script

```sh
scripts/release.sh X.Y.Z tag-message.md
```

The script runs these steps:

1. `release-set-version.sh` writes the version into all tracked files.
2. Commits and pushes the version bump.
3. Waits for CI to finish on that commit.
4. `release-set-hashes.sh` collects CI artifact hashes into Formula, Cask,
   bucket, and port files. CI builds the source tarball and uploads it in
   the `release-hashes` artifact. The hashes in port distinfo come from
   that tarball.
5. Commits the hashes.
6. Creates the annotated tag from the message file.
7. Pushes branch and tag atomically.

`release.yml` triggers on the tag push. It downloads the CI source tarball
so the published asset matches the committed port hashes. It builds the
remaining artifacts, checks the committed hashes against them, and creates
the GitHub release.

## 4. Verify

Check the release page. Download one artifact and compare its SHA-256 against
`SHA256SUMS` in the release.

## 5. Submit the MacPorts update

```sh
scripts/release-macports-pr.sh
```

The script syncs the `lkraider/macports-ports` fork with upstream, copies
`ports/macports/Portfile` into a version-named branch, and opens a PR
against `macports/macports-ports`.

## What can go wrong

**Binary hash mismatch in the release workflow.** The release runner's macOS SDK
changed between the CI run and the release build. The `LC_UUID` in the Swift
binary depends on the installed SDK. Re-run CI on the same commit and update the
hashes again with `release-set-hashes.sh`.

**Source tarball hash mismatch.** The release workflow downloads the CI source
tarball and publishes it. If the CI `release-hashes` artifact expired or the
workflow cannot find the CI run, it falls back to `git archive`. That fallback
produces a different tarball because `git archive` embeds the commit SHA in a pax
global header. Re-run CI on the version-bump commit and update port hashes.

**Version check fails in the release workflow.** A file still holds the old
version. Run `release-set-version.sh --check X.Y.Z` locally to find it. Fix,
commit, push, delete the tag, and retag.

**Script fails mid-run.** Re-run the same command. Each step checks whether it
already completed and skips forward. To start a step over, delete the local tag
(`git tag -d vX.Y.Z`) and re-run.
