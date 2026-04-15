const std = @import("std");
const sysinfo = @import("sysinfo.zig");
const tui = @import("tui.zig");

pub const ThemeName = enum {
    default,
    gruvbox,
    nord,
    solarized,
    catppuccin,

    pub fn label(self: ThemeName) []const u8 {
        return switch (self) {
            .default => "Default",
            .gruvbox => "Gruvbox",
            .nord => "Nord",
            .solarized => "Solarized",
            .catppuccin => "Catppuccin",
        };
    }
};

pub const Theme = struct {
    brand: tui.Tui.Color,
    text: tui.Tui.Color,
    muted: tui.Tui.Color,
    border: tui.Tui.Color,
    tab_active: tui.Tui.Color,
    cpu_title: tui.Tui.Color,
    memory_title: tui.Tui.Color,
    disk_title: tui.Tui.Color,
    network_title: tui.Tui.Color,
    sensor_title: tui.Tui.Color,
    battery_title: tui.Tui.Color,
    process_title: tui.Tui.Color,
    selection_bg: tui.Tui.Color,
    selection_fg: tui.Tui.Color,
    usage_idle: tui.Tui.Color,
    usage_good: tui.Tui.Color,
    usage_warn: tui.Tui.Color,
    usage_critical: tui.Tui.Color,
    memory_low: tui.Tui.Color,
    memory_mid: tui.Tui.Color,
    memory_warn: tui.Tui.Color,
    memory_critical: tui.Tui.Color,
    io_rate: tui.Tui.Color,
    filter_prompt: tui.Tui.Color,
    command_prompt: tui.Tui.Color,
};

pub const ThemeOverrides = struct {
    brand: ?tui.Tui.Color = null,
    text: ?tui.Tui.Color = null,
    muted: ?tui.Tui.Color = null,
    border: ?tui.Tui.Color = null,
    tab_active: ?tui.Tui.Color = null,
    cpu_title: ?tui.Tui.Color = null,
    memory_title: ?tui.Tui.Color = null,
    disk_title: ?tui.Tui.Color = null,
    network_title: ?tui.Tui.Color = null,
    sensor_title: ?tui.Tui.Color = null,
    battery_title: ?tui.Tui.Color = null,
    process_title: ?tui.Tui.Color = null,
    selection_bg: ?tui.Tui.Color = null,
    selection_fg: ?tui.Tui.Color = null,
    usage_idle: ?tui.Tui.Color = null,
    usage_good: ?tui.Tui.Color = null,
    usage_warn: ?tui.Tui.Color = null,
    usage_critical: ?tui.Tui.Color = null,
    memory_low: ?tui.Tui.Color = null,
    memory_mid: ?tui.Tui.Color = null,
    memory_warn: ?tui.Tui.Color = null,
    memory_critical: ?tui.Tui.Color = null,
    io_rate: ?tui.Tui.Color = null,
    filter_prompt: ?tui.Tui.Color = null,
    command_prompt: ?tui.Tui.Color = null,

    pub fn apply(self: ThemeOverrides, theme: *Theme) void {
        inline for (std.meta.fields(ThemeOverrides)) |field| {
            if (@field(self, field.name)) |value| {
                @field(theme, field.name) = value;
            }
        }
    }
};

pub const Config = struct {
    theme_name: ThemeName,
    theme: Theme,
    theme_overrides: ThemeOverrides,
    default_sort: sysinfo.SortBy,
    default_tab: u8,
    default_tree_view: bool,
    show_help_on_startup: bool,
    update_interval_ms: u32,
    ignore_launch_cmd_substr_buf: [256]u8,
    ignore_launch_cmd_substr_len: u16,
    nerd_fonts: bool,

    pub fn defaults() Config {
        return .{
            .theme_name = .default,
            .theme = themePreset(.default),
            .theme_overrides = .{},
            .default_sort = .cpu,
            .default_tab = 1,
            .default_tree_view = false,
            .show_help_on_startup = false,
            .update_interval_ms = 500,
            .ignore_launch_cmd_substr_buf = std.mem.zeroes([256]u8),
            .ignore_launch_cmd_substr_len = 0,
            .nerd_fonts = false,
        };
    }

    pub fn ignoredLaunchCommandSubstr(self: *const Config) []const u8 {
        return self.ignore_launch_cmd_substr_buf[0..self.ignore_launch_cmd_substr_len];
    }
};

