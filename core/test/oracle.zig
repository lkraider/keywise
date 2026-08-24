//! Diffs core/src/sqlitedb.zig against the system sqlite3. For every fixture
//! it walks every table twice. It compares each column's bytes, each rowid,
//! and the row order. This is the correctness argument for core/src/sqlitedb.zig.
//!
//! build.zig builds this test only when the target is the host and the host
//! is macOS, since it links libsqlite3 from the macOS SDK.

const std = @import("std");
const sqlite = @import("sqlite");
const sqlitedb = @import("sqlitedb");

const testing = std.testing;

const fixtures = [_][]const u8{
    "core/testdata/fresh/key4.db",
    "core/testdata/migrated/key4.db",
    "core/testdata/primary/key4.db",
    "core/testdata/sync-shaped/key4.db",
    "core/testdata/unmigrated/key4.db",
    "core/testdata/two-profiles/Profiles/real.default-release/key4.db",
    // Written by scripts/test-mkfixtures.py with a 512-byte page, so its rows spill
    // to overflow pages and its b-tree grows an interior page. No key4.db
    // reaches either branch.
    "core/testdata/overflow.db",
    // A 65536-byte page. SQLite stores that size as 1 in the two-byte field at
    // header offset 16, and sqlitedb.Db.open maps it back.
    "core/testdata/page64k.db",
    // A 16-byte reserved tail on every page. The payload arithmetic counts 496
    // usable bytes of each 512-byte page. Every other fixture reserves 0,
    // where usable and page_size are equal.
    "core/testdata/reserved.db",
    // Random column counts, type affinities, boundary integers, and rows
    // whose records stop before the last column after ALTER TABLE ADD COLUMN.
    "core/testdata/random.db",
    "core/testdata/no-password-row/key4.db",
    "core/testdata/no-key-row/key4.db",
};

/// The widest record is the 75005-byte one in the 64 KB page fixture.
const row_buf_len = 128 * 1024;

test "the reader returns what sqlite3 returns, for every column of every fixture" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const buf = try testing.allocator.alloc(u8, row_buf_len);
    defer testing.allocator.free(buf);

    for (fixtures) |path| try diffFile(io, path, buf);
}

fn diffFile(io: std.Io, path: []const u8, buf: []u8) !void {
    const path_z = try testing.allocator.dupeZ(u8, path);
    defer testing.allocator.free(path_z);

    var ref: ?*sqlite.sqlite3 = null;
    try testing.expectEqual(
        sqlite.SQLITE_OK,
        sqlite.sqlite3_open_v2(path_z.ptr, &ref, sqlite.SQLITE_OPEN_READONLY, null),
    );
    defer _ = sqlite.sqlite3_close(ref);

    var db = try sqlitedb.Db.open(io, path);
    defer db.close();

    var tables: std.ArrayList([]u8) = .empty;
    defer {
        for (tables.items) |t| testing.allocator.free(t);
        tables.deinit(testing.allocator);
    }

    var stmt: ?*sqlite.sqlite3_stmt = null;
    try prepare(ref, "select name from sqlite_master where type = 'table' and name not like 'sqlite_%'", &stmt);
    defer _ = sqlite.sqlite3_finalize(stmt);
    while (sqlite.sqlite3_step(stmt) == sqlite.SQLITE_ROW) {
        try tables.append(testing.allocator, try testing.allocator.dupe(u8, text(stmt, 0)));
    }
    try testing.expect(tables.items.len > 0);

    for (tables.items) |name| try diffTable(&db, ref, name, buf);
}

const Column = struct {
    /// Where the record stores this column, resolved through the
    /// `CREATE TABLE` text the way keydb.zig resolves it.
    index: usize,
    /// A column declared `INTEGER PRIMARY KEY` aliases the rowid.
    rowid_alias: bool,
};

