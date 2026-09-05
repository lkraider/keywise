#!/bin/sh
# Wraps swift build's plain executable in a minimal .app bundle. A plain
# executable launches outside LaunchServices. The window opens, but it
# cannot take keyboard focus from the terminal that launched it.
# Wrapping it in a bundle registers the process with LaunchServices, so
# Finder can launch it too.
#
# Defaults to release. Debug disables Swift's whole-module optimization
# and Zig's inlining. Those two optimizations are why filtering and
# reveal felt sluggish in Debug. Pass "debug" for a fast dev rebuild.
set -eu

config="${1:-release}"
cd "$(dirname "$0")/.."
repo_root="$(cd .. && pwd)"

if [ -z "${KEYWISE_UNIVERSAL:-}" ]; then
    if [ "$config" = "release" ]; then
        zig_optimize=ReleaseSafe
    else
        zig_optimize=Debug
    fi
    (cd "$repo_root" && ./zig/zig-aarch64-macos-0.16.0/zig build -Doptimize="$zig_optimize")
fi

# swiftc/ld embeds something debug-info-derived into the binary that
# varies build to build, the same class of issue -fstrip fixes on the
# Zig side. -gnone strips that. Verified: two clean rebuilds of
# identical source are byte-identical, even after the ad-hoc codesign
# below.
#
# KEYWISE_UNIVERSAL builds both architectures with --triple, then merges
# them with lipo. --triple preserves -Xswiftc flags. Dual --arch does not.
if [ -n "${KEYWISE_UNIVERSAL:-}" ]; then
    swift build -c "$config" -Xswiftc -gnone --triple arm64-apple-macosx
    swift build -c "$config" -Xswiftc -gnone --triple x86_64-apple-macosx
    mkdir -p .build/universal
    lipo -create \
        ".build/arm64-apple-macosx/$config/Keywise" \
        ".build/x86_64-apple-macosx/$config/Keywise" \
        -output ".build/universal/Keywise"
    build_dir=".build/universal"
else
    swift build -c "$config" -Xswiftc -gnone
    build_dir=".build/$config"
fi

app=".build/$config/Keywise.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$build_dir/Keywise" "$app/Contents/MacOS/Keywise"
cp "Info.plist" "$app/Contents/Info.plist"
# Info.plist's CFBundleIconFile names this file. scripts/make-icon.swift
# draws it, and the committed .icns is what a build copies.
cp "Icon.icns" "$app/Contents/Resources/Icon.icns"
codesign --force --deep --sign - "$app"

# A fixed mtime on every file. The app's contents are already
# byte-identical across rebuilds by this point, so the timestamps are the
# last source of variance between two zips of the same bundle.
#
# The trailing Z makes touch read the stamp as UTC.
# scripts/release-package.sh repeats this value for its own archives.
/usr/bin/find "$app" -exec touch -d 2026-01-01T00:00:00Z {} +

echo "$app"
