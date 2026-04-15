const std = @import("std");
const ztop = @import("ztop");
const Tui = ztop.tui.Tui;
const SysInfo = ztop.sysinfo.SysInfo;
const CpuTopology = ztop.sysinfo.CpuTopology;
const CpuEfficiencyClass = ztop.sysinfo.CpuEfficiencyClass;
const MetricHistory = ztop.history.MetricHistory;
const RateHistory = ztop.history.RateHistory;

pub fn usageColor(theme: ztop.config.Theme, percent: f32) Tui.Color {
    if (percent >= 90) return theme.usage_critical;
    if (percent >= 70) return theme.usage_warn;
    if (percent >= 40) return theme.usage_good;
    return theme.usage_idle;
}

pub const UnitValue = struct {
    value: f32,
    unit: []const u8,
};

pub fn formatUnit(bytes: u64) UnitValue {
    const fbytes = @as(f32, @floatFromInt(bytes));
    if (bytes >= (1 << 30)) {
        return .{ .value = fbytes / @as(f32, 1 << 30), .unit = "GB" };
    } else if (bytes >= (1 << 20)) {
        return .{ .value = fbytes / @as(f32, 1 << 20), .unit = "MB" };
    } else if (bytes >= (1 << 10)) {
        return .{ .value = fbytes / @as(f32, 1 << 10), .unit = "KB" };
    } else {
        return .{ .value = fbytes, .unit = "B" };
    }
}

pub fn memoryColor(theme: ztop.config.Theme, percent: f32) Tui.Color {
    if (percent >= 80) return theme.memory_critical;
    if (percent >= 60) return theme.memory_warn;
    if (percent >= 35) return theme.memory_mid;
    return theme.memory_low;
}

pub const MetricColorMode = enum {
    cpu,
    memory,
};

const graph_blocks = [_][]const u8{ " ", "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" };
const meter_blocks = [_][]const u8{ " ", "▏", "▎", "▍", "▌", "▋", "▊", "▉", "█" };

pub const RateSeries = struct {
    label: []const u8,
    short_label: []const u8,
    rate_bytes_ps: u64,
    total_bytes: ?u64 = null,
    history: *const RateHistory,
    color: Tui.Color,
};

fn metricGraphColor(theme: ztop.config.Theme, mode: MetricColorMode, percent: f32) Tui.Color {
    return switch (mode) {
        .cpu => usageColor(theme, percent),
        .memory => memoryColor(theme, percent),
    };
}

fn historyGraphRows(box_height: u16) u16 {
    if (box_height >= 16) return 4;
    if (box_height >= 11) return 3;
    if (box_height >= 8) return 2;
    return 0;
}

pub fn suggestedHistoryGraphRows(box_height: u16) u16 {
    return historyGraphRows(box_height);
}

fn historyGraphLevel(percent: f32, rows: usize) usize {
    if (rows == 0 or percent <= 0) return 0;

    const total_levels = rows * 8;
    const clamped = @max(0.0, @min(percent, 100.0));
    return @max(1, @min(total_levels, @as(usize, @intFromFloat(@ceil((clamped / 100.0) * @as(f32, @floatFromInt(total_levels)))))));
}

pub fn renderHistoryGraph(
    app_tui: *Tui,
    theme: ztop.config.Theme,
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

    for (0..graph_height) |row| {
        try app_tui.moveCursor(x, y + @as(u16, @intCast(row)));

        for (0..graph_width) |column| {
            if (history.valueForColumn(column, graph_width)) |value| {
                const total_level = historyGraphLevel(value, graph_height);
                const rows_below = graph_height - row - 1;
                const row_base = rows_below * 8;
                const cell_level = if (total_level > row_base)
                    @min(total_level - row_base, 8)
                else
                    0;

                try app_tui.writeStyled(.{ .fg = metricGraphColor(theme, mode, value) }, graph_blocks[cell_level]);
            } else {
                try app_tui.out.writeStreamingAll(app_tui.io, " ");
            }
        }
    }
}

