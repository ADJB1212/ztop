const std = @import("std");
const tui = @import("../tui.zig");
const config = @import("../config.zig");
const history_mod = @import("../history.zig");
const util = @import("util.zig");
const Tui = tui.Tui;
const MetricHistory = history_mod.MetricHistory;
const RateHistory = history_mod.RateHistory;

pub const MetricColorMode = enum {
    cpu,
    memory,
};

const graph_blocks = [_][]const u8{ " ", "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" };

fn metricGraphColor(theme: config.Theme, mode: MetricColorMode, percent: f32) Tui.Color {
    return switch (mode) {
        .cpu => util.usageColor(theme, percent),
        .memory => util.memoryColor(theme, percent),
    };
}

pub fn historyGraphRows(box_height: u16) u16 {
    if (box_height >= 16) return 4;
    if (box_height >= 11) return 3;
    if (box_height >= 8) return 2;
    return 0;
}

pub fn suggestedHistoryGraphRows(box_height: u16, disable_history: bool) u16 {
    if (disable_history) return 0;
    return historyGraphRows(box_height);
}

fn historyGraphLevel(percent: f32, rows: usize) usize {
    if (rows == 0 or percent <= 0) return 0;

    const total_levels = rows * 8;
    const clamped = @max(0.0, @min(percent, 100.0));
    return @max(1, @min(total_levels, @as(usize, @intFromFloat(@ceil((clamped / 100.0) * @as(f32, @floatFromInt(total_levels)))))));
}

fn graphLevels(comptime T: type, values: []const ?T, max_value: T, rows: usize, levels: []u32) void {
    std.debug.assert(values.len == levels.len);
    if (rows == 0 or max_value == 0) {
        @memset(levels, 0);
        return;
    }
    const Floats = @Vector(4, f32);
    const limit: Floats = @splat(if (T == f32) max_value else @floatFromInt(max_value));
    const total: Floats = @splat(@floatFromInt(rows * 8));
    var column: usize = 0;
    while (values.len - column >= 4) : (column += 4) {
        var samples: [4]T = undefined;
        inline for (0..4) |lane| samples[lane] = values[column + lane] orelse 0;
        const input: @Vector(4, T) = samples;
        const floats: Floats = if (T == f32) input else @floatFromInt(input);
        const clamped = @max(@as(Floats, @splat(0)), @min(floats, limit));
        const scaled = @min(total, @max(@as(Floats, @splat(1)), @ceil((clamped / limit) * total)));
        const result: @Vector(4, u32) = @intFromFloat(@select(f32, clamped > @as(Floats, @splat(0)), scaled, @as(Floats, @splat(0))));
        levels[column..][0..4].* = result;
    }
    while (column < values.len) : (column += 1) {
        const value = values[column] orelse 0;
        levels[column] = @intCast(if (T == f32) historyGraphLevel(value, rows) else rateGraphLevel(value, max_value, rows));
    }
}

pub fn historyGraphLevels(values: []const ?f32, rows: u16, levels: []u32) void {
    graphLevels(f32, values, 100, rows, levels);
}

pub fn rateGraphLevels(values: []const ?u64, max_value: u64, rows: u16, levels: []u32) void {
    graphLevels(u64, values, max_value, rows, levels);
}

pub fn renderHistoryGraph(
    app_tui: *Tui,
    theme: config.Theme,
    x: u16,
    y: u16,
    width: u16,
    height: u16,
    history: *const MetricHistory,
    mode: MetricColorMode,
) !void {
    if (width == 0 or height == 0 or history.len() == 0) return;

    const graph_width: usize = width;
    const graph_height: usize = height;
    var column_values: [history_mod.MAX_HISTORY_SAMPLES]?f32 = undefined;
    var column_levels: [history_mod.MAX_HISTORY_SAMPLES]u32 = undefined;
    const cache_columns = graph_width <= column_values.len;
    if (cache_columns) {
        history.valuesForColumns(column_values[0..graph_width]);
        historyGraphLevels(column_values[0..graph_width], height, column_levels[0..graph_width]);
    }

    for (0..graph_height) |row| {
        try app_tui.moveCursor(x, y + @as(u16, @intCast(row)));

        for (0..graph_width) |column| {
            const maybe_value = if (cache_columns)
                column_values[column]
            else
                history.valueForColumn(column, graph_width);
            if (maybe_value) |value| {
                const total_level = if (cache_columns)
                    column_levels[column]
                else
                    historyGraphLevel(value, graph_height);
                const rows_below = graph_height - row - 1;
                const row_base = rows_below * 8;
                const cell_level = if (total_level > row_base)
                    @min(total_level - row_base, 8)
                else
                    0;

                try app_tui.writeStyled(.{ .fg = metricGraphColor(theme, mode, value) }, graph_blocks[cell_level]);
            } else {
                try app_tui.bufWrite(" ");
            }
        }
    }
}

fn rateGraphLevel(value: u64, max_value: u64, rows: usize) usize {
    if (rows == 0 or value == 0 or max_value == 0) return 0;

    const total_levels = rows * 8;
    const normalized = @as(f32, @floatFromInt(@min(value, max_value))) / @as(f32, @floatFromInt(max_value));
    return @max(1, @min(total_levels, @as(usize, @intFromFloat(@ceil(normalized * @as(f32, @floatFromInt(total_levels)))))));
}

pub fn renderRateHistoryGraph(
    app_tui: *Tui,
    theme: config.Theme,
    x: u16,
    y: u16,
    width: u16,
    height: u16,
    history: *const RateHistory,
    color: Tui.Color,
    max_value: u64,
) !void {
    if (width == 0 or height == 0 or history.len() == 0) return;

    const graph_width: usize = width;
    const graph_height: usize = height;
    var column_values: [history_mod.MAX_HISTORY_SAMPLES]?u64 = undefined;
    var column_levels: [history_mod.MAX_HISTORY_SAMPLES]u32 = undefined;
    const cache_columns = graph_width <= column_values.len;
    if (cache_columns) {
        history.valuesForColumns(column_values[0..graph_width]);
        rateGraphLevels(column_values[0..graph_width], max_value, height, column_levels[0..graph_width]);
    }

    for (0..graph_height) |row| {
        try app_tui.moveCursor(x, y + @as(u16, @intCast(row)));

        for (0..graph_width) |column| {
            const maybe_value = if (cache_columns)
                column_values[column]
            else
                history.valueForColumn(column, graph_width);
            if (maybe_value) |value| {
                const total_level = if (cache_columns)
                    column_levels[column]
                else
                    rateGraphLevel(value, max_value, graph_height);
                const rows_below = graph_height - row - 1;
                const row_base = rows_below * 8;
                const cell_level = if (total_level > row_base)
                    @min(total_level - row_base, 8)
                else
                    0;

                if (cell_level > 0) {
                    try app_tui.writeStyled(.{ .fg = color, .bold = value == max_value and max_value > 0 }, graph_blocks[cell_level]);
                } else {
                    try app_tui.writeStyled(.{ .fg = theme.muted, .dim = true }, "·");
                }
            } else {
                try app_tui.writeStyled(.{ .fg = theme.muted, .dim = true }, " ");
            }
        }
    }
}
