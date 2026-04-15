const std = @import("std");
const config = @import("ztop").config;
const tui = @import("ztop").tui;

test "config parse applies theme defaults and overrides" {
    const parsed = try config.parse(
        \\theme = nord
        \\default_sort = mem
        \\default_tab = sensors
        \\default_tree_view = true
        \\show_help_on_startup = yes
        \\update_interval_ms = 750
        \\color.brand = bright_magenta
        \\color.selection_bg = magenta
    );

    try std.testing.expectEqual(config.ThemeName.nord, parsed.theme_name);
    try std.testing.expectEqual(@as(u32, 750), parsed.update_interval_ms);
    try std.testing.expectEqual(@import("ztop").sysinfo.SortBy.mem, parsed.default_sort);
    try std.testing.expectEqual(@as(u8, 3), parsed.default_tab);
    try std.testing.expectEqual(true, parsed.default_tree_view);
    try std.testing.expectEqual(true, parsed.show_help_on_startup);
    try std.testing.expectEqual(tui.Tui.Color.bright_magenta, parsed.theme.brand);
    try std.testing.expectEqual(tui.Tui.Color.magenta, parsed.theme.selection_bg);
    try std.testing.expectEqual(tui.Tui.Color{ .indexed = 67 }, parsed.theme.memory_title);
}

test "config parse supports aliases and quoted values" {
    const parsed = try config.parse(
        \\theme = "catppuccin-mocha"
        \\sort = process-name
        \\startup_tab = "network"
        \\tree_view = 1
        \\startup_help = true
        \\colors.io-rate = bright_cyan
    );

    try std.testing.expectEqual(config.ThemeName.catppuccin, parsed.theme_name);
    try std.testing.expectEqual(@import("ztop").sysinfo.SortBy.name, parsed.default_sort);
    try std.testing.expectEqual(@as(u8, 4), parsed.default_tab);
    try std.testing.expectEqual(true, parsed.default_tree_view);
    try std.testing.expectEqual(true, parsed.show_help_on_startup);
    try std.testing.expectEqual(tui.Tui.Color.bright_cyan, parsed.theme.io_rate);
    try std.testing.expectEqual(tui.Tui.Color{ .indexed = 183 }, parsed.theme.process_title);
}

test "config parse supports 256 color themes and numeric overrides" {
    const parsed = try config.parse(
        \\theme = "default-light"
        \\color.command_prompt = 33
    );

    try std.testing.expectEqual(config.ThemeName.default_light, parsed.theme_name);
    try std.testing.expectEqual(tui.Tui.Color{ .indexed = 25 }, parsed.theme.brand);
    try std.testing.expectEqual(tui.Tui.Color{ .indexed = 33 }, parsed.theme.command_prompt);

    const palenight = try config.parse("theme = palenight\n");
    try std.testing.expectEqual(config.ThemeName.palenight, palenight.theme_name);
    try std.testing.expectEqual(tui.Tui.Color{ .indexed = 141 }, palenight.theme.brand);
    try std.testing.expectEqual(tui.Tui.Color{ .indexed = 235 }, palenight.theme.selection_bg);
}

test "config parse supports launch command ignore substring list" {
    const parsed = try config.parse(
        \\ignore_launch_cmd_substr = "Google Chrome, Chrome Helper, /Applications/Slack.app"
    );

    try std.testing.expectEqualStrings("Google Chrome, Chrome Helper, /Applications/Slack.app", parsed.ignoredLaunchCommandSubstr());
}

test "config parse supports process column selection" {
    const parsed = try config.parse(
        \\process_columns = pid, ppid, state, cpu, name
        \\io_process_columns = disk_io, pid, mem
    );

    try std.testing.expectEqual(true, parsed.process_columns.pid);
    try std.testing.expectEqual(true, parsed.process_columns.ppid);
    try std.testing.expectEqual(true, parsed.process_columns.state);
    try std.testing.expectEqual(true, parsed.process_columns.cpu);
    try std.testing.expectEqual(false, parsed.process_columns.mem);
    try std.testing.expectEqual(false, parsed.process_columns.threads);

    try std.testing.expectEqual(true, parsed.io_process_columns.pid);
    try std.testing.expectEqual(true, parsed.io_process_columns.mem);
    try std.testing.expectEqual(true, parsed.io_process_columns.disk_read);
    try std.testing.expectEqual(true, parsed.io_process_columns.disk_write);
    try std.testing.expectEqual(false, parsed.io_process_columns.cpu);
}

