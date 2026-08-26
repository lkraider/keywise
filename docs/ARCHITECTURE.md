# Architecture

How this repository is put together. It holds the decisions already made,
the module map, the C ABI a front end links, and what each front end does
with it. Nothing here depends on a toolchain version.

`docs/FORMAT.md` covers Firefox's on-disk format. `docs/PLATFORM.md` covers
what the pinned Zig and the current operating systems do.
`docs/REPRODUCIBLE.md` covers byte-identical builds. `README.md` covers usage
and the threat model.

## Decisions

This table only grows. A reversed decision gets a new row marked superseded,
so the row that recorded the original choice stays readable.

| Decision | Choice | Rejected alternative |
|---|---|---|
| Crypto source | Reimplement PBES2 in Zig | Linking NSS needs a matching libnss3 per platform and a bundled dylib on macOS |
| 3DES | Not implemented. `sdr.decrypt` returns `LegacyTripleDes` | A DES implementation adds roughly 300 lines of legacy cipher that 0 of 1701 entries need |
| DER | Own bounds-checked reader | `std.crypto.Certificate.der` has no bounds checks, no canonical-form checks and no tests (ziglang/zig#19775) |
| C interop | `b.addTranslateC` | `@cImport` is deprecated in Zig 0.16 |
| SQLite | `core/src/sqlitedb.zig`, a read-only reader for the file format | The vendored amalgamation needs libc. Three exes at `-Doptimize=ReleaseSmall` on `x86_64-windows-gnu`, measured against the 3.53.4 amalgamation: 803840 bytes with it, 64000 for a minimal one linking libc, 4608 for a minimal one without it. SQLite's CVE advisories also cover a SQL layer this reader never calls |
| Win32 | Hand-written externs in `win/src/win32.zig` | `zigwin32` is a generated source tree of about 300 MB |
| Windows UI | Windows mechanisms for every macOS feature: a `Profile` menu, a context menu, `MessageBoxW`, a `DIALOGEX` template | Porting a SwiftUI layout puts macOS interactions in a Windows app |
| Windows optimize mode | `ReleaseSafe` for both released zips | `ReleaseSmall` saves 81 KB in the zip and drops the bounds, alignment and overflow checks. `sqlitedb.zig` takes every offset it follows from the file it reads |
| Zig | Pin 0.16.0 | Tracking master breaks on each stdlib redesign |
| Reveal | Masked by default, reveal one entry, copy to clipboard | Printing every password fills terminal scrollback |
| Target architectures | Ship one `aarch64-macos` slice, plus `x86_64-windows` and `aarch64-windows` | A macOS universal binary adds a lipo step and a second build for an architecture no release targets |
| Fixtures | Written by an installed Firefox over Marionette, committed under `core/testdata/` | A generator built from this project's own reading of the format would only show the reader agrees with itself |
| Archive determinism | `--format ustar`, an absolute `touch -d` instant, `TZ=UTC` on `zip` and `ditto` | `SOURCE_DATE_EPOCH` with `--mtime` and `--clamp-mtime`, the reproducible-builds.org recipe. bsdtar 3.5.3 accepts neither flag |

## Module layout

```
core/src/
  der.zig        bounds-checked TLV reader
  oids.zig       encoded OID bodies and the Cipher enum
  aescbc.zig     AES-256-CBC over std.crypto.core.aes, PKCS7
  pbes2.zig      unwraps key4.db values
  sdr.zig        parses logins.json blobs
  profiles.zig   resolves and enumerates profiles
  sqlitedb.zig   read-only reader for the SQLite file format
  keydb.zig      reads key4.db, returns the master keys
  logins.zig     decrypts and classifies logins.json entries
  store.zig      owns the arena, the keys, the entries, and the search filter
  messages.zig   the text a front end shows for a core failure
  core.zig       exports the C ABI the macOS app links, core/include/keywise.h
  root.zig       the module a front end imports through
  main.zig       validation probe
  c.h            the stdlib header for addTranslateC, for getenv
  tests.zig      NIST and DER vectors, and fixture round-trips
core/test/
  oracle.zig     diffs sqlitedb.zig against the system sqlite3
  smoke.c        calls every function in keywise.h
build.zig
tui/src/        the libvaxis TUI, imports store.zig through root.zig
macos/          the SwiftUI app, a Swift package linking core.zig's static library
win/src/        the Win32 app, importing the core module directly
scripts/                 automation and one-shot validation tools
  ci-compare-sums.sh      asserts every build host recorded one sum per target
  docs-screenshots.sh     writes the README images
  docs-social-preview.py  writes the two share cards from tui.png and icon.png
  docs-window-list.swift  lists every on-screen window and its bounds
  linux-launch-check.sh   drives the keywise paths that run without a terminal
  linux-tui-check.py      drives the Linux TUI through a controlling PTY
  release-package.sh      builds and archives every published artifact
  release-set-version.sh  writes the release version, or compares it with a tag
  test-check.sh           rejects a test run that silently executed no tests
  test-mkfixtures.py      writes every fixture under core/testdata/
  win-build-hash.ps1      builds the Windows exe and records its SHA-256
  win-launch-check.ps1    launches the Windows exe on a CI runner
  win-make-ico.py         writes win/icon.ico from macos/Icon.icns
  wine-check.sh           asserts the Windows app's behaviour under wine
  wine-input.swift        posts synthetic mouse and keyboard events
  wine-pixdiff.swift      counts differing pixels in one rectangle
  wine-shutdown.sh        ends a wine prefix's session and kills its helpers
```

Names encode their role; Linux-, Windows- and Wine-only drivers carry explicit
platform prefixes.

`docs-social-preview.py` imports Pillow. Every other Python script here reads
the standard library alone. It also reads the two Georgia faces under
`/System/Library/Fonts/Supplemental`. It writes `docs/images/social-preview.png`
at 1280x640 for the repo's Social preview field and for `twitter:image`, and
`docs/images/social-og.png` at 1200x630 for `og:image`. Both embed
`docs/images/tui.png`, so retaking that screenshot leaves both cards showing
the old content. The render reproduces byte for byte, so a rerun followed by
`git diff --stat docs/images/` reports it.

Two scripts compile `docs-window-list.swift`. `docs-screenshots.sh` compiles
it for the Terminal capture, the macOS app capture and the wine capture.
`wine-check.sh` compiles it for its window lookups. The prefix names the
first caller.

Inside `win/src/`, `model.zig` holds every rule about what a row shows and
what an activation means. It imports `core` and `std` alone, so `zig build
test` runs its tests on the build host. `main.zig` owns the window, the
timers and the dialogs. `win32.zig` holds the externs and `clipboard.zig`
the clipboard writer. `text.zig` converts UTF-8 into a caller-sized UTF-16
buffer, and its tests run on the build host too. `crash.zig` holds the panic
handler.

The Swift files above are one-shot tools. `docs-screenshots.sh` and
`wine-check.sh` each compile the ones they need with `swiftc -O` into their
own work directory.

Both scripts create a wine prefix per run and call `wine-shutdown.sh` from
their cleanup trap. `wineboot --init` starts `services.exe`, `explorer.exe`,
`plugplay.exe`, `svchost.exe` and two `winedevice.exe` for the prefix. On wine
11.15 under Rosetta 2 those keep running after `wineserver -k` and after the
prefix directory is deleted, reparented to launchd. A run that skips the call
leaves 8 of them, and they stay until the Mac reboots. Their argv holds a
Windows path and names no prefix, so `wine-shutdown.sh` reads each candidate's
cwd through `lsof` and kills the ones inside the prefix it was given.

### A panic on Windows shows a message box

`build.zig` sets `win_exe.subsystem = .Windows`, so the process has no console
and Zig's default panic write to stderr reaches nobody. A panic there closes
the window.

`main.zig` declares `pub const panic = std.debug.FullPanic(crash.report)`.
`std.debug.panicExtra` formats each safety panic into text, so `crash.report`
receives strings like `index out of bounds: index 512, len 511`. The handler
shows that text, the return address and the issues URL in a `MessageBoxW` with
a null owner, then calls `std.process.exit(3)`.

`crash.report` calls `Model.wipeSecrets` first. `MessageBoxW` waits as long as
the user takes, and a memory dump taken during that wait would hold the
revealed password. `wipeSecrets` zeroes both 8192-byte buffers whole and reads
no stored length, because a panic can arrive with `revealed_len` set past the
buffer.

`MessageBoxW` runs a modal message loop that dispatches to this thread's
windows, so a panic inside `windowProc` re-enters `windowProc`. A `reporting`
flag turns a second panic into `exit(3)` with no message.

`ci.yml`'s two Windows jobs run `scripts/win-launch-check.ps1`. That script
asserts the exe is still alive 5 seconds after launch, so a panic during
startup fails the job.

## Linking the core from another front end

`zig build` installs the static library at `zig-out/lib/libkeywise.a` and the
header at `zig-out/include/keywise.h`. A front end links those two. Any
language with a C FFI can call them. The SwiftUI app links them through a
raw `-L`/`-l` flag and uses no bridging header.

Call `keywise_open` first. It returns `KEYWISE_ERR_NEEDS_PASSWORD` for a profile
with a Primary Password, so call `keywise_unlock` next. Then `keywise_entries`
fills a whole list in one call, `keywise_search` filters it, and `keywise_reveal`
returns one password. Release that password with `keywise_secret_free`. It
zeroes the buffer before freeing it. One `keywise_store` belongs to one
thread.

`core/test/smoke.c` calls every function in the header in order and runs as
`zig build smoke`.

### Store.open is the one entry point that reads profile data

`Store.open` is the only store operation that touches a file. `keydb.load`
opens `key4.db`, reads it and closes it before returning. `Store.open` then
reads all of `logins.json` into the arena and closes that too. `Store.reveal`
decrypts from the SDR blob and the master key already in the arena.

An open profile is therefore a snapshot. Firefox may rewrite either file
while a front end holds a `Store`, and the entry list stays as it was. A
login saved after the open appears when the front end calls `Store.open`
again. `switchProfile` in `win/src/main.zig` calls it for the profile
already selected, and `selectProfile` in `AppModel.swift` builds a fresh
store, so choosing the same profile reloads on both. The TUI opens once
per run.

A `Store.open` that lands while Firefox writes either file can return
`OpenFailed`, `QueryFailed` or `MalformedJson`, so a torn read reaches the front
end as a message. Reaching that state needs a write to a live profile, and
`docs/FORMAT.md` records that case as untested.

The decryption modules call no OS-specific API. The platform assumptions
live in the front ends. `core.zig` and `tui/src/main.zig` find the root
through `profiles.resolveDir`, and `win/src/main.zig` builds
`%APPDATA%\Mozilla\Firefox`. `tui/src/main.zig` copies with OSC 52 and a
best-effort helper; `win/src/main.zig` copies through `SetClipboardData`.

## Front-end behaviour

### The profile root

A root is the directory holding `profiles.ini` and the profile folders it
names. `profiles.home_relative_dirs` lists the roots for the host it
compiles for, each relative to `$HOME`. macOS has one,
`Library/Application Support/Firefox`. Linux has these:

    .mozilla/firefox
    snap/firefox/common/.mozilla/firefox
    .var/app/org.mozilla.firefox/.mozilla/firefox

`resolveDir` walks that list in order and returns the first root holding a
`profiles.ini`. One run reads one root. A distro package, the Ubuntu snap
and the Flatpak each keep their own, and one machine can carry all of them
populated. Each Firefox install reads the one root its packaging fixes, and
the snap Firefox cannot see `~/.mozilla/firefox`. Reading every root and
merging the lists would print one list mixing two installs, and `--profile`
could then name a profile the running Firefox cannot open.

`--profile <path>` names a profile directory and matches Firefox's own
`-profile <path>`. `main` resolves the root inside the `--list-profiles`
branch and inside the default-profile branch. Resolving it any earlier makes
a populated root a precondition for every run, including a run that names
its own profile directory.

With no root found, `keywise` prints every path it tried and exits 1.
`--list-profiles` prints the resolved root to stderr and the profiles to
stdout, so `cut -f1` over stdout keeps working.

### Copying on Linux

`tui/src/main.zig` picks a helper chain from the environment and stops at
the first helper that spawns and exits 0:

- `$WAYLAND_DISPLAY` set: `wl-copy`, then `xclip -selection clipboard`, then
  `xsel --clipboard --input`.
- `$DISPLAY` set alone: `xclip`, then `xsel`.
- With no display variable set: the chain is empty.

`wl-copy` connects to a Wayland compositor and fails on an X11 session.
`xclip` and `xsel` need `$DISPLAY`, and they reach a Wayland clipboard
through XWayland. Over SSH with no X11 forwarding, every helper fails to
connect, and keywise's OSC 52 write reaches the local terminal's clipboard.
`wl-copy --paste-once` serves one paste request and then drops the
clipboard, so a paste into an XWayland window returns nothing.

Every successful copy leaves `copied` on the status line. `wl-copy` ships in
the `wl-clipboard` package, `xclip` in `xclip` and `xsel` in `xsel`.
`README.md` and `keywise --help` name them.

### The stdout path

`y` copies the password into a buffer on `Model` when
`std.Io.File.stdout().isTty` returns false. `main` writes that buffer once,
after `app.run` returns, with no trailing newline. The last `y` of the run
is what a reader receives.

    keywise                    # stdout is the terminal, so nothing is written
    keywise | wl-copy          # stdout is a pipe, so the password goes down it
    keywise > /tmp/p           # stdout is a file, so the password lands there

libvaxis opens `/dev/tty` directly, so the UI survives a pipe. An
interactive `keywise` writes into terminal scrollback, into a tmux buffer and
into `script` output, and the tty check keeps the password out of all
three. The helper chain runs independently of this, so `keywise > /tmp/p`
behaves the same on a host with `xclip` and on one without it. A `y` press
is what puts bytes anywhere, so a redirect alone writes nothing.

`wl-copy` and `xclip` copy the bytes they receive, and a newline inside a
password field breaks a login form, so the write ends without one. Bytes
already in a pipe cannot be retracted, so buffering lets the last `y`
replace the one before it. The write ends with `catch {}`. A reader that
exits first gives `error.BrokenPipe`, and a `try` would make
`keywise | head -c 5` exit non-zero with a trace.

Each native GUI marks a copied password so a clipboard manager skips it.
macOS writes the `org.nspasteboard.ConcealedType` pasteboard type.
`win/src/clipboard.zig` registers four formats and writes all four ahead of
`CF_UNICODETEXT`, so a monitor reading the moment the text lands already
finds them:

- `CanIncludeInClipboardHistory` and `CanUploadToCloudClipboard` take a
  DWORD 0. These are Windows' own opt-outs for `Win+V` history and for the
  cloud clipboard.
- `ExcludeClipboardContentFromMonitorProcessing` takes any value. A monitor
  that finds it leaves the copy alone.
- `Clipboard Viewer Ignore` is the convention third-party managers honoured
  before Windows 10 named its own.

Both apps clear the clipboard 30 seconds after a copy, and both re-mask a
revealed password on the same timer. Each reads the clipboard's serial
number right after its own write and compares before it clears, so a copy
another program made in between stays. The call is
`GetClipboardSequenceNumber` on Windows and `NSPasteboard.changeCount` on
macOS. The TUI writes through OSC 52 and a helper program, and arms no timer
on any platform.

## Limits

- The Linux TUI arms no clipboard timer and writes no conceal marker. A
  password it copies stays on the clipboard until something else replaces
  it.
- A Linux host with no clipboard helper installed, on a terminal that drops
  OSC 52, reports `copied` and leaves the clipboard empty. The status line
  carries one string.
- The Windows TUI is out of scope. `tui/src/main.zig` calls
  `std.process.Args.Iterator.init`, and that function is a compile error on
  Windows. `build.zig` installs `keywise` only for a non-Windows target.
- The Windows app follows the system dark-mode setting at startup only. It
  reads `AppsUseLightTheme` once and handles no `WM_SETTINGCHANGE`.
