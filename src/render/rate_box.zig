const std = @import("std");
const tui = @import("../tui.zig");
const config = @import("../config.zig");
const history_mod = @import("../history.zig");
const util = @import("util.zig");
const graphs = @import("graphs.zig");
const Tui = tui.Tui;
const RateHistory = history_mod.RateHistory;

pub const RateSeries = struct {
    label: []const u8,
    short_label: []const u8,
    rate_bytes_ps: u64,
    total_bytes: ?u64 = null,
    history: *const RateHistory,
    color: Tui.Color,
};

pub const DetailLine = struct {
    text: []const u8,
    style: Tui.Style,
};

fn renderRateMetricRow(
    app_tui: *Tui,
    theme: config.Theme,
    x: u16,
    y: u16,
    width: u16,
    series: RateSeries,
    peak_rate: u64,
) !void {
    if (width == 0) return;

    try app_tui.moveCursor(x, y);

    var used: usize = try util.writeChip(
        app_tui,
        .{ .fg = theme.selection_fg, .bg = series.color, .bold = true },
        series.label,
    );
    if (used >= width) return;

    try app_tui.bufWrite(" ");
    used += 1;

    const rate = util.formatUnit(series.rate_bytes_ps);
    var rate_buf: [32]u8 = undefined;
    const rate_text = std.fmt.bufPrint(&rate_buf, "{d:4.1} {s}/s", .{ rate.value, rate.unit }) catch "0.0 B/s";
    try app_tui.printStyled(.{ .fg = series.color, .bold = true }, "{s}", .{rate_text});
    used += rate_text.len;

    if (series.total_bytes) |total_bytes| {
        const total = util.formatUnit(total_bytes);
        var total_buf: [32]u8 = undefined;
        const total_text = std.fmt.bufPrint(&total_buf, "  Σ {d:4.1} {s}", .{ total.value, total.unit }) catch "";
        if (used + total_text.len + 6 <= width) {
            try app_tui.printStyled(.{ .fg = theme.muted }, "{s}", .{total_text});
            used += total_text.len;
        }
    }

    if (used + 6 > width) return;

    try app_tui.bufWrite(" ");
    used += 1;

    const meter_width: u16 = @intCast(width - used);
    const ratio = if (peak_rate > 0)
        (@as(f32, @floatFromInt(series.rate_bytes_ps)) / @as(f32, @floatFromInt(peak_rate))) * 100.0
    else
        0.0;
    try util.renderMeter(
        app_tui,
        meter_width,
        ratio,
        .{ .fg = series.color, .bold = ratio >= 75 },
        .{ .fg = theme.muted, .dim = true },
    );
}

fn renderRateLane(
    app_tui: *Tui,
    theme: config.Theme,
    x: u16,
    y: u16,
    width: u16,
    height: u16,
    series: RateSeries,
    peak_rate: u64,
) !void {
    if (width == 0 or height == 0) return;

    const label_width: u16 = if (width >= 8) 4 else 0;
    if (label_width > 0) {
        try app_tui.moveCursor(x, y);
        try app_tui.printStyled(.{ .fg = series.color, .bold = true }, "{s}", .{series.short_label});
        for (series.short_label.len..label_width) |_| {
            try app_tui.bufWrite(" ");
        }
    }

    const graph_x = x + label_width;
    const graph_width = width -| label_width;
    if (graph_width == 0) return;
    try graphs.renderRateHistoryGraph(app_tui, theme, graph_x, y, graph_width, height, series.history, series.color, peak_rate);
}

pub fn renderDualRateBox(
    app_tui: *Tui,
    theme: config.Theme,
    box_x: u16,
    box_y: u16,
    box_width: u16,
    box_height: u16,
    title: []const u8,
    title_color: Tui.Color,
    primary: RateSeries,
    secondary: RateSeries,
    detail_lines: []const DetailLine,
    disable_history: bool,
) !void {
    try app_tui.drawBoxStyled(
        box_x,
        box_y,
        box_width,
        box_height,
        title,
        .{ .fg = theme.border },
        .{ .fg = title_color, .bold = true },
    );
    if (box_height < 3 or box_width < 8) return;

    const inner_x = box_x + 2;
    const inner_y = box_y + 1;
    const inner_width = box_width -| 4;
    const inner_height = box_height -| 2;
    if (inner_width == 0 or inner_height == 0) return;

    const peak_rate = @max(
        @max(primary.history.maxSample(), secondary.history.maxSample()),
        @max(primary.rate_bytes_ps, secondary.rate_bytes_ps),
    );

    var content_y = inner_y;
    var content_height = inner_height;

    for (detail_lines) |detail| {
        if (content_height == 0) return;
        try app_tui.moveCursor(inner_x, content_y);
        try util.writeAlignedCell(
            app_tui,
            detail.style,
            inner_width,
            .left,
            util.clipUtf8(detail.text, inner_width),
        );
        content_y += 1;
        content_height -|= 1;
    }

    try renderRateMetricRow(app_tui, theme, inner_x, content_y, inner_width, primary, peak_rate);
    if (content_height == 1) return;

    try renderRateMetricRow(app_tui, theme, inner_x, content_y + 1, inner_width, secondary, peak_rate);

    const graph_rows = if (disable_history) 0 else content_height -| 2;
    if (graph_rows == 0) return;

    if (graph_rows == 1) {
        try app_tui.moveCursor(inner_x, content_y + 2);
        try app_tui.printStyled(.{ .fg = theme.muted }, "Peak scale ", .{});
        var peak_buf: [24]u8 = undefined;
        const peak_text = if (peak_rate > 0) blk: {
            const peak = util.formatUnit(peak_rate);
            break :blk std.fmt.bufPrint(&peak_buf, "{d:4.1} {s}/s", .{ peak.value, peak.unit }) catch "0.0 B/s";
        } else "0.0 B/s";
        try app_tui.printStyled(.{ .fg = title_color, .bold = true }, "{s}", .{peak_text});
        return;
    }

    const primary_height = (graph_rows + 1) / 2;
    const secondary_height = graph_rows / 2;
    try renderRateLane(app_tui, theme, inner_x, content_y + 2, inner_width, @intCast(primary_height), primary, peak_rate);
    if (secondary_height > 0) {
        try renderRateLane(
            app_tui,
            theme,
            inner_x,
            content_y + 2 + @as(u16, @intCast(primary_height)),
            inner_width,
            @intCast(secondary_height),
            secondary,
            peak_rate,
        );
    }
}
