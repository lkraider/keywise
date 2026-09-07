//! Writes one password to the Windows clipboard and clears it later.
//!
//! Windows keeps a clipboard history and syncs the clipboard to the user's
//! other devices. Four registered formats opt one copy out of both.
//! Microsoft documents the first three at
//! <https://learn.microsoft.com/en-us/windows/win32/dataxchg/clipboard-formats>.
//! KeePassXC sets `ExcludeClipboardContentFromMonitorProcessing`, KeePass 2
//! sets the two DWORD formats, and CopyQ honours any of them. These are the
//! Windows counterpart of `org.nspasteboard.ConcealedType` in
//! macos/Sources/Keywise/ClipboardWriter.swift.

const std = @import("std");
const core = @import("core");
const w = @import("win32.zig");

pub const Error = error{ ClipboardBusy, OutOfMemory, TooLong, InvalidUtf8 };

/// Takes any value. A monitor that finds it leaves the copy alone.
const exclude_monitor = std.unicode.utf8ToUtf16LeStringLiteral(
    "ExcludeClipboardContentFromMonitorProcessing",
);
/// These two take a DWORD 0.
const no_history = std.unicode.utf8ToUtf16LeStringLiteral("CanIncludeInClipboardHistory");
const no_cloud = std.unicode.utf8ToUtf16LeStringLiteral("CanUploadToCloudClipboard");
/// The format clipboard managers honoured before Windows 10 named its own.
const viewer_ignore = std.unicode.utf8ToUtf16LeStringLiteral("Clipboard Viewer Ignore");

pub const Writer = struct {
    /// GetClipboardSequenceNumber's value right after the last write. The
    /// delayed clear compares against it, so a copy someone else made in
    /// between survives.
    sequence: w.DWORD = 0,
    owns_content: bool = false,
    scratch: [core.logins.max_field_len + 1]u16 = undefined,

    pub fn write(self: *Writer, owner: w.HWND, text: []const u8) Error!void {
        if (text.len + 1 > self.scratch.len) return error.TooLong;
        defer std.crypto.secureZero(u16, &self.scratch);
        const n = try std.unicode.utf8ToUtf16Le(&self.scratch, text);
        self.scratch[n] = 0;

        if (w.OpenClipboard(owner) == 0) return error.ClipboardBusy;
        var wrote = false;
        defer {
            _ = w.CloseClipboard();
            if (wrote) {
                self.owns_content = true;
                self.sequence = w.GetClipboardSequenceNumber();
            }
        }

        if (self.owns_content) zeroClipboardData();
        _ = w.EmptyClipboard();

        putRegistered(exclude_monitor, &[_]u8{0}) catch {};
        putRegistered(viewer_ignore, &[_]u8{0}) catch {};
        putRegistered(no_history, std.mem.asBytes(&@as(u32, 0))) catch {};
        putRegistered(no_cloud, std.mem.asBytes(&@as(u32, 0))) catch {};

        try put(w.CF_UNICODETEXT, std.mem.sliceAsBytes(self.scratch[0 .. n + 1]));
        wrote = true;
    }

    /// The 30-second timer in main.zig calls this. A copy made by another
    /// program moves the sequence number, and this leaves that copy in place.
    pub fn clearIfUnchanged(self: *Writer, owner: w.HWND) void {
        if (!self.owns_content) return;
        self.owns_content = false;
        if (w.GetClipboardSequenceNumber() != self.sequence) return;
        if (w.OpenClipboard(owner) == 0) return;
        zeroClipboardData();
        _ = w.EmptyClipboard();
        _ = w.CloseClipboard();
    }
};

fn zeroClipboardData() void {
    if (w.GetClipboardData(w.CF_UNICODETEXT)) |handle| {
        if (w.GlobalLock(handle)) |ptr| {
            const size = w.GlobalSize(handle);
            if (size > 0) {
                const dest: [*]u8 = @ptrCast(ptr);
                std.crypto.secureZero(u8, dest[0..size]);
            }
            _ = w.GlobalUnlock(handle);
        }
    }
}

fn putRegistered(name: [*:0]const u16, bytes: []const u8) Error!void {
    const format = w.RegisterClipboardFormatW(name);
    if (format == 0) return error.OutOfMemory;
    return put(format, bytes);
}

/// Copies `bytes` into a moveable global and hands it to the clipboard. The
/// clipboard owns the block after that, so this frees it only on failure.
fn put(format: w.UINT, bytes: []const u8) Error!void {
    const handle = w.GlobalAlloc(w.GMEM_MOVEABLE, bytes.len) orelse return error.OutOfMemory;
    errdefer _ = w.GlobalFree(handle);

    const target = w.GlobalLock(handle) orelse return error.OutOfMemory;
    const dest: [*]u8 = @ptrCast(target);
    @memcpy(dest[0..bytes.len], bytes);
    _ = w.GlobalUnlock(handle);

    if (w.SetClipboardData(format, @ptrCast(handle)) == null) return error.OutOfMemory;
}
