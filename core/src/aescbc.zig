//! AES-256-CBC decryption. std.crypto.modes provides ctr only, so CBC is
//! implemented here over the raw block cipher.

const std = @import("std");
const Aes256 = std.crypto.core.aes.Aes256;

pub const Error = error{
    BadCiphertextLength,
    BadPadding,
    BufferTooSmall,
};

pub const block_len = 16;

/// Decrypts without touching padding. `out` receives exactly ct.len bytes.
pub fn decryptRaw(out: []u8, ct: []const u8, key: *const [32]u8, iv: [block_len]u8) Error!void {
    if (ct.len == 0 or ct.len % block_len != 0) return error.BadCiphertextLength;
    if (out.len < ct.len) return error.BufferTooSmall;

    var ctx = Aes256.initDec(key.*);
    defer std.crypto.secureZero(u8, std.mem.asBytes(&ctx));
    var prev = iv;
    var i: usize = 0;
    while (i < ct.len) : (i += block_len) {
        const block = ct[i..][0..block_len];
        var dec: [block_len]u8 = undefined;
        defer std.crypto.secureZero(u8, &dec);
        ctx.decrypt(&dec, block);
        for (dec, prev, 0..) |d, p, j| out[i + j] = d ^ p;
        prev = block.*;
    }
}

/// Decrypts and strips PKCS7 padding. The returned slice aliases `out`.
/// Firefox pads every stored value, so a padding failure means the key is wrong.
pub fn decrypt(out: []u8, ct: []const u8, key: *const [32]u8, iv: [block_len]u8) Error![]u8 {
    try decryptRaw(out, ct, key, iv);
    const pad = out[ct.len - 1];
    if (pad == 0 or pad > block_len or pad > ct.len) return error.BadPadding;
    for (out[ct.len - pad ..][0..pad]) |b| {
        if (b != pad) return error.BadPadding;
    }
    return out[0 .. ct.len - pad];
}
