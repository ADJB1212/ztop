const std = @import("std");
const manifest = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});
    const sdk_root = b.option([]const u8, "sdk-root", "Path to macOS SDK root (for cross-compilation)");
    const version = std.SemanticVersion.parse(manifest.version) catch @panic("invalid version in build.zig.zon");

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", manifest.version);
    const strip = b.option(bool, "strip", "Strip symbols") orelse false;

    const mod = b.addModule("ztop", .{
        .root_source_file = b.path("src/root.zig"),

        .target = target,
    });

    const exe = b.addExecutable(.{
        .name = "ztop",
        .version = version,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),

            .target = target,
            .optimize = optimize,
            .strip = strip,

            .imports = &.{
                .{ .name = "ztop", .module = mod },
            },
        }),
    });
    exe.root_module.addOptions("build_options", build_options);

    const tests_module = b.createModule(.{
        .root_source_file = b.path("tests/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ztop", .module = mod },
        },
    });
    tests_module.addOptions("build_options", build_options);

    const tests = b.addTest(.{
        .root_module = tests_module,
    });

    if (target.result.os.tag != .macos) {
        std.debug.panic("ztop is only supported on macOS", .{});
    }
    if (target.result.cpu.arch != .aarch64) {
        std.debug.panic("ztop is only supported on ARM (Apple Silicon) Macs", .{});
    }

    const swiftc = b.addSystemCommand(&.{
        "swiftc",
        "-O",
        "-emit-library",
        "-static",
        "-framework",
        "FoundationModels",
    });
    if (sdk_root) |root| {
        swiftc.addArgs(&.{ "-sdk", root });
    }
    const fm_lib = swiftc.addPrefixedOutputFileArg("-o", "libfmbridge.a");
    swiftc.addFileArg(b.path("src/ai/fm_bridge.swift"));

    exe.root_module.addObjectFile(fm_lib);
    tests.root_module.addObjectFile(fm_lib);

    exe.root_module.addCSourceFile(.{
        .file = b.path("src/sysinfo/darwin/wifi.m"),
    });
    tests.root_module.addCSourceFile(.{
        .file = b.path("src/sysinfo/darwin/wifi.m"),
    });
    exe.root_module.addCSourceFile(.{
        .file = b.path("src/sysinfo/darwin/power.m"),
    });
    tests.root_module.addCSourceFile(.{
        .file = b.path("src/sysinfo/darwin/power.m"),
    });

    var sdk_path_buf: [1024]u8 = undefined;
    const effective_sdk_root: ?[]const u8 = if (sdk_root) |root| root else blk: {
        var code: u8 = 0;
        if (b.runAllowFail(&.{ "xcrun", "--show-sdk-path" }, &code, .ignore)) |out| {
            if (code == 0) {
                const trimmed = std.mem.trimEnd(u8, out, "\r\n ");
                if (trimmed.len > 0 and trimmed.len < sdk_path_buf.len) {
                    @memcpy(sdk_path_buf[0..trimmed.len], trimmed);
                    break :blk sdk_path_buf[0..trimmed.len];
                }
            }
        } else |_| {}
        break :blk null;
    };

    if (effective_sdk_root) |root| {
        exe.root_module.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ root, "usr/include" }) });
        exe.root_module.addSystemFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ root, "System/Library/Frameworks" }) });
        exe.root_module.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ root, "usr/lib/swift" }) });
        exe.root_module.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ root, "usr/lib" }) });
        tests.root_module.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ root, "usr/include" }) });
        tests.root_module.addSystemFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ root, "System/Library/Frameworks" }) });
        tests.root_module.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ root, "usr/lib/swift" }) });
        tests.root_module.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ root, "usr/lib" }) });
    }
    exe.root_module.addLibraryPath(.{ .cwd_relative = "/usr/lib/swift" });
    exe.root_module.addLibraryPath(.{ .cwd_relative = "/usr/lib" });
    tests.root_module.addLibraryPath(.{ .cwd_relative = "/usr/lib/swift" });
    tests.root_module.addLibraryPath(.{ .cwd_relative = "/usr/lib" });

    exe.root_module.linkSystemLibrary("c", .{});
    tests.root_module.linkSystemLibrary("c", .{});

    const swift_libs: []const []const u8 = &.{
        "swiftCore",           "swift_Concurrency",      "swiftDispatch",
        "swiftCoreFoundation", "swiftIOKit",             "swiftObjectiveC",
        "swiftXPC",            "swift_Builtin_float",    "swift_errno",
        "swift_math",          "swift_signal",           "swift_stdio",
        "swift_time",          "swift_StringProcessing", "swift_Volatile",
    };
    for (swift_libs) |lib| {
        exe.root_module.linkSystemLibrary(lib, .{});
        tests.root_module.linkSystemLibrary(lib, .{});
    }

    exe.root_module.linkFramework("IOKit", .{});
    exe.root_module.linkFramework("CoreFoundation", .{});
    exe.root_module.linkFramework("Foundation", .{});
    exe.root_module.linkFramework("CoreWLAN", .{});
    exe.root_module.linkFramework("FoundationModels", .{ .weak = true });
    exe.root_module.linkSystemLibrary("IOReport", .{});
    tests.root_module.linkFramework("IOKit", .{});
    tests.root_module.linkFramework("CoreFoundation", .{});
    tests.root_module.linkFramework("Foundation", .{});
    tests.root_module.linkFramework("CoreWLAN", .{});
    tests.root_module.linkFramework("FoundationModels", .{ .weak = true });
    tests.root_module.linkSystemLibrary("IOReport", .{});

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const test_step = b.step("test", "Run unit tests");

    const run_tests = b.addRunArtifact(tests);

    const print_success = b.addSystemCommand(&.{
        "echo",
        "\x1b[32m✔ All tests passed!\x1b[0m",
    });
    print_success.step.dependOn(&run_tests.step);

    test_step.dependOn(&print_success.step);
}
