//! Every rule the Windows front end follows. It imports core and std only,
//! so `zig build test` runs it on the build host against core/testdata.
//!
//! main.zig owns the window, the timers and the message box. It asks this
//! file what to show and what an activation means.

const std = @import("std");
const core = @import("core");
const profiles = core.profiles;
const store_mod = core.store;
const logins = core.logins;

/// Six U+2022 BULLET characters. The list draws this for every masked row.
pub const masked_password = "\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}";

pub const account_reveal_prompt =
    "This reveals Firefox Sync account credentials.\n\nReveal the password?";
pub const account_copy_prompt =
    "This copies Firefox Sync account credentials to the clipboard.\n\nCopy the password?";

pub const Opened = enum { opened, needs_password, failed };

pub const Reveal = enum { revealed, hidden, needs_confirmation, failed };

pub const Copy = union(enum) {
    /// Points into the model's own buffer. Call `clearCopy` after the
    /// clipboard has taken it.
    copied: []const u8,
    needs_confirmation,
    failed,
};

/// Why the clipboard refused the plaintext `requestCopy` handed back.
///
/// This enum repeats the variants of `clipboard.Error`, and main.zig maps one
/// to the other at its one call site. clipboard.zig imports win32.zig, which
/// declares `extern "user32"` functions. build.zig builds this file's tests
/// with the `core` import alone and runs them on the build host, so an import
/// of clipboard.zig here would break that link.
pub const CopyFailure = enum { clipboard_busy, too_long, invalid_text, out_of_memory };

