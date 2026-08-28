//! Every rule the TUI front end follows. It imports core and std only,
//! so `zig build test` runs it on the build host against core/testdata.
//!
//! main.zig owns the vaxis widgets, the drawing and the clipboard. It
//! asks this file what to show and what an activation means.

const std = @import("std");
const core = @import("core");
const store_mod = core.store;
const logins = core.logins;

pub const masked_password = "\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}";

pub const Opened = enum { opened, needs_password, wrong_password, failed };

pub const Reveal = enum { revealed, hidden, needs_confirmation, failed };

pub const Copy = union(enum) {
    copied: []const u8,
    needs_confirmation,
    failed,
};

const AccountAction = enum { reveal, copy };
const PendingAccountAction = struct { index: usize, action: AccountAction };

pub const Model = struct {
    gpa: std.mem.Allocator,
    io: std.Io,

    store: ?store_mod.Store = null,
    matches: std.ArrayList(usize) = .empty,

    revealed_index: ?usize = null,
    revealed_len: usize = 0,
    reveal_buf: [8192]u8 = undefined,

    copy_len: usize = 0,
    copy_buf: [8192]u8 = undefined,

    status_len: usize = 0,
    status_buf: [256]u8 = undefined,

    pending_account_action: ?PendingAccountAction = null,
    needs_password: bool = false,

    pub fn init(gpa: std.mem.Allocator, io: std.Io) Model {
        return .{ .gpa = gpa, .io = io };
    }

    pub fn deinit(self: *Model) void {
        self.close();
        self.matches.deinit(self.gpa);
    }

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

    pub fn unlock(self: *Model, profile_path: []const u8, password: []const u8) Opened {
        return self.openWith(profile_path, password);
    }

    fn openWith(self: *Model, profile_path: []const u8, password: []const u8) Opened {
        self.close();
        self.needs_password = false;
        self.store = store_mod.Store.open(self.gpa, self.io, profile_path, password) catch |err| {
            if (err == error.WrongPassword and password.len == 0) {
                self.needs_password = true;
                self.setStatus("{s}", .{"this profile needs its Primary Password"});
                return .needs_password;
            }
            self.setStatus("{s}", .{core.messages.friendly(err)});
            if (err == error.WrongPassword) return .wrong_password;
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

    pub fn passwordText(self: *const Model, row: usize) []const u8 {
        if (!self.isRevealed(row)) return masked_password;
        return self.reveal_buf[0..self.revealed_len];
    }

    pub fn isAccountRow(self: *const Model, row: usize) bool {
        const entry = self.entryAt(row) orelse return false;
        return entry.kind == .account_credential;
    }

    pub fn toggleReveal(self: *Model, row: usize) Reveal {
        const index = self.entryIndex(row) orelse return .failed;
        if (self.revealed_index == index) {
            self.hideRevealed();
            return .hidden;
        }
        if (self.isAccountRow(row) and !self.confirmAccountAction(index, .reveal)) {
            return .needs_confirmation;
        }

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
        return .revealed;
    }

    pub fn requestCopy(self: *Model, row: usize) Copy {
        const index = self.entryIndex(row) orelse return .failed;
        if (self.isAccountRow(row) and !self.confirmAccountAction(index, .copy)) {
            return .needs_confirmation;
        }

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
        self.setStatus("{s}", .{"copied"});
    }

    pub fn clearCopy(self: *Model) void {
        std.crypto.secureZero(u8, &self.copy_buf);
        self.copy_len = 0;
    }

    pub fn hideRevealed(self: *Model) void {
        std.crypto.secureZero(u8, &self.reveal_buf);
        self.revealed_len = 0;
        self.revealed_index = null;
    }

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

    pub fn tombstonesSkipped(self: *const Model) usize {
        const s = self.store orelse return 0;
        return s.tombstones_skipped;
    }

    pub fn reportEntryCount(self: *Model) void {
        const tombstones = self.tombstonesSkipped();
        if (tombstones > 0) {
            self.setStatus("{d} logins ({d} tombstones skipped)", .{ self.entryCount(), tombstones });
        } else {
            self.setStatus("{d} logins", .{self.entryCount()});
        }
    }

    pub fn setStatus(self: *Model, comptime fmt: []const u8, args: anytype) void {
        var w: std.Io.Writer = .fixed(&self.status_buf);
        w.print(fmt, args) catch {};
        self.status_len = w.end;
    }

    fn confirmAccountAction(self: *Model, index: usize, action: AccountAction) bool {
        if (self.pending_account_action) |pending| {
            if (pending.index == index and pending.action == action) {
                self.pending_account_action = null;
                return true;
            }
        }
        self.pending_account_action = .{ .index = index, .action = action };
        return false;
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

test "the account row reveals only after a second activation" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var m = testModel(&threaded);
    defer m.deinit();
    try openFixture(&m, "sync-shaped");

    const row = accountRow(&m).?;
    try testing.expectEqual(Reveal.needs_confirmation, m.toggleReveal(row));
    try testing.expect(m.revealed_index == null);
    try testing.expectEqualStrings(masked_password, m.passwordText(row));

    try testing.expectEqual(Reveal.revealed, m.toggleReveal(row));
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
    try testing.expectEqual(Reveal.revealed, m.toggleReveal(row));
    try testing.expect(std.mem.startsWith(u8, m.passwordText(row), "fixture-pass-"));

    try testing.expectEqual(Reveal.hidden, m.toggleReveal(row));
    try testing.expectEqualStrings(masked_password, m.passwordText(row));
    try testing.expectEqualStrings("5 logins (2 tombstones skipped)", m.status());
}

test "revealing a second row masks the first" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var m = testModel(&threaded);
    defer m.deinit();
    try openFixture(&m, "fresh");

    try testing.expectEqual(Reveal.revealed, m.toggleReveal(0));
    try testing.expectEqual(Reveal.revealed, m.toggleReveal(1));
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
    try testing.expectEqual(Copy.needs_confirmation, m.requestCopy(row));

    switch (m.requestCopy(row)) {
        .copied => |text| try testing.expect(text.len > 0),
        else => return error.CopyFailed,
    }
    try testing.expectEqualStrings("5 logins (2 tombstones skipped)", m.status());
    try testing.expect(m.revealed_index == null);
    m.clearCopy();

    try testing.expectEqual(Reveal.needs_confirmation, m.toggleReveal(row));
}

test "clearCopy wipes the plaintext" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var m = testModel(&threaded);
    defer m.deinit();
    try openFixture(&m, "fresh");

    const copied = switch (m.requestCopy(0)) {
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

    try testing.expectEqual(Reveal.revealed, m.toggleReveal(0));
    switch (m.requestCopy(0)) {
        .copied => {},
        else => return error.CopyFailed,
    }
    try testing.expect(m.revealed_len > 0);
    try testing.expect(m.copy_len > 0);

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
    try testing.expectEqual(Reveal.failed, m.toggleReveal(0));
    for (&m.reveal_buf) |b| try testing.expectEqual(@as(u8, 0), b);

    @memset(&m.copy_buf, 0xa5);
    try testing.expectEqual(Copy.failed, m.requestCopy(0));
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
    try testing.expectEqual(Opened.wrong_password, m.unlock("core/testdata/primary", "wrong"));
    try testing.expectEqualStrings(core.messages.friendly(error.WrongPassword), m.status());

    try testing.expectEqual(
        Opened.opened,
        m.unlock("core/testdata/primary", "fixture-primary-password-1"),
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
