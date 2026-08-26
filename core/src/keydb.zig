//! Reads key4.db and returns the SDR master keys.

const std = @import("std");
const sqlitedb = @import("sqlitedb.zig");
const pbes2 = @import("pbes2.zig");

pub const Error = error{
    OpenFailed,
    QueryFailed,
    MissingPasswordRow,
    WrongPassword,
    NoSdrKey,
    WalJournal,
    KeyUnwrapFailed,
} || pbes2.Error;

/// A profile can carry both keys at once. Firefox 144 adds the 32-byte key
/// and leaves the 24-byte one in place, both under the same CKA_ID. `load`
/// tells them apart by decrypted length.
pub const Keys = struct {
    aes256: ?[32]u8 = null,
    des3: ?[24]u8 = null,
};

/// NSS gives every SDR master key this object id.
const cka_id = [_]u8{ 0xF8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x01 };

/// CKO_SECRET_KEY, stored big-endian in nssPrivate.a0.
const cko_secret_key = [_]u8{ 0, 0, 0, 0x04 };

/// The widest record in key4.db is sqlite_master's row for nssPrivate. Its
/// CREATE TABLE text runs to 1385 bytes in the fixtures. The data rows measure
/// about 400 bytes.
const row_buf_len = 4096;

pub fn load(io: std.Io, path: []const u8, password: []const u8) Error!Keys {
    // Opening read-only keeps this tool from touching a profile Firefox may
    // be using.
    var db = sqlitedb.Db.open(io, path) catch |e| switch (e) {
        error.WalJournal => return error.WalJournal,
        else => return error.OpenFailed,
    };
    defer db.close();

    var buf: [row_buf_len]u8 = undefined;

    var global_salt_buf: [64]u8 = undefined;
    var global_salt_len: usize = 0;
    var check_buf: [256]u8 = undefined;
    var check_len: usize = 0;

    {
        const meta = db.table("metaData", &buf) catch return error.QueryFailed;
        const id_col = meta.columnIndex("id") catch return error.QueryFailed;
        const item1_col = meta.columnIndex("item1") catch return error.QueryFailed;
        const item2_col = meta.columnIndex("item2") catch return error.QueryFailed;

        // metaData also holds sig_key_* rows. In the primary fixture the
        // password row comes second.
        var it = meta.rows(&db, &buf);
        const found = while (it.next() catch return error.QueryFailed) |row| {
            const id = row.column(id_col) orelse continue;
            if (!std.mem.eql(u8, id, "password")) continue;

            const salt = row.column(item1_col) orelse &.{};
            const check = row.column(item2_col) orelse &.{};
            if (salt.len > global_salt_buf.len or check.len > check_buf.len) return error.QueryFailed;
            @memcpy(global_salt_buf[0..salt.len], salt);
            @memcpy(check_buf[0..check.len], check);
            global_salt_len = salt.len;
            check_len = check.len;
            break true;
        } else false;
        if (!found) return error.MissingPasswordRow;
    }

    const global_salt = global_salt_buf[0..global_salt_len];

    // metaData.item2 decrypts to the ASCII string "password-check". This proves
    // the password before any key material is unwrapped.
    if (check_len != 0) {
        var out: [256]u8 = undefined;
        const plain = pbes2.unwrap(check_buf[0..check_len], global_salt, password, &out) catch |e| switch (e) {
            error.BadPadding => return error.WrongPassword,
            else => return e,
        };
        if (!std.mem.eql(u8, plain, "password-check")) return error.WrongPassword;
    }

    var keys: Keys = .{};
    {
        const nss = db.table("nssPrivate", &buf) catch return error.QueryFailed;
        const a0_col = nss.columnIndex("a0") catch return error.QueryFailed;
        const a11_col = nss.columnIndex("a11") catch return error.QueryFailed;
        const a102_col = nss.columnIndex("a102") catch return error.QueryFailed;

        var unwrap_failures: usize = 0;
        var it = nss.rows(&db, &buf);
        while (it.next() catch return error.QueryFailed) |row| {
            const id = row.column(a102_col) orelse continue;
            if (!std.mem.eql(u8, id, &cka_id)) continue;
            const class = row.column(a0_col) orelse continue;
            if (!std.mem.eql(u8, class, &cko_secret_key)) continue;
            const wrapped = row.column(a11_col) orelse continue;

            var out: [128]u8 = undefined;
            defer std.crypto.secureZero(u8, &out);
            const plain = pbes2.unwrap(wrapped, global_salt, password, &out) catch {
                unwrap_failures += 1;
                continue;
            };
            switch (plain.len) {
                32 => keys.aes256 = plain[0..32].*,
                24 => keys.des3 = plain[0..24].*,
                else => {},
            }
        }

        if (keys.aes256 == null and keys.des3 == null) {
            if (unwrap_failures > 0) return error.KeyUnwrapFailed;
            return error.NoSdrKey;
        }
    }
    return keys;
}
