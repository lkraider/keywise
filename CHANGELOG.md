# Changelog

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Fixed

- A `logins.json` where the `"logins"` value is an object (`{}`) caused a
  panic. The reader now returns `NoLoginsArray`.
- A `key4.db` whose key rows all fail to unwrap now returns
  `KeyUnwrapFailed` with a message that names the two readings: a wrong
  Primary Password, or damaged key data.

### Added

- `WalJournal` message when `key4.db` uses SQLite's write-ahead log. The
  message tells the person to open Firefox and close it.
- Every error `Store.open` and `Store.reveal` can return now maps to text
  a person can act on. An exhaustive compile-time test walks the error set
  and fails if a member falls through to the generic fallback.

## [2.0.0] - 2026-08-20

### Changed

- The product is Keywise. Mozilla's trademark policy forbids a product name
  that leads with Firefox, so the name slot carries no Mozilla mark now. The
  tree held `ffpw`, `FirefoxPasswordView` and `firefox-password-view` for one
  product, and one token replaces all three.
- **Breaking.** The C ABI renames every symbol. Functions move from the
  `ffpw_` prefix to `keywise_` and constants from `FFPW_` to `KEYWISE_`.
  `zig build` installs `zig-out/lib/libkeywise.a` and
  `zig-out/include/keywise.h`. A program linking the library needs an edit.
- **Breaking.** The terminal command is `keywise`. The macOS app is
  `Keywise.app` and the Windows executable is `Keywise.exe`. The macOS bundle
  identifier is `br.com.nkey.Keywise`, so a 1.x install stays on disk beside
  this one.
- **Breaking.** The release assets carry new filenames:
  `Keywise-<version>-macos.zip`, `Keywise-<version>-windows-arm64.zip`,
  `Keywise-<version>-windows-x86_64.zip`, `keywise-aarch64-macos.tar.gz`,
  `keywise-x86_64-linux.tar.gz` and `keywise-aarch64-linux.tar.gz`. A script
  that downloads a 1.x filename needs an edit.
- **Breaking.** The tap and both tokens changed:

  ```
  brew tap lkraider/keywise https://github.com/lkraider/keywise
  brew install lkraider/keywise/keywise
  brew install --cask lkraider/keywise/keywise-app
  ```

  Run `brew untap lkraider/firefox-password-view` after uninstalling the 1.x
  formula and cask.
- **Breaking.** The repository is `lkraider/keywise`. GitHub redirects the old
  path, and that covers the v1.0.0 to v1.3.0 download URLs.
- `FFPW_SKIP_BUILD` and `FFPW_WINE` became `KEYWISE_SKIP_BUILD` and
  `KEYWISE_WINE`.
- `build.zig.zon` declares `.name = .keywise`. A Zig fingerprint holds
  `crc32(name)` in its high 32 bits, so that half moved to `0x30020c5e`. The
  low half stays, so the package keeps its identity.
- `docs/images/tui.png` reads `tui — keywise` in its title bar. The 1.3.0
  image read the home folder's name of the machine that took it.

### Added

- `README.md` carries the trademark attribution notice Mozilla's policy asks
  for. The prose keeps the word Firefox where it states what the tool reads,
  which the policy's "You May" list allows.

## [1.3.0] - 2026-08-19

### Added

- Linux binaries. Releases ship `ffpw-x86_64-linux.tar.gz` and
  `ffpw-aarch64-linux.tar.gz`, both cross-compiled from macOS against musl
  at `ReleaseSafe`. `tui_mod` links no C library, so each one is static and
  runs on any distro. `ci.yml` builds both natively too and
  `scripts/ci-compare-sums.sh` compares the two hosts.
- `ffpw` finds the Linux profile directory. It tries `~/.mozilla/firefox`,
  then the Ubuntu snap root, then the Flatpak root, and reads the first one
  holding a `profiles.ini`. One run reads one root, because each Firefox
  install reads the one root its packaging fixes.
- A copy on Linux runs `wl-copy`, `xclip` or `xsel`, picked from
  `$WAYLAND_DISPLAY` and `$DISPLAY`. The status line reads `copied` on every
  press, so a host with none of those installed and a terminal that drops
  OSC 52 reports a copy and leaves the clipboard empty. `README.md` and
  `ffpw --help` name the package each helper ships in: `wl-clipboard`,
  `xclip` and `xsel`.
- `y` writes the password to stdout on any run where stdout is a pipe or a
  file, so `ffpw | wl-copy` and `ffpw > /tmp/p` work. The write happens once,
  after the UI exits, with no trailing newline, and the last `y` of the run
  is what a reader receives. On a terminal it writes nothing.
- `ffpw --version` prints the version and exits 0.
- `scripts/linux-launch-check.sh` drives the paths that run without a
  terminal and exits non-zero on a failure. `ci.yml` runs it on
  `ubuntu-latest` and `ubuntu-24.04-arm`. Those two jobs are also the first
  to run `zig build test` on Linux.

