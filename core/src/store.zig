//! Owns one profile's decrypted state. The arena holds every string in
//! `entries`. `keys` decrypts a revealed password. The search filter lives
//! here, so the TUI and the macOS app match the same way.

const std = @import("std");
const keydb = @import("keydb.zig");
const logins = @import("logins.zig");

pub const Error = keydb.Error || logins.Error || error{ LoginsUnreadable, AccessDenied } || std.mem.Allocator.Error;
pub const RevealError = logins.RevealError;

pub const Entry = logins.Entry;
pub const Kind = logins.Kind;

pub const Store = struct {
    arena: std.heap.ArenaAllocator,
    keys: keydb.Keys,
    entries: []Entry,
    tombstones_skipped: usize,
    malformed: usize,

    /// Decrypts every username here, and keeps each password as its SDR blob
    /// for `reveal`. `backing` serves the open itself. Everything returned
    /// lives in the arena this `Store` owns from here on.
    pub fn open(
        backing: std.mem.Allocator,
        io: std.Io,
        profile_path: []const u8,
        password: []const u8,
    ) Error!Store {
        var arena_state = std.heap.ArenaAllocator.init(backing);
        errdefer arena_state.deinit();
        const gpa = arena_state.allocator();

        const key4 = try std.fmt.allocPrint(gpa, "{s}/key4.db", .{profile_path});
        var keys = try keydb.load(io, key4, password);
        defer std.crypto.secureZero(u8, std.mem.asBytes(&keys));

        const cwd = std.Io.Dir.cwd();
        const logins_path = try std.fmt.allocPrint(gpa, "{s}/logins.json", .{profile_path});
        const json = cwd.readFileAlloc(io, logins_path, gpa, .unlimited) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.FileNotFound => return .{
                .arena = arena_state,
                .keys = keys,
                .entries = &.{},
                .tombstones_skipped = 0,
                .malformed = 0,
            },
            error.AccessDenied => return error.AccessDenied,
            else => return error.LoginsUnreadable,
        };

        const result = try logins.scan(gpa, json, &keys);

        return .{
            .arena = arena_state,
            .keys = keys,
            .entries = result.entries,
            .tombstones_skipped = result.tombstones_skipped,
            .malformed = result.malformed,
        };
    }

    /// Wipes every decrypted username and key before freeing the arena that
    /// holds the entries. `reveal` decrypts into the caller's buffer, and the
    /// caller wipes that one.
    pub fn deinit(self: *Store) void {
        for (self.entries) |e| {
            std.crypto.secureZero(u8, @constCast(e.username));
        }
        std.crypto.secureZero(u8, std.mem.asBytes(&self.keys));
        self.arena.deinit();
    }

    /// Case-insensitive substring match over hostname and username. Writes
    /// at most `out.len` matching indices, in entry order, and returns the
    /// total number that matched. That total may exceed `out.len`. An empty
    /// query matches every entry.
    pub fn search(self: *const Store, query: []const u8, out: []usize) usize {
        var count: usize = 0;
        for (self.entries, 0..) |e, i| {
            const hit = query.len == 0 or
                containsIgnoreCase(e.hostname, query) or
                containsIgnoreCase(e.username, query);
            if (!hit) continue;
            if (count < out.len) out[count] = i;
            count += 1;
        }
        return count;
    }

    /// Decrypts entry `index`'s password into `out`. Returns
    /// `error.LegacyTripleDes` for an entry this project cannot decrypt.
    pub fn reveal(self: *const Store, index: usize, scratch: []u8, out: []u8) RevealError![]u8 {
        return logins.revealPassword(self.entries[index], &self.keys, scratch, out);
    }
};

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}
