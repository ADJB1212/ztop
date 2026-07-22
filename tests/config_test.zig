const std = @import("std");
const config = @import("ztop").config;
const tui = @import("ztop").tui;

test "config parse applies theme defaults and overrides" {
    const parsed = config.parse(
        \\theme = nord
        \\default_sort = mem
        \\default_tab = sensors
        \\default_tree_view = true
        \\show_help_on_startup = yes
        \\update_interval_ms = 750
        \\color.brand = bright_magenta
        \\color.selection_bg = magenta
        \\disable_history = true
    );

    try std.testing.expectEqual(config.ThemeName.nord, parsed.theme_name);
    try std.testing.expectEqual(@as(u32, 750), parsed.update_interval_ms);
    try std.testing.expectEqual(@import("ztop").sysinfo.SortBy.mem, parsed.default_sort);
    try std.testing.expectEqual(@as(u8, 3), parsed.default_tab);
    try std.testing.expectEqual(true, parsed.default_tree_view);
    try std.testing.expectEqual(true, parsed.show_help_on_startup);
    try std.testing.expectEqual(true, parsed.disable_history);
    try std.testing.expectEqual(tui.Tui.Color.bright_magenta, parsed.theme.brand);
    try std.testing.expectEqual(tui.Tui.Color.magenta, parsed.theme.selection_bg);
    try std.testing.expectEqual(tui.Tui.Color{ .indexed = 67 }, parsed.theme.memory_title);
}

