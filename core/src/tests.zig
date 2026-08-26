const std = @import("std");
const testing = std.testing;

const der = @import("der.zig");
const oids = @import("oids.zig");
const aescbc = @import("aescbc.zig");
const pbes2 = @import("pbes2.zig");
const sdr = @import("sdr.zig");
const keydb = @import("keydb.zig");
const sqlitedb = @import("sqlitedb.zig");
const store = @import("store.zig");
const messages = @import("messages.zig");

test {
    _ = @import("profiles.zig");
    _ = sqlitedb;
}

/// keydb.load reads key4.db through std.Io. Each caller below opens a profile
/// once, so a fresh Threaded per call costs one thread pool per fixture.
fn loadKeys(path: []const u8, password: []const u8) !keydb.Keys {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    return keydb.load(threaded.io(), path, password);
}

fn hex(comptime s: []const u8) [s.len / 2]u8 {
    var out: [s.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, s) catch unreachable;
    return out;
}

test "aes-256-cbc matches NIST SP 800-38A F.2.6" {
    const key = hex("603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4");
    const iv = hex("000102030405060708090a0b0c0d0e0f");
    const ct = hex("f58c4c04d6e5f1ba779eabfb5f7bfbd6" ++ "9cfc4e967edb808d679f777bc6702c7d");
    const want = hex("6bc1bee22e409f96e93d7e117393172a" ++ "ae2d8a571e03ac9c9eb76fac45af8e51");

    var out: [32]u8 = undefined;
    try aescbc.decryptRaw(&out, &ct, key, iv);
    try testing.expectEqualSlices(u8, &want, &out);
}

test "pkcs7 padding is stripped and validated" {
    const key = hex("603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4");
    const iv = hex("000102030405060708090a0b0c0d0e0f");
    // "hi" padded with 14 bytes of 0x0e, encrypted under the key and iv above.
    const ct = hex("3bc29a16024812f18539438a650d4acd");

    var out: [16]u8 = undefined;
    const plain = try aescbc.decrypt(&out, &ct, key, iv);
    try testing.expectEqualStrings("hi", plain);

    // A wrong key yields padding that does not validate.
    var bad_key = key;
    bad_key[0] ^= 1;
    try testing.expectError(error.BadPadding, aescbc.decrypt(&out, &ct, bad_key, iv));
}

test "der reader walks a nested sequence" {
    // SEQUENCE { INTEGER 1, OCTET STRING "ab", OID 1.2.840.113549.2.9 }
    const buf = hex("3011" ++ "020101" ++ "04026162" ++ "06082a864886f70d0209");
    var top = der.Reader.init(&buf);
    var s = try top.seq();
    try testing.expectEqual(@as(u32, 1), try s.int());
    try testing.expectEqualStrings("ab", try s.octetString());
    try testing.expect(oids.eql(try s.oid(), &oids.hmac_sha256));
    try testing.expect(s.atEnd());
}

test "der reader rejects a length that runs past the buffer" {
    // SEQUENCE claiming 16 contents octets with only 2 present.
    const buf = hex("30106162");
    var top = der.Reader.init(&buf);
    try testing.expectError(error.Truncated, top.seq());
}

test "der reader rejects the indefinite length form" {
    const buf = hex("3080020101");
    var top = der.Reader.init(&buf);
    try testing.expectError(error.UnsupportedLength, top.seq());
}

test "der reader rejects a truncated header" {
    const buf = [_]u8{0x30};
    var top = der.Reader.init(&buf);
    try testing.expectError(error.Truncated, top.seq());
}