fn renderMeter(
    app_tui: *Tui,
    width: u16,
    percent: f32,
    fill_style: Tui.Style,
    empty_style: Tui.Style,
) !void {
    if (width == 0) return;

    const clamped = @max(0.0, @min(percent, 100.0));
    const total_eighths = @as(usize, width) * 8;
    const filled_eighths = @min(
        total_eighths,
        @as(usize, @intFromFloat(@round((clamped / 100.0) * @as(f32, @floatFromInt(total_eighths))))),
    );
    const full_blocks = filled_eighths / 8;
    const partial_block = filled_eighths % 8;

    for (0..width) |idx| {
        if (idx < full_blocks) {
            try app_tui.writeStyled(fill_style, meter_blocks[8]);
        } else if (idx == full_blocks and partial_block > 0) {
            try app_tui.writeStyled(fill_style, meter_blocks[partial_block]);
        } else {
            try app_tui.writeStyled(empty_style, "░");
        }
    }
}

fn rateGraphLevel(value: u64, max_value: u64, rows: usize) usize {
    if (rows == 0 or value == 0 or max_value == 0) return 0;

    const total_levels = rows * 8;
    const normalized = @as(f32, @floatFromInt(value)) / @as(f32, @floatFromInt(max_value));
    return @max(1, @min(total_levels, @as(usize, @intFromFloat(@ceil(normalized * @as(f32, @floatFromInt(total_levels)))))));
}