test "config parse supports aliases and quoted values" {
    const parsed = config.parse(
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

test "config parse supports wakeup attribution sort and column" {
    const parsed = config.parse(
        \\default_sort = wakeups
        \\process_columns = pid, cpu, wakeups
    );

    try std.testing.expectEqual(@import("ztop").sysinfo.SortBy.wakeups, parsed.default_sort);
    try std.testing.expectEqual(true, parsed.process_columns.pid);
    try std.testing.expectEqual(true, parsed.process_columns.cpu);
    try std.testing.expectEqual(true, parsed.process_columns.wakeups);
}

test "config parse supports 256 color themes and numeric overrides" {
    const parsed = config.parse(
        \\theme = "default-light"
        \\color.command_prompt = 33
    );

    try std.testing.expectEqual(config.ThemeName.default_light, parsed.theme_name);
    try std.testing.expectEqual(tui.Tui.Color{ .indexed = 25 }, parsed.theme.brand);
    try std.testing.expectEqual(tui.Tui.Color{ .indexed = 33 }, parsed.theme.command_prompt);

    const palenight = config.parse("theme = palenight\n");
    try std.testing.expectEqual(config.ThemeName.palenight, palenight.theme_name);
    try std.testing.expectEqual(tui.Tui.Color{ .indexed = 141 }, palenight.theme.brand);
    try std.testing.expectEqual(tui.Tui.Color{ .indexed = 235 }, palenight.theme.selection_bg);

    const colorblind = config.parse("theme = colorblind\n");
    try std.testing.expectEqual(config.ThemeName.colorblind, colorblind.theme_name);
    try std.testing.expectEqual(tui.Tui.Color{ .indexed = 33 }, colorblind.theme.brand);
    try std.testing.expectEqual(tui.Tui.Color{ .indexed = 202 }, colorblind.theme.usage_critical);
}

test "config parse supports launch command ignore substring list" {
    const parsed = config.parse(
        \\ignore_launch_cmd_substr = "Google Chrome, Chrome Helper, /Applications/Slack.app"
    );

    try std.testing.expectEqualStrings("Google Chrome, Chrome Helper, /Applications/Slack.app", parsed.ignoredLaunchCommandSubstr());
}

test "config parse supports process column selection" {
    const parsed = config.parse(
        \\process_columns = pid, ppid, launch_path, state, cpu, name
        \\io_process_columns = disk_io, pid, mem
    );

    try std.testing.expectEqual(true, parsed.process_columns.pid);
    try std.testing.expectEqual(true, parsed.process_columns.ppid);
    try std.testing.expectEqual(true, parsed.process_columns.launch_path);
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

test "process columns keep launch path disabled by default" {
    const defaults = config.Config.defaults();
    try std.testing.expectEqual(false, defaults.process_columns.launch_path);
    try std.testing.expectEqual(false, defaults.io_process_columns.launch_path);
}

test "config parse supports process column presets" {
    const parsed = config.parse(
        \\process_columns = none
        \\io_process_columns = all
    );

    try std.testing.expectEqual(@as(usize, 0), parsed.process_columns.countVisible());
    try std.testing.expectEqual(@as(usize, config.process_column_order.len), parsed.io_process_columns.countVisible());
}

test "config parse rejects invalid options" {
    const default_cfg = config.Config.defaults();
    var errors: std.ArrayList(config.DiagnosticError) = .empty;
    defer errors.deinit(std.testing.allocator);

    const parsed1 = config.parseWithErrors(std.testing.allocator, "not_real = value\n", &errors);
    try std.testing.expectEqual(default_cfg.theme_name, parsed1.theme_name);
    try std.testing.expectEqual(@as(usize, 1), errors.items.len);
    try std.testing.expectEqual(error.UnknownConfigKey, errors.items[0].err);
    errors.clearRetainingCapacity();

    const parsed2 = config.parseWithErrors(std.testing.allocator, "theme = vaporwave\n", &errors);
    try std.testing.expectEqual(default_cfg.theme_name, parsed2.theme_name);
    try std.testing.expectEqual(@as(usize, 1), errors.items.len);
    try std.testing.expectEqual(error.UnknownTheme, errors.items[0].err);
    errors.clearRetainingCapacity();

    const parsed3 = config.parseWithErrors(std.testing.allocator, "default_tab = logs\n", &errors);
    try std.testing.expectEqual(default_cfg.default_tab, parsed3.default_tab);
    try std.testing.expectEqual(@as(usize, 1), errors.items.len);
    try std.testing.expectEqual(error.UnknownTab, errors.items[0].err);
    errors.clearRetainingCapacity();

    const parsed4 = config.parseWithErrors(std.testing.allocator, "update_interval_ms = 50\n", &errors);
    try std.testing.expectEqual(default_cfg.update_interval_ms, parsed4.update_interval_ms);
    try std.testing.expectEqual(@as(usize, 1), errors.items.len);
    try std.testing.expectEqual(error.InvalidUpdateInterval, errors.items[0].err);
    errors.clearRetainingCapacity();

    const parsed5 = config.parseWithErrors(std.testing.allocator, "default_tree_view = maybe\n", &errors);
    try std.testing.expectEqual(default_cfg.default_tree_view, parsed5.default_tree_view);
    try std.testing.expectEqual(@as(usize, 1), errors.items.len);
    try std.testing.expectEqual(error.InvalidBooleanValue, errors.items[0].err);
    errors.clearRetainingCapacity();

    const parsed6 = config.parseWithErrors(std.testing.allocator, "color.nope = blue\n", &errors);
    try std.testing.expectEqual(default_cfg.theme.brand, parsed6.theme.brand);
    try std.testing.expectEqual(@as(usize, 1), errors.items.len);
    try std.testing.expectEqual(error.UnknownColorKey, errors.items[0].err);
    errors.clearRetainingCapacity();

    const parsed7 = config.parseWithErrors(std.testing.allocator, "process_columns = nope\n", &errors);
    try std.testing.expectEqual(default_cfg.process_columns.countVisible(), parsed7.process_columns.countVisible());
    try std.testing.expectEqual(@as(usize, 1), errors.items.len);
    try std.testing.expectEqual(error.UnknownProcessColumn, errors.items[0].err);
    errors.clearRetainingCapacity();
}

test "config file loader reads explicit path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "ztop.cfg", .data = "theme = solarized\ncolor.command_prompt = bright_yellow\n" });

    const config_path = try absoluteTmpPath(std.testing.allocator, &tmp, "ztop.cfg");
    defer std.testing.allocator.free(config_path);

    const loaded = config.loadPath(std.testing.allocator, std.testing.io, config_path);

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

    const loaded = config.load(std.testing.allocator, std.testing.io, &environ_map);

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

    const loaded = config.load(std.testing.allocator, std.testing.io, &environ_map);

    try std.testing.expectEqual(config.ThemeName.catppuccin, loaded.theme_name);
    try std.testing.expectEqual(true, loaded.show_help_on_startup);
}

test "config parse enable_ai option" {
    const default_cfg = config.Config.defaults();
    try std.testing.expectEqual(true, default_cfg.enable_ai);

    const parsed = config.parse("enable_ai = false");
    try std.testing.expectEqual(false, parsed.enable_ai);

    const parsed2 = config.parse("ai = false");
    try std.testing.expectEqual(false, parsed2.enable_ai);
}

test "config parse temperature_unit option and format calculations" {
    const default_cfg = config.Config.defaults();
    try std.testing.expectEqual(config.TemperatureUnit.celsius, default_cfg.temperature_unit);

    const parsed_f = config.parse("temperature_unit = fahrenheit");
    try std.testing.expectEqual(config.TemperatureUnit.fahrenheit, parsed_f.temperature_unit);

    const parsed_f_alias = config.parse("unit = f");
    try std.testing.expectEqual(config.TemperatureUnit.fahrenheit, parsed_f_alias.temperature_unit);

    const parsed_k = config.parse("temp_unit = k");
    try std.testing.expectEqual(config.TemperatureUnit.kelvin, parsed_k.temperature_unit);

    // Verify conversions
    try std.testing.expectEqual(@as(f32, 100.0), config.TemperatureUnit.celsius.format(100.0));
    try std.testing.expectEqual(@as(f32, 212.0), config.TemperatureUnit.fahrenheit.format(100.0));
    try std.testing.expectEqual(@as(f32, 373.15), config.TemperatureUnit.kelvin.format(100.0));
}

fn absoluteTmpPath(allocator: std.mem.Allocator, tmp: *const std.testing.TmpDir, sub_path: []const u8) ![]u8 {
    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);

    if (sub_path.len == 0) {
        return try std.fs.path.join(allocator, &.{ cwd, ".zig-cache", "tmp", tmp.sub_path[0..] });
    }

    return try std.fs.path.join(allocator, &.{ cwd, ".zig-cache", "tmp", tmp.sub_path[0..], sub_path });
}
