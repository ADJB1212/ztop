const std = @import("std");
const manifest = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});
    const sdk_root = b.option([]const u8, "sdk-root", "Path to macOS SDK root (for cross-compilation)");
    const version = std.SemanticVersion.parse(manifest.version) catch @panic("invalid version in build.zig.zon");

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", manifest.version);

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

    if (target.result.os.tag == .macos) {
        // Allow explicit SDK root for cross-compilation (e.g. aarch64 from x86_64 host).
        // Pass with: -Dsdk-root=$(xcrun --show-sdk-path)
        if (sdk_root) |root| {
            exe.root_module.addFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ root, "System/Library/Frameworks" }) });
            exe.root_module.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ root, "usr/lib" }) });
            tests.root_module.addFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ root, "System/Library/Frameworks" }) });
            tests.root_module.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ root, "usr/lib" }) });
        }
        exe.root_module.linkFramework("IOKit", .{});
        exe.root_module.linkFramework("CoreFoundation", .{});
        tests.root_module.linkFramework("IOKit", .{});
        tests.root_module.linkFramework("CoreFoundation", .{});
    }

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