fn renderRateHistoryGraph(
    app_tui: *Tui,
    theme: ztop.config.Theme,
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

    for (0..graph_height) |row| {
        try app_tui.moveCursor(x, y + @as(u16, @intCast(row)));

        for (0..graph_width) |column| {
            if (history.valueForColumn(column, graph_width)) |value| {
                const total_level = rateGraphLevel(value, max_value, graph_height);
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

fn writeChip(app_tui: *Tui, style: Tui.Style, label: []const u8) !usize {
    try app_tui.printStyled(style, " {s} ", .{label});
    return label.len + 2;
}

fn renderRateMetricRow(
    app_tui: *Tui,
    theme: ztop.config.Theme,
    x: u16,
    y: u16,
    width: u16,
    series: RateSeries,
    peak_rate: u64,
) !void {
    if (width == 0) return;

    try app_tui.moveCursor(x, y);

    var used: usize = try writeChip(
        app_tui,
        .{ .fg = theme.selection_fg, .bg = series.color, .bold = true },
        series.label,
    );
    if (used >= width) return;

    try app_tui.out.writeStreamingAll(app_tui.io, " ");
    used += 1;

    const rate = formatUnit(series.rate_bytes_ps);
    var rate_buf: [32]u8 = undefined;
    const rate_text = std.fmt.bufPrint(&rate_buf, "{d:4.1} {s}/s", .{ rate.value, rate.unit }) catch "0.0 B/s";
    try app_tui.printStyled(.{ .fg = series.color, .bold = true }, "{s}", .{rate_text});
    used += rate_text.len;

    if (series.total_bytes) |total_bytes| {
        const total = formatUnit(total_bytes);
        var total_buf: [32]u8 = undefined;
        const total_text = std.fmt.bufPrint(&total_buf, "  Σ {d:4.1} {s}", .{ total.value, total.unit }) catch "";
        if (used + total_text.len + 6 <= width) {
            try app_tui.printStyled(.{ .fg = theme.muted }, "{s}", .{total_text});
            used += total_text.len;
        }
    }

    if (used + 6 > width) return;

    try app_tui.out.writeStreamingAll(app_tui.io, " ");
    used += 1;

    const meter_width: u16 = @intCast(width - used);
    const ratio = if (peak_rate > 0)
        (@as(f32, @floatFromInt(series.rate_bytes_ps)) / @as(f32, @floatFromInt(peak_rate))) * 100.0
    else
        0.0;
    try renderMeter(
        app_tui,
        meter_width,
        ratio,
        .{ .fg = series.color, .bold = ratio >= 75 },
        .{ .fg = theme.muted, .dim = true },
    );
}

fn renderRateLane(
    app_tui: *Tui,
    theme: ztop.config.Theme,
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
            try app_tui.out.writeStreamingAll(app_tui.io, " ");
        }
    }

    const graph_x = x + label_width;
    const graph_width = width -| label_width;
    if (graph_width == 0) return;
    try renderRateHistoryGraph(app_tui, theme, graph_x, y, graph_width, height, series.history, series.color, peak_rate);
}

pub fn renderDualRateBox(
    app_tui: *Tui,
    theme: ztop.config.Theme,
    box_x: u16,
    box_y: u16,
    box_width: u16,
    box_height: u16,
    title: []const u8,
    title_color: Tui.Color,
    primary: RateSeries,
    secondary: RateSeries,
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

    try renderRateMetricRow(app_tui, theme, inner_x, inner_y, inner_width, primary, peak_rate);
    if (inner_height == 1) return;

    try renderRateMetricRow(app_tui, theme, inner_x, inner_y + 1, inner_width, secondary, peak_rate);

    const graph_rows = inner_height -| 2;
    if (graph_rows == 0) return;

    if (graph_rows == 1) {
        try app_tui.moveCursor(inner_x, inner_y + 2);
        try app_tui.printStyled(.{ .fg = theme.muted }, "Peak scale ", .{});
        var peak_buf: [24]u8 = undefined;
        const peak_text = if (peak_rate > 0) blk: {
            const peak = formatUnit(peak_rate);
            break :blk std.fmt.bufPrint(&peak_buf, "{d:4.1} {s}/s", .{ peak.value, peak.unit }) catch "0.0 B/s";
        } else "0.0 B/s";
        try app_tui.printStyled(.{ .fg = title_color, .bold = true }, "{s}", .{peak_text});
        return;
    }

    const primary_height = (graph_rows + 1) / 2;
    const secondary_height = graph_rows / 2;
    try renderRateLane(app_tui, theme, inner_x, inner_y + 2, inner_width, @intCast(primary_height), primary, peak_rate);
    if (secondary_height > 0) {
        try renderRateLane(
            app_tui,
            theme,
            inner_x,
            inner_y + 2 + @as(u16, @intCast(primary_height)),
            inner_width,
            @intCast(secondary_height),
            secondary,
            peak_rate,
        );
    }
}

const TopologyPhysicalRow = struct {
    physical_id: u16,
    package_id: u16,
    numa_node_id: i16,
    shared_cache_group_id: i16,
    shared_cache_level: u8,
    efficiency_class: CpuEfficiencyClass,
};

const TopologyLine = union(enum) {
    header: TopologyPhysicalRow,
    row: TopologyPhysicalRow,
};

fn efficiencySortKey(class: CpuEfficiencyClass) u8 {
    return switch (class) {
        .performance => 0,
        .balanced => 1,
        .efficiency => 2,
        .unknown => 3,
    };
}

fn sameTopologySection(a: TopologyPhysicalRow, b: TopologyPhysicalRow) bool {
    return a.package_id == b.package_id and
        a.numa_node_id == b.numa_node_id and
        a.shared_cache_group_id == b.shared_cache_group_id and
        a.shared_cache_level == b.shared_cache_level and
        a.efficiency_class == b.efficiency_class;
}

fn collectTopologyRows(topology: CpuTopology, rows: *[ztop.sysinfo.common.MAX_CORES]TopologyPhysicalRow) usize {
    var row_count: usize = 0;

    for (topology.logical_cores) |logical_core| {
        var exists = false;
        for (rows[0..row_count]) |row| {
            if (row.physical_id == logical_core.physical_id) {
                exists = true;
                break;
            }
        }
        if (exists or row_count >= rows.len) continue;

        rows[row_count] = .{
            .physical_id = logical_core.physical_id,
            .package_id = logical_core.package_id,
            .numa_node_id = logical_core.numa_node_id,
            .shared_cache_group_id = logical_core.shared_cache_group_id,
            .shared_cache_level = logical_core.shared_cache_level,
            .efficiency_class = logical_core.efficiency_class,
        };
        row_count += 1;
    }

    std.mem.sort(TopologyPhysicalRow, rows[0..row_count], {}, struct {
        fn lessThan(_: void, a: TopologyPhysicalRow, b: TopologyPhysicalRow) bool {
            const a_numa = if (a.numa_node_id >= 0) a.numa_node_id else std.math.maxInt(i16);
            const b_numa = if (b.numa_node_id >= 0) b.numa_node_id else std.math.maxInt(i16);
            if (a_numa != b_numa) return a_numa < b_numa;
            if (a.package_id != b.package_id) return a.package_id < b.package_id;
            const a_eff = efficiencySortKey(a.efficiency_class);
            const b_eff = efficiencySortKey(b.efficiency_class);
            if (a_eff != b_eff) return a_eff < b_eff;
            if (a.shared_cache_level != b.shared_cache_level) return a.shared_cache_level < b.shared_cache_level;
            if (a.shared_cache_group_id != b.shared_cache_group_id) return a.shared_cache_group_id < b.shared_cache_group_id;
            return a.physical_id < b.physical_id;
        }
    }.lessThan);

    return row_count;
}

fn buildTopologyHeaderText(buf: []u8, row: TopologyPhysicalRow, topology: CpuTopology) []const u8 {
    var writer: std.Io.Writer = .fixed(buf);
    var wrote_any = false;

    if (topology.has_numa and row.numa_node_id >= 0) {
        writer.print("N{d}", .{row.numa_node_id}) catch {};
        wrote_any = true;
    }
    if (topology.package_count > 1) {
        if (wrote_any) writer.writeAll(" ") catch {};
        writer.print("Pkg{d}", .{row.package_id}) catch {};
        wrote_any = true;
    }
    if (topology.has_efficiency_classes and row.efficiency_class != .unknown) {
        if (wrote_any) writer.writeAll(" ") catch {};
        writer.writeAll(switch (row.efficiency_class) {
            .performance => "Perf",
            .efficiency => "Eff",
            .balanced => "Bal",
            .unknown => "?",
        }) catch {};
        wrote_any = true;
    }
    if (topology.has_cache_groups and row.shared_cache_group_id >= 0 and row.shared_cache_level > 0) {
        if (wrote_any) writer.writeAll(" ") catch {};
        writer.print("L{d}#{d}", .{ row.shared_cache_level, row.shared_cache_group_id }) catch {};
        wrote_any = true;
    }
    if (!wrote_any) {
        writer.writeAll("Topology") catch {};
    }

    return writer.buffered();
}

fn logicalCoreUsage(cpu: ztop.sysinfo.CpuStats, logical_id: u16) f32 {
    return if (@as(usize, logical_id) < cpu.per_core_usage.len)
        cpu.per_core_usage[logical_id]
    else
        0.0;
}

fn averageCoreUsage(cpu: ztop.sysinfo.CpuStats, topology: CpuTopology, physical_id: u16) f32 {
    var sum: f32 = 0.0;
    var count: usize = 0;

    for (topology.logical_cores) |logical_core| {
        if (logical_core.physical_id != physical_id) continue;
        sum += logicalCoreUsage(cpu, logical_core.logical_id);
        count += 1;
    }

    if (count == 0) return 0.0;
    return sum / @as(f32, @floatFromInt(count));
}

fn efficiencyLabel(class: CpuEfficiencyClass) []const u8 {
    return switch (class) {
        .performance => "P",
        .efficiency => "E",
        .balanced => "B",
        .unknown => "?",
    };
}

fn efficiencyAccentColor(theme: ztop.config.Theme, class: CpuEfficiencyClass) Tui.Color {
    return switch (class) {
        .performance => theme.cpu_title,
        .efficiency => theme.memory_low,
        .balanced => theme.memory_mid,
        .unknown => theme.muted,
    };
}

fn collectLogicalIndicesForPhysical(
    topology: CpuTopology,
    physical_id: u16,
    out: *[ztop.sysinfo.common.MAX_CORES]usize,
) []usize {
    var count: usize = 0;
    for (topology.logical_cores, 0..) |logical_core, idx| {
        if (logical_core.physical_id != physical_id or count >= out.len) continue;
        out[count] = idx;
        count += 1;
    }

    std.mem.sort(usize, out[0..count], topology, struct {
        fn lessThan(topology_ctx: CpuTopology, a_idx: usize, b_idx: usize) bool {
            const a = topology_ctx.logical_cores[a_idx];
            const b = topology_ctx.logical_cores[b_idx];
            if (a.thread_index != b.thread_index) return a.thread_index < b.thread_index;
            return a.logical_id < b.logical_id;
        }
    }.lessThan);

    return out[0..count];
}

fn renderTopologyHeaderLine(app_tui: *Tui, theme: ztop.config.Theme, column_width: u16, header_row: TopologyPhysicalRow, topology: CpuTopology) !void {
    var header_buf: [64]u8 = undefined;
    const label = buildTopologyHeaderText(&header_buf, header_row, topology);
    const fixed = 4; // "╺" + chip padding + "╸"
    const available_label: usize = if (column_width > fixed) @as(usize, @intCast(column_width - fixed)) else 0;
    const visible_label = label[0..@min(label.len, available_label)];

    try app_tui.printStyled(.{ .fg = theme.muted }, "╺", .{});
    _ = try writeChip(
        app_tui,
        .{
            .fg = theme.selection_fg,
            .bg = efficiencyAccentColor(theme, header_row.efficiency_class),
            .bold = true,
        },
        visible_label,
    );
    try app_tui.printStyled(.{ .fg = theme.muted }, "╸", .{});

    const used = fixed + visible_label.len;
    if (@as(usize, @intCast(column_width)) > used) {
        for (0..(@as(usize, @intCast(column_width)) - used)) |_| {
            try app_tui.printStyled(.{ .fg = theme.muted }, "━", .{});
        }
    }
}

fn renderTopologyPhysicalRowLine(
    app_tui: *Tui,
    theme: ztop.config.Theme,
    column_width: u16,
    physical_row: TopologyPhysicalRow,
    cpu: ztop.sysinfo.CpuStats,
    topology: CpuTopology,
) !void {
    var logical_indices: [ztop.sysinfo.common.MAX_CORES]usize = undefined;
    const indices = collectLogicalIndicesForPhysical(topology, physical_row.physical_id, &logical_indices);
    if (column_width == 0) return;

    const core_usage = averageCoreUsage(cpu, topology, physical_row.physical_id);
    const core_heat = usageColor(theme, core_usage);
    var written: usize = 0;

    written += try writeChip(
        app_tui,
        .{
            .fg = theme.selection_fg,
            .bg = efficiencyAccentColor(theme, physical_row.efficiency_class),
            .bold = true,
        },
        efficiencyLabel(physical_row.efficiency_class),
    );
    if (written >= column_width) return;

    try app_tui.out.writeStreamingAll(app_tui.io, " ");
    written += 1;
    if (written >= column_width) return;

    var prefix_buf: [8]u8 = undefined;
    const prefix = std.fmt.bufPrint(&prefix_buf, "C{d:0>2}", .{physical_row.physical_id}) catch "C??";
    try app_tui.printStyled(.{ .fg = theme.text, .bold = true }, "{s}", .{prefix});
    written += prefix.len;
    if (written >= column_width) return;

    try app_tui.out.writeStreamingAll(app_tui.io, " ");
    written += 1;
    if (written >= column_width) return;

    const min_bar_width: usize = 6;
    var hidden_threads: usize = 0;
    var visible_threads: usize = indices.len;

    while (true) {
        var tail_width: usize = 5; // " 100%"
        tail_width += visible_threads * 5; // " 00 " per thread
        if (hidden_threads > 0) {
            tail_width += 2 + std.fmt.count("{d}", .{hidden_threads});
        }

        const available_for_bar = @as(usize, @intCast(column_width)) -| written -| tail_width;
        if (available_for_bar >= min_bar_width or visible_threads == 0) break;
        visible_threads -= 1;
        hidden_threads += 1;
    }

    const bar_width: u16 = @intCast(@as(usize, @intCast(column_width)) -| written -| 5 -| (visible_threads * 5) -| if (hidden_threads > 0) 2 + std.fmt.count("{d}", .{hidden_threads}) else 0);
    try renderMeter(
        app_tui,
        bar_width,
        core_usage,
        .{ .fg = core_heat, .bold = core_usage >= 70 },
        .{ .fg = theme.muted, .dim = true },
    );
    written += bar_width;
    if (written >= column_width) return;

    const usage_int: u16 = @intFromFloat(@round(@max(core_usage, 0.0)));
    try app_tui.printStyled(.{ .fg = core_heat, .bold = core_usage >= 70 }, " {d:>3}%", .{usage_int});
    written += 5;

    for (indices[0..visible_threads]) |logical_idx| {
        const logical_core = topology.logical_cores[logical_idx];
        const usage = logicalCoreUsage(cpu, logical_core.logical_id);
        const heat = usageColor(theme, usage);
        try app_tui.printStyled(
            .{ .fg = theme.selection_fg, .bg = heat, .bold = usage >= 70 },
            " {d:0>2} ",
            .{logical_core.logical_id},
        );
        written += 5;
        if (written >= column_width) return;
    }

    if (hidden_threads > 0 and written < column_width) {
        try app_tui.printStyled(.{ .fg = theme.muted }, " +{d}", .{hidden_threads});
    }
}

fn renderPerCoreUsageArea(app_tui: *Tui, theme: ztop.config.Theme, x: u16, y: u16, width: u16, height: u16, cpu: ztop.sysinfo.CpuStats) !void {
    if (height == 0 or cpu.per_core_usage.len == 0) return;

    const rows_available: usize = height;
    const columns: usize = if (width >= 36 and cpu.per_core_usage.len > rows_available) 2 else 1;
    const entries_per_column = rows_available;
    const visible_cores = @min(cpu.per_core_usage.len, entries_per_column * columns);
    const column_width: u16 = if (columns == 1) width else width / 2;

    for (0..visible_cores) |i| {
        const row = i % entries_per_column;
        const column = i / entries_per_column;
        const col_x = x + @as(u16, @intCast(column)) * column_width;
        const row_y = y + @as(u16, @intCast(row));
        try app_tui.moveCursor(col_x, row_y);
        try app_tui.printStyled(.{ .fg = theme.muted }, "CPU{d:>2}: ", .{i});
        try app_tui.printStyled(.{ .fg = usageColor(theme, cpu.per_core_usage[i]), .bold = cpu.per_core_usage[i] >= 70 }, "{d:5.1}%", .{cpu.per_core_usage[i]});
    }
}

pub fn renderCpuTopologyBox(
    app_tui: *Tui,
    theme: ztop.config.Theme,
    box_x: u16,
    box_y: u16,
    box_width: u16,
    box_height: u16,
    cpu: ztop.sysinfo.CpuStats,
    topology: CpuTopology,
    history: *const MetricHistory,
) !void {
    const title = if (topology.logical_cores.len > 0) "CPU Topology Map" else "CPU";
    try app_tui.drawBoxStyled(
        box_x,
        box_y,
        box_width,
        box_height,
        title,
        .{ .fg = theme.border },
        .{ .fg = theme.cpu_title, .bold = true },
    );

    if (box_height < 3) return;

    try app_tui.moveCursor(box_x + 2, box_y + 1);
    try app_tui.printStyled(.{ .fg = theme.text, .dim = true }, "Usage: ", .{});
    try app_tui.printStyled(.{ .fg = usageColor(theme, cpu.usage_percent), .bold = true }, "{d:4.1}%", .{cpu.usage_percent});
    if (topology.logical_cores.len > 0 and topology.physical_cores > 0) {
        try app_tui.printStyled(.{ .fg = theme.muted }, " ({d} logical / {d} physical)", .{ cpu.cores, topology.physical_cores });
    } else {
        try app_tui.printStyled(.{ .fg = theme.muted }, " ({d} cores)", .{cpu.cores});
    }
    const content_x = box_x + 2;
    const content_width: u16 = box_width -| 4;
    const base_body_y = box_y + 2;
    const base_body_height: u16 = box_height -| 3;
    const graph_height = if (content_width >= 10 and history.len() > 1) historyGraphRows(box_height) else 0;
    const topology_height: u16 = base_body_height -| graph_height;

    if (topology.logical_cores.len > 0 and topology.has_smt and content_width >= 48) {
        try app_tui.printStyled(.{ .fg = theme.muted }, " | SMT ", .{});
        try app_tui.printStyled(.{ .fg = theme.usage_good, .bold = true }, "ON", .{});
    }
    if (topology.logical_cores.len > 0 and topology.has_efficiency_classes and content_width >= 62) {
        try app_tui.printStyled(.{ .fg = theme.muted }, " | hybrid", .{});
    }
    if (topology.logical_cores.len > 0 and topology.package_count > 1 and content_width >= 76) {
        try app_tui.printStyled(.{ .fg = theme.muted }, " | {d} pkg", .{topology.package_count});
    }

    if (graph_height > 0 and box_width >= 40) {
        try app_tui.printStyled(.{ .fg = theme.muted }, " | history", .{});
    }

    if (topology_height == 0 or content_width == 0) {
        if (graph_height > 0) {
            try renderHistoryGraph(app_tui, theme, content_x, base_body_y, content_width, graph_height, history, .cpu);
        }
        return;
    }

    if (topology.logical_cores.len == 0 or topology.physical_cores == 0) {
        try renderPerCoreUsageArea(app_tui, theme, content_x, base_body_y, content_width, topology_height, cpu);
        if (graph_height > 0) {
            try renderHistoryGraph(app_tui, theme, content_x, base_body_y + topology_height, content_width, graph_height, history, .cpu);
        }
        return;
    }

    var rows: [ztop.sysinfo.common.MAX_CORES]TopologyPhysicalRow = undefined;
    const row_count = collectTopologyRows(topology, &rows);
    if (row_count == 0) {
        try renderPerCoreUsageArea(app_tui, theme, content_x, base_body_y, content_width, topology_height, cpu);
        if (graph_height > 0) {
            try renderHistoryGraph(app_tui, theme, content_x, base_body_y + topology_height, content_width, graph_height, history, .cpu);
        }
        return;
    }

    var lines: [ztop.sysinfo.common.MAX_CORES * 2]TopologyLine = undefined;
    var line_count: usize = 0;
    for (rows[0..row_count], 0..) |row, idx| {
        if (idx == 0 or !sameTopologySection(rows[idx - 1], row)) {
            lines[line_count] = .{ .header = row };
            line_count += 1;
        }
        lines[line_count] = .{ .row = row };
        line_count += 1;
    }

    const body_height: usize = topology_height;
    const usable_width: usize = content_width;
    const columns = @max(std.math.divCeil(usize, line_count, body_height) catch 1, 1);
    const column_width = if (columns > 0) usable_width / columns else usable_width;
    if (column_width == 0) {
        try renderPerCoreUsageArea(app_tui, theme, content_x, base_body_y, content_width, topology_height, cpu);
        if (graph_height > 0) {
            try renderHistoryGraph(app_tui, theme, content_x, base_body_y + topology_height, content_width, graph_height, history, .cpu);
        }
        return;
    }

    var max_row_width: usize = 0;
    var header_buf: [64]u8 = undefined;
    for (rows[0..row_count]) |row| {
        const header = buildTopologyHeaderText(&header_buf, row, topology);
        max_row_width = @max(max_row_width, header.len + 4);

        var threads: usize = 0;
        for (topology.logical_cores) |logical_core| {
            if (logical_core.physical_id == row.physical_id) threads += 1;
        }
        // Layout estimate for the core-card rows:
        // " X  C00 " + meter + " 100%" + thread heat tiles.
        const row_width = 14 + threads * 5;
        max_row_width = @max(max_row_width, row_width);
    }

    if (column_width < max_row_width) {
        try renderPerCoreUsageArea(app_tui, theme, content_x, base_body_y, content_width, topology_height, cpu);
    } else {
        for (lines[0..line_count], 0..) |line, idx| {
            const column = idx / body_height;
            const row = idx % body_height;
            const x = content_x + @as(u16, @intCast(column * column_width));
            const y = base_body_y + @as(u16, @intCast(row));
            try app_tui.moveCursor(x, y);

            switch (line) {
                .header => |header_row| {
                    try renderTopologyHeaderLine(app_tui, theme, @intCast(column_width), header_row, topology);
                },
                .row => |physical_row| {
                    try renderTopologyPhysicalRowLine(app_tui, theme, @intCast(column_width), physical_row, cpu, topology);
                },
            }
        }
    }

    if (graph_height > 0) {
        try renderHistoryGraph(app_tui, theme, content_x, base_body_y + topology_height, content_width, graph_height, history, .cpu);
    }
}

pub fn setStatus(status_buf: *[160]u8, status_len: *usize, comptime fmt: []const u8, args: anytype) void {
    const msg = std.fmt.bufPrint(status_buf, fmt, args) catch {
        status_len.* = 0;
        return;
    };
    status_len.* = msg.len;
}

pub fn refreshConnections(
    allocator: std.mem.Allocator,
    sys_info: *SysInfo,
    cached_connections: *[]ztop.sysinfo.common.NetConnection,
) !void {
    const next = try sys_info.getNetConnections(allocator);
    if (cached_connections.*.len > 0) {
        allocator.free(cached_connections.*);
    }
    cached_connections.* = next;
}

pub fn footerCursorColumn(prompt_len: usize, input_len: usize, width: u16) u16 {
    if (width == 0) return 1;
    const col = prompt_len + input_len + 1;
    return @as(u16, @intCast(@min(col, @as(usize, width))));
}

pub fn updateFooterCursor(app_tui: *Tui, width: u16, height: u16, is_cmd_mode: bool, cmd_len: usize, is_filtering: bool, filter_len: usize) !void {
    if (is_cmd_mode) {
        try app_tui.setCursorStyle(.steady_bar);
        try app_tui.setCursorVisible(true);
        try app_tui.moveCursor(footerCursorColumn(1, cmd_len, width), height);
    } else if (is_filtering) {
        try app_tui.setCursorStyle(.steady_bar);
        try app_tui.setCursorVisible(true);
        try app_tui.moveCursor(footerCursorColumn("Filter: ".len, filter_len, width), height);
    } else {
        try app_tui.setCursorStyle(.steady_block);
        try app_tui.setCursorVisible(false);
    }
}