test "sdr blob parses key id, cipher and iv" {
    // SEQUENCE { OCTET STRING (key id),
    //            SEQUENCE { OID aes256-CBC, OCTET STRING (iv) },
    //            OCTET STRING (ciphertext) }
    const buf = hex("30430410f8000000000000000000000000000001" ++
        "301d060960864801650304012a" ++
        "0410000102030405060708090a0b0c0d0e0f" ++
        "0410aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");

    const blob = try sdr.parse(&buf);
    try testing.expectEqualSlices(u8, &sdr.sdr_key_id, blob.key_id);
    try testing.expectEqual(oids.Cipher.aes256_cbc, blob.cipher);
    try testing.expectEqual(@as(usize, 16), blob.iv.len);
    try testing.expectEqual(@as(usize, 16), blob.ciphertext.len);
}

test "a 3des entry reports the migration error and returns no plaintext" {
    // Same shape with the des-ede3-cbc OID and an 8-byte IV.
    const buf = hex("303a0410f8000000000000000000000000000001" ++
        "3014" ++ "06082a864886f70d0307" ++ "04080001020304050607" ++
        "0410aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");

    const blob = try sdr.parse(&buf);
    try testing.expectEqual(oids.Cipher.des_ede3_cbc, blob.cipher);

    var out: [16]u8 = undefined;
    try testing.expectError(error.LegacyTripleDes, sdr.decrypt(blob, @splat(0), &out));
}

fn freeScanResult(gpa: std.mem.Allocator, result: anytype) void {
    for (result.entries) |e| {
        gpa.free(e.hostname);
        gpa.free(e.username);
        gpa.free(e.encrypted_password);
    }
    gpa.free(result.entries);
}

test "logins.scan marks a 3des-only entry legacy_3des" {
    // A profile Firefox 144 has never opened carries no AES-256 key.
    // decryptField used to read keys.aes256 before parsing the blob, and
    // every entry then reported NoSdrKey. The blob names its own cipher, so
    // LegacyTripleDes is the answer that says what to do about it.
    const logins = @import("logins.zig");
    const json =
        \\{"logins": [{
        \\  "hostname": "https://example.com",
        \\  "encryptedUsername": "MDoEEPgAAAAAAAAAAAAAAAAAAAEwFAYIKoZIhvcNAwcECAABAgMEBQYHBBCqqqqqqqqqqqqqqqqqqqqq",
        \\  "encryptedPassword": "MDoEEPgAAAAAAAAAAAAAAAAAAAEwFAYIKoZIhvcNAwcECAABAgMEBQYHBBCqqqqqqqqqqqqqqqqqqqqq"
        \\}]}
    ;
    const keys: keydb.Keys = .{ .aes256 = null, .des3 = @splat(0) };
    const result = try logins.scan(testing.allocator, json, keys);
    defer freeScanResult(testing.allocator, result);

    try testing.expectEqual(@as(usize, 1), result.entries.len);
    try testing.expect(result.entries[0].legacy_3des);
    try testing.expectEqualStrings("", result.entries[0].username);
    try testing.expectEqualStrings("https://example.com", result.entries[0].hostname);
}

test "pbes2 seeds with SHA384 when the global salt is 48 bytes" {
    // Captured from a Firefox 152 profile after setting a synthetic
    // Primary Password ("fixture-primary-password-1"). A never-initialized
    // token carries a 20-byte SHA1-length global salt. Setting a Primary
    // Password for the first time replaces it with this 48-byte SHA384-length
    // one. NSS picks its seed hash by the salt's length, so a 48-byte salt
    // seeds with SHA384. Seeding with SHA1 makes the correct password look
    // wrong (regression: it did).
    const global_salt = hex("661C366FD887564582212421FC6E1388A4F37714EFA99166B3AE3D767079E607" ++
        "6FFA02718064165695084DAE22EDB6E9");
    const item2 = hex("308182306E06092A864886F70D01050D3061304206092A864886F70D01050C30" ++
        "35042087E7510D9573FAC37B76B335B4404A3B8C088B1A7B80AA01FCA56A3F87" ++
        "FBB7D702022710020120300A06082A864886F70D0209301B0609608648016503" ++
        "04012A040E9C99693DDEF51F20FE260E1FD5790410155C6C52F21267D0E27A5E" ++
        "64315CB340");

    var out: [256]u8 = undefined;
    const plain = try pbes2.unwrap(&item2, &global_salt, "fixture-primary-password-1", &out);
    try testing.expectEqualStrings("password-check", plain);

    try testing.expectError(
        error.BadPadding,
        pbes2.unwrap(&item2, &global_salt, "wrong-password", &out),
    );
}