### Changed

- The macOS build pins `LC_BUILD_VERSION`'s `minos` to 14.0, the floor
  `Package.swift` and `Formula/ffpw.rb` already declare. `build.zig` writes
  `os_version_min` into `target.query`, since `std.Build` sends the compiler
  the query and never the resolved result. An empty query let the compiler
  read `minos` from the build host, so a runner image bump moved the
  published tarball's hash.
- `--list-profiles` prints the directory it read to stderr. Its stdout stays
  at name, tab, path.

### Fixed

- The release archives reproduce on any macOS host. `bsdtar`'s default format
  adds an AppleDouble member when a file carries an extended attribute, and
  macOS 15.6 attaches `com.apple.provenance` to a freshly linked binary while
  15.7.7 does not. One `ffpw` at `8b49bb31` therefore archived to `88ab0442`
  on one Mac and to `b98f0c28` on another. `scripts/release-package.sh` passes
  `--format ustar`, stamps every member with the instant
  `2026-01-01T00:00:00Z`, and pins `TZ` for the `zip` and `ditto` calls.
  `docs/REPRODUCIBLE.md` has the mechanism for each.
- `profiles.resolvePath` tested `rel[0]` against `'/'`, so a Windows
  `profiles.ini` carrying `IsRelative=0` and `Path=C:\Users\x\profile`
  produced `%APPDATA%\Mozilla\Firefox\C:\Users\x\profile`. It calls
  `std.fs.path.isAbsolute`. That function reads a drive letter.

## [1.2.0] - 2026-08-18

### Added

- A Windows app under `win/`. It imports the `core` module directly and
  shows the same list the macOS app shows, through Windows mechanisms: a
  `Profile` menu, a `SysListView32`, a right-click context menu, a
  `msctls_statusbar32`, `Ctrl+C` and `Ctrl+F` accelerators, a `DIALOGEX`
  Primary Password prompt, and a `MessageBoxW` before the Firefox Accounts
  row gives up its password. Releases ship `x86_64` and `arm64` zips, both
  cross-compiled from macOS at `ReleaseSafe`, so the shipped exe keeps its
  bounds and alignment checks.
- A copy on Windows sets the four clipboard formats that keep the password
  out of `Win+V` history and out of the cloud clipboard. The clipboard
  clears 30 seconds later, and a copy someone else made in between
  survives.
- `core/test/oracle.zig` reads every fixture through the new SQLite reader
  and through the system sqlite3, then compares every column, every rowid
  and the row order. `core/testdata/overflow.db` covers the overflow and
  interior-page branches no `key4.db` reaches.
- `core/testdata/page64k.db` and `core/testdata/reserved.db` cover the two
  header fields no `key4.db` exercises: a 65536-byte page, stored as the
  value 1 at header offset 16, and a 16-byte reserved tail on every page.
  Replacing `usable` with `page_size` in `readPayload` fails the reserved
  fixture and passes every other one.
- `scripts/wine-check.sh` drives the Windows exe under wine and exits
  non-zero on a failure. It covers copy from the list, copy from the search
  box, copy from the row menu, the right-click selection, Tab, Escape and a
  600-byte profile name. CI runs no wine, so this script is local.
- Windows app: a panic now shows its message in a message box and exits with
  code 3. `win/src/crash.zig` wipes both plaintext buffers before the box
  goes up, since the box waits for a click. The windows subsystem gives the
  process no console, so every panic before this went unreported.
- CI runs the Windows exe on both architectures it ships for.
  `windows-latest` covers `x86_64` and `windows-11-arm` covers `arm64`. Each
  job builds the app at `ReleaseSafe` for the `gnu` ABI a release ships,
  launches it against the `fresh` fixture through
  `scripts/win-launch-check.ps1`, and asserts the process is alive with its own
  window class up. `windows-latest` also runs the core tests at `ReleaseSafe`,
  the mode `scripts/package-release.sh` builds, and builds the exe twice in
  parallel. Every build job records its exe's SHA-256 in the run summary, and
  the `compare-sums` job compares one sum per target across the hosts.
- `scripts/package-release.sh` starts both Windows builds beside the macOS
  chain, each with its own cache directory and install prefix. Two runs across
  a clean produced four identical artifacts, and every artifact matches what
  the sequential script wrote.
- The Windows exe reports its version in the Details tab of its Properties
  dialog. `win/app.rc` holds a `VERSIONINFO` block, and that tab showed no
  version before it.
- `scripts/set-version.sh` writes the release version into every file that
  holds it. `--check` compares them. `release.yml` runs that check against the
  pushed tag. It then compares the hashes in `Formula/ffpw.rb` and
  `Casks/firefox-password-view.rb` with the assets it packaged. A mismatch
  exits the job before the upload.

### Changed

