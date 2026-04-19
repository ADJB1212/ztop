const std = @import("std");
const sysinfo = @import("sysinfo.zig");
const tui = @import("tui.zig");

pub const ThemeName = enum {
    default,
    default_dark,
    default_light,
    gruvbox,
    nord,
    solarized,
    catppuccin,
    palenight,

    pub fn label(self: ThemeName) []const u8 {
        return switch (self) {
            .default => "Default",
            .default_dark => "Default Dark",
            .default_light => "Default Light",
            .gruvbox => "Gruvbox",
            .nord => "Nord",
            .solarized => "Solarized",
            .catppuccin => "Catppuccin",
            .palenight => "Palenight",
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

pub const ProcessColumn = enum(u8) {
    pid,
    ppid,
    state,
    cpu,
    mem,
    threads,
    disk_read,
    disk_write,

    pub fn label(self: ProcessColumn) []const u8 {
        return switch (self) {
            .pid => "PID",
            .ppid => "PPID",
            .state => "State",
            .cpu => "CPU%",
            .mem => "MEM%",
            .threads => "Threads",
            .disk_read => "Disk Read",
            .disk_write => "Disk Write",
        };
    }
};

pub const process_column_order = [_]ProcessColumn{
    .pid,
    .ppid,
    .state,
    .cpu,
    .mem,
    .threads,
    .disk_read,
    .disk_write,
};

pub const ProcessColumns = struct {
    pid: bool = false,
    ppid: bool = false,
    state: bool = false,
    cpu: bool = false,
    mem: bool = false,
    threads: bool = false,
    disk_read: bool = false,
    disk_write: bool = false,

    pub fn defaultsMain() ProcessColumns {
        return .{
            .pid = true,
            .cpu = true,
            .mem = true,
            .threads = true,
        };
    }

    pub fn defaultsIo() ProcessColumns {
        return .{
            .pid = true,
            .disk_read = true,
            .disk_write = true,
        };
    }

    pub fn all() ProcessColumns {
        return .{
            .pid = true,
            .ppid = true,
            .state = true,
            .cpu = true,
            .mem = true,
            .threads = true,
            .disk_read = true,
            .disk_write = true,
        };
    }

    pub fn none() ProcessColumns {
        return .{};
    }

    pub fn isVisible(self: ProcessColumns, column: ProcessColumn) bool {
        return switch (column) {
            .pid => self.pid,
            .ppid => self.ppid,
            .state => self.state,
            .cpu => self.cpu,
            .mem => self.mem,
            .threads => self.threads,
            .disk_read => self.disk_read,
            .disk_write => self.disk_write,
        };
    }

    pub fn setVisible(self: *ProcessColumns, column: ProcessColumn, visible: bool) void {
        switch (column) {
            .pid => self.pid = visible,
            .ppid => self.ppid = visible,
            .state => self.state = visible,
            .cpu => self.cpu = visible,
            .mem => self.mem = visible,
            .threads => self.threads = visible,
            .disk_read => self.disk_read = visible,
            .disk_write => self.disk_write = visible,
        }
    }

    pub fn toggle(self: *ProcessColumns, column: ProcessColumn) bool {
        const next = !self.isVisible(column);
        self.setVisible(column, next);
        return next;
    }

    pub fn countVisible(self: ProcessColumns) usize {
        var count: usize = 0;
        for (process_column_order) |column| {
            if (self.isVisible(column)) count += 1;
        }
        return count;
    }

    pub fn visibleOrdered(self: ProcessColumns, out: *[process_column_order.len]ProcessColumn) []const ProcessColumn {
        var count: usize = 0;
        for (process_column_order) |column| {
            if (!self.isVisible(column)) continue;
            out[count] = column;
            count += 1;
        }
        return out[0..count];
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
    tab_interval_ms: [4]?u32,
    process_columns: ProcessColumns,
    io_process_columns: ProcessColumns,
    ignore_launch_cmd_substr_buf: [256]u8,
    ignore_launch_cmd_substr_len: u16,
    nerd_fonts: bool,
    disable_history: bool,

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
            .tab_interval_ms = .{ null, null, null, null },
            .process_columns = ProcessColumns.defaultsMain(),
            .io_process_columns = ProcessColumns.defaultsIo(),
            .ignore_launch_cmd_substr_buf = std.mem.zeroes([256]u8),
            .ignore_launch_cmd_substr_len = 0,
            .nerd_fonts = false,
            .disable_history = false,
        };
    }

    pub fn effectiveIntervalMs(self: *const Config, tab: u8) u32 {
        if (tab >= 1 and tab <= 4) {
            if (self.tab_interval_ms[tab - 1]) |ms| return ms;
        }
        return self.update_interval_ms;
    }

    pub fn ignoredLaunchCommandSubstr(self: *const Config) []const u8 {
        return self.ignore_launch_cmd_substr_buf[0..self.ignore_launch_cmd_substr_len];
    }
};

pub fn load(allocator: std.mem.Allocator, io: std.Io, environ_map: *const std.process.Environ.Map) Config {
    var config = Config.defaults();
    const config_path = defaultConfigPath(allocator, environ_map) catch return config;
    defer if (config_path) |path| allocator.free(path);

    const path = config_path orelse return config;
    parseFile(io, allocator, path, &config) catch |err| switch (err) {
        error.FileNotFound => {},
        else => {
            std.debug.print("ztop: warning: failed to read config file {s}: {s}\n", .{ path, @errorName(err) });
        },
    };
    return config;
}

pub fn loadPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) Config {
    var config = Config.defaults();
    parseFile(io, allocator, path, &config) catch |err| {
        std.debug.print("ztop: warning: failed to read config file {s}: {s}\n", .{ path, @errorName(err) });
    };
    return config;
}

pub fn parse(text: []const u8) Config {
    var config = Config.defaults();
    parseInto(null, text, &config, null);
    return config;
}

pub fn parseWithErrors(allocator: std.mem.Allocator, text: []const u8, errors: *std.ArrayList(DiagnosticError)) Config {
    var config = Config.defaults();
    parseInto(allocator, text, &config, errors);
    return config;
}

pub fn themePreset(name: ThemeName) Theme {
    const c = tui.Tui.Color.index;

    return switch (name) {
        .default => themePreset(.default_dark),
        .default_dark => .{
            .brand = c(81),
            .text = c(253),
            .muted = c(245),
            .border = c(240),
            .tab_active = c(81),
            .cpu_title = c(81),
            .memory_title = c(186),
            .disk_title = c(74),
            .network_title = c(116),
            .sensor_title = c(167),
            .battery_title = c(114),
            .process_title = c(176),
            .selection_bg = c(238),
            .selection_fg = c(255),
            .usage_idle = c(81),
            .usage_good = c(114),
            .usage_warn = c(180),
            .usage_critical = c(167),
            .memory_low = c(110),
            .memory_mid = c(176),
            .memory_warn = c(180),
            .memory_critical = c(167),
            .io_rate = c(254),
            .filter_prompt = c(186),
            .command_prompt = c(114),
        },
        .default_light => .{
            .brand = c(25),
            .text = c(236),
            .muted = c(245),
            .border = c(244),
            .tab_active = c(25),
            .cpu_title = c(25),
            .memory_title = c(136),
            .disk_title = c(31),
            .network_title = c(31),
            .sensor_title = c(124),
            .battery_title = c(28),
            .process_title = c(90),
            .selection_bg = c(153),
            .selection_fg = c(235),
            .usage_idle = c(31),
            .usage_good = c(28),
            .usage_warn = c(136),
            .usage_critical = c(124),
            .memory_low = c(25),
            .memory_mid = c(97),
            .memory_warn = c(136),
            .memory_critical = c(124),
            .io_rate = c(238),
            .filter_prompt = c(136),
            .command_prompt = c(28),
        },
        .gruvbox => .{
            .brand = c(214),
            .text = c(223),
            .muted = c(242),
            .border = c(239),
            .tab_active = c(214),
            .cpu_title = c(214),
            .memory_title = c(142),
            .disk_title = c(208),
            .network_title = c(108),
            .sensor_title = c(203),
            .battery_title = c(142),
            .process_title = c(174),
            .selection_bg = c(237),
            .selection_fg = c(223),
            .usage_idle = c(66),
            .usage_good = c(142),
            .usage_warn = c(214),
            .usage_critical = c(203),
            .memory_low = c(66),
            .memory_mid = c(174),
            .memory_warn = c(214),
            .memory_critical = c(203),
            .io_rate = c(187),
            .filter_prompt = c(214),
            .command_prompt = c(142),
        },
        .nord => .{
            .brand = c(110),
            .text = c(255),
            .muted = c(240),
            .border = c(67),
            .tab_active = c(110),
            .cpu_title = c(110),
            .memory_title = c(67),
            .disk_title = c(109),
            .network_title = c(67),
            .sensor_title = c(139),
            .battery_title = c(144),
            .process_title = c(254),
            .selection_bg = c(238),
            .selection_fg = c(255),
            .usage_idle = c(109),
            .usage_good = c(144),
            .usage_warn = c(186),
            .usage_critical = c(131),
            .memory_low = c(67),
            .memory_mid = c(109),
            .memory_warn = c(186),
            .memory_critical = c(131),
            .io_rate = c(254),
            .filter_prompt = c(67),
            .command_prompt = c(110),
        },
        .solarized => .{
            .brand = c(136),
            .text = c(245),
            .muted = c(242),
            .border = c(36),
            .tab_active = c(136),
            .cpu_title = c(32),
            .memory_title = c(36),
            .disk_title = c(32),
            .network_title = c(36),
            .sensor_title = c(166),
            .battery_title = c(100),
            .process_title = c(136),
            .selection_bg = c(235),
            .selection_fg = c(254),
            .usage_idle = c(36),
            .usage_good = c(100),
            .usage_warn = c(136),
            .usage_critical = c(166),
            .memory_low = c(32),
            .memory_mid = c(36),
            .memory_warn = c(136),
            .memory_critical = c(166),
            .io_rate = c(247),
            .filter_prompt = c(136),
            .command_prompt = c(100),
        },
        .catppuccin => .{
            .brand = c(183),
            .text = c(189),
            .muted = c(243),
            .border = c(147),
            .tab_active = c(183),
            .cpu_title = c(117),
            .memory_title = c(111),
            .disk_title = c(117),
            .network_title = c(151),
            .sensor_title = c(211),
            .battery_title = c(151),
            .process_title = c(183),
            .selection_bg = c(239),
            .selection_fg = c(189),
            .usage_idle = c(111),
            .usage_good = c(151),
            .usage_warn = c(223),
            .usage_critical = c(211),
            .memory_low = c(147),
            .memory_mid = c(183),
            .memory_warn = c(223),
            .memory_critical = c(211),
            .io_rate = c(189),
            .filter_prompt = c(183),
            .command_prompt = c(151),
        },
        .palenight => .{
            .brand = c(141),
            .text = c(252),
            .muted = c(240),
            .border = c(237),
            .tab_active = c(141),
            .cpu_title = c(74),
            .memory_title = c(108),
            .disk_title = c(180),
            .network_title = c(80),
            .sensor_title = c(167),
            .battery_title = c(108),
            .process_title = c(168),
            .selection_bg = c(235),
            .selection_fg = c(255),
            .usage_idle = c(74),
            .usage_good = c(108),
            .usage_warn = c(180),
            .usage_critical = c(167),
            .memory_low = c(110),
            .memory_mid = c(146),
            .memory_warn = c(186),
            .memory_critical = c(168),
            .io_rate = c(116),
            .filter_prompt = c(186),
            .command_prompt = c(80),
        },
    };
}

pub const DiagnosticError = struct {
    line: usize,
    err: anyerror,
};

fn parseFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8, config: *Config) !void {
    const contents = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024));
    defer allocator.free(contents);
    parseInto(null, contents, config, null);
}