test "pbes2 rejects a scheme it does not implement" {
    // AlgorithmIdentifier carrying the legacy PBE-SHA1-3DES OID.
    const buf = hex("3013" ++ "300f" ++ "060b2a864886f70d010c050103" ++ "0400" ++ "0400");
    try testing.expectError(error.UnsupportedScheme, pbes2.parse(&buf));
}

// The installed Firefox writes these fixtures over Marionette, so they
// carry the format Firefox produces. See scripts/test-mkfixtures.py. Your own
// Firefox profile dropped into core/testdata fails these tests, since the
// documented passwords do not unlock it.

fn readFixtureLogins(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
}

test "the fresh fixture decrypts every entry with an empty Primary Password" {
    const logins = @import("logins.zig");
    const json = try readFixtureLogins(testing.allocator, "core/testdata/fresh/logins.json");
    defer testing.allocator.free(json);

    const keys = try loadKeys("core/testdata/fresh/key4.db", "");
    const result = try logins.scan(testing.allocator, json, keys);
    defer freeScanResult(testing.allocator, result);

    try testing.expectEqual(@as(usize, 3), result.entries.len);
    try testing.expectEqual(@as(usize, 0), result.tombstones_skipped);
    try testing.expectEqual(@as(usize, 0), result.malformed);
    for (result.entries) |e| {
        try testing.expect(!e.legacy_3des);
        try testing.expect(e.username.len > 0);
        try testing.expectEqual(logins.Kind.normal, e.kind);
    }
}

test "the primary fixture needs its documented Primary Password" {
    const logins = @import("logins.zig");
    const json = try readFixtureLogins(testing.allocator, "core/testdata/primary/logins.json");
    defer testing.allocator.free(json);

    try testing.expectError(error.WrongPassword, loadKeys("core/testdata/primary/key4.db", ""));
    try testing.expectError(error.WrongPassword, loadKeys("core/testdata/primary/key4.db", "wrong"));

    const keys = try loadKeys("core/testdata/primary/key4.db", "fixture-primary-password-1");
    const result = try logins.scan(testing.allocator, json, keys);
    defer freeScanResult(testing.allocator, result);

    try testing.expectEqual(@as(usize, 3), result.entries.len);
    for (result.entries) |e| {
        try testing.expect(!e.legacy_3des);
        try testing.expect(e.username.len > 0);
    }
}

test "two-profiles resolves to the profile the install section names" {
    const profiles = @import("profiles.zig");
    const firefox_dir = "core/testdata/two-profiles";

    const ini = try readFixtureLogins(testing.allocator, firefox_dir ++ "/profiles.ini");
    defer testing.allocator.free(ini);

    const profile = try profiles.resolveDefault(testing.allocator, firefox_dir, ini);
    defer testing.allocator.free(profile);
    // profiles.resolveDefault joins through std.fs.path.join. That function
    // writes the host's separator.
    try testing.expectEqualStrings(
        firefox_dir ++ std.fs.path.sep_str ++ "Profiles/real.default-release",
        profile,
    );

    const key4 = try std.fmt.allocPrint(testing.allocator, "{s}/key4.db", .{profile});
    defer testing.allocator.free(key4);
    _ = try loadKeys(key4, "");
}

