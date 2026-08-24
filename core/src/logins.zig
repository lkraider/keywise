//! Decrypts and keeps the entries in logins.json.

const std = @import("std");
const sdr = @import("sdr.zig");
const keydb = @import("keydb.zig");

pub const Error = error{ NoLoginsArray, MalformedJson } || std.mem.Allocator.Error;
pub const RevealError = error{ LegacyTripleDes, NoSdrKey, TooLarge } || std.base64.Error || sdr.Error;

/// `account_credential`'s password is Mozilla Account sync key material.
/// Whoever reads it holds the account. `extension` marks a row an add-on
/// saved for itself.
pub const Kind = enum { normal, account_credential, extension };

pub const Entry = struct {
    hostname: []const u8,
    /// Decrypted at load, since the list shows it. Empty when `legacy_3des`
    /// is true. Decrypting it there needs a 3DES implementation, and this
    /// project carries none (see docs/ARCHITECTURE.md, "Decisions").
    username: []const u8,
    kind: Kind,
    /// True when this entry's fields are still des_ede3_cbc. Firefox 144
    /// re-encrypts a store to AES-256 on its first open, so a true here
    /// means that open never happened. The username above and `reveal`'s
    /// password both fail to decrypt.
    legacy_3des: bool,
    /// The base64 SDR blob, kept as-is. `revealPassword` decrypts it on
    /// demand, so the password stays out of memory until someone asks.
    encrypted_password: []const u8,
    time_password_changed: i64,
};

pub const ScanResult = struct {
    entries: []Entry,
    /// Sync deletion tombstones: `deleted: true`, no hostname, no encrypted
    /// fields. They stay out of `entries` and out of the entry count.
    tombstones_skipped: usize = 0,
    /// A row missing its hostname or its encrypted fields, carrying no
    /// `deleted` flag. A Firefox-written profile holds none of these.
    malformed: usize = 0,
};

fn classify(hostname: []const u8) Kind {
    if (std.mem.eql(u8, hostname, "chrome://FirefoxAccounts")) return .account_credential;
    if (std.mem.startsWith(u8, hostname, "moz-extension://")) return .extension;
    return .normal;
}

/// Decrypts a base64 SDR field into `out`. The blob names its own cipher,
/// so this reads the cipher before it asks for a key. A profile carrying
/// only a 3DES key then reports `LegacyTripleDes`.
fn decryptField(b64: []const u8, keys: keydb.Keys, scratch: []u8, out: []u8) RevealError![]u8 {
    const decoder = std.base64.standard.Decoder;
    const n = try decoder.calcSizeForSlice(b64);
    if (n > scratch.len) return error.TooLarge;
    try decoder.decode(scratch[0..n], b64);

    const blob = try sdr.parse(scratch[0..n]);
    if (blob.cipher == .des_ede3_cbc) return error.LegacyTripleDes;
    const key = keys.aes256 orelse return error.NoSdrKey;
    return sdr.decrypt(blob, key, out);
}

/// Walks every entry in logins.json, decrypting each username now and
/// keeping each password's base64 blob for a later `Store.reveal`. `gpa`
/// owns the returned entries and every string they hold.
pub fn scan(gpa: std.mem.Allocator, json_bytes: []const u8, keys: keydb.Keys) Error!ScanResult {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, json_bytes, .{}) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.MalformedJson,
    };
    defer parsed.deinit();

    const logins_val = switch (parsed.value) {
        .object => |o| o.get("logins") orelse return error.NoLoginsArray,
        else => return error.NoLoginsArray,
    };
    const logins = switch (logins_val) {
        .array => |a| a,
        else => return error.NoLoginsArray,
    };

    var entries: std.ArrayList(Entry) = .empty;
    errdefer entries.deinit(gpa);

    var result: ScanResult = .{ .entries = &.{} };

    const scratch = try gpa.alloc(u8, 8192);
    defer gpa.free(scratch);
    const plain = try gpa.alloc(u8, 8192);
    defer gpa.free(plain);
    defer std.crypto.secureZero(u8, plain);

    for (logins.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => {
                result.malformed += 1;
                continue;
            },
        };

        if (obj.get("deleted")) |deleted| {
            if (deleted == .bool and deleted.bool) {
                result.tombstones_skipped += 1;
                continue;
            }
        }

        const hostname_v = obj.get("hostname");
        const pass_v = obj.get("encryptedPassword");
        const user_v = obj.get("encryptedUsername");
        if (hostname_v == null or pass_v == null or user_v == null) {
            result.malformed += 1;
            continue;
        }

        const hostname = switch (hostname_v.?) {
            .string => |s| s,
            else => {
                result.malformed += 1;
                continue;
            },
        };
        const encrypted_password = switch (pass_v.?) {
            .string => |s| s,
            else => {
                result.malformed += 1;
                continue;
            },
        };
        const encrypted_username = switch (user_v.?) {
            .string => |s| s,
            else => {
                result.malformed += 1;
                continue;
            },
        };

        var username: []const u8 = &.{};
        var legacy_3des = false;
        if (decryptField(encrypted_username, keys, scratch, plain)) |dec| {
            username = try gpa.dupe(u8, dec);
        } else |err| switch (err) {
            error.LegacyTripleDes => legacy_3des = true,
            else => {
                result.malformed += 1;
                continue;
            },
        }

        const time_password_changed: i64 = if (obj.get("timePasswordChanged")) |t|
            (switch (t) {
                .integer => |i| i,
                else => 0,
            })
        else
            0;

        try entries.append(gpa, .{
            .hostname = try gpa.dupe(u8, hostname),
            .username = username,
            .kind = classify(hostname),
            .legacy_3des = legacy_3des,
            .encrypted_password = try gpa.dupe(u8, encrypted_password),
            .time_password_changed = time_password_changed,
        });
    }

    result.entries = try entries.toOwnedSlice(gpa);
    return result;
}

/// Decrypts one entry's password. Never called at load time.
pub fn revealPassword(entry: Entry, keys: keydb.Keys, scratch: []u8, out: []u8) RevealError![]u8 {
    return decryptField(entry.encrypted_password, keys, scratch, out);
}
