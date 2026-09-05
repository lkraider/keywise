//! Validation probe. Reports what the core managed to read from the default
//! profile and prints no credential.

const std = @import("std");
const c = @import("c");
const profiles = @import("profiles.zig");
const store = @import("store.zig");

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // std.process.Environ needs the process init block. A plain main()
    // never receives one. libc is already linked for sqlite3.
    const home_c = c.getenv("HOME") orelse return error.NoHome;
    const home = std.mem.span(home_c);
    const firefox_dir = try std.fs.path.join(gpa, &.{ home, "Library/Application Support/Firefox" });

    const cwd = std.Io.Dir.cwd();
    const ini_path = try std.fs.path.join(gpa, &.{ firefox_dir, "profiles.ini" });
    const ini = try cwd.readFileAlloc(io, ini_path, gpa, .limited(1024 * 1024));

    const all_profiles = try profiles.enumerate(gpa, firefox_dir, ini);
    std.debug.print("profiles:  {d} found\n", .{all_profiles.len});

    const profile = try profiles.resolveDefault(gpa, firefox_dir, ini);
    std.debug.print("profile:   {s}\n", .{profile});

    var s = try store.Store.open(gpa, io, profile, "");
    defer s.deinit();
    std.debug.print("password-check verified with an empty Primary Password\n", .{});
    std.debug.print("aes256 key: {s}\n", .{if (s.keys.aes256 != null) "present (32 bytes)" else "absent"});
    std.debug.print("3des key:   {s}\n", .{if (s.keys.des3 != null) "present (24 bytes)" else "absent"});

    var legacy_3des: usize = 0;
    var account_credentials: usize = 0;
    var extensions: usize = 0;
    for (s.entries) |e| {
        if (e.legacy_3des) legacy_3des += 1;
        switch (e.kind) {
            .account_credential => account_credentials += 1,
            .extension => extensions += 1,
            .normal => {},
        }
    }

    std.debug.print(
        "logins:    {d} total, {d} decrypted, {d} legacy 3des, {d} tombstones skipped, {d} malformed\n",
        .{ s.entries.len, s.entries.len - legacy_3des, legacy_3des, s.tombstones_skipped, s.malformed },
    );
    std.debug.print(
        "kinds:     {d} account credential, {d} extension\n",
        .{ account_credentials, extensions },
    );

    // Times the substring scan itself. It prints no hostname, username or
    // password.
    const search_iterations: usize = 1000;
    const search_scratch = try gpa.alloc(usize, s.entries.len);
    const search_start: std.Io.Clock.Timestamp = .now(io, .awake);
    var iter: usize = 0;
    while (iter < search_iterations) : (iter += 1) _ = s.search("example", search_scratch);
    const search_ns: f64 = @floatFromInt(search_start.untilNow(io).raw.nanoseconds);
    std.debug.print(
        "search:    {d} calls over {d} entries in {d:.2} ms total, {d:.2} us/call\n",
        .{
            search_iterations,
            s.entries.len,
            search_ns / std.time.ns_per_ms,
            search_ns / @as(f64, @floatFromInt(search_iterations)) / std.time.ns_per_us,
        },
    );
}