pub const Model = struct {
    gpa: std.mem.Allocator,
    io: std.Io,

    store: ?store_mod.Store = null,
    /// Entry indices the current query matched, in entry order.
    matches: std.ArrayList(usize) = .empty,

    revealed_index: ?usize = null,
    revealed_len: usize = 0,
    reveal_buf: [8192]u8 = undefined,

    copy_len: usize = 0,
    copy_buf: [8192]u8 = undefined,

    status_len: usize = 0,
    status_buf: [256]u8 = undefined,

    /// Set by the last `open` or `unlock`. main.zig raises the Primary
    /// Password dialog while it is true.
    needs_password: bool = false,

    pub fn init(gpa: std.mem.Allocator, io: std.Io) Model {
        return .{ .gpa = gpa, .io = io };
    }

    pub fn deinit(self: *Model) void {
        self.close();
        self.matches.deinit(self.gpa);
    }

    /// Wipes both secret buffers and releases the profile.
    pub fn close(self: *Model) void {
        self.hideRevealed();
        self.clearCopy();
        if (self.store) |*s| s.deinit();
        self.store = null;
        self.matches.clearRetainingCapacity();
    }

    pub fn open(self: *Model, profile_path: []const u8) Opened {
        return self.openWith(profile_path, "");
    }

    /// The password the Primary Password dialog collected. `open` reports
    /// `needs_password` first, so this call knows the profile has one.
    pub fn unlock(self: *Model, profile_path: []const u8, password: []const u8) Opened {
        return self.openWith(profile_path, password);
    }

    fn openWith(self: *Model, profile_path: []const u8, password: []const u8) Opened {
        self.close();
        self.needs_password = false;
        self.store = store_mod.Store.open(self.gpa, self.io, profile_path, password) catch |err| {
            // An empty password reaching WrongPassword means the profile has
            // a Primary Password of its own. No caller supplied one yet.
            if (err == error.WrongPassword and password.len == 0) {
                self.needs_password = true;
                self.setStatus("{s}", .{"this profile needs its Primary Password"});
                return .needs_password;
            }
            self.setStatus("{s}", .{core.messages.friendly(err)});
            return .failed;
        };
        self.search("") catch {
            if (self.store) |*s| s.deinit();
            self.store = null;
            self.setStatus("{s}", .{"out of memory"});
            return .failed;
        };
        self.reportEntryCount();
        return .opened;
    }

    /// profiles.ini lists profiles Firefox abandoned, including the one the
    /// legacy `Default=1` flag points at. Those carry no key4.db and `open`
    /// fails on them. This returns the position of the first profile that
    /// opens or that asks for a Primary Password.
    pub fn openFirst(self: *Model, list: []const profiles.Profile) ?usize {
        for (list, 0..) |p, i| {
            switch (self.open(p.path)) {
                .opened, .needs_password => return i,
                .failed => {},
            }
        }
        self.setStatus("{s}", .{if (list.len == 0)
            "no Firefox profile found"
        else
            "no profile with saved logins found"});
        return null;
    }

    /// Refills `matches`. An empty query matches every entry.
    pub fn search(self: *Model, query: []const u8) !void {
        self.matches.clearRetainingCapacity();
        const s = &(self.store orelse return);
        try self.matches.ensureTotalCapacity(self.gpa, s.entries.len);
        self.matches.items.len = s.entries.len;
        const total = s.search(query, self.matches.items);
        self.matches.items.len = @min(total, s.entries.len);
    }

    pub fn rowCount(self: *const Model) usize {
        return self.matches.items.len;
    }

    /// The entry a list row draws. `row` counts matched rows, and the entry
    /// index behind it comes from `matches`.
    pub fn entryAt(self: *const Model, row: usize) ?logins.Entry {
        const s = self.store orelse return null;
        if (row >= self.matches.items.len) return null;
        return s.entries[self.matches.items[row]];
    }

    pub fn entryIndex(self: *const Model, row: usize) ?usize {
        if (row >= self.matches.items.len) return null;
        return self.matches.items[row];
    }

    pub fn entryCount(self: *const Model) usize {
        const s = self.store orelse return 0;
        return s.entries.len;
    }

    pub fn isRevealed(self: *const Model, row: usize) bool {
        const index = self.entryIndex(row) orelse return false;
        return self.revealed_index == index;
    }

    /// The text of a row's password column.
    pub fn passwordText(self: *const Model, row: usize) []const u8 {
        if (!self.isRevealed(row)) return masked_password;
        return self.reveal_buf[0..self.revealed_len];
    }

    pub fn isAccountRow(self: *const Model, row: usize) bool {
        const entry = self.entryAt(row) orelse return false;
        return entry.kind == .account_credential;
    }

    /// A second activation on the revealed row hides it. `confirmed` carries
    /// the answer to the message box main.zig raises for the account row.
    pub fn toggleReveal(self: *Model, row: usize, confirmed: bool) Reveal {
        const index = self.entryIndex(row) orelse return .failed;
        if (self.revealed_index == index) {
            self.hideRevealed();
            self.reportEntryCount();
            return .hidden;
        }
        if (self.isAccountRow(row) and !confirmed) return .needs_confirmation;

        const s = &(self.store orelse return .failed);
        self.hideRevealed();

        var scratch: [8192]u8 = undefined;
        defer std.crypto.secureZero(u8, &scratch);
        const plain = s.reveal(index, &scratch, &self.reveal_buf) catch |err| {
            self.hideRevealed();
            self.setStatus("{s}", .{core.messages.friendly(err)});
            return .failed;
        };
        self.revealed_index = index;
        self.revealed_len = plain.len;
        self.reportEntryCount();
        return .revealed;
    }

    /// Decrypts one row's password into `copy_buf`. The row stays masked.
    ///
    /// The status stays where it was. The clipboard has not taken the
    /// plaintext yet, and `OpenClipboard` returns 0 while another process
    /// holds the clipboard. main.zig calls `reportCopied` or
    /// `reportCopyFailed` once it knows.
    pub fn requestCopy(self: *Model, row: usize, confirmed: bool) Copy {
        const index = self.entryIndex(row) orelse return .failed;
        if (self.isAccountRow(row) and !confirmed) return .needs_confirmation;

        const s = &(self.store orelse return .failed);
        self.clearCopy();
        var scratch: [8192]u8 = undefined;
        defer std.crypto.secureZero(u8, &scratch);
        const plain = s.reveal(index, &scratch, &self.copy_buf) catch |err| {
            self.clearCopy();
            self.setStatus("{s}", .{core.messages.friendly(err)});
            return .failed;
        };
        self.copy_len = plain.len;
        return .{ .copied = self.copy_buf[0..self.copy_len] };
    }

    pub fn reportCopied(self: *Model) void {
        self.setStatus("{s}", .{"Copied"});
    }

    pub fn reportCopyFailed(self: *Model, reason: CopyFailure) void {
        self.setStatus("{s}", .{switch (reason) {
            .clipboard_busy => "another program is using the clipboard",
            .too_long => "this password is too long to copy",
            .invalid_text => "this password is not valid text",
            .out_of_memory => "out of memory",
        }});
    }

    pub fn clearCopy(self: *Model) void {
        std.crypto.secureZero(u8, &self.copy_buf);
        self.copy_len = 0;
    }

    /// The 30-second timer in main.zig calls this. So does Esc and so does a
    /// second activation on the revealed row.
    pub fn hideRevealed(self: *Model) void {
        std.crypto.secureZero(u8, &self.reveal_buf);
        self.revealed_len = 0;
        self.revealed_index = null;
    }

    /// Zeroes both plaintext buffers whole. crash.zig calls this from the
    /// panic handler; it deliberately reads neither stored length because a
    /// panic can arrive mid-assignment.
    pub fn wipeSecrets(self: *Model) void {
        std.crypto.secureZero(u8, &self.reveal_buf);
        std.crypto.secureZero(u8, &self.copy_buf);
        self.revealed_len = 0;
        self.revealed_index = null;
        self.copy_len = 0;
    }

    pub fn status(self: *const Model) []const u8 {
        return self.status_buf[0..self.status_len];
    }

    pub fn reportEntryCount(self: *Model) void {
        self.setStatus("{d} logins", .{self.entryCount()});
    }

    fn setStatus(self: *Model, comptime fmt: []const u8, args: anytype) void {
        var w: std.Io.Writer = .fixed(&self.status_buf);
        w.print(fmt, args) catch {};
        self.status_len = w.end;
    }
};

