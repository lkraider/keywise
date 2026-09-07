//! The Windows app's panic handler. It shows the message in a `MessageBoxW`
//! and exits with code 3.
//!
//! `build.zig` sets `win_exe.subsystem = .Windows`, so the process runs with no
//! console and Zig's default panic write to stderr reaches nobody. A panic
//! there closes the window and reports nothing.
//!
//! `main.zig` declares `pub const panic = std.debug.FullPanic(crash.report)`.
//! `std.debug.panicExtra` formats every safety panic into text first, so
//! `report` receives strings like `index out of bounds: index 512, len 511`.
//!
//! This file imports `win32.zig`, so `zig build test` cannot run its code on
//! the build host. `Model.wipeSecrets` holds the part `zig build test` covers.

const std = @import("std");

const w = @import("win32.zig");
const text_mod = @import("text.zig");
const model_mod = @import("model.zig");

/// Set in `WM_CREATE`. `report` wipes the plaintext buffers through it. It
/// stays null for a panic raised before the window exists.
pub var model: ?*model_mod.Model = null;
pub var row_buf: ?[]u16 = null;

var reporting = false;

const title = std.unicode.utf8ToUtf16LeStringLiteral("Keywise");

const headline = "The app hit a bug and has to close.";

pub fn report(msg: []const u8, first_trace_addr: ?usize) noreturn {
    @branchHint(.cold);
    // MessageBoxW below runs a modal message loop and dispatches to this
    // thread's windows, so a second panic can arrive inside that call with the
    // app's state part-way through whatever broke.
    if (reporting) std.process.exit(3);
    reporting = true;

    // MessageBoxW waits for a click, and it waits as long as the user takes. A
    // memory dump taken during that wait holds the revealed password.
    if (model) |m| m.wipeSecrets();
    if (row_buf) |buf| std.crypto.secureZero(u16, buf);

    // std.debug.panicExtra formats into a 0x1000-byte buffer, so a safety
    // panic's text reaches 4096 bytes. A shorter buffer here would drop it and
    // show the headline alone.
    var body: [4608]u8 = undefined;
    const written: []const u8 = std.fmt.bufPrint(&body,
        \\{s}
        \\
        \\{s}
        \\Return address: 0x{x}
        \\
        \\Please report this at
        \\https://github.com/lkraider/keywise/issues
    , .{ headline, msg, first_trace_addr orelse 0 }) catch headline;

    // UTF-8 spends at least one byte per UTF-16 unit, so this holds whatever
    // bufPrint wrote above.
    var wide: [4608]u16 = undefined;
    _ = text_mod.wideZ(&wide, written);
    _ = w.MessageBoxW(null, @ptrCast(&wide), title, w.MB_OK | w.MB_ICONERROR);

    // std.process.exit lowers to RtlExitUserProcess on Windows. A return from
    // this function is a compile error, and every other path back into the app
    // runs on state a safety check already rejected.
    std.process.exit(3);
}
