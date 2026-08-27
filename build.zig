const std = @import("std");
const builtin = @import("builtin");
const zon = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    var target = b.standardTargetOptions(.{});

    // The compiler locates the macOS SDK for a native query. With a triple
    // in the query, translate-c reports
    // `unable to find dynamic system library 'sqlite3'`. core/test/oracle.zig
    // links libsqlite3 and runs on the build host.
    const host_target = target;

    // std.Build sends the compiler `target.query`
    // (lib/std/Build/Module.zig:596). An empty query sends no -target and no
    // -mcpu. The compiler then reads the cpu and the macOS version from the
    // build host. A runner image bump moves the published bytes.
    //
    // 14.0 is the floor Package.swift and Formula/keywise.rb declare. Linux and
    // Windows keep the empty query. A native build there takes its kernel and
    // glibc versions from the host.
    if (target.result.os.tag == .macos) {
        target.query.cpu_arch = target.result.cpu.arch;
        target.query.os_tag = .macos;
        target.query.os_version_min = .{ .semver = .{ .major = 14, .minor = 0, .patch = 0 } };
    }

    const optimize = b.standardOptimizeOption(.{});
    const test_run_always = b.option(bool, "test-run-always", "Skip the test cache and re-run every test") orelse false;

    // `keywise --version` prints this. Reading the manifest keeps the version in
    // one file. scripts/release-set-version.sh writes it, and release.yml
    // checks it against the pushed tag.
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", zon.version);

    // Zig's macOS linker embeds an LC_UUID, and a code-signature hash that
    // covers it, derived from debug info that isn't otherwise deterministic.
    // Stripping removes that debug info, so two clean rebuilds of the same
    // source on the same machine produce identical bytes. Verified by
    // rebuilding keywise twice and diffing. Zero bytes differ, and the output
    // filename matches. Debug keeps its symbols. That build exists for
    // debugging.
    const strip = optimize != .Debug;

    // @cImport is deprecated in 0.16. C translation belongs to the build system.
    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("core/src/c.h"),
        .target = target,
        .optimize = optimize,
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("core/src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "c", .module = translate_c.createModule() }},
    });

    const exe = b.addExecutable(.{ .name = "keywise-probe", .root_module = exe_mod });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    b.step("run", "Run the validation probe").dependOn(&run.step);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("core/src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    const tests = b.addTest(.{ .root_module = test_mod });
    const test_step = b.step("test", "Run the core and TUI tests");
    const run_tests = b.addRunArtifact(tests);
    if (test_run_always) run_tests.has_side_effects = true;
    test_step.dependOn(&run_tests.step);

    // The oracle reads every fixture through core/src/sqlitedb.zig and again
    // through the system sqlite3, then compares the bytes. It links
    // libsqlite3 from the macOS SDK. The test binary runs on the host, so it
    // builds only when the target is the host and the host is macOS. The
    // Windows CI job passes -Doracle=false.
    const host_has_sqlite = builtin.os.tag == .macos and target.result.os.tag == builtin.os.tag;
    if (b.option(bool, "oracle", "Diff the SQLite reader against the system sqlite3") orelse host_has_sqlite) {
        const sqlite_c = b.addTranslateC(.{
            .root_source_file = b.path("core/test/sqlite.h"),
            .target = host_target,
            .optimize = optimize,
        });
        sqlite_c.linkSystemLibrary("sqlite3", .{});

        // A module rooted under core/test cannot import a file under
        // core/src by path, so the reader arrives as a named import.
        const oracle_mod = b.createModule(.{
            .root_source_file = b.path("core/test/oracle.zig"),
            .target = host_target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "sqlite", .module = sqlite_c.createModule() },
                .{ .name = "sqlitedb", .module = b.createModule(.{
                    .root_source_file = b.path("core/src/sqlitedb.zig"),
                    .target = host_target,
                    .optimize = optimize,
                }) },
            },
        });
        oracle_mod.linkSystemLibrary("sqlite3", .{});
        const oracle = b.addTest(.{ .root_module = oracle_mod });
        const run_oracle = b.addRunArtifact(oracle);
        if (test_run_always) run_oracle.has_side_effects = true;
        test_step.dependOn(&run_oracle.step);
    }

    // The TUI's argument parser. The tui module would pull vaxis and
    // sqlite3 into the link. Rooting this at args.zig keeps both out.
    const args_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tui/src/args.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    const run_args = b.addRunArtifact(args_tests);
    if (test_run_always) run_args.has_side_effects = true;
    test_step.dependOn(&run_args.step);

    const win_args_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("win/src/args.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    const run_win_args = b.addRunArtifact(win_args_tests);
    if (test_run_always) run_win_args.has_side_effects = true;
    test_step.dependOn(&run_win_args.step);

    // TUI. core/src/root.zig is the module a front end imports
    // through. A relative import cannot cross from tui/src into core/src.
    const core_mod = b.createModule(.{
        .root_source_file = b.path("core/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // tui/src/model.zig imports core and std only. This test runs on the
    // host that builds the exe.
    const tui_model_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tui/src/model.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "core", .module = core_mod }},
    }) });
    const run_tui_model = b.addRunArtifact(tui_model_tests);
    if (test_run_always) run_tui_model.has_side_effects = true;
    test_step.dependOn(&run_tui_model.step);

    const vaxis_dep = b.dependency("libvaxis", .{ .target = target, .optimize = optimize });

    const tui_mod = b.createModule(.{
        .root_source_file = b.path("tui/src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .imports = &.{
            .{ .name = "core", .module = core_mod },
            .{ .name = "vaxis", .module = vaxis_dep.module("vaxis") },
            .{ .name = "build_options", .module = build_options.createModule() },
        },
    });

    // The TUI serves macOS and Linux. Windows gets the Win32 front end under
    // win/. tui/src/main.zig calls std.process.Args.Iterator.init, and that
    // function is a compile error on Windows. It also reads HOME and joins
    // the macOS profile path.
    const tui_exe = b.addExecutable(.{ .name = "keywise", .root_module = tui_mod });
    if (target.result.os.tag != .windows) b.installArtifact(tui_exe);

    const run_tui = b.addRunArtifact(tui_exe);
    run_tui.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_tui.addArgs(args);
    b.step("tui", "Run the TUI").dependOn(&run_tui.step);

    // The Windows front end's rules. win/src/model.zig imports core and std
    // only. This test runs on the host that builds the exe.
    const model_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("win/src/model.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "core", .module = core_mod }},
    }) });
    const run_model = b.addRunArtifact(model_tests);
    if (test_run_always) run_model.has_side_effects = true;
    test_step.dependOn(&run_model.step);

    // win/app.rc and win/src/ids.zig repeat the same resource ids. The test
    // in ids.zig reads win/src/resource.h and compares every value.
    const ids_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("win/src/ids.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    const run_ids = b.addRunArtifact(ids_tests);
    if (test_run_always) run_ids.has_side_effects = true;
    test_step.dependOn(&run_ids.step);

    // win/src/text.zig imports std alone, so its cut-at-a-codepoint tests run
    // on the host that builds the exe.
    const text_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("win/src/text.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    const run_text = b.addRunArtifact(text_tests);
    if (test_run_always) run_text.has_side_effects = true;
    test_step.dependOn(&run_text.step);

    // The Win32 front end. It imports `core` directly, the way tui does. No
    // C ABI, no FFI, no libc.
    const win_mod = b.createModule(.{
        .root_source_file = b.path("win/src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .imports = &.{
            .{ .name = "core", .module = core_mod },
            .{ .name = "args", .module = b.createModule(.{
                .root_source_file = b.path("win/src/args.zig"),
                .target = target,
                .optimize = optimize,
            }) },
        },
    });
    for ([_][]const u8{ "user32", "comctl32", "gdi32", "dwmapi", "uxtheme", "advapi32" }) |lib| {
        win_mod.linkSystemLibrary(lib, .{});
    }
    // Zig bundles a .def file for each library above and generates the
    // import library from it, so this links with no Windows SDK.
    win_mod.addWin32ResourceFile(.{ .file = b.path("win/app.rc") });

    const win_exe = b.addExecutable(.{
        .name = "Keywise",
        .root_module = win_mod,
    });
    // The windows subsystem keeps a console window from opening behind the
    // app. Zig's WinStartup then calls `main` as declared in win/src/main.zig.
    win_exe.subsystem = .Windows;

    const win_step = b.step("win", "Build the Windows app");
    if (target.result.os.tag == .windows) {
        const install_win = b.addInstallArtifact(win_exe, .{});
        b.getInstallStep().dependOn(&install_win.step);
        win_step.dependOn(&install_win.step);
    } else {
        win_step.dependOn(&b.addFail(
            "the win step needs a Windows target, for example -Dtarget=aarch64-windows-gnu",
        ).step);
    }

    // C ABI static library. It shares `target` with everything else above,
    // so -Dtarget applies to it too. Releases ship a single aarch64-macos
    // slice, and no lipo step runs. core.zig calls c.getenv and allocates
    // through std.heap.c_allocator, and Swift links libc regardless.
    const core_lib_mod = b.createModule(.{
        .root_source_file = b.path("core/src/core.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .link_libc = true,
        .imports = &.{.{ .name = "c", .module = translate_c.createModule() }},
    });

    const core_lib = b.addLibrary(.{
        .name = "keywise",
        .root_module = core_lib_mod,
        .linkage = .static,
    });
    core_lib.installHeader(b.path("core/include/keywise.h"), "keywise.h");
    b.installArtifact(core_lib);

    // C smoke test, exercising the static library the way Swift will.
    const smoke_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    smoke_mod.addCSourceFile(.{ .file = b.path("core/test/smoke.c") });
    smoke_mod.addIncludePath(b.path("core/include"));
    smoke_mod.linkLibrary(core_lib);
    const smoke = b.addExecutable(.{ .name = "keywise-smoke", .root_module = smoke_mod });
    b.installArtifact(smoke);

    const run_smoke = b.addRunArtifact(smoke);
    run_smoke.step.dependOn(b.getInstallStep());
    b.step("smoke", "Run the C ABI smoke test").dependOn(&run_smoke.step);
}
