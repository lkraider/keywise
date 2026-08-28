const std = @import("std");
const store_mod = @import("store.zig");
const logins = @import("logins.zig");

pub const WriteResult = struct {
    written: usize = 0,
    failed: usize = 0,
};

pub const WriteError = std.Io.Writer.Error || error{TooLarge};

pub fn writeCsv(store: *const store_mod.Store, writer: *std.Io.Writer) WriteError!WriteResult {
    var scratch: [8192]u8 = undefined;
    var out: [8192]u8 = undefined;
    var buf: [32768]u8 = undefined;
    defer std.crypto.secureZero(u8, &scratch);
    defer std.crypto.secureZero(u8, &out);
    defer std.crypto.secureZero(u8, &buf);

    try writer.writeAll("\"url\",\"username\",\"password\",\"timePasswordChanged\"\r\n");

    var result: WriteResult = .{};
    for (store.entries, 0..) |entry, i| {
        const password = store.reveal(i, &scratch, &out) catch |err| switch (err) {
            error.LegacyTripleDes => {
                const row = formatCsvRow(entry, "<3DES, unsupported>", &buf) orelse return error.TooLarge;
                try writer.writeAll(row);
                std.crypto.secureZero(u8, &scratch);
                std.crypto.secureZero(u8, &out);
                std.crypto.secureZero(u8, &buf);
                result.failed += 1;
                continue;
            },
            error.TooLarge => return error.TooLarge,
            else => {
                const row = formatCsvRow(entry, "<decrypt failed>", &buf) orelse return error.TooLarge;
                try writer.writeAll(row);
                std.crypto.secureZero(u8, &scratch);
                std.crypto.secureZero(u8, &out);
                std.crypto.secureZero(u8, &buf);
                result.failed += 1;
                continue;
            },
        };
        const row = formatCsvRow(entry, password, &buf) orelse return error.TooLarge;
        try writer.writeAll(row);
        std.crypto.secureZero(u8, &scratch);
        std.crypto.secureZero(u8, &out);
        std.crypto.secureZero(u8, &buf);
        result.written += 1;
    }
    return result;
}

pub fn writeJson(store: *const store_mod.Store, writer: *std.Io.Writer) WriteError!WriteResult {
    var scratch: [8192]u8 = undefined;
    var out: [8192]u8 = undefined;
    var buf: [32768]u8 = undefined;
    defer std.crypto.secureZero(u8, &scratch);
    defer std.crypto.secureZero(u8, &out);
    defer std.crypto.secureZero(u8, &buf);

    try writer.writeAll("[\n");

    var result: WriteResult = .{};
    const len = store.entries.len;
    for (store.entries, 0..) |entry, i| {
        const is_last = (i == len - 1);
        const password = store.reveal(i, &scratch, &out) catch |err| switch (err) {
            error.LegacyTripleDes => {
                const frag = formatJsonEntry(entry, "<3DES, unsupported>", is_last, &buf) orelse return error.TooLarge;
                try writer.writeAll(frag);
                std.crypto.secureZero(u8, &scratch);
                std.crypto.secureZero(u8, &out);
                std.crypto.secureZero(u8, &buf);
                result.failed += 1;
                continue;
            },
            error.TooLarge => return error.TooLarge,
            else => {
                const frag = formatJsonEntry(entry, "<decrypt failed>", is_last, &buf) orelse return error.TooLarge;
                try writer.writeAll(frag);
                std.crypto.secureZero(u8, &scratch);
                std.crypto.secureZero(u8, &out);
                std.crypto.secureZero(u8, &buf);
                result.failed += 1;
                continue;
            },
        };
        const frag = formatJsonEntry(entry, password, is_last, &buf) orelse return error.TooLarge;
        try writer.writeAll(frag);
        std.crypto.secureZero(u8, &scratch);
        std.crypto.secureZero(u8, &out);
        std.crypto.secureZero(u8, &buf);
        result.written += 1;
    }

    try writer.writeAll("]\n");
    return result;
}

const BufWriter = struct {
    buf: []u8,
    pos: usize = 0,

    fn put(self: *BufWriter, bytes: []const u8) bool {
        if (self.pos + bytes.len > self.buf.len) return false;
        @memcpy(self.buf[self.pos..][0..bytes.len], bytes);
        self.pos += bytes.len;
        return true;
    }

    fn putByte(self: *BufWriter, byte: u8) bool {
        if (self.pos >= self.buf.len) return false;
        self.buf[self.pos] = byte;
        self.pos += 1;
        return true;
    }

    fn written(self: *const BufWriter) []const u8 {
        return self.buf[0..self.pos];
    }
};

pub fn formatCsvRow(entry: logins.Entry, password: []const u8, buf: []u8) ?[]const u8 {
    var w = BufWriter{ .buf = buf };
    if (!csvQuotedBuf(&w, entry.hostname)) return null;
    if (!w.putByte(',')) return null;
    if (!csvQuotedBuf(&w, if (entry.legacy_3des) "<3DES, unsupported>" else entry.username)) return null;
    if (!w.putByte(',')) return null;
    if (!csvQuotedBuf(&w, password)) return null;
    if (!w.putByte(',')) return null;
    if (!w.putByte('"')) return null;
    const ts = std.fmt.bufPrint(buf[w.pos..], "{d}", .{entry.time_password_changed}) catch return null;
    w.pos += ts.len;
    if (!w.put("\"\r\n")) return null;
    return w.written();
}