fn diffTable(db: *sqlitedb.Db, ref: ?*sqlite.sqlite3, name: []const u8, buf: []u8) !void {
    const table = try db.table(name, buf);

    var columns: std.ArrayList(Column) = .empty;
    defer columns.deinit(testing.allocator);
    {
        const sql = try std.fmt.allocPrintSentinel(testing.allocator, "pragma table_info({s})", .{name}, 0);
        defer testing.allocator.free(sql);

        var stmt: ?*sqlite.sqlite3_stmt = null;
        try prepare(ref, sql, &stmt);
        defer _ = sqlite.sqlite3_finalize(stmt);
        while (sqlite.sqlite3_step(stmt) == sqlite.SQLITE_ROW) {
            try columns.append(testing.allocator, .{
                .index = try table.columnIndex(text(stmt, 1)),
                .rowid_alias = std.ascii.eqlIgnoreCase(text(stmt, 2), "INTEGER") and
                    sqlite.sqlite3_column_int(stmt, 5) == 1,
            });
        }
    }
    try testing.expect(columns.items.len > 0);

    const sql = try std.fmt.allocPrintSentinel(testing.allocator, "select rowid, * from \"{s}\"", .{name}, 0);
    defer testing.allocator.free(sql);

    var stmt: ?*sqlite.sqlite3_stmt = null;
    try prepare(ref, sql, &stmt);
    defer _ = sqlite.sqlite3_finalize(stmt);

    var it = table.rows(db, buf);
    while (sqlite.sqlite3_step(stmt) == sqlite.SQLITE_ROW) {
        const row = (try it.next()) orelse return error.ReaderStoppedEarly;
        try testing.expectEqual(sqlite.sqlite3_column_int64(stmt, 0), row.rowid);

        for (columns.items, 0..) |col, i| {
            const at: c_int = @intCast(i + 1);
            switch (sqlite.sqlite3_column_type(stmt, at)) {
                sqlite.SQLITE_NULL => try testing.expect(row.column(col.index) == null),
                sqlite.SQLITE_INTEGER => {
                    const want = sqlite.sqlite3_column_int64(stmt, at);
                    if (col.rowid_alias) {
                        try testing.expect(row.column(col.index) == null);
                        try testing.expectEqual(want, row.rowid);
                    } else {
                        try testing.expectEqual(want, row.columnInt(col.index).?);
                    }
                },
                sqlite.SQLITE_FLOAT => {
                    const want = sqlite.sqlite3_column_double(stmt, at);
                    if (row.columnSerial(col.index).? == 7) {
                        const got = row.column(col.index).?;
                        try testing.expectEqual(@as(u64, @bitCast(want)), std.mem.readInt(u64, got[0..8], .big));
                    } else {
                        // A column with REAL affinity stores an integral
                        // value with an integer serial type. SQLite widens it
                        // back to a float on read.
                        try testing.expectEqual(want, @as(f64, @floatFromInt(row.columnInt(col.index).?)));
                    }
                },
                else => try testing.expectEqualSlices(u8, blob(stmt, at), row.column(col.index).?),
            }
        }
    }
    try testing.expect((try it.next()) == null);
}

fn prepare(ref: ?*sqlite.sqlite3, sql: [:0]const u8, stmt: *?*sqlite.sqlite3_stmt) !void {
    try testing.expectEqual(
        sqlite.SQLITE_OK,
        sqlite.sqlite3_prepare_v2(ref, sql.ptr, -1, stmt, null),
    );
}

fn blob(stmt: ?*sqlite.sqlite3_stmt, at: c_int) []const u8 {
    const ptr = sqlite.sqlite3_column_blob(stmt, at);
    const len: usize = @intCast(sqlite.sqlite3_column_bytes(stmt, at));
    if (ptr == null or len == 0) return &.{};
    const bytes: [*]const u8 = @ptrCast(ptr.?);
    return bytes[0..len];
}

fn text(stmt: ?*sqlite.sqlite3_stmt, at: c_int) []const u8 {
    return blob(stmt, at);
}