pub fn load(allocator: std.mem.Allocator) !Config {
    var config = Config.defaults();
    const config_path = try defaultConfigPath(allocator);
    defer if (config_path) |path| allocator.free(path);

    const path = config_path orelse return config;
    parseFile(allocator, path, &config) catch |err| switch (err) {
        error.FileNotFound => return config,
        else => return err,
    };
    return config;
}

pub fn loadPath(allocator: std.mem.Allocator, path: []const u8) !Config {
    var config = Config.defaults();
    try parseFile(allocator, path, &config);
    return config;
}

pub fn parse(text: []const u8) !Config {
    var config = Config.defaults();
    try parseInto(text, &config);
    return config;
}

pub fn themePreset(name: ThemeName) Theme {
    return switch (name) {
        .default => .{
            .brand = .bright_cyan,
            .text = .bright_white,
            .muted = .bright_black,
            .border = .bright_black,
            .tab_active = .bright_cyan,
            .cpu_title = .bright_cyan,
            .memory_title = .bright_yellow,
            .disk_title = .bright_cyan,
            .network_title = .bright_yellow,
            .sensor_title = .bright_red,
            .battery_title = .bright_green,
            .process_title = .bright_magenta,
            .selection_bg = .bright_black,
            .selection_fg = .bright_white,
            .usage_idle = .bright_cyan,
            .usage_good = .bright_green,
            .usage_warn = .bright_yellow,
            .usage_critical = .bright_red,
            .memory_low = .bright_blue,
            .memory_mid = .bright_magenta,
            .memory_warn = .bright_yellow,
            .memory_critical = .bright_red,
            .io_rate = .bright_white,
            .filter_prompt = .bright_yellow,
            .command_prompt = .bright_green,
        },
        .gruvbox => .{
            .brand = .bright_yellow,
            .text = .white,
            .muted = .bright_black,
            .border = .yellow,
            .tab_active = .bright_yellow,
            .cpu_title = .bright_yellow,
            .memory_title = .bright_green,
            .disk_title = .yellow,
            .network_title = .bright_cyan,
            .sensor_title = .bright_red,
            .battery_title = .bright_green,
            .process_title = .bright_magenta,
            .selection_bg = .bright_black,
            .selection_fg = .white,
            .usage_idle = .bright_cyan,
            .usage_good = .bright_green,
            .usage_warn = .bright_yellow,
            .usage_critical = .bright_red,
            .memory_low = .blue,
            .memory_mid = .magenta,
            .memory_warn = .bright_yellow,
            .memory_critical = .bright_red,
            .io_rate = .white,
            .filter_prompt = .bright_yellow,
            .command_prompt = .bright_green,
        },
        .nord => .{
            .brand = .bright_cyan,
            .text = .bright_white,
            .muted = .bright_black,
            .border = .bright_blue,
            .tab_active = .bright_cyan,
            .cpu_title = .bright_cyan,
            .memory_title = .bright_blue,
            .disk_title = .cyan,
            .network_title = .bright_blue,
            .sensor_title = .bright_magenta,
            .battery_title = .bright_green,
            .process_title = .bright_white,
            .selection_bg = .blue,
            .selection_fg = .bright_white,
            .usage_idle = .cyan,
            .usage_good = .bright_cyan,
            .usage_warn = .bright_yellow,
            .usage_critical = .bright_red,
            .memory_low = .blue,
            .memory_mid = .bright_blue,
            .memory_warn = .bright_yellow,
            .memory_critical = .bright_red,
            .io_rate = .bright_white,
            .filter_prompt = .bright_blue,
            .command_prompt = .bright_cyan,
        },
        .solarized => .{
            .brand = .yellow,
            .text = .white,
            .muted = .bright_black,
            .border = .cyan,
            .tab_active = .yellow,
            .cpu_title = .blue,
            .memory_title = .cyan,
            .disk_title = .blue,
            .network_title = .cyan,
            .sensor_title = .red,
            .battery_title = .green,
            .process_title = .yellow,
            .selection_bg = .blue,
            .selection_fg = .bright_white,
            .usage_idle = .cyan,
            .usage_good = .green,
            .usage_warn = .yellow,
            .usage_critical = .red,
            .memory_low = .blue,
            .memory_mid = .cyan,
            .memory_warn = .yellow,
            .memory_critical = .red,
            .io_rate = .white,
            .filter_prompt = .yellow,
            .command_prompt = .green,
        },
        .catppuccin => .{
            .brand = .bright_magenta,
            .text = .bright_white,
            .muted = .bright_black,
            .border = .magenta,
            .tab_active = .bright_magenta,
            .cpu_title = .bright_cyan,
            .memory_title = .bright_blue,
            .disk_title = .bright_cyan,
            .network_title = .bright_green,
            .sensor_title = .bright_red,
            .battery_title = .bright_green,
            .process_title = .bright_magenta,
            .selection_bg = .magenta,
            .selection_fg = .bright_white,
            .usage_idle = .bright_blue,
            .usage_good = .bright_green,
            .usage_warn = .bright_yellow,
            .usage_critical = .bright_red,
            .memory_low = .bright_blue,
            .memory_mid = .bright_magenta,
            .memory_warn = .bright_yellow,
            .memory_critical = .bright_red,
            .io_rate = .bright_white,
            .filter_prompt = .bright_magenta,
            .command_prompt = .bright_green,
        },
    };
}

