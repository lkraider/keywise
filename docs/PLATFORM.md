# Platform notes

What the pinned toolchain and the target operating systems do here, measured.
Every fact in this file expires. Read the versions below before trusting a
line of it.

    Measured against
    Zig 0.16.0 · macOS 15.6, and the macos-15 runner at 15.7.7
    wine 11.15 under Rosetta 2 · resinator as shipped with Zig 0.16.0
    Firefox 154.0.1 · Debian 12 aarch64 (Linux 7.0.14)

## Build

`libsqlite3` reaches only `core/test/oracle.zig`, and that test builds on a
macOS host. `/usr/lib/libsqlite3.dylib` lives in the dyld shared cache on
macOS 11 and later, and linking resolves through the SDK stub at
`$(xcrun --show-sdk-path)/usr/lib/libsqlite3.tbd`. Pass `-Doracle=false` on
a host without the Command Line Tools. The C ABI library still links libc,
and that link needs the same SDK, so cross-compiling `libkeywise.a` to macOS
from another host stays out of reach.

`build.zig.zon`'s `.version` is the one place the version string lives.
`build.zig` imports the manifest and hands the string to `tui_mod` as
`build_options.version`. `keywise --version` prints it.
`scripts/release-set-version.sh` writes the same string into
`macos/Info.plist`, `win/app.rc`, `CHANGELOG.md`, `Formula/keywise.rb` and the
cask. `release.yml` runs that script's `--check` against the pushed tag, so a
file left at the old version stops the release before it uploads anything.

Linux release binaries are built and exercised natively on both shipped
architectures. `scripts/test-check.sh` runs `zig build test` on both Linux
runners and verifies that every authored test passed with none skipped.
`scripts/linux-tui-check.py` is the executable specification for the terminal
lifecycle; extend it when terminal behavior changes rather than copying its
cases into this document. CI also rejects dynamically linked Linux release
binaries.

Nothing else links a C library. `zig build -Dtarget=x86_64-windows-gnu`,
`-Dtarget=aarch64-windows-gnu`, `-Dtarget=x86_64-linux-musl` and
`-Dtarget=aarch64-linux-musl` all run on a macOS host. `tui_mod` sets no
`link_libc`, so the two musl targets write static binaries that run on any
distro. `linux-test` and `linux-arm-test` assert the ReleaseSafe `keywise`
carries no `PT_INTERP` segment. A dynamically linked binary names its loader
there. `file` calls a static PIE "static-pie linked", so a grep for
"statically linked" fails on a correct binary.

`build.zig` names `user32`, `comctl32`, `gdi32`, `dwmapi`, `uxtheme` and
`advapi32`, and Zig links `kernel32` for every Windows target. Zig bundles a
`.def` file for each one under `lib/libc/mingw/lib-common/` and generates the
import library from it, so the Win32 link needs no Windows SDK.

## POSIX terminal lifecycle

vaxis 0.6 opens `/dev/tty` independently of stdin/stdout, saves termios, enters
raw mode and restores termios with `TCSAFLUSH` in `Tty.deinit`. `Vaxis.deinit`
pops Kitty keyboard mode, disables mouse and bracketed paste, shows the cursor,
leaves the alternate screen and flushes. `tui/src/main.zig` wraps panics with
`vaxis.recover`, disables key-release reports it does not consume, and turns
SIGHUP, SIGINT, SIGQUIT and SIGTERM into a clean event-loop exit before
restoring each prior handler. Ctrl-Z and SIGTSTP first scrub visible and typed
secrets, tear down vaxis, restore the prior SIGTSTP action and stop. After `fg`,
the app constructs a fresh vaxis reader around the same model. The signal
handler only updates a `sig_atomic_t` with atomic operations; terminal I/O and
termios restoration stay outside signal context.

Before `App.run`, the TUI reads `TIOCGWINSZ` and seeds vaxis with that exact
size. Only a zero row or column gets an 80x24 fallback written back with
`TIOCSWINSZ`; valid user dimensions must never be changed. vaxis wraps every
render in DECSET 2026 synchronized-output markers. Its current `App.run` enters
the alternate screen before capability probing. The TUI suppresses vaxis's
startup info log, then draws a complete loading frame before it performs SQLite
reads or password-based key derivation. This minimizes startup blanking without
copying or forking the framework's event loop.

