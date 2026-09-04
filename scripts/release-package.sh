#!/bin/sh
# Builds and packages the release artifacts: the TUI binary, the macOS app,
# and the Windows app for both architectures.
#
# release.yml runs this to build what a release publishes. CI runs it
# twice on separate runners and diffs the output. Every setting below
# that exists to keep the bytes stable is explained in
# docs/REPRODUCIBLE.md.
#
# The cross builds start first and run beside the macOS chain. Each gets its
# own cache directory and install prefix, so it reads no artifact of the
# others and leaves zig-out to the macOS build. Those two flags change no byte
# of the exe.
set -eu

version="${1:?usage: release-package.sh <version> <output-dir>}"
out="${2:?usage: release-package.sh <version> <output-dir>}"
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
zig_version="${ZIG_VERSION:-0.16.0}"
zig="$repo_root/zig/zig-aarch64-macos-${zig_version}/zig"
mkdir -p "$out"
out="$(cd "$out" && pwd)"

# Every archive below stamps its members with this instant. The trailing Z
# makes touch read it as UTC, and tar stores an absolute epoch.
# macos/scripts/bundle.sh repeats this value for the .app.
mtime=2026-01-01T00:00:00Z

# ReleaseSafe keeps the bounds, alignment and overflow checks. sqlitedb.zig
# reads every offset in key4.db out of the file itself, and logins.json and
# the SDR blobs arrive the same way. A bad offset panics under these checks.
# ReleaseSmall drops the checks and writes a Windows zip 81 KB smaller.
cross_jobs=""
for pair in "x86_64-windows-gnu win-x86_64" "aarch64-windows-gnu win-arm64" \
            "x86_64-linux-musl linux-x86_64" "aarch64-linux-musl linux-arm64"; do
    set -- $pair
    (cd "$repo_root" && "$zig" build -Dtarget="$1" -Doptimize=ReleaseSafe \
        --cache-dir ".zig-cache-$2" -p "out-$2") > "$repo_root/build-$2.log" 2>&1 &
    cross_jobs="$cross_jobs $!:$2"
done

(cd "$repo_root" && "$zig" build -Doptimize=ReleaseSafe)

# ustar cannot carry an extended attribute. bsdtar's default format can, and
# adds a ._name AppleDouble member for it, so the archive would depend on
# whether this macOS release attaches com.apple.provenance to a fresh binary.
# docs/REPRODUCIBLE.md has the sums.
touch -d "$mtime" "$repo_root/zig-out/bin/keywise"
tar --format ustar --numeric-owner --uid 0 --gid 0 -cf - -C "$repo_root/zig-out/bin" keywise \
    | gzip -n -9 > "$out/keywise-aarch64-macos.tar.gz"

# ditto and zip store the MS-DOS timestamp field. That field holds wall-clock
# time, and each program reads TZ to convert an mtime into it.
(cd "$repo_root/macos" && ./scripts/bundle.sh release)
TZ=UTC ditto -c -k --keepParent \
    "$repo_root/macos/.build/release/Keywise.app" \
    "$out/Keywise-${version}-macos.zip"

status=0
for job in $cross_jobs; do
    wait "${job%%:*}" || status=1
    echo "--- ${job#*:}"
    cat "$repo_root/build-${job#*:}.log"
done
[ "$status" -eq 0 ] || exit 1

# -X drops the UT extra field. That field carries the mtime as a UTC epoch, so
# it moves whenever the stamp does.
for arch in x86_64 arm64; do
    exe="$repo_root/out-win-$arch/bin/Keywise.exe"
    touch -d "$mtime" "$exe"
    rm -f "$out/Keywise-${version}-windows-$arch.zip"
    (cd "$(dirname "$exe")" && TZ=UTC zip -X -q -9 \
        "$out/Keywise-${version}-windows-$arch.zip" Keywise.exe)
done

# tui_mod links no C library, so the musl target writes a static binary. It
# runs on any distro.
for pair in "linux-x86_64 x86_64" "linux-arm64 aarch64"; do
    set -- $pair
    bin="$repo_root/out-$1/bin/keywise"
    touch -d "$mtime" "$bin"
    tar --format ustar --numeric-owner --uid 0 --gid 0 -cf - -C "$(dirname "$bin")" keywise \
        | gzip -n -9 > "$out/keywise-$2-linux.tar.gz"
done

src="$out/keywise-${version}-source.tar.gz"
if [ ! -f "$src" ]; then
    git archive --format=tar --prefix="keywise-${version}/" \
        --worktree-attributes HEAD | gzip -n > "$src"
fi
