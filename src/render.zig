const std = @import("std");
const tui = @import("tui.zig");
const sysinfo = @import("sysinfo.zig");
const config = @import("config.zig");
const history_mod = @import("history.zig");
const timeline_mod = @import("timeline.zig");
const Tui = tui.Tui;
const SysInfo = sysinfo.SysInfo;
const CpuTopology = sysinfo.CpuTopology;
const CpuEfficiencyClass = sysinfo.CpuEfficiencyClass;
const MetricHistory = history_mod.MetricHistory;
const RateHistory = history_mod.RateHistory;
const ProcessColumn = config.ProcessColumn;
const ProcessColumns = config.ProcessColumns;

pub fn usageColor(theme: config.Theme, percent: f32) Tui.Color {
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

pub fn memoryColor(theme: config.Theme, percent: f32) Tui.Color {
    if (percent >= 80) return theme.memory_critical;
    if (percent >= 60) return theme.memory_warn;
    if (percent >= 35) return theme.memory_mid;
    return theme.memory_low;
}

pub fn procStateLabel(state: sysinfo.ProcState) []const u8 {
    return switch (state) {
        .running => "running",
        .sleeping => "sleeping",
        .disk_sleep => "disk_slp",
        .stopped => "stopped",
        .tracing_stop => "tracing",
        .zombie => "zombie",
        .dead => "dead",
        .idle => "idle",
        .unknown => "unknown",
    };
}

pub fn procStateColor(theme: config.Theme, state: sysinfo.ProcState) Tui.Color {
    return switch (state) {
        .running => theme.usage_good,
        .sleeping => theme.muted,
        .disk_sleep => theme.usage_warn,
        .stopped => theme.usage_critical,
        .tracing_stop => theme.usage_warn,
        .zombie => theme.usage_critical,
        .dead => theme.usage_critical,
        .idle => theme.memory_low,
        .unknown => theme.muted,
    };
}

pub fn processColumnWidth(column: ProcessColumn) usize {
    return switch (column) {
        .pid => 6,
        .ppid => 6,
        .state => 9,
        .cpu => 10,
        .mem => 10,
        .threads => 8,
        .disk_read => 11,
        .disk_write => 11,
    };
}

pub fn planProcessTableLayout(columns: ProcessColumns, available_width: usize) ProcessTableLayout {
    var layout: ProcessTableLayout = .{};
    var visible_columns: [config.process_column_order.len]ProcessColumn = undefined;
    const visible = columns.visibleOrdered(&visible_columns);

    var fixed_width: usize = 0;
    for (visible) |column| {
        fixed_width += processColumnWidth(column);
    }

    layout.count = visible.len;
    while (layout.count > 0 and available_width < fixed_width + min_process_name_width) {
        layout.count -= 1;
        fixed_width -= processColumnWidth(visible[layout.count]);
        layout.dropped_count += 1;
    }

    if (layout.count > 0) {
        @memcpy(layout.columns[0..layout.count], visible[0..layout.count]);
    }

    layout.name_width = available_width -| fixed_width;
    return layout;
}

pub fn writeAlignedCell(app_tui: *Tui, style: Tui.Style, width: usize, text_align: TextAlign, text: []const u8) !void {
    if (width == 0) return;

    const clipped = if (text.len > width) text[0..width] else text;
    const padding = width - clipped.len;

    if (text_align == .right) {
        for (0..padding) |_| {
            try app_tui.writeStyled(style, " ");
        }
    }

    try app_tui.writeStyled(style, clipped);

    if (text_align == .left) {
        for (0..padding) |_| {
            try app_tui.writeStyled(style, " ");
        }
    }
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

pub const TextAlign = enum {
    left,
    right,
};

pub const ProcessTableLayout = struct {
    columns: [config.process_column_order.len]ProcessColumn = undefined,
    count: usize = 0,
    name_width: usize = 0,
    dropped_count: usize = 0,
};

pub const min_process_name_width: usize = 8;

fn metricGraphColor(theme: config.Theme, mode: MetricColorMode, percent: f32) Tui.Color {
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
    theme: config.Theme,
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
    theme: config.Theme,
    box_x: u16,
    box_y: u16,
    box_width: u16,
    box_height: u16,
    title: []const u8,
    title_color: Tui.Color,
    primary: RateSeries,
    secondary: RateSeries,
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

    try renderRateMetricRow(app_tui, theme, inner_x, inner_y, inner_width, primary, peak_rate);
    if (inner_height == 1) return;

    try renderRateMetricRow(app_tui, theme, inner_x, inner_y + 1, inner_width, secondary, peak_rate);

    const graph_rows = if (disable_history) 0 else inner_height -| 2;
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

fn collectTopologyRows(topology: CpuTopology, rows: *[sysinfo.common.MAX_CORES]TopologyPhysicalRow) usize {
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

fn logicalCoreUsage(cpu: sysinfo.CpuStats, logical_id: u16) f32 {
    return if (@as(usize, logical_id) < cpu.per_core_usage.len)
        cpu.per_core_usage[logical_id]
    else
        0.0;
}

fn averageCoreUsage(cpu: sysinfo.CpuStats, topology: CpuTopology, physical_id: u16) f32 {
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

fn efficiencyAccentColor(theme: config.Theme, class: CpuEfficiencyClass) Tui.Color {
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
    out: *[sysinfo.common.MAX_CORES]usize,
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

fn renderTopologyHeaderLine(app_tui: *Tui, theme: config.Theme, column_width: u16, header_row: TopologyPhysicalRow, topology: CpuTopology) !void {
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
    theme: config.Theme,
    column_width: u16,
    physical_row: TopologyPhysicalRow,
    cpu: sysinfo.CpuStats,
    topology: CpuTopology,
) !void {
    var logical_indices: [sysinfo.common.MAX_CORES]usize = undefined;
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

fn renderPerCoreUsageArea(app_tui: *Tui, theme: config.Theme, x: u16, y: u16, width: u16, height: u16, cpu: sysinfo.CpuStats) !void {
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
    theme: config.Theme,
    box_x: u16,
    box_y: u16,
    box_width: u16,
    box_height: u16,
    cpu: sysinfo.CpuStats,
    topology: CpuTopology,
    history: *const MetricHistory,
    disable_history: bool,
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
    const graph_height = if (content_width >= 10 and history.len() > 1 and !disable_history) historyGraphRows(box_height) else 0;
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

    var rows: [sysinfo.common.MAX_CORES]TopologyPhysicalRow = undefined;
    const row_count = collectTopologyRows(topology, &rows);
    if (row_count == 0) {
        try renderPerCoreUsageArea(app_tui, theme, content_x, base_body_y, content_width, topology_height, cpu);
        if (graph_height > 0) {
            try renderHistoryGraph(app_tui, theme, content_x, base_body_y + topology_height, content_width, graph_height, history, .cpu);
        }
        return;
    }

    var lines: [sysinfo.common.MAX_CORES * 2]TopologyLine = undefined;
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
    cached_connections: *[]sysinfo.common.NetConnection,
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

/// Render the timeline scrubber bar.
pub fn renderTimelineBar(
    app_tui: *Tui,
    theme: config.Theme,
    x: u16,
    y: u16,
    width: u16,
    tl: *const timeline_mod.Timeline,
    scrub_offset: usize,
    is_scrubbing: bool,
    diff_anchor: ?usize,
) !void {
    if (width < 12) return;
    const snap_count = tl.snapshotCount();
    // Diff anchor absolute index
    const anchor_abs: ?usize = if (diff_anchor) |anchor| (if (snap_count > 0) snap_count - 1 - @min(anchor, snap_count - 1) else null) else null;

    try app_tui.moveCursor(x, y);

    // Left nav indicator
    const can_go_older = is_scrubbing and scrub_offset + 1 < snap_count;
    try app_tui.writeStyled(
        if (can_go_older) .{ .fg = theme.tab_active, .bold = true } else .{ .fg = theme.muted },
        "◀",
    );

    const suffix_reserve: u16 = 12;
    const bar_width: usize = if (width > 4 + suffix_reserve) @as(usize, width) - 4 - @as(usize, suffix_reserve) else 2;

    try app_tui.out.writeStreamingAll(app_tui.io, " ");

    if (snap_count == 0) {
        try app_tui.writeStyled(.{ .fg = theme.muted }, "Recording...");
    } else {
        // Determine the visible window: last bar_width snapshots (newest on right)
        const visible_snaps = @min(snap_count, bar_width);
        const oldest_visible_abs = snap_count -| visible_snaps;

        // Scrub cursor absolute index (from oldest)
        const scrub_abs: usize = if (snap_count > 0) snap_count - 1 - scrub_offset else 0;

        for (0..bar_width) |col| {
            // col 0 = oldest visible, col bar_width-1 = newest
            const abs_idx = oldest_visible_abs + col;
            const in_range = abs_idx < snap_count;
            const is_cursor = is_scrubbing and in_range and abs_idx == scrub_abs;

            if (!in_range) {
                // Left-pad area before history starts
                try app_tui.out.writeStreamingAll(app_tui.io, " ");
                continue;
            }

            if (is_cursor) {
                // Show combined cursor+bookmark indicator if bookmarked
                if (tl.hasBookmarkAtAbsIndex(abs_idx)) {
                    try app_tui.writeStyled(.{ .bg = theme.tab_active, .fg = theme.selection_fg, .bold = true }, "▼");
                } else {
                    try app_tui.writeStyled(.{ .bg = theme.selection_bg, .fg = theme.selection_fg, .bold = true }, "|");
                }
                continue;
            }

            // Bookmark marker (priority over events)
            if (tl.hasBookmarkAtAbsIndex(abs_idx)) {
                try app_tui.writeStyled(.{ .fg = theme.tab_active, .bold = true }, "▼");
                continue;
            }

            // Diff anchor marker
            if (anchor_abs != null and abs_idx == anchor_abs.?) {
                try app_tui.writeStyled(.{ .fg = theme.usage_warn, .bold = true }, "◆");
                continue;
            }

            // Get the snapshot and look up any events at that moment
            const snap = tl.getSnapshotAtIndex(abs_idx) orelse {
                try app_tui.out.writeStreamingAll(app_tui.io, " ");
                continue;
            };
            const ts = snap.timestamp_ms;
            const ev_mask = tl.eventMaskInRange(ts - 600, ts + 600);

            if (ev_mask & (@as(u8, 1) << @intFromEnum(timeline_mod.EventKind.thermal_high)) != 0) {
                try app_tui.writeStyled(.{ .fg = theme.usage_critical, .bold = true }, "T");
            } else if (ev_mask & (@as(u8, 1) << @intFromEnum(timeline_mod.EventKind.cpu_spike)) != 0) {
                try app_tui.writeStyled(.{ .fg = theme.usage_warn, .bold = true }, "C");
            } else if (ev_mask & (@as(u8, 1) << @intFromEnum(timeline_mod.EventKind.mem_pressure)) != 0) {
                try app_tui.writeStyled(.{ .fg = theme.memory_critical, .bold = true }, "M");
            } else if (ev_mask & (@as(u8, 1) << @intFromEnum(timeline_mod.EventKind.disk_spike)) != 0) {
                try app_tui.writeStyled(.{ .fg = theme.disk_title }, "D");
            } else if (ev_mask & (@as(u8, 1) << @intFromEnum(timeline_mod.EventKind.net_spike)) != 0) {
                try app_tui.writeStyled(.{ .fg = theme.network_title }, "N");
            } else if (ev_mask & (@as(u8, 1) << @intFromEnum(timeline_mod.EventKind.proc_birth)) != 0) {
                try app_tui.writeStyled(.{ .fg = theme.usage_good }, "+");
            } else if (ev_mask & (@as(u8, 1) << @intFromEnum(timeline_mod.EventKind.proc_death)) != 0) {
                try app_tui.writeStyled(.{ .fg = theme.muted }, "-");
            } else {
                // No event: show CPU density block
                const ch: []const u8 = cpuDensityChar(snap.cpu_usage_pct);
                try app_tui.writeStyled(.{ .fg = theme.muted }, ch);
            }
        }
    }

    // Right nav indicator
    try app_tui.out.writeStreamingAll(app_tui.io, " ");
    const can_go_newer = is_scrubbing and scrub_offset > 0;
    try app_tui.writeStyled(
        if (can_go_newer) .{ .fg = theme.tab_active, .bold = true } else .{ .fg = theme.muted },
        "▶",
    );

    // Time label
    if (is_scrubbing) {
        if (tl.getSnapshot(0)) |newest| {
            if (tl.getSnapshot(scrub_offset)) |cur| {
                const delta_s = @divTrunc(newest.timestamp_ms - cur.timestamp_ms, 1000);
                var dur_buf: [16]u8 = undefined;
                const dur = timeline_mod.Timeline.formatDuration(&dur_buf, delta_s);
                var tbuf: [24]u8 = undefined;
                const label = std.fmt.bufPrint(&tbuf, "  T-{s}", .{dur}) catch "  T-?";
                try app_tui.writeStyled(.{ .fg = theme.usage_warn, .bold = true }, label);
            }
        }
    } else if (snap_count > 0) {
        var dur_buf: [16]u8 = undefined;
        const dur = timeline_mod.Timeline.formatDuration(&dur_buf, @intCast(snap_count));
        var tbuf: [24]u8 = undefined;
        const label = std.fmt.bufPrint(&tbuf, "  {s}", .{dur}) catch "  ?";
        try app_tui.writeStyled(.{ .fg = theme.muted }, label);
    }
}

fn cpuDensityChar(cpu_pct: f32) []const u8 {
    if (cpu_pct >= 75.0) return "▓";
    if (cpu_pct >= 50.0) return "▒";
    if (cpu_pct >= 25.0) return "░";
    return "·";
}

fn deltaSign(after: f32, before: f32) []const u8 {
    if (after > before + 0.5) return "▲";
    if (after < before - 0.5) return "▼";
    return "─";
}

fn deltaColor(theme: config.Theme, after: f32, before: f32) Tui.Color {
    if (after > before + 0.5) return theme.usage_critical;
    if (after < before - 0.5) return theme.usage_good;
    return theme.muted;
}

fn rateDeltaSign(after: u64, before: u64) []const u8 {
    if (after > before +| 1024) return "▲";
    if (before > after +| 1024) return "▼";
    return "─";
}

fn rateDeltaColor(theme: config.Theme, after: u64, before: u64) Tui.Color {
    if (after > before +| 1024) return theme.usage_warn;
    if (before > after +| 1024) return theme.usage_good;
    return theme.muted;
}

/// Render the before/after diff comparison view.
pub fn renderDiffView(
    app_tui: *Tui,
    theme: config.Theme,
    x: u16,
    y: u16,
    width: u16,
    height: u16,
    diff: timeline_mod.SnapshotDiff,
) !void {
    if (width < 20 or height < 6) return;

    // Title
    var dur_buf: [16]u8 = undefined;
    const abs_delta = if (diff.time_delta_ms < 0) -diff.time_delta_ms else diff.time_delta_ms;
    const dur = timeline_mod.Timeline.formatDuration(&dur_buf, @intCast(@divTrunc(abs_delta, 1000)));

    var title_buf: [64]u8 = undefined;
    const title = std.fmt.bufPrint(&title_buf, "Before/After Diff  ({s} apart)", .{dur}) catch "Before/After Diff";

    try app_tui.drawBoxStyled(x, y, width, height, title, .{ .fg = theme.border }, .{ .fg = theme.usage_warn, .bold = true });

    if (height < 4 or width < 24) return;

    const inner_x = x + 2;
    const inner_width = width -| 4;
    var row: u16 = y + 1;
    const max_row = y + height - 1;

    // Section: System Metrics
    if (row < max_row) {
        try app_tui.moveCursor(inner_x, row);
        try app_tui.printStyled(.{ .fg = theme.text, .bold = true }, "── System Metrics ──", .{});
        row += 1;
    }

    // CPU
    if (row < max_row) {
        try app_tui.moveCursor(inner_x, row);
        try app_tui.printStyled(.{ .fg = theme.text, .dim = true }, "CPU   ", .{});
        try app_tui.printStyled(.{ .fg = usageColor(theme, diff.cpu_before) }, "{d:5.1}%", .{diff.cpu_before});
        try app_tui.printStyled(.{ .fg = theme.muted }, " → ", .{});
        try app_tui.printStyled(.{ .fg = usageColor(theme, diff.cpu_after) }, "{d:5.1}%", .{diff.cpu_after});
        const cpu_delta = diff.cpu_after - diff.cpu_before;
        const cpu_sign: []const u8 = if (cpu_delta >= 0) "+" else "-";
        try app_tui.printStyled(.{ .fg = theme.muted }, "  ", .{});
        try app_tui.printStyled(.{ .fg = deltaColor(theme, diff.cpu_after, diff.cpu_before), .bold = true }, "{s} {s}{d:.1}%", .{ deltaSign(diff.cpu_after, diff.cpu_before), cpu_sign, @abs(cpu_delta) });
        row += 1;
    }

    // Memory
    if (row < max_row) {
        try app_tui.moveCursor(inner_x, row);
        try app_tui.printStyled(.{ .fg = theme.text, .dim = true }, "Mem   ", .{});
        try app_tui.printStyled(.{ .fg = memoryColor(theme, diff.mem_before_pct) }, "{d:5.1}%", .{diff.mem_before_pct});
        try app_tui.printStyled(.{ .fg = theme.muted }, " → ", .{});
        try app_tui.printStyled(.{ .fg = memoryColor(theme, diff.mem_after_pct) }, "{d:5.1}%", .{diff.mem_after_pct});
        const mem_delta = diff.mem_after_pct - diff.mem_before_pct;
        const mem_sign: []const u8 = if (mem_delta >= 0) "+" else "-";
        try app_tui.printStyled(.{ .fg = theme.muted }, "  ", .{});
        try app_tui.printStyled(.{ .fg = deltaColor(theme, diff.mem_after_pct, diff.mem_before_pct), .bold = true }, "{s} {s}{d:.1}%", .{ deltaSign(diff.mem_after_pct, diff.mem_before_pct), mem_sign, @abs(mem_delta) });
        row += 1;
    }

    // Disk I/O
    if (row < max_row) {
        const rb = formatUnit(diff.disk_read_before);
        const ra = formatUnit(diff.disk_read_after);
        try app_tui.moveCursor(inner_x, row);
        try app_tui.printStyled(.{ .fg = theme.text, .dim = true }, "Disk  ", .{});
        try app_tui.printStyled(.{ .fg = theme.disk_title }, "R ", .{});
        try app_tui.printStyled(.{ .fg = theme.text }, "{d:4.1}{s}/s", .{ rb.value, rb.unit });
        try app_tui.printStyled(.{ .fg = theme.muted }, "→", .{});
        try app_tui.printStyled(.{ .fg = theme.text }, "{d:4.1}{s}/s", .{ ra.value, ra.unit });
        try app_tui.printStyled(.{ .fg = rateDeltaColor(theme, diff.disk_read_after, diff.disk_read_before) }, " {s}", .{rateDeltaSign(diff.disk_read_after, diff.disk_read_before)});

        if (inner_width >= 50) {
            const wb = formatUnit(diff.disk_write_before);
            const wa = formatUnit(diff.disk_write_after);
            try app_tui.printStyled(.{ .fg = theme.muted }, "  ", .{});
            try app_tui.printStyled(.{ .fg = theme.disk_title }, "W ", .{});
            try app_tui.printStyled(.{ .fg = theme.text }, "{d:4.1}{s}/s", .{ wb.value, wb.unit });
            try app_tui.printStyled(.{ .fg = theme.muted }, "→", .{});
            try app_tui.printStyled(.{ .fg = theme.text }, "{d:4.1}{s}/s", .{ wa.value, wa.unit });
            try app_tui.printStyled(.{ .fg = rateDeltaColor(theme, diff.disk_write_after, diff.disk_write_before) }, " {s}", .{rateDeltaSign(diff.disk_write_after, diff.disk_write_before)});
        }
        row += 1;
    }

    // Network I/O
    if (row < max_row) {
        const rxb = formatUnit(diff.net_rx_before);
        const rxa = formatUnit(diff.net_rx_after);
        try app_tui.moveCursor(inner_x, row);
        try app_tui.printStyled(.{ .fg = theme.text, .dim = true }, "Net   ", .{});
        try app_tui.printStyled(.{ .fg = theme.network_title }, "↓ ", .{});
        try app_tui.printStyled(.{ .fg = theme.text }, "{d:4.1}{s}/s", .{ rxb.value, rxb.unit });
        try app_tui.printStyled(.{ .fg = theme.muted }, "→", .{});
        try app_tui.printStyled(.{ .fg = theme.text }, "{d:4.1}{s}/s", .{ rxa.value, rxa.unit });
        try app_tui.printStyled(.{ .fg = rateDeltaColor(theme, diff.net_rx_after, diff.net_rx_before) }, " {s}", .{rateDeltaSign(diff.net_rx_after, diff.net_rx_before)});

        if (inner_width >= 50) {
            const txb = formatUnit(diff.net_tx_before);
            const txa = formatUnit(diff.net_tx_after);
            try app_tui.printStyled(.{ .fg = theme.muted }, "  ", .{});
            try app_tui.printStyled(.{ .fg = theme.network_title }, "↑ ", .{});
            try app_tui.printStyled(.{ .fg = theme.text }, "{d:4.1}{s}/s", .{ txb.value, txb.unit });
            try app_tui.printStyled(.{ .fg = theme.muted }, "→", .{});
            try app_tui.printStyled(.{ .fg = theme.text }, "{d:4.1}{s}/s", .{ txa.value, txa.unit });
            try app_tui.printStyled(.{ .fg = rateDeltaColor(theme, diff.net_tx_after, diff.net_tx_before) }, " {s}", .{rateDeltaSign(diff.net_tx_after, diff.net_tx_before)});
        }
        row += 1;
    }

    // Temperature
    if (row < max_row and (diff.temp_before != null or diff.temp_after != null)) {
        try app_tui.moveCursor(inner_x, row);
        try app_tui.printStyled(.{ .fg = theme.text, .dim = true }, "Temp  ", .{});
        if (diff.temp_before) |tb| {
            try app_tui.printStyled(.{ .fg = if (tb >= 85) theme.usage_critical else if (tb >= 70) theme.usage_warn else theme.text }, "{d:5.1}°C", .{tb});
        } else {
            try app_tui.printStyled(.{ .fg = theme.muted }, "  N/A  ", .{});
        }
        try app_tui.printStyled(.{ .fg = theme.muted }, " → ", .{});
        if (diff.temp_after) |ta| {
            try app_tui.printStyled(.{ .fg = if (ta >= 85) theme.usage_critical else if (ta >= 70) theme.usage_warn else theme.text }, "{d:5.1}°C", .{ta});
            if (diff.temp_before) |tb| {
                const temp_d = ta - tb;
                try app_tui.printStyled(.{ .fg = theme.muted }, "  ", .{});
                const temp_sign: []const u8 = if (temp_d >= 0) "+" else "-";
                try app_tui.printStyled(.{ .fg = deltaColor(theme, ta, tb), .bold = true }, "{s} {s}{d:.1}°C", .{ deltaSign(ta, tb), temp_sign, @abs(temp_d) });
            }
        } else {
            try app_tui.printStyled(.{ .fg = theme.muted }, "  N/A  ", .{});
        }
        row += 1;
    }

    // Spacer
    if (row < max_row) row += 1;

    // Section: Process Changes
    if (row < max_row and diff.proc_diff_count > 0) {
        try app_tui.moveCursor(inner_x, row);
        try app_tui.printStyled(.{ .fg = theme.text, .bold = true }, "── Process Changes ──", .{});
        row += 1;

        // Header
        if (row < max_row) {
            try app_tui.moveCursor(inner_x, row);
            try app_tui.printStyled(.{ .fg = theme.muted }, " CHANGE   NAME             CPU            MEM", .{});
            row += 1;
        }

        for (diff.proc_diffs[0..diff.proc_diff_count]) |entry| {
            if (row >= max_row) break;
            try app_tui.moveCursor(inner_x, row);

            // Kind badge
            switch (entry.kind) {
                .appeared => try app_tui.printStyled(.{ .fg = theme.usage_good, .bold = true }, " + NEW   ", .{}),
                .disappeared => try app_tui.printStyled(.{ .fg = theme.usage_critical, .bold = true }, " - EXIT  ", .{}),
                .changed => try app_tui.printStyled(.{ .fg = theme.usage_warn, .bold = true }, " ~ CHG   ", .{}),
            }

            // Name (truncated to 16 chars)
            const name = entry.name();
            const display_name = if (name.len > 16) name[0..16] else name;
            try app_tui.printStyled(.{ .fg = theme.text }, "{s}", .{display_name});
            // Pad to 16
            if (display_name.len < 17) {
                for (0..17 - display_name.len) |_| {
                    try app_tui.out.writeStreamingAll(app_tui.io, " ");
                }
            }

            // CPU change
            switch (entry.kind) {
                .appeared => {
                    try app_tui.printStyled(.{ .fg = theme.muted }, "     → ", .{});
                    try app_tui.printStyled(.{ .fg = usageColor(theme, entry.cpu_after), .bold = true }, "{d:5.1}%", .{entry.cpu_after});
                },
                .disappeared => {
                    try app_tui.printStyled(.{ .fg = usageColor(theme, entry.cpu_before) }, "{d:5.1}%", .{entry.cpu_before});
                    try app_tui.printStyled(.{ .fg = theme.muted }, " →      ", .{});
                },
                .changed => {
                    try app_tui.printStyled(.{ .fg = usageColor(theme, entry.cpu_before) }, "{d:5.1}%", .{entry.cpu_before});
                    try app_tui.printStyled(.{ .fg = theme.muted }, "→", .{});
                    try app_tui.printStyled(.{ .fg = usageColor(theme, entry.cpu_after) }, "{d:5.1}%", .{entry.cpu_after});
                },
            }

            // MEM change (if width allows)
            if (inner_width >= 50) {
                try app_tui.printStyled(.{ .fg = theme.muted }, " ", .{});
                switch (entry.kind) {
                    .appeared => {
                        try app_tui.printStyled(.{ .fg = theme.muted }, "     → ", .{});
                        try app_tui.printStyled(.{ .fg = memoryColor(theme, entry.mem_after) }, "{d:5.1}%", .{entry.mem_after});
                    },
                    .disappeared => {
                        try app_tui.printStyled(.{ .fg = memoryColor(theme, entry.mem_before) }, "{d:5.1}%", .{entry.mem_before});
                        try app_tui.printStyled(.{ .fg = theme.muted }, " →      ", .{});
                    },
                    .changed => {
                        try app_tui.printStyled(.{ .fg = memoryColor(theme, entry.mem_before) }, "{d:5.1}%", .{entry.mem_before});
                        try app_tui.printStyled(.{ .fg = theme.muted }, "→", .{});
                        try app_tui.printStyled(.{ .fg = memoryColor(theme, entry.mem_after) }, "{d:5.1}%", .{entry.mem_after});
                    },
                }
            }

            row += 1;
        }
    } else if (row < max_row and diff.proc_diff_count == 0) {
        try app_tui.moveCursor(inner_x, row);
        try app_tui.printStyled(.{ .fg = theme.muted }, "No significant process changes", .{});
    }
}

/// Render the Resource Causality Graph view for a selected process.
/// Shows child processes, network connections, and resource summary with meters.
pub fn renderCausalityGraph(
    app_tui: *Tui,
    theme: config.Theme,
    x: u16,
    y: u16,
    width: u16,
    height: u16,
    pid: u32,
    proc_name_str: []const u8,
    cached_procs: []const sysinfo.ProcStats,
    causality_connections: []const sysinfo.common.NetConnection,
) !void {
    if (height < 5 or width < 30) return;

    // Draw main box
    var title_buf: [128]u8 = undefined;
    const title = std.fmt.bufPrint(&title_buf, "Causality: {s} (PID: {d})", .{ proc_name_str, pid }) catch "Causality";
    try app_tui.drawBoxStyled(x, y, width, height, title, .{ .fg = theme.border }, .{ .fg = theme.process_title, .bold = true });

    const inner_x = x + 2;
    const inner_width = width -| 4;
    const inner_height = height -| 2;
    if (inner_width < 10 or inner_height < 3) return;

    // Find target process for resource summary
    var target_proc: ?sysinfo.ProcStats = null;
    var children_count: usize = 0;
    for (cached_procs) |proc| {
        if (proc.pid == pid) target_proc = proc;
        if (proc.ppid == pid and proc.pid != pid) children_count += 1;
    }
    const conn_count = causality_connections.len;

    // Layout: resource summary (3 rows) at bottom, rest split left/right
    const summary_rows: u16 = if (inner_height >= 10) 3 else if (inner_height >= 7) 2 else 0;
    const divider_row: u16 = if (summary_rows > 0) 1 else 0;
    const list_height = inner_height -| summary_rows -| divider_row;
    if (list_height == 0) return;

    // Left/right split
    const left_width = if (inner_width >= 60) inner_width * 2 / 5 else inner_width / 2;
    const divider_col = inner_x + @as(u16, @intCast(left_width));
    const right_x = divider_col + 1;
    const right_width = inner_width -| @as(u16, @intCast(left_width)) -| 1;

    // ── Vertical divider ──
    for (0..list_height + 1) |row| {
        try app_tui.moveCursor(divider_col, y + 1 + @as(u16, @intCast(row)));
        try app_tui.writeStyled(.{ .fg = theme.border, .dim = true }, "│");
    }

    // ── Children header ──
    try app_tui.moveCursor(inner_x, y + 1);
    try app_tui.printStyled(.{ .fg = theme.process_title, .bold = true }, "CHILDREN", .{});
    try app_tui.printStyled(.{ .fg = theme.muted }, " ({d})", .{children_count});

    // ── Connections header ──
    try app_tui.moveCursor(right_x, y + 1);
    try app_tui.printStyled(.{ .fg = theme.process_title, .bold = true }, "CONNECTIONS", .{});
    try app_tui.printStyled(.{ .fg = theme.muted }, " ({d})", .{conn_count});

    // ── Children list ──
    const child_max_rows = list_height -| 1;
    if (children_count == 0) {
        if (child_max_rows > 0) {
            try app_tui.moveCursor(inner_x, y + 2);
            try app_tui.printStyled(.{ .fg = theme.muted, .dim = true }, "no child processes", .{});
        }
    } else {
        var child_row: u16 = 0;
        const name_col_width = if (left_width > 22) left_width - 18 else 6;
        for (cached_procs) |proc| {
            if (proc.ppid != pid or proc.pid == pid) continue;
            if (child_row >= child_max_rows) break;

            try app_tui.moveCursor(inner_x, y + 2 + child_row);

            // Tree connector
            child_row += 1;
            const is_last = blk: {
                var remaining: usize = 0;
                var past_current = false;
                for (cached_procs) |p| {
                    if (p.ppid != pid or p.pid == pid) continue;
                    if (past_current) {
                        remaining += 1;
                        break;
                    }
                    if (p.pid == proc.pid) past_current = true;
                }
                break :blk remaining == 0;
            };
            try app_tui.writeStyled(.{ .fg = theme.border, .dim = true }, if (is_last) "└─" else "├─");

            // Name
            const pname = proc.name();
            if (pname.len > name_col_width) {
                try app_tui.printStyled(.{ .fg = theme.text }, "{s}..", .{pname[0..name_col_width -| 2]});
            } else {
                try app_tui.printStyled(.{ .fg = theme.text }, "{s}", .{pname});
                for (0..name_col_width -| pname.len) |_| try app_tui.writeStyled(.{}, " ");
            }

            // CPU%
            const cpu_style: Tui.Style = .{ .fg = usageColor(theme, proc.cpu_percent), .bold = proc.cpu_percent >= 50 };
            try app_tui.printStyled(cpu_style, " {d:5.1}%", .{proc.cpu_percent});

            // MEM%
            try app_tui.printStyled(.{ .fg = memoryColor(theme, proc.mem_percent) }, " {d:5.1}%", .{proc.mem_percent});
        }

        // Overflow indicator
        if (children_count > child_max_rows) {
            try app_tui.moveCursor(inner_x, y + 2 + child_max_rows -| 1);
            const hidden = children_count - (child_max_rows -| 1);
            try app_tui.printStyled(.{ .fg = theme.muted, .dim = true }, "  (+{d} more)", .{hidden});
        }
    }

    // ── Connections list ──
    const conn_max_rows = list_height -| 1;
    if (conn_count == 0) {
        if (conn_max_rows > 0) {
            try app_tui.moveCursor(right_x, y + 2);
            try app_tui.printStyled(.{ .fg = theme.muted, .dim = true }, "no connections", .{});
        }
    } else {
        var conn_row: u16 = 0;
        for (causality_connections) |conn| {
            if (conn_row >= conn_max_rows) break;

            try app_tui.moveCursor(right_x, y + 2 + conn_row);

            // Protocol chip
            const proto_color: Tui.Color = switch (conn.protocol) {
                .tcp, .tcp6 => theme.usage_good,
                .udp, .udp6 => theme.io_rate,
                else => theme.muted,
            };
            try app_tui.printStyled(.{ .fg = proto_color, .bold = true }, "{s:<4}", .{@tagName(conn.protocol)});
            try app_tui.writeStyled(.{}, " ");

            // Local address:port
            const local_str = std.mem.sliceTo(&conn.local_addr, 0);
            const addr_max = if (right_width > 30) right_width -| 18 else right_width -| 6;
            if (conn.local_port > 0) {
                var addr_buf: [64]u8 = undefined;
                const addr_str = std.fmt.bufPrint(&addr_buf, "{s}:{d}", .{ local_str, conn.local_port }) catch local_str;
                const clip: usize = @min(addr_str.len, addr_max);
                try app_tui.printStyled(.{ .fg = theme.text }, "{s}", .{addr_str[0..clip]});
            } else {
                const clip: usize = @min(local_str.len, addr_max);
                try app_tui.printStyled(.{ .fg = theme.text }, "{s}", .{local_str[0..clip]});
            }

            // State for TCP
            if (right_width > 30) {
                if (conn.protocol == .tcp or conn.protocol == .tcp6) {
                    const state_str = @tagName(conn.state);
                    const state_color: Tui.Color = switch (conn.state) {
                        .established => theme.usage_good,
                        .listen => theme.io_rate,
                        .time_wait, .close_wait => theme.usage_warn,
                        else => theme.muted,
                    };
                    try app_tui.printStyled(.{ .fg = state_color, .dim = true }, " {s}", .{state_str});
                }
            }

            conn_row += 1;
        }

        // Overflow indicator
        if (conn_count > conn_max_rows) {
            try app_tui.moveCursor(right_x, y + 2 + conn_max_rows -| 1);
            const hidden = conn_count - (conn_max_rows -| 1);
            try app_tui.printStyled(.{ .fg = theme.muted, .dim = true }, "(+{d} more)", .{hidden});
        }
    }

    // ── Horizontal divider before resource summary ──
    if (summary_rows > 0) {
        const div_y = y + 1 + list_height + 1;
        try app_tui.moveCursor(x + 1, div_y - 1);
        for (0..width -| 2) |_| try app_tui.writeStyled(.{ .fg = theme.border, .dim = true }, "─");

        // ── Resource Summary ──
        if (target_proc) |proc| {
            const meter_width: u16 = if (inner_width > 50) 24 else if (inner_width > 35) 16 else 10;

            // CPU row
            try app_tui.moveCursor(inner_x, div_y);
            try app_tui.printStyled(.{ .fg = theme.text, .bold = true }, "CPU ", .{});
            try renderMeter(
                app_tui,
                meter_width,
                proc.cpu_percent,
                .{ .fg = usageColor(theme, proc.cpu_percent) },
                .{ .fg = theme.muted, .dim = true },
            );
            try app_tui.printStyled(.{ .fg = usageColor(theme, proc.cpu_percent), .bold = true }, " {d:5.1}%", .{proc.cpu_percent});

            // Stats on same row, right side
            const stats_x = inner_x + meter_width + 14;
            if (stats_x + 20 < x + width) {
                try app_tui.moveCursor(stats_x, div_y);
                try app_tui.printStyled(.{ .fg = procStateColor(theme, proc.state) }, "{s}", .{procStateLabel(proc.state)});
                try app_tui.printStyled(.{ .fg = theme.muted }, "  threads:", .{});
                try app_tui.printStyled(.{ .fg = theme.text, .bold = true }, "{d}", .{proc.threads});
            }

            // MEM row
            if (summary_rows >= 2) {
                try app_tui.moveCursor(inner_x, div_y + 1);
                try app_tui.printStyled(.{ .fg = theme.text, .bold = true }, "MEM ", .{});
                try renderMeter(
                    app_tui,
                    meter_width,
                    proc.mem_percent,
                    .{ .fg = memoryColor(theme, proc.mem_percent) },
                    .{ .fg = theme.muted, .dim = true },
                );
                try app_tui.printStyled(.{ .fg = memoryColor(theme, proc.mem_percent), .bold = true }, " {d:5.1}%", .{proc.mem_percent});

                // Disk I/O on same row
                if (stats_x + 20 < x + width) {
                    try app_tui.moveCursor(stats_x, div_y + 1);
                    const dr = formatUnit(proc.disk_read_ps);
                    const dw = formatUnit(proc.disk_write_ps);
                    try app_tui.printStyled(.{ .fg = theme.muted }, "disk ", .{});
                    try app_tui.printStyled(.{ .fg = theme.io_rate }, "R:{d:.1}{s}/s ", .{ dr.value, dr.unit });
                    try app_tui.printStyled(.{ .fg = theme.io_rate }, "W:{d:.1}{s}/s", .{ dw.value, dw.unit });
                }
            }

            // GPU row (if available and space)
            if (summary_rows >= 3) {
                try app_tui.moveCursor(inner_x, div_y + 2);
                try app_tui.printStyled(.{ .fg = theme.muted, .dim = true }, "PID {d}  PPID {d}  ", .{ proc.pid, proc.ppid });
                const cmd = proc.launchCommand();
                if (cmd.len > 0) {
                    const cmd_max = inner_width -| 20;
                    const clip: usize = @min(cmd.len, cmd_max);
                    try app_tui.printStyled(.{ .fg = theme.muted }, "{s}", .{cmd[0..clip]});
                    if (cmd.len > cmd_max) {
                        try app_tui.printStyled(.{ .fg = theme.muted, .dim = true }, "...", .{});
                    }
                }
            }
        } else {
            try app_tui.moveCursor(inner_x, div_y);
            try app_tui.printStyled(.{ .fg = theme.usage_critical }, "process exited", .{});
        }
    }
}