const testing = std.testing;

fn openFixture(m: *Model, name: []const u8) !void {
    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "core/testdata/{s}", .{name});
    try testing.expectEqual(Opened.opened, m.open(path));
}

fn testModel(threaded: *std.Io.Threaded) Model {
    return .init(testing.allocator, threaded.io());
}

fn accountRow(m: *const Model) ?usize {
    for (0..m.rowCount()) |row| if (m.isAccountRow(row)) return row;
    return null;
}

fn ordinaryRow(m: *const Model) ?usize {
    for (0..m.rowCount()) |row| {
        const entry = m.entryAt(row).?;
        if (entry.kind == .normal) return row;
    }
    return null;
}

test "the account row reveals only after a confirmed activation" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var m = testModel(&threaded);
    defer m.deinit();
    try openFixture(&m, "sync-shaped");

    const row = accountRow(&m).?;
    try testing.expectEqual(Reveal.needs_confirmation, m.toggleReveal(row, false));
    try testing.expect(m.revealed_index == null);
    try testing.expectEqualStrings(masked_password, m.passwordText(row));

    try testing.expectEqual(Reveal.revealed, m.toggleReveal(row, true));
    try testing.expect(m.revealed_index != null);
    try testing.expect(std.mem.startsWith(u8, m.passwordText(row), "{"));
}

test "an ordinary row reveals on the first activation and hides on the second" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var m = testModel(&threaded);
    defer m.deinit();
    try openFixture(&m, "sync-shaped");

    const row = ordinaryRow(&m).?;
    try testing.expectEqual(Reveal.revealed, m.toggleReveal(row, false));
    try testing.expect(std.mem.startsWith(u8, m.passwordText(row), "fixture-pass-"));

    try testing.expectEqual(Reveal.hidden, m.toggleReveal(row, false));
    try testing.expectEqualStrings(masked_password, m.passwordText(row));
    try testing.expectEqualStrings("5 logins", m.status());
}