fn parseFile(allocator: std.mem.Allocator, path: []const u8, config: *Config) !void {
    const contents = try std.fs.cwd().readFileAlloc(allocator, path, 64 * 1024);
    defer allocator.free(contents);
    try parseInto(contents, config);
}

fn parseInto(text: []const u8, config: *Config) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '#' or line[0] == ';') continue;

        const equals_idx = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidConfigLine;
        const raw_key = std.mem.trim(u8, line[0..equals_idx], " \t");
        const raw_value = std.mem.trim(u8, line[equals_idx + 1 ..], " \t");
        if (raw_key.len == 0 or raw_value.len == 0) return error.InvalidConfigLine;

        try applyEntry(config, raw_key, stripQuotes(raw_value));
    }
}

fn applyEntry(config: *Config, raw_key: []const u8, raw_value: []const u8) !void {
    var key_buf: [64]u8 = undefined;
    var value_buf: [256]u8 = undefined;

    const key = try normalize(&key_buf, raw_key);
    const value = try normalize(&value_buf, raw_value);

    if (std.mem.eql(u8, key, "theme")) {
        config.theme_name = try parseThemeName(value);
        config.theme = themePreset(config.theme_name);
        config.theme_overrides.apply(&config.theme);
        return;
    }

    if (std.mem.eql(u8, key, "default_sort") or std.mem.eql(u8, key, "sort") or std.mem.eql(u8, key, "sort_by")) {
        config.default_sort = try parseSortBy(value);
        return;
    }

    if (std.mem.eql(u8, key, "default_tab") or std.mem.eql(u8, key, "startup_tab") or std.mem.eql(u8, key, "tab")) {
        config.default_tab = try parseTab(value);
        return;
    }

    if (std.mem.eql(u8, key, "update_interval_ms") or std.mem.eql(u8, key, "refresh_interval_ms")) {
        const interval_ms = try std.fmt.parseInt(u32, raw_value, 10);
        if (interval_ms < 100 or interval_ms > 10_000) return error.InvalidUpdateInterval;
        config.update_interval_ms = interval_ms;
        return;
    }

    if (std.mem.eql(u8, key, "nerd_fonts") or std.mem.eql(u8, key, "nerd_font")) {
        config.nerd_fonts = try parseBool(value);
        return;
    }

    if (std.mem.eql(u8, key, "default_tree_view") or
        std.mem.eql(u8, key, "tree_view") or
        std.mem.eql(u8, key, "start_in_tree_view"))
    {
        config.default_tree_view = try parseBool(value);
        return;
    }

    if (std.mem.eql(u8, key, "show_help_on_startup") or
        std.mem.eql(u8, key, "help_on_startup") or
        std.mem.eql(u8, key, "startup_help"))
    {
        config.show_help_on_startup = try parseBool(value);
        return;
    }

    if (std.mem.eql(u8, key, "ignore_launch_cmd_substr") or
        std.mem.eql(u8, key, "ignore_launch_command_substr") or
        std.mem.eql(u8, key, "ignore_process_substr"))
    {
        if (raw_value.len > config.ignore_launch_cmd_substr_buf.len) return error.ConfigValueTooLong;
        @memset(&config.ignore_launch_cmd_substr_buf, 0);
        @memcpy(config.ignore_launch_cmd_substr_buf[0..raw_value.len], raw_value);
        config.ignore_launch_cmd_substr_len = @intCast(raw_value.len);
        return;
    }

    if (std.mem.startsWith(u8, key, "color.")) {
        try setColorOverride(&config.theme_overrides, key["color.".len..], try parseColor(value));
        config.theme_overrides.apply(&config.theme);
        return;
    }

    if (std.mem.startsWith(u8, key, "colors.")) {
        try setColorOverride(&config.theme_overrides, key["colors.".len..], try parseColor(value));
        config.theme_overrides.apply(&config.theme);
        return;
    }

    return error.UnknownConfigKey;
}

