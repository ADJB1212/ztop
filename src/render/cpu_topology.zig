const std = @import("std");
const tui = @import("../tui.zig");
const sysinfo = @import("../sysinfo.zig");
const config = @import("../config.zig");
const history_mod = @import("../history.zig");
const util = @import("util.zig");
const graphs = @import("graphs.zig");
const Tui = tui.Tui;
const CpuTopology = sysinfo.CpuTopology;
const CpuEfficiencyClass = sysinfo.CpuEfficiencyClass;
const MetricHistory = history_mod.MetricHistory;

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
    // Bitmap: one bit per physical_id (max 256 = MAX_CORES)
    var seen: [sysinfo.common.MAX_CORES / 8]u8 = std.mem.zeroes([sysinfo.common.MAX_CORES / 8]u8);

    for (topology.logical_cores) |logical_core| {
        const pid = logical_core.physical_id;
        if (pid >= sysinfo.common.MAX_CORES) continue;
        const byte_idx = pid / 8;
        const bit: u3 = @intCast(pid % 8);
        if (seen[byte_idx] & (@as(u8, 1) << bit) != 0) continue;
        seen[byte_idx] |= @as(u8, 1) << bit;
        if (row_count >= rows.len) continue;

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
    _ = try util.writeChip(
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
    const core_heat = util.usageColor(theme, core_usage);
    var written: usize = 0;

    written += try util.writeChip(
        app_tui,
        .{
            .fg = theme.selection_fg,
            .bg = efficiencyAccentColor(theme, physical_row.efficiency_class),
            .bold = true,
        },
        efficiencyLabel(physical_row.efficiency_class),
    );
    if (written >= column_width) return;

    try app_tui.bufWrite(" ");
    written += 1;
    if (written >= column_width) return;

    var prefix_buf: [8]u8 = undefined;
    const prefix = std.fmt.bufPrint(&prefix_buf, "C{d:0>2}", .{physical_row.physical_id}) catch "C??";
    try app_tui.printStyled(.{ .fg = theme.text, .bold = true }, "{s}", .{prefix});
    written += prefix.len;
    if (written >= column_width) return;

    try app_tui.bufWrite(" ");
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
    try util.renderMeter(
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
        const heat = util.usageColor(theme, usage);
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
        try app_tui.printStyled(.{ .fg = util.usageColor(theme, cpu.per_core_usage[i]), .bold = cpu.per_core_usage[i] >= 70 }, "{d:5.1}%", .{cpu.per_core_usage[i]});
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
    try app_tui.printStyled(.{ .fg = util.usageColor(theme, cpu.usage_percent), .bold = true }, "{d:4.1}%", .{cpu.usage_percent});
    if (topology.logical_cores.len > 0 and topology.physical_cores > 0) {
        try app_tui.printStyled(.{ .fg = theme.muted }, " ({d} logical / {d} physical)", .{ cpu.cores, topology.physical_cores });
    } else {
        try app_tui.printStyled(.{ .fg = theme.muted }, " ({d} cores)", .{cpu.cores});
    }
    const content_x = box_x + 2;
    const content_width: u16 = box_width -| 4;
    const base_body_y = box_y + 2;
    const base_body_height: u16 = box_height -| 3;
    const graph_height = if (content_width >= 10 and history.len() > 1 and !disable_history) graphs.historyGraphRows(box_height) else 0;
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
            try graphs.renderHistoryGraph(app_tui, theme, content_x, base_body_y, content_width, graph_height, history, .cpu);
        }
        return;
    }

    if (topology.logical_cores.len == 0 or topology.physical_cores == 0) {
        try renderPerCoreUsageArea(app_tui, theme, content_x, base_body_y, content_width, topology_height, cpu);
        if (graph_height > 0) {
            try graphs.renderHistoryGraph(app_tui, theme, content_x, base_body_y + topology_height, content_width, graph_height, history, .cpu);
        }
        return;
    }

    var rows: [sysinfo.common.MAX_CORES]TopologyPhysicalRow = undefined;
    const row_count = collectTopologyRows(topology, &rows);
    if (row_count == 0) {
        try renderPerCoreUsageArea(app_tui, theme, content_x, base_body_y, content_width, topology_height, cpu);
        if (graph_height > 0) {
            try graphs.renderHistoryGraph(app_tui, theme, content_x, base_body_y + topology_height, content_width, graph_height, history, .cpu);
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
            try graphs.renderHistoryGraph(app_tui, theme, content_x, base_body_y + topology_height, content_width, graph_height, history, .cpu);
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
        try graphs.renderHistoryGraph(app_tui, theme, content_x, base_body_y + topology_height, content_width, graph_height, history, .cpu);
    }
}