- `core/src/sqlitedb.zig` replaces the two SQL statements in `keydb.zig`
  with a read-only reader for the SQLite file format. `core/test/oracle.zig`
  is now the only build target that links `libsqlite3`, so the core
  cross-compiles to Windows and Linux from a Mac.
- `keydb.load` takes an `std.Io` and a plain path. Its error set is
  unchanged.
- Windows app: `Ctrl+C` copies the search text while the search box holds
  the focus. It copied the selected row's password before. The row context
  menu and `Ctrl+C` over the list are unchanged.

### Fixed

- The SQLite reader followed a b-tree that reaches one page many times
  until the caller gave up. A crafted 11,776-byte `key4.db` made
  `keydb.load` run over 20 seconds with no return. One walk now descends
  into at most as many pages as the file holds, and that file returns
  `error.QueryFailed` in 0.37 seconds. `core/testdata/fanout.db` covers it.
- Windows app: a profile whose `profiles.ini` name runs past 511 characters
  made the app exit with no window and no message. The conversion to UTF-16
  panicked, and the windows subsystem sends a panic to a stderr with no
  console.
- `scripts/wine-check.sh` and `scripts/screenshots.sh` left 8 wine helper
  processes running per run. `wineboot` starts them, they survive
  `wineserver -k` and the prefix's deletion, and launchd adopts them. Both
  scripts now call `scripts/wine-shutdown.sh` from their cleanup trap.
- Windows app: the status bar reported `Copied` for a copy the clipboard
  refused. It now names the reason.
- Windows app: `refreshRows` wrote past a zero-length slice when the arena
  satisfied the first allocation and failed the second.

## [1.1.0] - 2026-08-17

### Added

- Both front ends copy a password without revealing it. The macOS app puts
  a copy button on every row. The TUI's `y` copies the row under the
  cursor. The row stays masked on both paths, and the decrypted buffer is
  wiped before the call returns.
- macOS app: a revealed password masks itself after 30 seconds, matching
  the clipboard's own timeout.
- TUI: `--profile <path>` opens that profile, `--list-profiles` prints
  every profile in `profiles.ini`, and `--help` prints the usage.

### Fixed

- macOS app: the entry list could stay empty for the life of the window
  while the status bar showed the right login count. The list is an
  `NSTableView`, and the SwiftUI view wrapping it read nothing from
  `AppModel`, so SwiftUI never re-ran it once the entries finished
  loading. Roughly one launch in six.
- macOS app: the app opened two windows at launch, and both showed the
  same profile. Every window ran the profile load again against one
  shared store.
- macOS app: revealing the `chrome://FirefoxAccounts` row took one
  activation. It now asks a second time, as the TUI already did. That
  password is Mozilla Account sync key material.

### Changed

- macOS app: each entry row is a button carrying an accessibility label
  and action. A tap gesture drew the row before. A tap gesture carries no
  accessibility action, so revealing and copying a password took a mouse
  click.
- The `chrome://FirefoxAccounts` row asks for a second activation before a
  copy, as it already did before a reveal. Each action asks on its own.
- TUI: the 3DES message reads "this entry is still 3DES and this app cannot
  decrypt it".

## [1.0.0] - 2026-08-16

First release. Binaries for Apple Silicon macOS.

### Added

- Core: reads `key4.db` and `logins.json`, unwraps the AES-256 and legacy
  3DES master keys, decrypts every entry, and reports which entries are
  still 3DES.
- Core: resolves and enumerates Firefox profiles from `profiles.ini`,
  reading the `[InstallXXXX]` section ahead of the legacy `Default=1`
  flag.
- Core: `store.zig`, the shared search filter and arena both front ends
  use.
- Core: a C ABI (`core/include/ffpw.h`) for Swift and other C callers.
  `ffpw_entries` fetches every entry's display data in one call.
- TUI: a search field, a masked-password list, reveal, copy, and a Primary
  Password prompt, built on libvaxis.
- macOS app: a SwiftUI equivalent of the TUI, linking the same C ABI. The
  entry list is an `NSTableView` with a fixed row height
  (`EntryTableView.swift`). It holds a steady scroll on a 1000+ row
  profile.
- Both front ends label the `chrome://FirefoxAccounts` row and ask for
  confirmation before revealing it. Its password is Mozilla Account sync
  key material.
- Fixtures written by an installed Firefox driven over Marionette,
  covering a fresh profile, a Primary Password, the pre- and
  post-Firefox-144 3DES-to-AES-256 migration, two profiles under one
  `profiles.ini`, and a synced profile's tombstones and non-web schemes.
- A fuzz corpus for the DER reader, mutating captured SDR blobs through
  `sdr.parse` and `pbes2.parse`.
- `docs/`: the on-disk format and the reasoning behind each implementation
  decision.
- `macos/scripts/bundle.sh`: wraps the Swift package's executable in a
  minimal ad-hoc-signed `.app` bundle.
- `scripts/package-release.sh`: builds both release artifacts. CI packages
  them twice and diffs the result on every push.
- `LICENSE`: MIT.
