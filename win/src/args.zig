//! Command line parsing for the Win32 front end. `parse` takes a plain slice,
//! so its tests need no process.

const std = @import("std");

pub const Options = struct {
    /// The profile directory to open. Null means read profiles.ini and take
    /// the pick `profiles.resolveDefault` returns.
    profile_path: ?[]const u8 = null,
};

pub const Error = error{ MissingValue, UnknownFlag };

/// `argv` excludes the program name.
pub fn parse(argv: []const []const u8) Error!Options {
    var options: Options = .{};
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--profile")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            if (std.mem.startsWith(u8, argv[i], "--")) return error.MissingValue;
            options.profile_path = argv[i];
        } else if (std.mem.startsWith(u8, arg, "--profile=")) {
            const value = arg["--profile=".len..];
            if (value.len == 0) return error.MissingValue;
            options.profile_path = value;
        } else {
            return error.UnknownFlag;
        }
    }
    return options;
}

test "no arguments leaves every field at its default" {
    const options = try parse(&.{});
    try std.testing.expect(options.profile_path == null);
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

test "--profile rejects a flag as its value" {
    try std.testing.expectError(error.MissingValue, parse(&.{ "--profile", "--version" }));
    try std.testing.expectError(error.MissingValue, parse(&.{ "--profile", "--help" }));
}

test "an unrecognized argument reports UnknownFlag" {
    try std.testing.expectError(error.UnknownFlag, parse(&.{"--colour"}));
    try std.testing.expectError(error.UnknownFlag, parse(&.{"/tmp/p"}));
}