test "the unmigrated fixture carries a 24-byte 3DES key and no AES-256 key" {
    // Written by Firefox 143.0.4, before Firefox 144 added the AES-256 key
    // and re-encrypted the store. Every entry here is des_ede3_cbc.
    const logins = @import("logins.zig");
    const json = try readFixtureLogins(testing.allocator, "core/testdata/unmigrated/logins.json");
    defer testing.allocator.free(json);

    const keys = try loadKeys("core/testdata/unmigrated/key4.db", "");
    try testing.expect(keys.aes256 == null);
    try testing.expect(keys.des3 != null);

    const result = try logins.scan(testing.allocator, json, keys);
    defer freeScanResult(testing.allocator, result);

    try testing.expectEqual(@as(usize, 3), result.entries.len);
    for (result.entries) |e| {
        try testing.expect(e.legacy_3des);
        try testing.expectEqualStrings("", e.username);
    }
}

test "the migrated fixture carries both key rows and decrypts every entry" {
    // The unmigrated fixture's profile, opened once by Firefox 152. NSS
    // leaves the original 24-byte 3DES key row in place under the same
    // CKA_ID and adds the 32-byte AES-256 row alongside it, and re-encrypts
    // every entry to AES-256. Picking the first nssPrivate row by insertion
    // order returns the 3DES key and fails every entry's PKCS7 check. The
    // reader sorts by decrypted length to pick between them.
    const logins = @import("logins.zig");
    const json = try readFixtureLogins(testing.allocator, "core/testdata/migrated/logins.json");
    defer testing.allocator.free(json);

    const keys = try loadKeys("core/testdata/migrated/key4.db", "");
    try testing.expect(keys.aes256 != null);
    try testing.expect(keys.des3 != null);

    const result = try logins.scan(testing.allocator, json, keys);
    defer freeScanResult(testing.allocator, result);

    try testing.expectEqual(@as(usize, 3), result.entries.len);
    for (result.entries) |e| {
        try testing.expect(!e.legacy_3des);
        try testing.expect(e.username.len > 0);
    }
}

test "the sync-shaped fixture filters tombstones and labels the account and extension rows" {
    const logins = @import("logins.zig");
    const json = try readFixtureLogins(testing.allocator, "core/testdata/sync-shaped/logins.json");
    defer testing.allocator.free(json);

    const keys = try loadKeys("core/testdata/sync-shaped/key4.db", "");
    const result = try logins.scan(testing.allocator, json, keys);
    defer freeScanResult(testing.allocator, result);

    // 7 rows in logins.json: 3 ordinary logins, 1 account row, 1 extension
    // row, and 2 tombstones. The store filters the tombstones out before
    // it counts.
    try testing.expectEqual(@as(usize, 5), result.entries.len);
    try testing.expectEqual(@as(usize, 2), result.tombstones_skipped);
    try testing.expectEqual(@as(usize, 0), result.malformed);

    var account_count: usize = 0;
    var extension_count: usize = 0;
    var normal_count: usize = 0;
    for (result.entries) |e| {
        switch (e.kind) {
            .account_credential => {
                account_count += 1;
                try testing.expectEqualStrings("chrome://FirefoxAccounts", e.hostname);
            },
            .extension => {
                extension_count += 1;
                try testing.expect(std.mem.startsWith(u8, e.hostname, "moz-extension://"));
            },
            .normal => normal_count += 1,
        }
        try testing.expect(!e.legacy_3des);
        try testing.expect(e.username.len > 0);
    }
    try testing.expectEqual(@as(usize, 1), account_count);
    try testing.expectEqual(@as(usize, 1), extension_count);
    try testing.expectEqual(@as(usize, 3), normal_count);
}

fn openFixture(profile_path: []const u8, password: []const u8) !@import("store.zig").Store {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    return @import("store.zig").Store.open(testing.allocator, io, profile_path, password);
}

test "Store.open on the sync-shaped fixture filters tombstones like logins.scan" {
    var s = try openFixture("core/testdata/sync-shaped", "");
    defer s.deinit();

    try testing.expectEqual(@as(usize, 5), s.entries.len);
    try testing.expectEqual(@as(usize, 2), s.tombstones_skipped);

    var scratch: [8192]u8 = undefined;
    var out: [8192]u8 = undefined;
    for (s.entries, 0..) |e, i| {
        if (e.kind != .normal) continue;
        const plain = try s.reveal(i, &scratch, &out);
        try testing.expect(std.mem.startsWith(u8, plain, "fixture-pass-"));
    }
}

