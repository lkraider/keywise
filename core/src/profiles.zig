//! Resolves which profile Firefox opens.

const std = @import("std");
const builtin = @import("builtin");

pub const Error = error{NoProfileFound} || std.mem.Allocator.Error;

/// Firefox writes profiles.ini under one of these, relative to $HOME. A
/// distro package, the Ubuntu snap and the Flatpak each keep their own root,
/// and one machine can carry all of them. Each install reads the one root its
/// packaging fixes. A merged list would name profiles the running Firefox
/// cannot open.
///
/// Windows keeps its root under %APPDATA%. `win/src/main.zig` joins it.
pub const home_relative_dirs: []const []const u8 = switch (builtin.os.tag) {
    .macos => &.{"Library/Application Support/Firefox"},
    .windows => &.{},
    else => &.{
        ".mozilla/firefox",
        "snap/firefox/common/.mozilla/firefox",
        ".var/app/org.mozilla.firefox/.mozilla/firefox",
    },
};

pub const DirError = error{NoFirefoxDir} || std.mem.Allocator.Error;

/// The first root under `home` that holds a profiles.ini. Caller owns the
/// memory.
pub fn resolveDir(io: std.Io, gpa: std.mem.Allocator, home: []const u8) DirError![]u8 {
    return resolveDirIn(io, gpa, home, home_relative_dirs);
}

fn resolveDirIn(
    io: std.Io,
    gpa: std.mem.Allocator,
    home: []const u8,
    dirs: []const []const u8,
) DirError![]u8 {
    const cwd = std.Io.Dir.cwd();
    for (dirs) |rel| {
        const dir = try std.fs.path.join(gpa, &.{ home, rel });
        errdefer gpa.free(dir);

        const ini = try std.fs.path.join(gpa, &.{ dir, "profiles.ini" });
        defer gpa.free(ini);

        if (cwd.access(io, ini, .{})) return dir else |_| gpa.free(dir);
    }
    return error.NoFirefoxDir;
}

const KeyValue = struct { key: []const u8, value: []const u8 };
const Section = struct { name: []const u8, fields: []const KeyValue };

/// Splits `ini` into sections, in file order. Every string in the result
/// points into `ini`, so the result dies with it. The caller frees each
/// section's `fields` and the returned slice, both with `gpa`.
fn parseSections(gpa: std.mem.Allocator, ini: []const u8) std.mem.Allocator.Error![]Section {
    var sections: std.ArrayList(Section) = .empty;
    errdefer {
        for (sections.items) |s| gpa.free(s.fields);
        sections.deinit(gpa);
    }

    var name: []const u8 = "";
    var fields: std.ArrayList(KeyValue) = .empty;
    errdefer fields.deinit(gpa);

    var lines = std.mem.splitScalar(u8, ini, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;

        if (line.len >= 2 and line[0] == '[' and line[line.len - 1] == ']') {
            try sections.append(gpa, .{ .name = name, .fields = try fields.toOwnedSlice(gpa) });
            name = std.mem.trim(u8, line[1 .. line.len - 1], "]");
            continue;
        }

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        try fields.append(gpa, .{
            .key = std.mem.trim(u8, line[0..eq], " \t"),
            .value = std.mem.trim(u8, line[eq + 1 ..], " \t"),
        });
    }
    try sections.append(gpa, .{ .name = name, .fields = try fields.toOwnedSlice(gpa) });

    return sections.toOwnedSlice(gpa);
}

fn freeSections(gpa: std.mem.Allocator, sections: []const Section) void {
    for (sections) |s| gpa.free(s.fields);
    gpa.free(sections);
}

