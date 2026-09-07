//! Read-only reader for the SQLite file format. It walks one table's b-tree.
//! It hands back each row's column bytes. The caller filters the rows.
//!
//! Every read is a positional read at one file offset. The caller supplies
//! the row buffer. Every slice a `Row` returns points into that buffer.
//!
//! The format is documented at <https://sqlite.org/fileformat2.html>.

const std = @import("std");

pub const Error = error{
    NotSqlite,
    UnsupportedEncoding,
    WalJournal,
    Corrupt,
    TableNotFound,
    ColumnNotFound,
    RowTooLarge,
};

pub const ReadError = std.Io.File.ReadPositionalError || std.Io.File.LengthError;
pub const OpenError = Error || ReadError || std.Io.File.OpenError;

const magic = "SQLite format 3\x00";

/// A table b-tree this deep holds more rows than any key4.db. The limit also
/// stops the walk on a page that points back at itself.
const max_depth = 24;

pub const Db = struct {
    io: std.Io,
    file: std.Io.File,
    page_size: u32,
    /// `page_size` minus the reserved tail every page gives to an extension.
    /// The payload arithmetic counts usable bytes.
    usable: u32,
    page_count: u32,

    pub fn open(io: std.Io, path: []const u8) OpenError!Db {
        const file = try std.Io.Dir.cwd().openFile(io, path, .{ .allow_directory = false });
        errdefer file.close(io);

        var head: [100]u8 = undefined;
        if (try file.readPositionalAll(io, &head, 0) != head.len) return error.NotSqlite;
        if (!std.mem.eql(u8, head[0..16], magic)) return error.NotSqlite;

        // Offset 16 is two bytes wide, so it stores a 65536-byte page as 1.
        const declared = std.mem.readInt(u16, head[16..18], .big);
        const page_size: u32 = if (declared == 1) 65536 else declared;
        if (page_size < 512 or !std.math.isPowerOfTwo(page_size)) return error.NotSqlite;

        // Write version 2 means WAL. The newest committed rows then live in a
        // -wal file. This reader reads the main file only.
        if (head[18] == 2) return error.WalJournal;

        // The caller matches a text column against UTF-8 bytes.
        if (std.mem.readInt(u32, head[56..60], .big) != 1) return error.UnsupportedEncoding;

        const reserved: u32 = head[20];
        if (page_size - reserved < 480) return error.Corrupt;

        // The page count at offset 28 is valid only while the change counter
        // at 24 matches the version-valid-for number at 92. Dividing the file
        // length by the page size gives the count in every case.
        const size = try file.length(io);
        const page_count = size / page_size;
        if (page_count == 0 or page_count > std.math.maxInt(u32)) return error.Corrupt;

        return .{
            .io = io,
            .file = file,
            .page_size = page_size,
            .usable = page_size - reserved,
            .page_count = @intCast(page_count),
        };
    }

    pub fn close(self: *Db) void {
        self.file.close(self.io);
    }

    /// The root page and the `CREATE TABLE` text of `name`. `sql` points into
    /// `buf`, so read the column indices out before passing `buf` to `rows`.
    pub fn table(self: *const Db, name: []const u8, buf: []u8) (Error || ReadError)!Table {
        // sqlite_master sits on page 1. The format fixes its columns: type,
        // name, tbl_name, rootpage, sql.
        var it: RowIterator = .{ .db = self, .root = 1, .buf = buf };
        while (try it.next()) |row| {
            const kind = row.column(0) orelse continue;
            if (!std.mem.eql(u8, kind, "table")) continue;
            const found = row.column(1) orelse continue;
            if (!std.mem.eql(u8, found, name)) continue;

            const root = row.columnInt(3) orelse return error.Corrupt;
            if (root < 1 or root > self.page_count) return error.Corrupt;
            return .{ .root = @intCast(root), .sql = row.column(4) orelse return error.Corrupt };
        }
        return error.TableNotFound;
    }

    fn read(self: *const Db, page: u32, offset: u32, buf: []u8) (Error || ReadError)!void {
        if (page == 0 or page > self.page_count) return error.Corrupt;
        if (@as(u64, offset) + buf.len > self.page_size) return error.Corrupt;
        const at = (@as(u64, page - 1) * self.page_size) + offset;
        if (try self.file.readPositionalAll(self.io, buf, at) != buf.len) return error.Corrupt;
    }

    /// Copies one cell's payload into `buf` and returns its length.
    fn readPayload(self: *const Db, buf: []u8, page: u32, offset: u32, total: usize) (Error || ReadError)!usize {
        if (total > buf.len) return error.RowTooLarge;

        const max_local: usize = self.usable - 35;
        if (total <= max_local) {
            try self.read(page, offset, buf[0..total]);
            return total;
        }

        // K fills the last overflow page exactly. SQLite falls back to
        // min_local when K runs past what the cell's own page can hold.
        const min_local: usize = ((@as(usize, self.usable) - 12) * 32 / 255) - 23;
        const k = min_local + (total - min_local) % (@as(usize, self.usable) - 4);
        const local = if (k <= max_local) k else min_local;
        try self.read(page, offset, buf[0..local]);

        var link: [4]u8 = undefined;
        try self.read(page, offset + @as(u32, @intCast(local)), &link);
        var next = std.mem.readInt(u32, &link, .big);

        var have = local;
        var visited: u32 = 0;
        while (have < total) {
            if (next == 0) return error.Corrupt;
            visited += 1;
            if (visited > self.page_count) return error.Corrupt;

            try self.read(next, 0, &link);
            const chunk = @min(@as(usize, self.usable) - 4, total - have);
            try self.read(next, 4, buf[have..][0..chunk]);
            have += chunk;
            next = std.mem.readInt(u32, &link, .big);
        }
        return total;
    }
};

