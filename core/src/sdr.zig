//! Parses the NSS SDR blobs stored base64-encoded in logins.json.

const std = @import("std");
const der = @import("der.zig");
const oids = @import("oids.zig");
const aescbc = @import("aescbc.zig");

pub const Error = error{
    UnsupportedCipher,
    BadIvLength,
    LegacyTripleDes,
} || der.Error || aescbc.Error;

/// Key id every Firefox profile uses for the SDR key.
pub const sdr_key_id = [_]u8{ 0xf8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x01 };

pub const Blob = struct {
    key_id: []const u8,
    cipher: oids.Cipher,
    iv: []const u8,
    ciphertext: []const u8,
};

pub fn parse(blob: []const u8) Error!Blob {
    var top = der.Reader.init(blob);
    var outer = try top.seq();

    const key_id = try outer.octetString();

    var alg = try outer.seq();
    const cipher = oids.Cipher.fromOid(try alg.oid()) orelse return error.UnsupportedCipher;
    // Unlike the key4.db wrapping, the IV here is the element body.
    const iv = try alg.octetString();

    return .{
        .key_id = key_id,
        .cipher = cipher,
        .iv = iv,
        .ciphertext = try outer.octetString(),
    };
}

/// Returns a slice of `out`. Firefox 144 re-encrypted existing stores to
/// AES-256. A des_ede3_cbc value comes from a profile that version has
/// never opened.
pub fn decrypt(b: Blob, key: *const [32]u8, out: []u8) Error![]u8 {
    switch (b.cipher) {
        .des_ede3_cbc => return error.LegacyTripleDes,
        .aes256_cbc => {
            if (b.iv.len != aescbc.block_len) return error.BadIvLength;
            return aescbc.decrypt(out, b.ciphertext, key, b.iv[0..aescbc.block_len].*);
        },
    }
}