test "revealing a second row masks the first" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var m = testModel(&threaded);
    defer m.deinit();
    try openFixture(&m, "fresh");

    try testing.expectEqual(Reveal.revealed, m.toggleReveal(0, false));
    try testing.expectEqual(Reveal.revealed, m.toggleReveal(1, false));
    try testing.expectEqualStrings(masked_password, m.passwordText(0));
    try testing.expect(std.mem.startsWith(u8, m.passwordText(1), "fixture-pass-"));
}

test "a confirmed copy leaves the row masked and the next reveal asks again" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var m = testModel(&threaded);
    defer m.deinit();
    try openFixture(&m, "sync-shaped");

    const row = accountRow(&m).?;
    try testing.expectEqual(Copy.needs_confirmation, m.requestCopy(row, false));

    switch (m.requestCopy(row, true)) {
        .copied => |text| try testing.expect(text.len > 0),
        else => return error.CopyFailed,
    }
    // The clipboard has not taken it yet, so the bar still shows the count.
    try testing.expectEqualStrings("5 logins", m.status());
    try testing.expect(m.revealed_index == null);
    m.clearCopy();

    // Confirming the copy answered that copy. The reveal is a second
    // decision.
    try testing.expectEqual(Reveal.needs_confirmation, m.toggleReveal(row, false));
}

test "the status carries the reason a copy failed" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var m = testModel(&threaded);
    defer m.deinit();
    try openFixture(&m, "fresh");

    // requestCopy hands main.zig the plaintext and leaves the bar alone.
    switch (m.requestCopy(0, false)) {
        .copied => {},
        else => return error.CopyFailed,
    }
    try testing.expectEqualStrings("3 logins", m.status());
    m.clearCopy();

    m.reportCopyFailed(.clipboard_busy);
    try testing.expectEqualStrings("another program is using the clipboard", m.status());
    m.reportCopyFailed(.too_long);
    try testing.expectEqualStrings("this password is too long to copy", m.status());
    m.reportCopyFailed(.invalid_text);
    try testing.expectEqualStrings("this password is not valid text", m.status());
    m.reportCopyFailed(.out_of_memory);
    try testing.expectEqualStrings("out of memory", m.status());

    m.reportCopied();
    try testing.expectEqualStrings("Copied", m.status());
}

test "clearCopy wipes the plaintext it handed the clipboard" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var m = testModel(&threaded);
    defer m.deinit();
    try openFixture(&m, "fresh");

    const copied = switch (m.requestCopy(0, false)) {
        .copied => |text| text,
        else => return error.CopyFailed,
    };
    const len = copied.len;
    try testing.expect(len > 0);

    m.clearCopy();
    for (m.copy_buf[0..len]) |b| try testing.expectEqual(@as(u8, 0), b);
}

test "wipeSecrets clears both buffers whole and survives a length past the buffer" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var m = testModel(&threaded);
    defer m.deinit();
    try openFixture(&m, "fresh");

    try testing.expectEqual(Reveal.revealed, m.toggleReveal(0, false));
    switch (m.requestCopy(0, false)) {
        .copied => {},
        else => return error.CopyFailed,
    }
    try testing.expect(m.revealed_len > 0);
    try testing.expect(m.copy_len > 0);

    // The panic this runs from can arrive mid-assignment, so both lengths
    // carry a value no code path leaves behind.
    m.revealed_len = m.reveal_buf.len + 4096;
    m.copy_len = std.math.maxInt(usize);

    m.wipeSecrets();
    for (&m.reveal_buf) |b| try testing.expectEqual(@as(u8, 0), b);
    for (&m.copy_buf) |b| try testing.expectEqual(@as(u8, 0), b);
    try testing.expectEqual(@as(usize, 0), m.revealed_len);
    try testing.expectEqual(@as(usize, 0), m.copy_len);
    try testing.expect(m.revealed_index == null);
}

