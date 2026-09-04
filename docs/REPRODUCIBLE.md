# Reproducible builds

Two packagings of one commit write the same bytes. The macOS app zip is the
exception. Every setting recorded here exists to keep the rest true.

    Measured against
    Zig 0.16.0 · macOS 15.6, and the macos-15 runner at 15.7.7
    bsdtar 3.5.3 · Apple gzip 457.140.3 · Info-ZIP Zip 3.0

Two layers reproduce separately. A binary reproduces on any host that can
target it. The archive around it reproduces on any macOS host, and
`release-package.sh` runs `swift build` for the `.app`, so macOS is the only
host that packages a release.

## The binaries

`build.zig` sets `strip` for every mode except Debug. Zig's macOS linker
derives `LC_UUID`, and the code-signature hash covering it, from debug info
that varies between builds. Stripping removes that input.
`macos/scripts/bundle.sh` passes `-Xswiftc -gnone` for the same reason.

`build.zig` writes `os_version_min` into `target.query` for a macOS target.
`std.Build` sends the compiler `target.query` and never the resolved result
(`lib/std/Build/Module.zig:596`), so an empty query let the compiler read the
deployment version from the build host, and a runner image bump moved the
published bytes. `LC_BUILD_VERSION` now reports `minos 14.0` everywhere, the
floor `Package.swift` and `Formula/keywise.rb` declare.

`zig build-exe --help` reports `--build-id ... none (default)`, so no build
ID enters an ELF.

## The archives

These settings in `release-package.sh` keep the archive bytes independent of
which Mac runs it.

`tar --format ustar`. bsdtar defaults to "pax restricted". That format adds a
`._name` AppleDouble member when the file carries an extended attribute. macOS
15.6 attaches `com.apple.provenance` to a freshly linked binary that has never
run, and 15.7.7 leaves it off. One `keywise` at `8b49bb31` therefore archived to
`88ab0442` on 15.6 and to `b98f0c28` on 15.7.7. Under `ustar` both write
`b98f0c28`.

`touch -d 2026-01-01T00:00:00Z`. tar stores an absolute epoch, and `touch -t`
reads its stamp as local time, so a host at -03 wrote 1767236400 where a UTC
host wrote 1767225600. `macos/scripts/bundle.sh` stamps the `.app` with the
same instant.

`TZ=UTC` on the `zip` and `ditto` calls. `zip -X` drops the UT extra field and
leaves the MS-DOS field. That field holds wall-clock time, and both programs
read `TZ` to convert an mtime into it.

Apple gzip and GNU gzip emit different deflate streams for one ustar tar,
`b98f0c28` against `a5d1c23b`. A Linux host that rebuilds a published archive
gets the same binary inside a different `.tar.gz`.

## The macOS app zip

`Keywise-<version>-macos.zip` holds the Swift binary, and its
`LC_UUID` follows the installed SDK. `vtool(1)` rewrites `LC_BUILD_VERSION`
and has no option for `LC_UUID`. Closing this needs the macOS SDK vendored
into every build environment, as `zig-build-macos-sdk` does for Ghostty.

`Formula/keywise.rb` and `Casks/keywise-app.rb` therefore carry a hash
from `ci.yml`'s `macos-test` job. `release.yml` packages on a second
runner and compares both hashes with the assets it built. A mismatch exits
before the upload.

Every other artifact reproduces across Macs, measured on 15.6 against the
runner's 15.7.7 and across three runs from clean at -03, +09 and +12:45.

## What CI asserts

`macos-reproducible` builds once on a second runner and diffs the archive
hashes against `macos-test`. Each build job writes its binary's SHA-256 to
the run summary and publishes it as a job output. `compare-sums` waits for
all of them and runs
`ci-compare-sums.sh` once per target. An empty sum fails that job, since two
missing values compare equal.

`windows-test` builds `x86_64` twice in parallel and fails when the two
disagree. A query carrying a triple serializes `-mcpu baseline`, so the target
string decides the code generation on every host.