fn defaultConfigPath(allocator: std.mem.Allocator) !?[]u8 {
    if (std.process.getEnvVarOwned(allocator, "XDG_CONFIG_HOME")) |xdg_config_home| {
        defer allocator.free(xdg_config_home);
        return try std.fs.path.join(allocator, &.{ xdg_config_home, "ztop.cfg" });
    } else |err| switch (err) {
        error.EnvironmentVariableNotFound => {},
        else => return err,
    }

    if (std.process.getEnvVarOwned(allocator, "HOME")) |home| {
        defer allocator.free(home);
        return try std.fs.path.join(allocator, &.{ home, ".config", "ztop.cfg" });
    } else |err| switch (err) {
        error.EnvironmentVariableNotFound => return null,
        else => return err,
    }
}

fn normalize(buffer: []u8, text: []const u8) ![]const u8 {
    if (text.len > buffer.len) return error.ConfigValueTooLong;

    for (text, 0..) |c, i| {
        buffer[i] = switch (c) {
            'A'...'Z' => std.ascii.toLower(c),
            '-' => '_',
            else => c,
        };
    }

    return buffer[0..text.len];
}

fn stripQuotes(text: []const u8) []const u8 {
    if (text.len >= 2 and ((text[0] == '"' and text[text.len - 1] == '"') or (text[0] == '\'' and text[text.len - 1] == '\''))) {
        return text[1 .. text.len - 1];
    }
    return text;
}

fn parseThemeName(value: []const u8) !ThemeName {
    if (std.mem.eql(u8, value, "default")) return .default;
    if (std.mem.eql(u8, value, "gruvbox") or std.mem.eql(u8, value, "gruvbox_dark")) return .gruvbox;
    if (std.mem.eql(u8, value, "nord")) return .nord;
    if (std.mem.eql(u8, value, "solarized") or std.mem.eql(u8, value, "solarized_dark")) return .solarized;
    if (std.mem.eql(u8, value, "catppuccin") or std.mem.eql(u8, value, "catppuccin_mocha")) return .catppuccin;
    return error.UnknownTheme;
}

fn parseSortBy(value: []const u8) !sysinfo.SortBy {
    if (std.mem.eql(u8, value, "memory")) return .mem;
    if (std.mem.eql(u8, value, "process_name")) return .name;
    return std.meta.stringToEnum(sysinfo.SortBy, value) orelse error.UnknownSort;
}

fn parseTab(value: []const u8) !u8 {
    if (std.mem.eql(u8, value, "1") or std.mem.eql(u8, value, "main")) return 1;
    if (std.mem.eql(u8, value, "2") or std.mem.eql(u8, value, "io") or std.mem.eql(u8, value, "i_o")) return 2;
    if (std.mem.eql(u8, value, "3") or std.mem.eql(u8, value, "sensor") or std.mem.eql(u8, value, "sensors")) return 3;
    if (std.mem.eql(u8, value, "4") or std.mem.eql(u8, value, "network") or std.mem.eql(u8, value, "connections")) return 4;
    return error.UnknownTab;
}

fn parseBool(value: []const u8) !bool {
    if (std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "1") or std.mem.eql(u8, value, "yes")) {
        return true;
    }
    if (std.mem.eql(u8, value, "false") or std.mem.eql(u8, value, "0") or std.mem.eql(u8, value, "no")) {
        return false;
    }
    return error.InvalidBooleanValue;
}

fn parseColor(value: []const u8) !tui.Tui.Color {
    return std.meta.stringToEnum(tui.Tui.Color, value) orelse error.UnknownColor;
}

fn setColorOverride(overrides: *ThemeOverrides, field_name: []const u8, color: tui.Tui.Color) !void {
    inline for (std.meta.fields(ThemeOverrides)) |field| {
        if (std.mem.eql(u8, field_name, field.name)) {
            @field(overrides, field.name) = color;
            return;
        }
    }

    return error.UnknownColorKey;
}