pub const Table = struct {
    root: u32,
    sql: []const u8,

    /// The position of `name` in the `CREATE TABLE` column list. nssPrivate
    /// declares 192 columns in one profile and 193 in another, so a constant
    /// index would be an assumption about the profile.
    pub fn columnIndex(self: Table, name: []const u8) Error!usize {
        const open = std.mem.indexOfScalar(u8, self.sql, '(') orelse return error.ColumnNotFound;
        const close = std.mem.lastIndexOfScalar(u8, self.sql, ')') orelse return error.ColumnNotFound;
        if (close <= open) return error.ColumnNotFound;
        const body = self.sql[open + 1 .. close];

        var index: usize = 0;
        var depth: usize = 0;
        var start: usize = 0;
        for (body, 0..) |ch, i| switch (ch) {
            '(' => depth += 1,
            ')' => depth -|= 1,
            ',' => if (depth == 0) {
                if (std.mem.eql(u8, firstToken(body[start..i]), name)) return index;
                index += 1;
                start = i + 1;
            },
            else => {},
        };
        if (std.mem.eql(u8, firstToken(body[start..]), name)) return index;
        return error.ColumnNotFound;
    }

    pub fn rows(self: Table, db: *const Db, buf: []u8) RowIterator {
        return .{ .db = db, .root = self.root, .buf = buf };
    }
};

/// The declared name at the head of one column definition. It strips the
/// quoting SQLite accepts around a name.
fn firstToken(segment: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, segment, " \t\r\n");
    if (trimmed.len == 0) return trimmed;
    const quote: ?u8 = switch (trimmed[0]) {
        '"' => '"',
        '`' => '`',
        '[' => ']',
        else => null,
    };
    if (quote) |q| {
        const end = std.mem.indexOfScalarPos(u8, trimmed, 1, q) orelse return trimmed[1..];
        return trimmed[1..end];
    }
    const end = std.mem.indexOfAny(u8, trimmed, " \t\r\n(") orelse trimmed.len;
    return trimmed[0..end];
}

