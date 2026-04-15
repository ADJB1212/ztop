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
    try std.testing.expectEqual(tui.Tui.Color.bright_blue, parsed.theme.memory_title);
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
    try std.testing.expectEqual(tui.Tui.Color.bright_magenta, parsed.theme.process_title);
}

test "config parse supports launch command ignore substring list" {
    const parsed = try config.parse(
        \\ignore_launch_cmd_substr = "Google Chrome, Chrome Helper, /Applications/Slack.app"
    );

    try std.testing.expectEqualStrings("Google Chrome, Chrome Helper, /Applications/Slack.app", parsed.ignoredLaunchCommandSubstr());
}

test "config parse rejects invalid options" {
    try std.testing.expectError(error.UnknownConfigKey, config.parse("not_real = value\n"));
    try std.testing.expectError(error.UnknownTheme, config.parse("theme = vaporwave\n"));
    try std.testing.expectError(error.UnknownTab, config.parse("default_tab = logs\n"));
    try std.testing.expectError(error.InvalidUpdateInterval, config.parse("update_interval_ms = 50\n"));
    try std.testing.expectError(error.InvalidBooleanValue, config.parse("default_tree_view = maybe\n"));
    try std.testing.expectError(error.UnknownColorKey, config.parse("color.nope = blue\n"));
}

test "config file loader reads explicit path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "ztop.cfg", .data = "theme = solarized\ncolor.command_prompt = bright_yellow\n" });

    const config_path = try tmp.dir.realpathAlloc(std.testing.allocator, "ztop.cfg");
    defer std.testing.allocator.free(config_path);

    const loaded = try config.loadPath(std.testing.allocator, config_path);

    try std.testing.expectEqual(config.ThemeName.solarized, loaded.theme_name);
    try std.testing.expectEqual(tui.Tui.Color.bright_yellow, loaded.theme.command_prompt);
    try std.testing.expectEqual(tui.Tui.Color.blue, loaded.theme.cpu_title);
}