test "config parse supports process column presets" {
    const parsed = try config.parse(
        \\process_columns = none
        \\io_process_columns = all
    );

    try std.testing.expectEqual(@as(usize, 0), parsed.process_columns.countVisible());
    try std.testing.expectEqual(@as(usize, config.process_column_order.len), parsed.io_process_columns.countVisible());
}

test "config parse rejects invalid options" {
    try std.testing.expectError(error.UnknownConfigKey, config.parse("not_real = value\n"));
    try std.testing.expectError(error.UnknownTheme, config.parse("theme = vaporwave\n"));
    try std.testing.expectError(error.UnknownTab, config.parse("default_tab = logs\n"));
    try std.testing.expectError(error.InvalidUpdateInterval, config.parse("update_interval_ms = 50\n"));
    try std.testing.expectError(error.InvalidBooleanValue, config.parse("default_tree_view = maybe\n"));
    try std.testing.expectError(error.UnknownColorKey, config.parse("color.nope = blue\n"));
    try std.testing.expectError(error.UnknownProcessColumn, config.parse("process_columns = nope\n"));
}

test "config file loader reads explicit path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "ztop.cfg", .data = "theme = solarized\ncolor.command_prompt = bright_yellow\n" });

    const config_path = try absoluteTmpPath(std.testing.allocator, &tmp, "ztop.cfg");
    defer std.testing.allocator.free(config_path);

    const loaded = try config.loadPath(std.testing.allocator, std.testing.io, config_path);

    try std.testing.expectEqual(config.ThemeName.solarized, loaded.theme_name);
    try std.testing.expectEqual(tui.Tui.Color.bright_yellow, loaded.theme.command_prompt);
    try std.testing.expectEqual(tui.Tui.Color{ .indexed = 32 }, loaded.theme.cpu_title);
}

test "config loader resolves XDG_CONFIG_HOME from environ map" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "ztop.cfg",
        .data = "theme = gruvbox\nnerd_fonts = true\n",
    });

    const xdg_config_home = try absoluteTmpPath(std.testing.allocator, &tmp, "");
    defer std.testing.allocator.free(xdg_config_home);

    var environ_map = std.process.Environ.Map.init(std.testing.allocator);
    defer environ_map.deinit();
    try environ_map.put("XDG_CONFIG_HOME", xdg_config_home);

    const loaded = try config.load(std.testing.allocator, std.testing.io, &environ_map);

    try std.testing.expectEqual(config.ThemeName.gruvbox, loaded.theme_name);
    try std.testing.expectEqual(true, loaded.nerd_fonts);
}

test "config loader falls back to HOME from environ map" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, ".config");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = ".config/ztop.cfg",
        .data = "theme = catppuccin\nshow_help_on_startup = true\n",
    });

    const home = try absoluteTmpPath(std.testing.allocator, &tmp, "");
    defer std.testing.allocator.free(home);

    var environ_map = std.process.Environ.Map.init(std.testing.allocator);
    defer environ_map.deinit();
    try environ_map.put("HOME", home);

    const loaded = try config.load(std.testing.allocator, std.testing.io, &environ_map);

    try std.testing.expectEqual(config.ThemeName.catppuccin, loaded.theme_name);
    try std.testing.expectEqual(true, loaded.show_help_on_startup);
}

fn absoluteTmpPath(allocator: std.mem.Allocator, tmp: *const std.testing.TmpDir, sub_path: []const u8) ![]u8 {
    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);

    if (sub_path.len == 0) {
        return try std.fs.path.join(allocator, &.{ cwd, ".zig-cache", "tmp", tmp.sub_path[0..] });
    }

    return try std.fs.path.join(allocator, &.{ cwd, ".zig-cache", "tmp", tmp.sub_path[0..], sub_path });
}