/// Walks a table b-tree in rowid order and refills `buf` with each row.
pub const RowIterator = struct {
    db: *const Db,
    root: u32,
    buf: []u8,
    stack: [max_depth]Frame = undefined,
    depth: usize = 0,
    started: bool = false,
    pushed: u32 = 0,

    const Frame = struct {
        page: u32,
        /// Page 1 carries the 100-byte file header ahead of its b-tree header.
        base: u32,
        leaf: bool,
        cells: u32,
        cell: u32,
    };

    pub fn next(self: *RowIterator) (Error || ReadError)!?Row {
        if (!self.started) {
            self.started = true;
            try self.push(self.root);
        }

        while (self.depth > 0) {
            const f = &self.stack[self.depth - 1];
            if (f.leaf) {
                if (f.cell == f.cells) {
                    self.depth -= 1;
                    continue;
                }
                const offset = try self.cellOffset(f.*, f.cell);
                f.cell += 1;
                return try self.readCell(f.page, offset);
            }

            // An interior cell holds its left child's page number. The header
            // holds the rightmost child at offset 8. The walk reaches that
            // child after the last cell.
            if (f.cell < f.cells) {
                const offset = try self.cellOffset(f.*, f.cell);
                f.cell += 1;
                try self.descend(f.page, offset);
                continue;
            }
            if (f.cell == f.cells) {
                const at = f.base + 8;
                f.cell += 1;
                try self.descend(f.page, at);
                continue;
            }
            self.depth -= 1;
        }
        return null;
    }

    fn descend(self: *RowIterator, page: u32, offset: u32) (Error || ReadError)!void {
        var child: [4]u8 = undefined;
        try self.db.read(page, offset, &child);
        try self.push(std.mem.readInt(u32, &child, .big));
    }

    fn push(self: *RowIterator, page: u32) (Error || ReadError)!void {
        if (self.depth == max_depth) return error.Corrupt;
        // A valid b-tree reaches each page once, so a walk that descends into
        // more pages than the file holds is revisiting one. The depth limit
        // above counts nesting alone. An interior page whose 71 cells all
        // name the same child multiplies the work at every level and leaves
        // the stack at one frame.
        if (self.pushed == self.db.page_count) return error.Corrupt;
        self.pushed += 1;
        const base: u32 = if (page == 1) 100 else 0;

        var head: [12]u8 = undefined;
        try self.db.read(page, base, &head);
        const leaf = switch (head[0]) {
            0x0d => true,
            0x05 => false,
            else => return error.Corrupt,
        };

        self.stack[self.depth] = .{
            .page = page,
            .base = base,
            .leaf = leaf,
            .cells = std.mem.readInt(u16, head[3..5], .big),
            .cell = 0,
        };
        self.depth += 1;
    }

    fn cellOffset(self: *RowIterator, f: Frame, i: u32) (Error || ReadError)!u32 {
        const header_len: u32 = if (f.leaf) 8 else 12;
        var slot: [2]u8 = undefined;
        try self.db.read(f.page, f.base + header_len + 2 * i, &slot);
        return std.mem.readInt(u16, &slot, .big);
    }

    fn readCell(self: *RowIterator, page: u32, offset: u32) (Error || ReadError)!Row {
        // A table leaf cell opens with the payload size and the rowid. Each is
        // a varint of at most 9 bytes.
        var head: [18]u8 = undefined;
        const room = self.db.page_size -| offset;
        const n = @min(head.len, room);
        try self.db.read(page, offset, head[0..n]);

        const size = try varint(head[0..n]);
        const rowid = try varint(head[size.len..n]);
        const start = offset + size.len + rowid.len;
        const len = try self.db.readPayload(self.buf, page, start, std.math.cast(usize, size.value) orelse
            return error.RowTooLarge);

        var row = try Row.init(self.buf[0..len]);
        row.rowid = @bitCast(rowid.value);
        return row;
    }
};

/// One row's record. `init` walks the header once and rejects a malformed
/// one. `column` and `columnInt` walk the same header again and always
/// succeed.
pub const Row = struct {
    record: []const u8,
    header_len: usize,
    types_at: usize,
    /// A column declared `INTEGER PRIMARY KEY` aliases this and stores a NULL
    /// in the record.
    rowid: i64 = 0,

    fn init(record: []const u8) Error!Row {
        const header = try varint(record);
        const header_len = std.math.cast(usize, header.value) orelse return error.Corrupt;
        if (header_len > record.len or header_len < header.len) return error.Corrupt;

        var at = header.len;
        var body = header_len;
        while (at < header_len) {
            const t = try varint(record[at..header_len]);
            at += t.len;
            body += try serialLen(t.value);
            if (body > record.len) return error.Corrupt;
        }
        if (at != header_len) return error.Corrupt;

        return .{ .record = record, .header_len = header_len, .types_at = header.len };
    }

    const Value = struct { serial: u64, bytes: []const u8 };

    fn value(self: Row, index: usize) ?Value {
        var at = self.types_at;
        var body = self.header_len;
        var col: usize = 0;
        while (at < self.header_len) : (col += 1) {
            // init walked this header already.
            const t = varint(self.record[at..self.header_len]) catch unreachable;
            at += t.len;
            const n = serialLen(t.value) catch unreachable;
            if (col == index) return .{ .serial = t.value, .bytes = self.record[body..][0..n] };
            body += n;
        }
        return null;
    }

    /// The serial type the record stores for `index`. 0 is NULL, 1 to 6 are
    /// integers, 7 is a float, 8 and 9 are the constants 0 and 1, an even
    /// type from 12 is a blob and an odd type from 13 is text.
    pub fn columnSerial(self: Row, index: usize) ?u64 {
        const v = self.value(index) orelse return null;
        return v.serial;
    }

    /// The column's stored bytes, big-endian for an integer type. Null for a
    /// SQL NULL and for a column the record stops before.
    pub fn column(self: Row, index: usize) ?[]const u8 {
        const v = self.value(index) orelse return null;
        if (v.serial == 0) return null;
        return v.bytes;
    }

    /// Decodes the integer serial types. `sqlite_master` stores rootpage as
    /// one of them.
    pub fn columnInt(self: Row, index: usize) ?i64 {
        const v = self.value(index) orelse return null;
        switch (v.serial) {
            8 => return 0,
            9 => return 1,
            1...6 => {},
            else => return null,
        }
        var n: u64 = if (v.bytes[0] & 0x80 != 0) std.math.maxInt(u64) else 0;
        for (v.bytes) |b| n = (n << 8) | b;
        return @bitCast(n);
    }
};

