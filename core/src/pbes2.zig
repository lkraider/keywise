//! Unwraps the PBES2 structures in key4.db: the password-check value in
//! metaData and the wrapped master keys in nssPrivate.

const std = @import("std");
const der = @import("der.zig");
const oids = @import("oids.zig");
const aescbc = @import("aescbc.zig");

pub const Error = error{
    UnsupportedScheme,
    UnsupportedPrf,
    UnsupportedCipher,
    BadIvLength,
    UnsupportedKeyLen,
    UnsupportedGlobalSaltLen,
} || der.Error || aescbc.Error || std.crypto.errors.WeakParametersError;

pub const Prf = enum { hmac_sha1, hmac_sha256 };

pub const Params = struct {
    entry_salt: []const u8,
    iterations: u32,
    key_len: u32,
    prf: Prf,
    iv: [aescbc.block_len]u8,
    ciphertext: []const u8,
};

pub fn parse(blob: []const u8) Error!Params {
    var top = der.Reader.init(blob);
    var outer = try top.seq();

    var algid = try outer.seq();
    if (!oids.eql(try algid.oid(), &oids.pbes2)) return error.UnsupportedScheme;

    var scheme = try algid.seq();

    var kdf = try scheme.seq();
    if (!oids.eql(try kdf.oid(), &oids.pbkdf2)) return error.UnsupportedScheme;
    var kdf_params = try kdf.seq();
    const entry_salt = try kdf_params.octetString();
    const iterations = try kdf_params.int();
    const key_len = try kdf_params.int();
    var prf_seq = try kdf_params.seq();
    const prf_oid = try prf_seq.oid();
    const prf: Prf = if (oids.eql(prf_oid, &oids.hmac_sha256))
        .hmac_sha256
    else if (oids.eql(prf_oid, &oids.hmac_sha1))
        .hmac_sha1
    else
        return error.UnsupportedPrf;

    var enc = try scheme.seq();
    if (!oids.eql(try enc.oid(), &oids.aes256_cbc)) return error.UnsupportedCipher;
    const iv_element = try enc.expect(der.tag_octet_string);
    // NSS feeds the whole DER encoding of this element to AES as the IV. Two
    // header octets plus a 14-byte body supply the 16 bytes CBC needs.
    if (iv_element.raw.len != aescbc.block_len) return error.BadIvLength;

    var params: Params = .{
        .entry_salt = entry_salt,
        .iterations = iterations,
        .key_len = key_len,
        .prf = prf,
        .iv = undefined,
        .ciphertext = try outer.octetString(),
    };
    @memcpy(&params.iv, iv_element.raw);
    return params;
}

/// A never-initialized token stores a 20-byte SHA1-length global salt and
/// seeds with SHA1. Setting a Primary Password for the first time replaces it
/// with a 48-byte SHA384-length salt and seeds with SHA384 instead. NSS picks
/// the hash by matching the salt length, in `sftkdb_passwordToKey`.
fn seedHash(global_salt: []const u8, password: []const u8, out: []u8) Error!void {
    switch (global_salt.len) {
        20 => {
            var h = std.crypto.hash.Sha1.init(.{});
            h.update(global_salt);
            h.update(password);
            h.final(out[0..20]);
        },
        48 => {
            var h = std.crypto.hash.sha2.Sha384.init(.{});
            h.update(global_salt);
            h.update(password);
            h.final(out[0..48]);
        },
        else => return error.UnsupportedGlobalSaltLen,
    }
}

pub fn deriveKey(p: Params, global_salt: []const u8, password: []const u8, out: []u8) Error!void {
    var seed: [48]u8 = undefined;
    defer std.crypto.secureZero(u8, &seed);
    try seedHash(global_salt, password, &seed);
    const seed_slice = seed[0..global_salt.len];

    switch (p.prf) {
        .hmac_sha256 => std.crypto.pwhash.pbkdf2(
            out,
            seed_slice,
            p.entry_salt,
            p.iterations,
            std.crypto.auth.hmac.sha2.HmacSha256,
        ) catch |e| switch (e) {
            // out is 32 bytes, well below maxInt(u32) * h_len
            error.OutputTooLong => unreachable,
            error.WeakParameters => return error.WeakParameters,
        },
        .hmac_sha1 => std.crypto.pwhash.pbkdf2(
            out,
            seed_slice,
            p.entry_salt,
            p.iterations,
            std.crypto.auth.hmac.HmacSha1,
        ) catch |e| switch (e) {
            error.OutputTooLong => unreachable,
            error.WeakParameters => return error.WeakParameters,
        },
    }
}

/// Returns a slice of `out`. A BadPadding error means the Primary Password
/// was wrong, because Firefox pads every value it stores here.
pub fn unwrap(
    blob: []const u8,
    global_salt: []const u8,
    password: []const u8,
    out: []u8,
) Error![]u8 {
    const p = try parse(blob);
    if (p.key_len != 32) return error.UnsupportedKeyLen;

    var key: [32]u8 = undefined;
    defer std.crypto.secureZero(u8, &key);
    try deriveKey(p, global_salt, password, &key);

    return aescbc.decrypt(out, p.ciphertext, key, p.iv);
}