/// std.fs.path.isAbsolute reads a drive letter on Windows. Testing `rel[0]`
/// against '/' sent `Path=C:\Users\x\profile` down the join branch and
/// produced `%APPDATA%\Mozilla\Firefox\C:\Users\x\profile`.
pub fn resolvePath(gpa: std.mem.Allocator, firefox_dir: []const u8, rel: []const u8) std.mem.Allocator.Error![]u8 {
    if (std.fs.path.isAbsolute(rel)) return gpa.dupe(u8, rel);
    return std.fs.path.join(gpa, &.{ firefox_dir, rel });
}

/// Returns the absolute profile directory. Caller owns the memory.
///
/// Since Firefox 67 the `[InstallXXXX]` section names the profile for a given
/// installation and `Default=1` under `[ProfileN]` is only the pre-67 fallback.
/// Reading `Default=1` first selects an abandoned profile on machines that have
/// one.
pub fn resolveDefault(gpa: std.mem.Allocator, firefox_dir: []const u8, ini: []const u8) Error![]u8 {
    const sections = try parseSections(gpa, ini);
    defer freeSections(gpa, sections);

    var install_path: ?[]const u8 = null;
    var legacy_path: ?[]const u8 = null;

    for (sections) |s| {
        if (std.mem.startsWith(u8, s.name, "Install")) {
            for (s.fields) |f| {
                if (std.mem.eql(u8, f.key, "Default") and f.value.len > 0) install_path = f.value;
            }
        } else if (std.mem.startsWith(u8, s.name, "Profile")) {
            var path: ?[]const u8 = null;
            var is_default = false;
            for (s.fields) |f| {
                if (std.mem.eql(u8, f.key, "Path") and f.value.len > 0) path = f.value;
                if (std.mem.eql(u8, f.key, "Default") and std.mem.eql(u8, f.value, "1")) is_default = true;
            }
            if (is_default) {
                if (path) |p| legacy_path = p;
            }
        }
    }

    const rel = install_path orelse legacy_path orelse return error.NoProfileFound;
    return resolvePath(gpa, firefox_dir, rel);
}

pub const Profile = struct {
    /// The `Name` key. Empty if a section carried none.
    name: []const u8,
    /// Absolute, resolved the same way `resolveDefault` resolves one.
    path: []const u8,
};

/// Every `[ProfileN]` section in profiles.ini, in file order.
/// `resolveDefault` returns one path. A profile Firefox abandoned carries no
/// key4.db, and opening it fails, so a front end needs the other sections to
/// fall back on.
pub fn enumerate(gpa: std.mem.Allocator, firefox_dir: []const u8, ini: []const u8) std.mem.Allocator.Error![]Profile {
    const sections = try parseSections(gpa, ini);
    defer freeSections(gpa, sections);

    var profiles: std.ArrayList(Profile) = .empty;
    errdefer {
        for (profiles.items) |p| {
            gpa.free(p.name);
            gpa.free(p.path);
        }
        profiles.deinit(gpa);
    }

    for (sections) |s| {
        if (!std.mem.startsWith(u8, s.name, "Profile")) continue;
        var name: []const u8 = "";
        var path: ?[]const u8 = null;
        for (s.fields) |f| {
            if (std.mem.eql(u8, f.key, "Name")) name = f.value;
            if (std.mem.eql(u8, f.key, "Path") and f.value.len > 0) path = f.value;
        }
        const p = path orelse continue;
        try profiles.append(gpa, .{
            .name = try gpa.dupe(u8, name),
            .path = try resolvePath(gpa, firefox_dir, p),
        });
    }

    return profiles.toOwnedSlice(gpa);
}

/// `resolveDefault` and `enumerate` join through `std.fs.path.join`, which
/// writes the host's separator. The tail of each expectation below keeps the
/// forward slashes profiles.ini itself carries.
const sep = std.fs.path.sep_str;