## Windows

Zig ships no `windows.h`. `win/app.rc` therefore defines every constant it
uses. Measured: without those defines the compile fails with
`expected number or number expression; got 'DS_MODALFRAME'`. The same file
gives the `Profile` popup one separator, because resinator rejects an empty
block with `empty menu of type 'POPUP' not allowed`, and
`buildProfileMenu` deletes that separator after it inserts the profiles.

Win32 hands out pointers that miss their natural alignment, and
`@ptrFromInt` checks alignment in Debug and in ReleaseSafe. These casts
carry `align(1)`:

- `win32.zig` declares `LPCWSTR` as `[*:0]align(1) const WCHAR`, because
  `intResource` turns a resource id into a pointer and `IDI_APP` is 1.
  Windows reads a pointer whose high word is zero as an id in the low word.
- `onNotify` reads `NMHDR` through an `align(1)` pointer, because
  commctrl.h declares `NMLVKEYDOWN` inside `pshpack1.h`. Measured: an arrow
  key in the list delivered `lparam = 0x11125aa`, 2 bytes off an 8-byte
  boundary. `NMHDR`'s three fields sit at offsets 0, 8 and 16 in the packed
  layout and in the unpacked one.

The message loop calls `IsDialogMessageW`, so Tab moves the focus between
the search box and the list. Both carry `WS_TABSTOP`. The call runs after
`TranslateAcceleratorW`, so the accelerator table keeps Enter and Escape.
`WM_SETFOCUS` on the frame hands the focus to the search box. That covers
the launch and a click on the frame.

The loop passes `WM_SYSKEYDOWN`, `WM_SYSKEYUP` and `WM_SYSCHAR` straight to
`TranslateMessage`. `IsDialogMessage` swallows those three while a modeless
dialog is active, and the frame's menu mnemonics then stop working.

`TranslateAcceleratorW` matches whatever control holds the focus, so Ctrl+C
over a selected search term used to copy the selected row's password. The
HIWORD of `wParam` is 1 for an accelerator and 0 for a menu item. The
`IDM_ROW_COPY` branch reads it and sends `WM_COPY` to the search box in the
accelerator case.

## wine

The `x86_64-windows-gnu` exe runs under wine on macOS.
`scripts/docs-screenshots.sh win` writes the README image there, and
`scripts/wine-check.sh` asserts behaviour and exits non-zero on a failure.
Measured under wine 11.15: the profile list, the search filter, reveal,
copy, the 30-second clipboard clear, the 30-second re-mask, the
account-row confirmation, the context menu, the `Profile` menu, the
Primary Password dialog and the failure message box.

wine's Mac driver bridges the Win32 clipboard to `NSPasteboard` in
`dlls/winemac.drv/clipboard.c`, so `pbpaste` reads what a copy put there.
`pbpaste` reads plain text alone, and the four registered privacy formats
never appear in it. comctl32 moves the list selection on `WM_RBUTTONDOWN`,
so `showRowMenu` acts on the row the cursor is over.

Option+P under wine typed a literal character into the search box, both
through System Events and through a CGEvent carrying `.maskAlternate`. The
menu mnemonics still need a Windows machine.

## macOS

macOS App Sandbox needs a per-run open panel before it allows reading
another app's data directory. TCC leaves `~/Library/Application Support`
open to any process outside the sandbox, so the app reads a profile with
no permission prompt.

## Limits

- `zig build test --fuzz` does not run on the pinned Zig 0.16.0. Zig's
  bundled `test_runner.zig` passes a `*builtin.StackTrace` to
  `std.debug.writeStackTrace`, whose signature now wants
  `*debug.StackTrace`. The runner fails to compile. Plain `zig build
  test` still runs the fuzz corpus once, with no mutation.
- Zig 0.16.0's `aarch64-windows` build cannot run `zig build`. On a
  `windows-11-arm` runner it answers `zig version` and `zig env`, then exits
  `-1073741819`, an access violation, printing nothing. `ci.yml`'s
  `windows-arm-test` therefore runs the `x86_64-windows` toolchain under
  Windows-on-ARM emulation and cross-compiles with
  `-Dtarget=aarch64-windows-gnu`. `zig build test` runs on `windows-latest`
  and on `macos-15`. No machine runs the core tests compiled for arm64
  Windows.