const Varint = struct { value: u64, len: u32 };

/// SQLite's own varint: 1 to 9 bytes, big-endian, 7 bits per byte and all 8
/// bits in the ninth. This is not LEB128.
fn varint(buf: []const u8) Error!Varint {
    var value: u64 = 0;
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        if (i >= buf.len) return error.Corrupt;
        const b = buf[i];
        value = (value << 7) | (b & 0x7f);
        if (b & 0x80 == 0) return .{ .value = value, .len = @intCast(i + 1) };
    }
    if (buf.len < 9) return error.Corrupt;
    return .{ .value = (value << 8) | buf[8], .len = 9 };
}

/// The format reserves serial types 10 and 11 for internal use. This reader
/// treats a record that carries one as corruption.
fn serialLen(t: u64) Error!usize {
    return switch (t) {
        0, 8, 9 => 0,
        1...4 => @intCast(t),
        5 => 6,
        6, 7 => 8,
        10, 11 => error.Corrupt,
        else => std.math.cast(usize, (t - 12) / 2) orelse return error.Corrupt,
    };
}

const testing = std.testing;

test "varint decodes the one-byte, multi-byte and nine-byte forms" {
    try testing.expectEqual(@as(u64, 0x7f), (try varint(&.{0x7f})).value);
    try testing.expectEqual(@as(u32, 1), (try varint(&.{0x7f})).len);

    // 0x81 0x00 is 128.
    try testing.expectEqual(@as(u64, 128), (try varint(&.{ 0x81, 0x00 })).value);
    try testing.expectEqual(@as(u32, 2), (try varint(&.{ 0x81, 0x00 })).len);

    // Eight continuation bytes, then all 8 bits of the ninth.
    const nine = [_]u8{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff };
    try testing.expectEqual(@as(u64, 0xffff_ffff_ffff_ffff), (try varint(&nine)).value);
    try testing.expectEqual(@as(u32, 9), (try varint(&nine)).len);

    try testing.expectError(error.Corrupt, varint(&.{0x81}));
    try testing.expectError(error.Corrupt, varint(&.{}));
}

test "a record decodes a null, a text, a blob and an integer column" {
    // Header: length 5, then serial types 0, 19, 16, 2. Type 19 is 3 bytes of
    // text, type 16 is a 2-byte blob, type 2 is a 2-byte integer.
    // Body: "abc", 0xdead, 0x0102.
    const record = [_]u8{ 5, 0, 19, 16, 2 } ++ "abc".* ++ [_]u8{ 0xde, 0xad, 0x01, 0x02 };
    const row = try Row.init(&record);

    try testing.expect(row.column(0) == null);
    try testing.expectEqualStrings("abc", row.column(1).?);
    try testing.expectEqualSlices(u8, &.{ 0xde, 0xad }, row.column(2).?);
    try testing.expectEqual(@as(i64, 0x0102), row.columnInt(3).?);

    // A record can stop before its last column. ALTER TABLE ADD COLUMN leaves
    // the existing rows in that state. Those columns read as null.
    try testing.expect(row.column(4) == null);
}

test "Row.init rejects a header that claims more bytes than the record holds" {
    try testing.expectError(error.Corrupt, Row.init(&.{ 5, 0, 0, 0, 60 }));
    try testing.expectError(error.Corrupt, Row.init(&.{ 9, 0 }));
}

test "columnIndex reads the CREATE TABLE list and skips a nested paren" {
    const t: Table = .{
        .root = 2,
        .sql = "CREATE TABLE t (id PRIMARY KEY, \"a b\" VARCHAR(20, 4), c, [d] INT)",
    };
    try testing.expectEqual(@as(usize, 0), try t.columnIndex("id"));
    try testing.expectEqual(@as(usize, 1), try t.columnIndex("a b"));
    try testing.expectEqual(@as(usize, 2), try t.columnIndex("c"));
    try testing.expectEqual(@as(usize, 3), try t.columnIndex("d"));
    try testing.expectError(error.ColumnNotFound, t.columnIndex("nope"));
}
