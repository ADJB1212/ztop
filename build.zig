const std = @import("std");
const manifest = @import("build.zig.zon");
const Translator = @import("translate_c").Translator;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    if (target.result.os.tag != .macos) {
        std.debug.panic("ztop is only supported on macOS", .{});
    }
    if (target.result.cpu.arch != .aarch64) {
        std.debug.panic("ztop is only supported on ARM (Apple Silicon) Macs", .{});
    }

    const optimize = b.standardOptimizeOption(.{});
    const sdk_root = resolveSdkRoot(b);
    const version = std.SemanticVersion.parse(manifest.version) catch @panic("invalid version in build.zig.zon");

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", manifest.version);
    const strip = b.option(bool, "strip", "Strip symbols") orelse false;

    const mod = b.addModule("ztop", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
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

    if (exe.root_module.optimize != .debug) {
        exe.link_gc_sections = true;
    }

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

    const swiftc = b.addSystemCommand(&.{ "swiftc", "-emit-library", "-static", "-framework", "FoundationModels", "-use-ld=lld" });
    swiftc.addArgs(switch (optimize) {
        .debug => &.{ "-Onone", "-g" },
        .fast, .safe => &.{ "-O", "-whole-module-optimization", "-gnone" },
        .small => &.{ "-Osize", "-whole-module-optimization", "-gnone" },
    });
    swiftc.addArgs(&.{ "-sdk", sdk_root });
    const fm_lib = swiftc.addPrefixedOutputFileArg("-o", "libfmbridge.a");
    swiftc.addFileArg(b.path("src/ai/fm_bridge.swift"));

    configureNativeModule(b, exe.root_module, sdk_root, fm_lib);
    configureNativeModule(b, tests.root_module, sdk_root, fm_lib);

    const translate_c = b.dependency("translate_c", .{});
    const darwin_c: Translator = .init(translate_c, .{
        .c_source_file = b.path("src/sysinfo/darwin/bindings.h"),
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("darwin_c", darwin_c.mod);

    darwin_c.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sdk_root, "usr/include" }) });
    darwin_c.addSystemFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sdk_root, "System/Library/Frameworks" }) });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    const test_step = b.step("test", "Run unit tests");
    const run_tests = b.addRunArtifact(tests);
    const print_success = b.addSystemCommand(&.{ "echo", "All tests passed" });
    print_success.step.dependOn(&run_tests.step);
    test_step.dependOn(&print_success.step);
}

fn resolveSdkRoot(b: *std.Build) []const u8 {
    if (b.option([]const u8, "sdk-root", "Path to macOS SDK root (for cross-compilation)")) |root| {
        if (root.len == 0) std.debug.panic("-Dsdk-root must not be empty", .{});
        return root;
    }

    var code: u8 = 0;
    const output = b.runAllowFail(&.{ "xcrun", "--sdk", "macosx", "--show-sdk-path" }, &code, .inherit) catch |err| {
        std.debug.panic("Unable to locate the macOS SDK ({s}); set -Dsdk-root", .{@errorName(err)});
    };
    const root = std.mem.trimEnd(u8, output, "\r\n ");
    if (code != 0 or root.len == 0) {
        std.debug.panic("Unable to locate the macOS SDK; set -Dsdk-root", .{});
    }
    return root;
}

fn configureNativeModule(b: *std.Build, module: *std.Build.Module, sdk_root: []const u8, fm_lib: std.Build.LazyPath) void {
    module.addObjectFile(fm_lib);
    module.addCSourceFiles(.{
        .files = &.{ "src/sysinfo/darwin/wifi.m", "src/sysinfo/darwin/power.m" },
        .flags = &([_][]const u8{"-fuse-ld=lld"} ++ if (module.optimize != .debug) [_][]const u8{ "-O3", "-fvectorize" } else [_][]const u8{ "-Wall", "-Wextra" }),
    });
    module.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sdk_root, "usr/include" }) });
    module.addSystemFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sdk_root, "System/Library/Frameworks" }) });
    module.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ sdk_root, "usr/lib/swift" }) });
    module.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ sdk_root, "usr/lib" }) });
    module.addLibraryPath(.{ .cwd_relative = "/usr/lib/swift" });
    module.addLibraryPath(.{ .cwd_relative = "/usr/lib" });
    module.linkSystemLibrary("c", .{});
    module.linkSystemLibrary("IOReport", .{});

    const swift_libs: []const []const u8 = &.{
        "swiftCore",           "swift_Concurrency",      "swiftDispatch",
        "swiftCoreFoundation", "swiftIOKit",             "swiftObjectiveC",
        "swiftXPC",            "swift_Builtin_float",    "swift_errno",
        "swift_math",          "swift_signal",           "swift_stdio",
        "swift_time",          "swift_StringProcessing", "swift_Volatile",
        "swiftCoreImage",      "swiftMetal",             "swiftUniformTypeIdentifiers",
    };
    for (swift_libs) |lib| {
        module.linkSystemLibrary(lib, .{});
    }

    const frameworks: []const []const u8 = &.{
        "IOKit", "CoreFoundation", "Foundation", "CoreWLAN", "FoundationModels",
    };

    for (frameworks) |framework| {
        module.linkFramework(framework, .{});
    }
}