test "install section wins over the legacy Default flag" {
    const ini =
        \\[Profile1]
        \\Name=default
        \\IsRelative=1
        \\Path=Profiles/abandoned.default
        \\Default=1
        \\
        \\[Profile0]
        \\Name=default-release
        \\IsRelative=1
        \\Path=Profiles/real.default-release
        \\
        \\[Install2656FF1E876E9973]
        \\Default=Profiles/real.default-release
        \\Locked=1
    ;
    const got = try resolveDefault(std.testing.allocator, "/ff", ini);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("/ff" ++ sep ++ "Profiles/real.default-release", got);
}

test "falls back to Default=1 when no install section exists" {
    const ini =
        \\[Profile0]
        \\Path=Profiles/only.default
        \\Default=1
    ;
    const got = try resolveDefault(std.testing.allocator, "/ff", ini);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("/ff" ++ sep ++ "Profiles/only.default", got);
}

test "enumerate lists every Profile section, including one Default does not pick" {
    const ini =
        \\[Profile1]
        \\Name=default
        \\IsRelative=1
        \\Path=Profiles/abandoned.default
        \\Default=1
        \\
        \\[Profile0]
        \\Name=default-release
        \\IsRelative=1
        \\Path=Profiles/real.default-release
        \\
        \\[Install2656FF1E876E9973]
        \\Default=Profiles/real.default-release
        \\Locked=1
    ;
    const got = try enumerate(std.testing.allocator, "/ff", ini);
    defer {
        for (got) |p| {
            std.testing.allocator.free(p.name);
            std.testing.allocator.free(p.path);
        }
        std.testing.allocator.free(got);
    }

    try std.testing.expectEqual(@as(usize, 2), got.len);
    try std.testing.expectEqualStrings("default", got[0].name);
    try std.testing.expectEqualStrings("/ff" ++ sep ++ "Profiles/abandoned.default", got[0].path);
    try std.testing.expectEqualStrings("default-release", got[1].name);
    try std.testing.expectEqualStrings("/ff" ++ sep ++ "Profiles/real.default-release", got[1].path);
}

test "enumerate returns an empty slice for an ini with no Profile sections" {
    const got = try enumerate(std.testing.allocator, "/ff", "[General]\nVersion=2\n");
    defer std.testing.allocator.free(got);
    try std.testing.expectEqual(@as(usize, 0), got.len);
}

test "resolvePath leaves an absolute path alone and joins a relative one" {
    const gpa = std.testing.allocator;

    const absolute = if (builtin.os.tag == .windows) "C:\\Users\\x\\profile" else "/home/x/profile";
    const kept = try resolvePath(gpa, "/ff", absolute);
    defer gpa.free(kept);
    try std.testing.expectEqualStrings(absolute, kept);

    const joined = try resolvePath(gpa, "/ff", "Profiles/p");
    defer gpa.free(joined);
    try std.testing.expectEqualStrings("/ff" ++ sep ++ "Profiles/p", joined);
}

// home_relative_dirs holds one entry on macOS, so this passes its own list.
test "resolveDir skips a root with no profiles.ini and reports the paths it tried" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const found = try resolveDirIn(io, gpa, "core/testdata", &.{ "fresh", "two-profiles" });
    defer gpa.free(found);
    try std.testing.expectEqualStrings("core/testdata" ++ sep ++ "two-profiles", found);

    try std.testing.expectError(
        error.NoFirefoxDir,
        resolveDirIn(io, gpa, "core/testdata", &.{"fresh"}),
    );
}

test "malformed sections and empty profile paths are ignored" {
    try std.testing.expectError(
        error.NoProfileFound,
        resolveDefault(std.testing.allocator, "/firefox", "[\n[]\n[Profile0]\nPath=\n"),
    );
    try std.testing.expectError(
        error.NoProfileFound,
        resolveDefault(std.testing.allocator, "/firefox", "[Profile0]\nPath=\nDefault=1\n"),
    );

    const listed = try enumerate(std.testing.allocator, "/firefox", "[Profile0]\nPath=\n");
    defer std.testing.allocator.free(listed);
    try std.testing.expectEqual(@as(usize, 0), listed.len);
}