test "Store.search matches case-insensitively over hostname and username" {
    var s = try openFixture("core/testdata/fresh", "");
    defer s.deinit();

    var out: [8]usize = undefined;

    // Every hostname in `fresh` is lowercase and carries "example".
    const example_count = s.search("EXAMPLE", &out);
    try testing.expectEqual(@as(usize, 3), example_count);

    const empty_count = s.search("", &out);
    try testing.expectEqual(s.entries.len, empty_count);

    const none_count = s.search("no-such-substring-anywhere", &out);
    try testing.expectEqual(@as(usize, 0), none_count);

    // fixture-user-2 appears in no hostname, so this reaches the username
    // field.
    const one_count = s.search("fixture-user-2", &out);
    try testing.expectEqual(@as(usize, 1), one_count);
    try testing.expectEqualStrings("https://sub.example.org", s.entries[out[0]].hostname);
}

test "Store.search reports the true match count past the output cap" {
    var s = try openFixture("core/testdata/fresh", "");
    defer s.deinit();

    var out: [1]usize = undefined;
    const count = s.search("", &out);
    try testing.expectEqual(s.entries.len, count);
    try testing.expect(count > out.len);
}

fn drainRows(it: *sqlitedb.RowIterator) !void {
    while (try it.next()) |_| {}
}

test "the fan-out fixture stops the walk at the page budget" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    var db = try sqlitedb.Db.open(threaded.io(), "core/testdata/fanout.db");
    defer db.close();

    var buf: [4096]u8 = undefined;
    const table = try db.table("metaData", &buf);

    // The file holds 23 pages and every interior page names the next one 72
    // times, so the walk reaches 72**21 leaves. The budget stops it after 23
    // pushes.
    var it = table.rows(&db, &buf);
    try testing.expectError(error.Corrupt, drainRows(&it));
}

test "the reserved-bytes fixture returns the payload the tail excludes" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    var db = try sqlitedb.Db.open(threaded.io(), "core/testdata/reserved.db");
    defer db.close();

    // Header offset 20 reserves 16 bytes of every 512-byte page, so the
    // payload arithmetic counts 496 usable bytes. Reading the same file with
    // page_size in place of usable takes 92 local bytes where this takes 108.
    try testing.expectEqual(@as(u32, 512), db.page_size);
    try testing.expectEqual(@as(u32, 496), db.usable);

    var buf: [4096]u8 = undefined;
    const table = try db.table("wide", &buf);
    const body = try table.columnIndex("body");

    var it = table.rows(&db, &buf);
    const row = (try it.next()) orelse return error.NoRow;
    const bytes = row.column(body) orelse return error.NoColumn;

    // scripts/test-mkfixtures.py fills the blob with (position * 7) % 251. The record
    // totals 600 bytes and its own header takes 4, so 596 reach this column.
    try testing.expectEqual(@as(usize, 596), bytes.len);
    for (bytes, 0..) |b, i| try testing.expectEqual(@as(u8, @intCast((i * 7) % 251)), b);
    try testing.expect((try it.next()) == null);
}