test "a failed 3DES reveal or copy wipes the destination buffer" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var m = testModel(&threaded);
    defer m.deinit();
    try openFixture(&m, "unmigrated");

    @memset(&m.reveal_buf, 0xa5);
    try testing.expectEqual(Reveal.failed, m.toggleReveal(0, false));
    for (&m.reveal_buf) |b| try testing.expectEqual(@as(u8, 0), b);

    @memset(&m.copy_buf, 0xa5);
    try testing.expectEqual(Copy.failed, m.requestCopy(0, false));
    try testing.expectEqualStrings(
        core.messages.friendly(error.LegacyTripleDes),
        m.status(),
    );
    for (&m.copy_buf) |b| try testing.expectEqual(@as(u8, 0), b);
    try testing.expectEqual(@as(usize, 0), m.copy_len);
}

test "search narrows the rows and an empty query restores them" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var m = testModel(&threaded);
    defer m.deinit();
    try openFixture(&m, "fresh");

    try testing.expectEqual(@as(usize, 3), m.rowCount());
    try m.search("fixture-user-2");
    try testing.expectEqual(@as(usize, 1), m.rowCount());
    try testing.expectEqualStrings("https://sub.example.org", m.entryAt(0).?.hostname);

    try m.search("no-such-substring-anywhere");
    try testing.expectEqual(@as(usize, 0), m.rowCount());

    try m.search("");
    try testing.expectEqual(@as(usize, 3), m.rowCount());
}

test "the primary fixture asks for its Primary Password and unlock opens it" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var m = testModel(&threaded);
    defer m.deinit();

    try testing.expectEqual(Opened.needs_password, m.open("core/testdata/primary"));
    try testing.expectEqual(Opened.failed, m.unlock("core/testdata/primary", "wrong"));
    try testing.expectEqualStrings(core.messages.friendly(error.WrongPassword), m.status());

    try testing.expectEqual(
        Opened.opened,
        m.unlock("core/testdata/primary", "fixture-primary-password-1"),
    );
    try testing.expectEqual(@as(usize, 3), m.rowCount());
}

test "openFirst skips the profile with no key4.db" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var m = testModel(&threaded);
    defer m.deinit();

    const firefox_dir = "core/testdata/two-profiles";
    const ini = try std.Io.Dir.cwd().readFileAlloc(
        threaded.io(),
        firefox_dir ++ "/profiles.ini",
        testing.allocator,
        .unlimited,
    );
    defer testing.allocator.free(ini);

    const list = try profiles.enumerate(testing.allocator, firefox_dir, ini);
    defer {
        for (list) |p| {
            testing.allocator.free(p.name);
            testing.allocator.free(p.path);
        }
        testing.allocator.free(list);
    }

    // Profile0 in this ini is `abandoned.default`, an empty directory.
    const picked = m.openFirst(list).?;
    // profiles.enumerate joins through std.fs.path.join. That function writes
    // the host's separator.
    try testing.expectEqualStrings(
        firefox_dir ++ std.fs.path.sep_str ++ "Profiles/real.default-release",
        list[picked].path,
    );
    try testing.expectEqual(@as(usize, 3), m.rowCount());
}

test "a profile with key4.db but no logins.json opens with 0 logins" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var m = testModel(&threaded);
    defer m.deinit();
    try openFixture(&m, "no-logins");

    try testing.expectEqual(@as(usize, 0), m.rowCount());
    try testing.expectEqualStrings("0 logins", m.status());
}

test "openFirst reports the empty list" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var m = testModel(&threaded);
    defer m.deinit();

    try testing.expect(m.openFirst(&.{}) == null);
    try testing.expectEqualStrings("no Firefox profile found", m.status());
}

test "setStatus truncates on overflow and reports the valid length" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var m = testModel(&threaded);
    defer m.deinit();

    const long = "A" ** 300;
    m.setStatus("{s}", .{long});
    try testing.expectEqual(@as(usize, 256), m.status().len);
    for (m.status()) |b| try testing.expectEqual(@as(u8, 'A'), b);
}
