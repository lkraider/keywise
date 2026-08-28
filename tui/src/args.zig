//! Command line parsing for the TUI. `parse` takes a plain slice, so its
//! tests need no process.

const std = @import("std");

pub const ExportFormat = enum { csv, json };

pub const Options = struct {
    /// The profile directory to open. Null means read profiles.ini and take
    /// the pick `profiles.resolveDefault` returns.
    profile_path: ?[]const u8 = null,
    export_path: ?[]const u8 = null,
    list_profiles: bool = false,
    version: bool = false,
    help: bool = false,

    pub fn exportFormat(self: Options) error{BadExtension}!?ExportFormat {
        const path = self.export_path orelse return null;
        if (std.mem.endsWith(u8, path, ".csv")) return .csv;
        if (std.mem.endsWith(u8, path, ".json")) return .json;
        return error.BadExtension;
    }
};

pub const Error = error{ MissingValue, UnknownFlag, BadExtension };

pub const usage =
    \\keywise -- view a local Firefox profile's saved logins
    \\
    \\Usage:
    \\  keywise                     open the profile Firefox uses
    \\  keywise --profile <path>    open the profile in <path>
    \\  keywise --export <file>     export logins to file (.csv or .json)
    \\  keywise --list-profiles     print every profile in profiles.ini
    \\  keywise --version           print the version
    \\  keywise --help              print this text
    \\
    \\Keys:
    \\  /            search, enter or escape leaves the field
    \\  up down k j  move through the list
    \\  PgDn PgUp    jump one screenful
    \\  Home End     jump to first / last
    \\  enter        reveal the selected password, again to hide it
    \\  y            copy the selected password. The row stays masked. A copy
    \\               on Linux runs wl-copy from the wl-clipboard package,
    \\               xclip from xclip, or xsel from xsel. With stdout on a
    \\               pipe or a file, y writes the password there as well. The
    \\               last y of the run writes.
    \\  q ctrl-c     quit
    \\
;

/// `argv` excludes the program name.
pub fn parse(argv: []const []const u8) Error!Options {
    var options: Options = .{};
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            options.help = true;
        } else if (std.mem.eql(u8, arg, "--list-profiles")) {
            options.list_profiles = true;
        } else if (std.mem.eql(u8, arg, "--version")) {
            options.version = true;
        } else if (std.mem.eql(u8, arg, "--profile")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            if (std.mem.startsWith(u8, argv[i], "--")) return error.MissingValue;
            options.profile_path = argv[i];
        } else if (std.mem.startsWith(u8, arg, "--profile=")) {
            const value = arg["--profile=".len..];
            if (value.len == 0) return error.MissingValue;
            options.profile_path = value;
        } else if (std.mem.eql(u8, arg, "--export")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            if (std.mem.startsWith(u8, argv[i], "--")) return error.MissingValue;
            options.export_path = argv[i];
            _ = try options.exportFormat();
        } else if (std.mem.startsWith(u8, arg, "--export=")) {
            const value = arg["--export=".len..];
            if (value.len == 0) return error.MissingValue;
            options.export_path = value;
            _ = try options.exportFormat();
        } else {
            return error.UnknownFlag;
        }
    }
    return options;
}

test "no arguments leaves every field at its default" {
    const options = try parse(&.{});
    try std.testing.expect(options.profile_path == null);
    try std.testing.expect(options.export_path == null);
    try std.testing.expect(!options.list_profiles);
    try std.testing.expect(!options.version);
    try std.testing.expect(!options.help);
}

test "--profile takes the next argument" {
    const options = try parse(&.{ "--profile", "/tmp/p" });
    try std.testing.expectEqualStrings("/tmp/p", options.profile_path.?);
}

test "--profile=<path> takes the value after the equals sign" {
    const options = try parse(&.{"--profile=/tmp/p"});
    try std.testing.expectEqualStrings("/tmp/p", options.profile_path.?);
}

test "--profile with nothing after it reports MissingValue" {
    try std.testing.expectError(error.MissingValue, parse(&.{"--profile"}));
    try std.testing.expectError(error.MissingValue, parse(&.{"--profile="}));
}

test "--list-profiles, --version and --help set their flags" {
    try std.testing.expect((try parse(&.{"--list-profiles"})).list_profiles);
    try std.testing.expect((try parse(&.{"--version"})).version);
    try std.testing.expect((try parse(&.{"--help"})).help);
    try std.testing.expect((try parse(&.{"-h"})).help);
}

test "--version takes no value, so a path after it reports UnknownFlag" {
    try std.testing.expectError(error.UnknownFlag, parse(&.{ "--version", "/tmp/p" }));
    try std.testing.expectError(error.UnknownFlag, parse(&.{"--version=1"}));
}

test "an unrecognized argument reports UnknownFlag" {
    try std.testing.expectError(error.UnknownFlag, parse(&.{"--colour"}));
    try std.testing.expectError(error.UnknownFlag, parse(&.{"/tmp/p"}));
}

test "--export takes the next argument" {
    const options = try parse(&.{ "--export", "/tmp/out.csv" });
    try std.testing.expectEqualStrings("/tmp/out.csv", options.export_path.?);
}

test "--export=<path> takes the value after the equals sign" {
    const options = try parse(&.{"--export=/tmp/out.json"});
    try std.testing.expectEqualStrings("/tmp/out.json", options.export_path.?);
}

test "--export with nothing after it reports MissingValue" {
    try std.testing.expectError(error.MissingValue, parse(&.{"--export"}));
    try std.testing.expectError(error.MissingValue, parse(&.{"--export="}));
}

test "--export rejects a path without .csv or .json" {
    try std.testing.expectError(error.BadExtension, parse(&.{ "--export", "/tmp/out.txt" }));
    try std.testing.expectError(error.BadExtension, parse(&.{"--export=logins.xml"}));
}

test "exportFormat returns csv for .csv and json for .json" {
    const csv_opts = try parse(&.{ "--export", "logins.csv" });
    try std.testing.expect((try csv_opts.exportFormat()).? == .csv);
    const json_opts = try parse(&.{ "--export", "logins.json" });
    try std.testing.expect((try json_opts.exportFormat()).? == .json);
}

test "exportFormat returns null when no export path is set" {
    const options = try parse(&.{});
    try std.testing.expect((try options.exportFormat()) == null);
}

test "--profile rejects a flag as its value" {
    try std.testing.expectError(error.MissingValue, parse(&.{ "--profile", "--version" }));
    try std.testing.expectError(error.MissingValue, parse(&.{ "--profile", "--export" }));
}

test "--export rejects a flag as its value" {
    try std.testing.expectError(error.MissingValue, parse(&.{ "--export", "--profile" }));
    try std.testing.expectError(error.MissingValue, parse(&.{ "--export", "--version" }));
}

test "--export combines with --profile" {
    const options = try parse(&.{ "--profile", "/tmp/p", "--export", "/tmp/out.csv" });
    try std.testing.expectEqualStrings("/tmp/p", options.profile_path.?);
    try std.testing.expectEqualStrings("/tmp/out.csv", options.export_path.?);
}
