const std = @import("std");
const ztop = @import("ztop");
const Tui = ztop.tui.Tui;
const SysInfo = ztop.sysinfo.SysInfo;
const CpuTopology = ztop.sysinfo.CpuTopology;
const CpuEfficiencyClass = ztop.sysinfo.CpuEfficiencyClass;

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

const TopologyRowText = struct {
    text: []const u8,
    hot: bool,
};

fn digitsU16(value: u16) usize {
    var digits: usize = 1;
    var remaining = value;
    while (remaining >= 10) {
        remaining /= 10;
        digits += 1;
    }
    return digits;
}

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
    var stream = std.io.fixedBufferStream(buf);
    const writer = stream.writer();
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

    return buf[0..stream.pos];
}

fn buildTopologyRowText(buf: []u8, row: TopologyPhysicalRow, cpu: ztop.sysinfo.CpuStats, topology: CpuTopology) TopologyRowText {
    var logical_indices: [ztop.sysinfo.common.MAX_CORES]usize = undefined;
    var logical_count: usize = 0;

    for (topology.logical_cores, 0..) |logical_core, idx| {
        if (logical_core.physical_id != row.physical_id or logical_count >= logical_indices.len) continue;
        logical_indices[logical_count] = idx;
        logical_count += 1;
    }

    std.mem.sort(usize, logical_indices[0..logical_count], topology, struct {
        fn lessThan(topology_ctx: CpuTopology, a_idx: usize, b_idx: usize) bool {
            const a = topology_ctx.logical_cores[a_idx];
            const b = topology_ctx.logical_cores[b_idx];
            if (a.thread_index != b.thread_index) return a.thread_index < b.thread_index;
            return a.logical_id < b.logical_id;
        }
    }.lessThan);

    var stream = std.io.fixedBufferStream(buf);
    const writer = stream.writer();
    writer.print("C{d:0>2} ", .{row.physical_id}) catch {};

    var hot = false;
    for (logical_indices[0..logical_count], 0..) |logical_idx, thread_idx| {
        const logical_core = topology.logical_cores[logical_idx];
        const usage = if (@as(usize, logical_core.logical_id) < cpu.per_core_usage.len)
            cpu.per_core_usage[logical_core.logical_id]
        else
            0.0;
        const usage_int: u16 = @intFromFloat(@round(@max(usage, 0.0)));
        hot = hot or usage >= 70;

        if (thread_idx > 0) writer.writeAll(" ") catch {};
        writer.print("{d:0>2}:{d:>3}", .{ logical_core.logical_id, usage_int }) catch {};
    }

    return .{
        .text = buf[0..stream.pos],
        .hot = hot,
    };
}

fn renderPerCoreUsageBody(app_tui: *Tui, theme: ztop.config.Theme, box_x: u16, box_y: u16, box_width: u16, box_height: u16, cpu: ztop.sysinfo.CpuStats) !void {
    if (box_height <= 3 or cpu.per_core_usage.len == 0) return;

    const rows_available: usize = box_height - 3;
    const columns: usize = if (box_width >= 40 and cpu.per_core_usage.len > rows_available) 2 else 1;
    const entries_per_column = rows_available;
    const visible_cores = @min(cpu.per_core_usage.len, entries_per_column * columns);
    const column_width: u16 = if (columns == 1) box_width - 4 else box_width / 2;

    for (0..visible_cores) |i| {
        const row = i % entries_per_column;
        const column = i / entries_per_column;
        const x = box_x + 2 + @as(u16, @intCast(column)) * column_width;
        const y = box_y + 2 + @as(u16, @intCast(row));
        try app_tui.moveCursor(x, y);
        try app_tui.printStyled(.{ .fg = theme.muted }, "CPU{d:>2}: ", .{i});
        try app_tui.printStyled(.{ .fg = usageColor(theme, cpu.per_core_usage[i]), .bold = cpu.per_core_usage[i] >= 70 }, "{d:5.1}%", .{cpu.per_core_usage[i]});
    }
}

pub fn renderCpuTopologyBox(app_tui: *Tui, theme: ztop.config.Theme, box_x: u16, box_y: u16, box_width: u16, box_height: u16, cpu: ztop.sysinfo.CpuStats, topology: CpuTopology) !void {
    const title = if (topology.logical_cores.len > 0) "CPU Topology" else "CPU";
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

    if (box_height <= 3 or topology.logical_cores.len == 0 or topology.physical_cores == 0) {
        try renderPerCoreUsageBody(app_tui, theme, box_x, box_y, box_width, box_height, cpu);
        return;
    }

    const body_height: usize = box_height - 3;
    const content_width: usize = box_width - 4;
    if (body_height == 0 or content_width == 0) {
        return;
    }

    var rows: [ztop.sysinfo.common.MAX_CORES]TopologyPhysicalRow = undefined;
    const row_count = collectTopologyRows(topology, &rows);
    if (row_count == 0) {
        try renderPerCoreUsageBody(app_tui, theme, box_x, box_y, box_width, box_height, cpu);
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

    const columns = @max(std.math.divCeil(usize, line_count, body_height) catch 1, 1);
    const column_width = if (columns > 0) content_width / columns else content_width;
    if (column_width == 0) {
        try renderPerCoreUsageBody(app_tui, theme, box_x, box_y, box_width, box_height, cpu);
        return;
    }

    var max_row_width: usize = 0;
    var header_buf: [64]u8 = undefined;
    for (rows[0..row_count]) |row| {
        const header = buildTopologyHeaderText(&header_buf, row, topology);
        max_row_width = @max(max_row_width, header.len);

        var threads: usize = 0;
        for (topology.logical_cores) |logical_core| {
            if (logical_core.physical_id == row.physical_id) threads += 1;
        }
        const physical_digits = digitsU16(row.physical_id);
        const logical_digits = digitsU16(@intCast(cpu.cores -| 1));
        const row_width = physical_digits + 1 + threads * (logical_digits + 5);
        max_row_width = @max(max_row_width, row_width);
    }

    if (column_width < max_row_width) {
        try renderPerCoreUsageBody(app_tui, theme, box_x, box_y, box_width, box_height, cpu);
        return;
    }

    for (lines[0..line_count], 0..) |line, idx| {
        const column = idx / body_height;
        const row = idx % body_height;
        const x = box_x + 2 + @as(u16, @intCast(column * column_width));
        const y = box_y + 2 + @as(u16, @intCast(row));
        try app_tui.moveCursor(x, y);

        switch (line) {
            .header => |header_row| {
                const label = buildTopologyHeaderText(&header_buf, header_row, topology);
                const visible = label[0..@min(label.len, column_width)];
                try app_tui.printStyled(.{ .fg = theme.cpu_title, .bold = true }, "{s}", .{visible});
            },
            .row => |physical_row| {
                var row_buf: [256]u8 = undefined;
                const row_text = buildTopologyRowText(&row_buf, physical_row, cpu, topology);
                const visible = row_text.text[0..@min(row_text.text.len, column_width)];
                const row_style: Tui.Style = if (row_text.hot)
                    .{ .fg = theme.text, .bold = true }
                else
                    .{ .fg = theme.text };
                try app_tui.printStyled(row_style, "{s}", .{visible});
            },
        }
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
