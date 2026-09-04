# ![](docs/images/icon.png) Keywise

[![CI](https://github.com/lkraider/keywise/actions/workflows/ci.yml/badge.svg)](https://github.com/lkraider/keywise/actions/workflows/ci.yml)
[![reproducible: yes](https://img.shields.io/badge/reproducible-yes-brightgreen)](docs/REPRODUCIBLE.md)

**Page:** https://lkraider.github.io/keywise/

A terminal UI, a macOS app and a Windows app show the saved logins in a
local Firefox profile. All three read them through one Zig core. The
released binaries are Apple Silicon macOS, Linux x86_64, Linux ARM64,
Windows x86_64 and Windows ARM64.

### TUI

![The terminal UI listing five logins with masked passwords, one revealed, and the confirmation prompt on the Firefox Accounts row](docs/images/tui.png)

### SwiftUI

![The macOS app listing the same five logins, each with a copy button, and icons marking the Firefox Accounts row and the extension row](docs/images/macos-app.png)

### Win32

![The Windows app listing the same five logins in a report-view list, with the second row selected and its password revealed, and the status bar showing the login count](docs/images/windows-app.png)

## Installing

```
brew tap lkraider/keywise https://github.com/lkraider/keywise
brew install lkraider/keywise/keywise             # the terminal UI
brew install --cask lkraider/keywise/keywise-app  # the macOS app
```

The app is ad-hoc signed. This project has no Apple Developer ID, so it is
not notarized. Gatekeeper blocks a first launch as coming from an
unidentified developer. Right-click the app in Finder and choose Open.
Clearing the quarantine flag works too:

```
xattr -cr /Applications/Keywise.app
```

An extended attribute sits outside the code signature, so
`codesign -v --deep --strict` still passes after that command.

On Linux, download `keywise-x86_64-linux.tar.gz` or
`keywise-aarch64-linux.tar.gz` from the releases page:

```
tar -xzf keywise-x86_64-linux.tar.gz
install -m 755 keywise ~/.local/bin/keywise
```

The binary is static, so it runs on any distro. A copy on Wayland needs
`wl-copy` from the `wl-clipboard` package. A copy on X11 needs `xclip` from
`xclip` or `xsel` from `xsel`.

```
sudo apt install wl-clipboard    # Wayland
sudo apt install xclip           # X11
```

`dnf install` and `pacman -S` take the same package names.

On Windows, install with [Scoop](https://scoop.sh/):

```
scoop bucket add keywise https://github.com/lkraider/keywise
scoop install keywise
```

Or download `Keywise-<version>-windows-arm64.zip` or
`-windows-x86_64.zip` from the releases page and unzip it. The exe is a
single file and needs no install. It is unsigned, so SmartScreen shows a
warning on first launch. Choose More info, then Run anyway.

## Using it

Run `keywise`. It finds the directory holding `profiles.ini` and opens the
profile your Firefox uses. It prompts for a Primary Password when the
profile has one.

macOS keeps that directory at `~/Library/Application Support/Firefox`. On
Linux `keywise` tries the paths below in order and reads the first one holding
a `profiles.ini`:

```
~/.mozilla/firefox                                # distro package
~/snap/firefox/common/.mozilla/firefox            # Ubuntu snap
~/.var/app/org.mozilla.firefox/.mozilla/firefox   # Flatpak
```

One run reads one of them.

| Key | Does |
|---|---|
| `/` | Enter the search field. `↑` `↓` navigate results while typing. |
| `esc` | Leave the search field. |
| `↑` `↓`, `k` `j` | Move through the list. |
| `PgDn` `PgUp` | Jump one screenful. |
| `Home` `End` | Jump to first or last. |
| `enter` | Reveal the selected password. Press again to hide it. |
| `y` | Copy the selected password. The row stays masked. |
| `q`, `ctrl-c` | Quit. |

On Linux, `y` sends OSC 52 before it tries `wl-copy`, `xclip` or `xsel` as a
best-effort local helper. Every successful copy reports `copied`. Over SSH,
OSC 52 can reach the clipboard of the terminal you are sitting at.

`y` also writes the password to stdout on any run where stdout is a pipe or
a file. On a terminal it writes nothing.

```
keywise | wl-copy             # press y, then q
keywise > /tmp/p              # the last y of the run lands in the file
```

To export logins:

```
keywise --export logins.csv   # CSV, same format Firefox uses
keywise --export logins.json  # JSON array
```

The export prompts for the Primary Password on `/dev/tty` and writes the
file with mode 0600.

To open another profile:

```
keywise --list-profiles   # one profile per line, name then path
keywise --profile <path>  # open that directory
```

`--list-profiles` prints the profiles to stdout and the directory it read
to stderr.

On Windows, run `Keywise.exe`. It reads `profiles.ini` under
`%APPDATA%\Mozilla\Firefox`. The `Profile` menu lists every profile it
found, and `--profile <path>` opens one directory.

| Key | Does |
|---|---|
| `Ctrl+F` | Move focus to the search box. |
| `Enter`, double-click | Reveal the selected password. Press again to hide it. |
| `Ctrl+C` | Copy the selected password. The row stays masked. |
| `Esc` | Hide the revealed password. |
| right-click | Reveal and Copy for the row under the cursor. |

Passwords stay masked until you press `enter`, and only the selected one is
shown. The macOS app shows the same data under the same rules. Each row there
has a copy button, and the row stays masked when you use it.

## Limits

This reads a profile and writes nothing back. Firefox can stay open while
you use it.

The list is a snapshot from the moment you opened the profile. To pick up
a login Firefox saved after that, open the profile again. Windows has the
`Profile` menu, macOS has the profile picker, and the TUI needs a restart.

It cannot read these profiles:

- One with a Primary Password you do not know. Decryption uses the
  password you type. There is no recovery path.
- One that Firefox 144 or newer has never opened. Those hold
  3DES-encrypted entries only. This tool reports 3DES per entry and stops
  there.
- One whose `key4.db` uses SQLite's write-ahead log. No Firefox profile
  measured uses one. The app reports "key4.db uses write-ahead logging.
  Open Firefox and close it to commit the log". If Firefox cannot open
  the profile, convert a copy:

  ```
  cp -R <profile> /tmp/profile-copy
  sqlite3 /tmp/profile-copy/key4.db 'PRAGMA journal_mode=delete'
  keywise --profile /tmp/profile-copy
  ```

## Security

Copying marks the clipboard entry so a clipboard manager skips it. On
Windows that keeps the password out of `Win+V` history and out of the
cloud clipboard. Copying never puts the password on screen. There are no
network calls and no telemetry.

The macOS app and the Windows app clear the clipboard 30 seconds after a
copy. Both mask a revealed password after the same 30 seconds. Copy
something else in the meantime and that copy stays.

The TUI runs no timer. A password it copies stays on the clipboard until
something else replaces it, and a revealed row stays open until you press
`enter` again. On Linux it writes no marker, so a clipboard manager there
keeps the copy.

Anyone who can read your files already has this data. Firefox exposes the
same logins through its own UI. The code wipes every decrypted buffer it
owns.

A profile synced to a Mozilla Account holds a `chrome://FirefoxAccounts`
row. Its password is sync key material, so revealing it hands over the
whole account. All three front ends mark that row and ask a second time
before revealing it.

## Building

Needs [Zig 0.16.0](https://ziglang.org/download/#release-0.16.0). On macOS it
also needs Xcode Command Line Tools (`xcode-select --install`), because the C
ABI library links libc and `core/test/oracle.zig` links `libsqlite3` through
the SDK those tools install.

```
zig build          # core, the TUI, and the C ABI static library
zig build test     # the core tests, against the committed fixtures
zig build tui      # run the TUI
zig build smoke    # the C ABI smoke test
```

`zig build test` reads only `core/testdata/`. It runs on a machine with no
Firefox installed. Pass `-Doracle=false` to drop the test that diffs the
SQLite reader against the system sqlite3.

The Windows app cross-compiles from macOS or Linux with no Windows SDK:

```
zig build win -Dtarget=aarch64-windows-gnu -Doptimize=ReleaseSafe
zig build win -Dtarget=x86_64-windows-gnu  -Doptimize=ReleaseSafe
```

The Linux binaries cross-compile the same way. musl links statically, so one
binary per architecture runs on any distro:

```
zig build -Dtarget=x86_64-linux-musl  -Doptimize=ReleaseSafe
zig build -Dtarget=aarch64-linux-musl -Doptimize=ReleaseSafe
```

`scripts/linux-launch-check.sh zig-out/bin/keywise` drives the paths that run
without a terminal.

The released zips are built at `ReleaseSafe`. That mode keeps the bounds and
alignment checks over the hand-written `key4.db` reader.

`scripts/release-package.sh <version> <dir>` builds and archives every
published artifact. The Linux tarballs, the macOS `keywise` tarball and the
Windows zips reproduce byte for byte on any macOS host. The macOS app zip
does not. Its hash follows the SDK installed on the build machine.
[`docs/REPRODUCIBLE.md`](docs/REPRODUCIBLE.md) has the settings and the
measurements.

`win/icon.ico` is committed, and a build reads that file. `python3
scripts/win-make-ico.py` rewrites it from `macos/Icon.icns`.

The macOS app is a separate Swift package. See
[`macos/README.md`](macos/README.md) for how to build and test it.

`scripts/docs-screenshots.sh` regenerates the images above. Its `win` target
needs wine.

## Layout

```
core/       key4.db and logins.json decryption, and the C ABI
tui/        the terminal UI, on libvaxis
macos/      the SwiftUI app
win/        the Win32 app
scripts/    the release, CI and fixture tooling
```

`docs/` covers the rest:

- [`docs/FORMAT.md`](docs/FORMAT.md) — what Firefox writes into a profile,
  and the encryption over it.
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — the decision table, the
  module map, and the C ABI a front end links.
- [`docs/PLATFORM.md`](docs/PLATFORM.md) — what the pinned Zig, Win32, wine
  and macOS do here.
- [`docs/REPRODUCIBLE.md`](docs/REPRODUCIBLE.md) — the settings that make two
  packagings of one commit write the same bytes.

## License

MIT. See [`LICENSE`](LICENSE).

## Trademarks

Firefox is a trademark of the Mozilla Foundation in the US and other
countries. This project is not affiliated with Mozilla.