test "profiles.enumerate on two-profiles finds the one with no key4.db" {
    const profiles = @import("profiles.zig");
    const firefox_dir = "core/testdata/two-profiles";

    const ini = try readFixtureLogins(testing.allocator, firefox_dir ++ "/profiles.ini");
    defer testing.allocator.free(ini);

    const list = try profiles.enumerate(testing.allocator, firefox_dir, ini);
    defer {
        for (list) |p| {
            testing.allocator.free(p.name);
            testing.allocator.free(p.path);
        }
        testing.allocator.free(list);
    }

    try testing.expectEqual(@as(usize, 2), list.len);

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cwd = std.Io.Dir.cwd();

    var without_key4: usize = 0;
    var with_key4: usize = 0;
    for (list) |p| {
        const key4 = try std.fmt.allocPrint(testing.allocator, "{s}/key4.db", .{p.path});
        defer testing.allocator.free(key4);
        if (cwd.access(io, key4, .{})) {
            with_key4 += 1;
        } else |_| {
            without_key4 += 1;
        }
    }
    try testing.expectEqual(@as(usize, 1), without_key4);
    try testing.expectEqual(@as(usize, 1), with_key4);
}

test "sdr.parse, pbes2.parse and pbes2.unwrap do not panic on mutated DER blobs" {
    const blobs = [_][]const u8{
        &hex("30430410f8000000000000000000000000000001" ++
            "301d060960864801650304012a" ++
            "0410000102030405060708090a0b0c0d0e0f" ++
            "0410aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
        &hex("303a0410f8000000000000000000000000000001" ++
            "3014" ++ "06082a864886f70d0307" ++ "04080001020304050607" ++
            "0410aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
        &hex("30430410f8000000000000000000000000000001" ++
            "301d060960864801650304012a" ++
            "0410aff746a5e8fbc81eeda1ea77890d8169" ++
            "0410a85a33da899c6e4f8c92a5e91c35b7f3"),
    };

    var prng = std.Random.DefaultPrng.init(0xdeadbeef_cafebabe);
    const rand = prng.random();

    var buf: [256]u8 = undefined;
    var out: [256]u8 = undefined;
    const global_salt: [20]u8 = @splat(0);

    for (blobs) |original| {
        for (0..256) |_| {
            @memcpy(buf[0..original.len], original);
            buf[rand.intRangeLessThan(usize, 0, original.len)] = rand.int(u8);
            _ = sdr.parse(buf[0..original.len]) catch {};
            _ = pbes2.parse(buf[0..original.len]) catch {};
            _ = pbes2.unwrap(buf[0..original.len], &global_salt, "", &out) catch {};

            const trunc_len = rand.intRangeAtMost(usize, 0, original.len);
            _ = sdr.parse(original[0..trunc_len]) catch {};
            _ = pbes2.parse(original[0..trunc_len]) catch {};
            _ = pbes2.unwrap(original[0..trunc_len], &global_salt, "", &out) catch {};

            @memcpy(buf[0..original.len], original);
            const ext = original.len + rand.intRangeLessThan(usize, 1, 65);
            for (buf[original.len..ext]) |*b| b.* = rand.int(u8);
            _ = sdr.parse(buf[0..ext]) catch {};
            _ = pbes2.parse(buf[0..ext]) catch {};
            _ = pbes2.unwrap(buf[0..ext], &global_salt, "", &out) catch {};
        }
    }
}

test "byte-flip explorer: keydb.load and sqlitedb do not panic on mutated fixtures" {
    const seed: u64 = 0xa5a5a5a5_5a5a5a5a;
    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cwd = std.Io.Dir.cwd();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [64]u8 = undefined;
    const tmp_file = std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/mutant.db", .{&tmp.sub_path}) catch unreachable;

    {
        const original = try cwd.readFileAlloc(io, "core/testdata/fresh/key4.db", testing.allocator, .unlimited);
        defer testing.allocator.free(original);

        const buf = try testing.allocator.alloc(u8, original.len);
        defer testing.allocator.free(buf);

        for (0..64) |i| {
            std.debug.print("seed=0x{x} key4.db {d}/64\n", .{ seed, i });
            @memcpy(buf, original);
            buf[rand.intRangeLessThan(usize, 0, original.len)] = rand.int(u8);
            try tmp.dir.writeFile(io, .{ .sub_path = "mutant.db", .data = buf });
            _ = keydb.load(io, tmp_file, "") catch continue;
        }
    }

    const small = [_]struct { path: []const u8, table_name: []const u8 }{
        .{ .path = "core/testdata/reserved.db", .table_name = "wide" },
        .{ .path = "core/testdata/fanout.db", .table_name = "metaData" },
    };

    for (small) |fixture| {
        const original = try cwd.readFileAlloc(io, fixture.path, testing.allocator, .unlimited);
        defer testing.allocator.free(original);

        const buf = try testing.allocator.alloc(u8, original.len);
        defer testing.allocator.free(buf);

        for (0..256) |i| {
            std.debug.print("seed=0x{x} {s} {d}/256\n", .{ seed, fixture.path, i });
            @memcpy(buf, original);
            buf[rand.intRangeLessThan(usize, 0, original.len)] = rand.int(u8);
            try tmp.dir.writeFile(io, .{ .sub_path = "mutant.db", .data = buf });

            var db = sqlitedb.Db.open(io, tmp_file) catch continue;
            defer db.close();

            var row_buf: [4096]u8 = undefined;
            const tbl = db.table(fixture.table_name, &row_buf) catch continue;
            var it = tbl.rows(&db, &row_buf);
            while (it.next() catch null) |row| {
                for (0..8) |col| _ = row.column(col);
            }
        }
    }
}

// `zig build test --fuzz` mutates the DER blobs in the corpus below (an
// AES-256 SDR blob, a des_ede3_cbc one, and one decoded out of the fresh
// fixture's encryptedUsername) and feeds every mutation to der.Reader
// through sdr.parse and pbes2.parse. A panic is what this looks for. A
// parse error is the correct answer for mutated bytes.
//
// `--fuzz` itself does not run on the pinned Zig 0.16.0: test_runner.zig
// calls std.debug.writeStackTrace with a *builtin.StackTrace where it now
// takes a *debug.StackTrace, a compile error in Zig's own bundled test
// runner (github.com/ziglang/zig, "Errors when trying to run
// std.testing.fuzz on 0.16", Ziggit thread 15515). Plain `zig build test`
// still compiles and runs this test once, over the corpus above, with no
// mutation. Rerun with --fuzz once a Zig version fixes that runner.
test "fuzz sdr.parse and pbes2.parse over mutated captured blobs" {
    try testing.fuzz({}, fuzzParsers, .{
        .corpus = &.{
            &hex("30430410f8000000000000000000000000000001" ++
                "301d060960864801650304012a" ++
                "0410000102030405060708090a0b0c0d0e0f" ++
                "0410aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
            &hex("303a0410f8000000000000000000000000000001" ++
                "3014" ++ "06082a864886f70d0307" ++ "04080001020304050607" ++
                "0410aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
            &hex("30430410f8000000000000000000000000000001" ++
                "301d060960864801650304012a" ++
                "0410aff746a5e8fbc81eeda1ea77890d8169" ++
                "0410a85a33da899c6e4f8c92a5e91c35b7f3"),
        },
    });
}

fn fuzzParsers(_: void, smith: *testing.Smith) anyerror!void {
    var buf: [512]u8 = undefined;
    const n = smith.slice(&buf);
    const data = buf[0..n];
    _ = sdr.parse(data) catch {};
    _ = pbes2.parse(data) catch {};
}

test "messages.friendly covers every error in store.Error and store.RevealError" {
    const sets = .{
        @typeInfo(store.Error).error_set.?,
        @typeInfo(store.RevealError).error_set.?,
    };
    inline for (sets) |errors| {
        inline for (errors) |e| {
            const err = @field(anyerror, e.name);
            const text = messages.friendly(err);
            if (std.mem.eql(u8, text, messages.unexpected)) {
                std.debug.print("messages.friendly has no arm for error.{s}\n", .{e.name});
                return error.MissingMessageArm;
            }
        }
    }
}

test "Store.open returns an empty store when logins.json is missing" {
    var s = try openFixture("core/testdata/no-logins", "");
    defer s.deinit();

    try testing.expectEqual(@as(usize, 0), s.entries.len);
    try testing.expectEqual(@as(usize, 0), s.tombstones_skipped);
    try testing.expectEqual(@as(usize, 0), s.malformed);

    var out: [8]usize = undefined;
    const count = s.search("", &out);
    try testing.expectEqual(@as(usize, 0), count);
}

test "logins.scan rejects an object value for the logins key" {
    const logins = @import("logins.zig");
    const keys: keydb.Keys = .{};
    try testing.expectError(error.NoLoginsArray, logins.scan(testing.allocator,
        \\{"logins": {}}
    , keys));
}

test "logins.scan rejects malformed JSON" {
    const logins = @import("logins.zig");
    const keys: keydb.Keys = .{};
    try testing.expectError(error.MalformedJson, logins.scan(testing.allocator, "not json at all", keys));
}

test "logins.scan rejects an object with no logins key" {
    const logins = @import("logins.zig");
    const keys: keydb.Keys = .{};
    try testing.expectError(error.NoLoginsArray, logins.scan(testing.allocator,
        \\{"other": []}
    , keys));
}

test "pbes2 rejects a key_len other than 32" {
    var blob = hex("308182306E06092A864886F70D01050D3061304206092A864886F70D01050C30" ++
        "35042087E7510D9573FAC37B76B335B4404A3B8C088B1A7B80AA01FCA56A3F87" ++
        "FBB7D702022710020120300A06082A864886F70D0209301B0609608648016503" ++
        "04012A040E9C99693DDEF51F20FE260E1FD5790410155C6C52F21267D0E27A5E" ++
        "64315CB340");
    blob[73] = 0x10;
    var out: [256]u8 = undefined;
    const global_salt = hex("661C366FD887564582212421FC6E1388A4F37714EFA99166B3AE3D767079E607" ++
        "6FFA02718064165695084DAE22EDB6E9");
    try testing.expectError(error.UnsupportedKeyLen, pbes2.unwrap(&blob, &global_salt, "", &out));
}

test "pbes2 rejects zero iterations" {
    var blob = hex("308182306E06092A864886F70D01050D3061304206092A864886F70D01050C30" ++
        "35042087E7510D9573FAC37B76B335B4404A3B8C088B1A7B80AA01FCA56A3F87" ++
        "FBB7D702022710020120300A06082A864886F70D0209301B0609608648016503" ++
        "04012A040E9C99693DDEF51F20FE260E1FD5790410155C6C52F21267D0E27A5E" ++
        "64315CB340");
    blob[69] = 0x00;
    blob[70] = 0x00;
    var out: [256]u8 = undefined;
    const global_salt = hex("661C366FD887564582212421FC6E1388A4F37714EFA99166B3AE3D767079E607" ++
        "6FFA02718064165695084DAE22EDB6E9");
    try testing.expectError(error.WeakParameters, pbes2.unwrap(&blob, &global_salt, "", &out));
}

test "keydb.load rejects a database in WAL mode" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cwd = std.Io.Dir.cwd();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const original = try cwd.readFileAlloc(io, "core/testdata/fresh/key4.db", testing.allocator, .unlimited);
    defer testing.allocator.free(original);

    original[18] = 2;
    try tmp.dir.writeFile(io, .{ .sub_path = "key4.db", .data = original });

    var path_buf: [128]u8 = undefined;
    const tmp_path = std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/key4.db", .{&tmp.sub_path}) catch unreachable;

    try testing.expectError(error.WalJournal, keydb.load(io, tmp_path, ""));
}

test "a key4.db with no password-check row returns MissingPasswordRow" {
    try testing.expectError(error.MissingPasswordRow, loadKeys("core/testdata/no-password-row/key4.db", ""));
}

test "a key4.db with no key row returns NoSdrKey" {
    try testing.expectError(error.NoSdrKey, loadKeys("core/testdata/no-key-row/key4.db", ""));
}