pub fn formatJsonEntry(entry: logins.Entry, password: []const u8, is_last: bool, buf: []u8) ?[]const u8 {
    var w = BufWriter{ .buf = buf };
    if (!w.put("  {\n    \"url\": ")) return null;
    if (!jsonStringBuf(&w, entry.hostname)) return null;
    if (!w.put(",\n    \"username\": ")) return null;
    if (!jsonStringBuf(&w, if (entry.legacy_3des) "<3DES, unsupported>" else entry.username)) return null;
    if (!w.put(",\n    \"password\": ")) return null;
    if (!jsonStringBuf(&w, password)) return null;
    if (!w.put(",\n    \"timePasswordChanged\": ")) return null;
    const ts = std.fmt.bufPrint(buf[w.pos..], "{d}", .{entry.time_password_changed}) catch return null;
    w.pos += ts.len;
    if (is_last) {
        if (!w.put("\n  }\n")) return null;
    } else {
        if (!w.put("\n  },\n")) return null;
    }
    return w.written();
}

fn csvQuotedBuf(w: *BufWriter, value: []const u8) bool {
    if (!w.putByte('"')) return false;
    for (value) |c| {
        if (c == '"') {
            if (!w.put("\"\"")) return false;
        } else {
            if (!w.putByte(c)) return false;
        }
    }
    return w.putByte('"');
}

fn jsonStringBuf(w: *BufWriter, value: []const u8) bool {
    if (!w.putByte('"')) return false;
    for (value) |c| {
        const ok = switch (c) {
            '"' => w.put("\\\""),
            '\\' => w.put("\\\\"),
            '\n' => w.put("\\n"),
            '\r' => w.put("\\r"),
            '\t' => w.put("\\t"),
            else => if (c < 0x20) blk: {
                const esc = std.fmt.bufPrint(w.buf[w.pos..], "\\u{x:0>4}", .{c}) catch return false;
                w.pos += esc.len;
                break :blk true;
            } else w.putByte(c),
        };
        if (!ok) return false;
    }
    return w.putByte('"');
}

// --- Tests ---

const testing = std.testing;

fn testEntry(hostname: []const u8, username: []const u8, time: i64) logins.Entry {
    return .{
        .hostname = hostname,
        .username = username,
        .kind = .normal,
        .legacy_3des = false,
        .encrypted_password = "",
        .time_password_changed = time,
    };
}

test "formatCsvRow quotes fields and escapes internal quotes" {
    var buf: [1024]u8 = undefined;
    const entry = testEntry("https://example.com", "user@example.com", 1714000000000);
    const row = formatCsvRow(entry, "p4ss\"word", &buf).?;
    try testing.expectEqualStrings(
        "\"https://example.com\",\"user@example.com\",\"p4ss\"\"word\",\"1714000000000\"\r\n",
        row,
    );
}

test "formatCsvRow shows 3DES placeholder for legacy entries" {
    var buf: [1024]u8 = undefined;
    var entry = testEntry("https://old.example.com", "", 1000);
    entry.legacy_3des = true;
    const row = formatCsvRow(entry, "<3DES, unsupported>", &buf).?;
    try testing.expectEqualStrings(
        "\"https://old.example.com\",\"<3DES, unsupported>\",\"<3DES, unsupported>\",\"1000\"\r\n",
        row,
    );
}

test "formatJsonEntry produces valid JSON with escaping" {
    var buf: [1024]u8 = undefined;
    const entry = testEntry("https://example.com", "user@example.com", 1714000000000);
    const frag = formatJsonEntry(entry, "pass\\word\"1", true, &buf).?;
    try testing.expectEqualStrings(
        \\  {
        \\    "url": "https://example.com",
        \\    "username": "user@example.com",
        \\    "password": "pass\\word\"1",
        \\    "timePasswordChanged": 1714000000000
        \\  }
        \\
    , frag);
}

test "formatJsonEntry trailing comma on non-last entry" {
    var buf: [1024]u8 = undefined;
    const entry = testEntry("https://a.com", "u", 42);
    const frag = formatJsonEntry(entry, "pw", false, &buf).?;
    try testing.expect(std.mem.endsWith(u8, frag, "  },\n"));
}

test "formatCsvRow returns null when buffer is too small" {
    var buf: [10]u8 = undefined;
    const entry = testEntry("https://example.com", "user", 0);
    try testing.expect(formatCsvRow(entry, "password", &buf) == null);
}

test "jsonStringBuf escapes control characters" {
    var buf: [256]u8 = undefined;
    var w = BufWriter{ .buf = &buf };
    try testing.expect(jsonStringBuf(&w, "a\x00b\nc"));
    try testing.expectEqualStrings("\"a\\u0000b\\nc\"", w.written());
}