fn parseInto(allocator: ?std.mem.Allocator, text: []const u8, config: *Config, errors: ?*std.ArrayList(DiagnosticError)) void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var line_num: usize = 1;
    while (lines.next()) |raw_line| : (line_num += 1) {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '#' or line[0] == ';') continue;

        const equals_idx = std.mem.indexOfScalar(u8, line, '=') orelse {
            if (errors) |errs| {
                if (allocator) |alloc| errs.append(alloc, .{ .line = line_num, .err = error.MissingEquals }) catch {};
            } else {
                std.debug.print("ztop: warning: invalid config at line {d}: missing '='\n", .{line_num});
            }
            continue;
        };
        const raw_key = std.mem.trim(u8, line[0..equals_idx], " \t");
        const raw_value = std.mem.trim(u8, line[equals_idx + 1 ..], " \t");
        if (raw_key.len == 0 or raw_value.len == 0) {
            if (errors) |errs| {
                if (allocator) |alloc| errs.append(alloc, .{ .line = line_num, .err = error.MissingKeyOrValue }) catch {};
            } else {
                std.debug.print("ztop: warning: invalid config at line {d}: missing key or value\n", .{line_num});
            }
            continue;
        }

        applyEntry(config, raw_key, stripQuotes(raw_value)) catch |err| {
            if (errors) |errs| {
                if (allocator) |alloc| errs.append(alloc, .{ .line = line_num, .err = err }) catch {};
            } else {
                std.debug.print("ztop: warning: failed to parse config at line {d}: {s}\n", .{ line_num, @errorName(err) });
            }
        };
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

    if (std.mem.eql(u8, key, "tab1_interval_ms") or std.mem.eql(u8, key, "main_interval_ms")) {
        const ms = try std.fmt.parseInt(u32, raw_value, 10);
        if (ms < 100 or ms > 10_000) return error.InvalidUpdateInterval;
        config.tab_interval_ms[0] = ms;
        return;
    }

    if (std.mem.eql(u8, key, "tab2_interval_ms") or std.mem.eql(u8, key, "io_interval_ms")) {
        const ms = try std.fmt.parseInt(u32, raw_value, 10);
        if (ms < 100 or ms > 10_000) return error.InvalidUpdateInterval;
        config.tab_interval_ms[1] = ms;
        return;
    }

    if (std.mem.eql(u8, key, "tab3_interval_ms") or std.mem.eql(u8, key, "sensors_interval_ms")) {
        const ms = try std.fmt.parseInt(u32, raw_value, 10);
        if (ms < 100 or ms > 10_000) return error.InvalidUpdateInterval;
        config.tab_interval_ms[2] = ms;
        return;
    }

    if (std.mem.eql(u8, key, "tab4_interval_ms") or std.mem.eql(u8, key, "network_interval_ms")) {
        const ms = try std.fmt.parseInt(u32, raw_value, 10);
        if (ms < 100 or ms > 10_000) return error.InvalidUpdateInterval;
        config.tab_interval_ms[3] = ms;
        return;
    }

    if (std.mem.eql(u8, key, "nerd_fonts") or std.mem.eql(u8, key, "nerd_font")) {
        config.nerd_fonts = try parseBool(value);
        return;
    }

    if (std.mem.eql(u8, key, "disable_history")) {
        config.disable_history = try parseBool(value);
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

    if (std.mem.eql(u8, key, "process_columns") or
        std.mem.eql(u8, key, "main_process_columns") or
        std.mem.eql(u8, key, "process_table_columns"))
    {
        config.process_columns = try parseProcessColumns(value, ProcessColumns.defaultsMain());
        return;
    }

    if (std.mem.eql(u8, key, "io_process_columns") or
        std.mem.eql(u8, key, "process_io_columns") or
        std.mem.eql(u8, key, "io_table_columns"))
    {
        config.io_process_columns = try parseProcessColumns(value, ProcessColumns.defaultsIo());
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

fn defaultConfigPath(allocator: std.mem.Allocator, environ_map: *const std.process.Environ.Map) !?[]u8 {
    if (environ_map.get("XDG_CONFIG_HOME")) |xdg_config_home| {
        return try std.fs.path.join(allocator, &.{ xdg_config_home, "ztop.cfg" });
    }

    if (environ_map.get("HOME")) |home| {
        return try std.fs.path.join(allocator, &.{ home, ".config", "ztop.cfg" });
    }

    return null;
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
    if (std.mem.eql(u8, value, "default_dark")) return .default_dark;
    if (std.mem.eql(u8, value, "default_light")) return .default_light;
    if (std.mem.eql(u8, value, "gruvbox") or std.mem.eql(u8, value, "gruvbox_dark")) return .gruvbox;
    if (std.mem.eql(u8, value, "nord")) return .nord;
    if (std.mem.eql(u8, value, "solarized") or std.mem.eql(u8, value, "solarized_dark")) return .solarized;
    if (std.mem.eql(u8, value, "catppuccin") or std.mem.eql(u8, value, "catppuccin_mocha")) return .catppuccin;
    if (std.mem.eql(u8, value, "palenight") or std.mem.eql(u8, value, "pale_night")) return .palenight;
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

fn parseProcessColumns(value: []const u8, defaults: ProcessColumns) !ProcessColumns {
    if (std.mem.eql(u8, value, "default")) return defaults;
    if (std.mem.eql(u8, value, "all")) return ProcessColumns.all();
    if (std.mem.eql(u8, value, "none")) return ProcessColumns.none();

    var columns = ProcessColumns.none();
    var parts = std.mem.splitScalar(u8, value, ',');
    while (parts.next()) |part_raw| {
        const part = std.mem.trim(u8, part_raw, " \t");
        if (part.len == 0) continue;
        if (std.mem.eql(u8, part, "name")) continue;

        if (std.mem.eql(u8, part, "disk_io") or std.mem.eql(u8, part, "io")) {
            columns.disk_read = true;
            columns.disk_write = true;
            continue;
        }

        columns.setVisible(try parseProcessColumn(part), true);
    }

    return columns;
}

fn parseProcessColumn(value: []const u8) !ProcessColumn {
    if (std.mem.eql(u8, value, "parent_pid")) return .ppid;
    if (std.mem.eql(u8, value, "status")) return .state;
    if (std.mem.eql(u8, value, "cpu_percent")) return .cpu;
    if (std.mem.eql(u8, value, "memory") or std.mem.eql(u8, value, "memory_percent") or std.mem.eql(u8, value, "mem_percent")) return .mem;
    if (std.mem.eql(u8, value, "thread")) return .threads;
    if (std.mem.eql(u8, value, "read")) return .disk_read;
    if (std.mem.eql(u8, value, "write")) return .disk_write;
    return std.meta.stringToEnum(ProcessColumn, value) orelse error.UnknownProcessColumn;
}

fn parseColor(value: []const u8) !tui.Tui.Color {
    if (std.fmt.parseInt(u8, value, 10)) |index| {
        return tui.Tui.Color.index(index);
    } else |err| switch (err) {
        error.InvalidCharacter => {},
        error.Overflow => return error.UnknownColor,
    }

    if (std.mem.eql(u8, value, "black")) return .black;
    if (std.mem.eql(u8, value, "red")) return .red;
    if (std.mem.eql(u8, value, "green")) return .green;
    if (std.mem.eql(u8, value, "yellow")) return .yellow;
    if (std.mem.eql(u8, value, "blue")) return .blue;
    if (std.mem.eql(u8, value, "magenta")) return .magenta;
    if (std.mem.eql(u8, value, "cyan")) return .cyan;
    if (std.mem.eql(u8, value, "white")) return .white;
    if (std.mem.eql(u8, value, "bright_black")) return .bright_black;
    if (std.mem.eql(u8, value, "bright_red")) return .bright_red;
    if (std.mem.eql(u8, value, "bright_green")) return .bright_green;
    if (std.mem.eql(u8, value, "bright_yellow")) return .bright_yellow;
    if (std.mem.eql(u8, value, "bright_blue")) return .bright_blue;
    if (std.mem.eql(u8, value, "bright_magenta")) return .bright_magenta;
    if (std.mem.eql(u8, value, "bright_cyan")) return .bright_cyan;
    if (std.mem.eql(u8, value, "bright_white")) return .bright_white;
    return error.UnknownColor;
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
