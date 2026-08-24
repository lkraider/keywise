#!/bin/sh
# Writes the release version into every file that holds it, or compares them.
#
#   scripts/release-set-version.sh 1.2.0            write
#   scripts/release-set-version.sh --check 1.2.0    compare, exit 1 on a mismatch
#
# .github/workflows/release.yml runs the check against the pushed tag. A file
# left at the old version stops the release before it uploads anything.
#
# Formula/keywise.rb and Casks/keywise-app.rb also hold a SHA-256 of the
# built artifact. Read those from ci.yml's reproducible-build job and paste them
# in. This script leaves them alone.
set -eu

mode=write
if [ "${1:-}" = "--check" ]; then
    mode=check
    shift
fi
version="${1:?usage: set-version.sh [--check] <version>}"
# FILEVERSION in win/app.rc takes four numbers. A suffix such as 1.2.0-rc1 fits
# no field there.
ok=
case "$version" in
    *[!0-9.]*) ;;
    [0-9]*.[0-9]*.[0-9]*) ok=yes ;;
esac
if [ -z "$ok" ]; then
    echo "version must read major.minor.patch in digits: $version" >&2
    exit 1
fi

cd "$(cd "$(dirname "$0")/.." && pwd)"

# PlistBuddy rewrites the whole file. It converts the 4-space indent to tabs
# and sorts the keys. That turned a two-line bump into a 36-line diff. These
# read the line after the key, the way the plist is laid out.
plist_value() {
    sed -n "/<key>$1<\/key>/{n;s|.*<string>\(.*\)</string>.*|\1|p;}" macos/Info.plist
}
read_plist() { plist_value CFBundleShortVersionString; }
read_rc() { sed -n 's/^ *VALUE "ProductVersion", "\([^"]*\)".*/\1/p' win/app.rc; }
read_rc_binary() { sed -n 's/^PRODUCTVERSION \([0-9,]*\).*/\1/p' win/app.rc; }
read_zon() { sed -n 's/^ *\.version = "\([^"]*\)".*/\1/p' build.zig.zon; }
read_changelog() { sed -n 's/^## \[\([^]]*\)\].*/\1/p' CHANGELOG.md | head -1; }
read_cask() { sed -n 's/^ *version "\([^"]*\)".*/\1/p' Casks/keywise-app.rb; }
read_formula() { sed -n 's|.*/download/v\([^/]*\)/.*|\1|p' Formula/keywise.rb; }
read_scoop() { sed -n 's/^ *"version": "\([^"]*\)".*/\1/p' bucket/keywise.json; }

check() {
    status=0
    for pair in \
        "macos/Info.plist=$(read_plist)" \
        "win/app.rc=$(read_rc)" \
        "build.zig.zon=$(read_zon)" \
        "CHANGELOG.md=$(read_changelog)" \
        "Casks/keywise-app.rb=$(read_cask)" \
        "Formula/keywise.rb=$(read_formula)" \
        "bucket/keywise.json=$(read_scoop)"
    do
        found="${pair#*=}"
        if [ "$found" = "$version" ]; then
            echo "ok    ${pair%%=*}"
        else
            echo "WRONG ${pair%%=*} reads '$found', wanted '$version'" >&2
            status=1
        fi
    done
    # 1.2.0 becomes 1,2,0,0. FILEVERSION and PRODUCTVERSION take four numbers.
    want_binary="$(echo "$version" | tr '.' ',')",0
    if [ "$(read_rc_binary)" = "$want_binary" ]; then
        echo "ok    win/app.rc PRODUCTVERSION"
    else
        echo "WRONG win/app.rc PRODUCTVERSION reads '$(read_rc_binary)', wanted '$want_binary'" >&2
        status=1
    fi
    return "$status"
}

if [ "$mode" = check ]; then
    check
    exit
fi

edit() {
    file="$1"
    shift
    sed "$@" "$file" > "$file.tmp"
    mv "$file.tmp" "$file"
}

# A human writes the changelog section. This runs before any write, so a
# missing section leaves every file at the version it already held.
if [ "$(read_changelog)" != "$version" ] && ! grep -q '^## \[Unreleased\]' CHANGELOG.md; then
    echo "CHANGELOG.md has no [Unreleased] heading. Write the $version section first." >&2
    exit 1
fi

# CFBundleVersion counts releases. It moves only when the short version moves,
# so a rerun with the same version keeps the count.
if [ "$(read_plist)" != "$version" ]; then
    build=$(plist_value CFBundleVersion)
    edit macos/Info.plist \
        -e "/<key>CFBundleShortVersionString<\/key>/{n;s|<string>.*</string>|<string>$version</string>|;}" \
        -e "/<key>CFBundleVersion<\/key>/{n;s|<string>.*</string>|<string>$((build + 1))</string>|;}"
fi

quad="$(echo "$version" | tr '.' ',')",0
edit win/app.rc \
    -e "s/^FILEVERSION .*/FILEVERSION $quad/" \
    -e "s/^PRODUCTVERSION .*/PRODUCTVERSION $quad/" \
    -e "s/^\( *VALUE \"FileVersion\", \)\".*\"/\1\"$version\"/" \
    -e "s/^\( *VALUE \"ProductVersion\", \)\".*\"/\1\"$version\"/"

edit build.zig.zon -e "s/^\( *\.version = \)\".*\"/\1\"$version\"/"
edit Casks/keywise-app.rb -e "s/^\( *version \)\".*\"/\1\"$version\"/"
edit Formula/keywise.rb -e "s|/download/v[^/]*/|/download/v$version/|"
edit bucket/keywise.json \
    -e "s/\"version\": \"[^\"]*\"/\"version\": \"$version\"/" \
    -e "s|/download/v[^/]*/|/download/v$version/|" \
    -e "s/Keywise-[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*/Keywise-$version/g"

# A heading that already names this version keeps its date.
if [ "$(read_changelog)" != "$version" ]; then
    edit CHANGELOG.md -e "1,/^## \[Unreleased\]/s/^## \[Unreleased\]/## [$version] - $(date +%Y-%m-%d)/"
fi

check
