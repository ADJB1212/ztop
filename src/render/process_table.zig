const std = @import("std");
const config = @import("../config.zig");
const sysinfo = @import("../sysinfo.zig");
const tui = @import("../tui.zig");
const util = @import("util.zig");
const ProcessColumn = config.ProcessColumn;
const ProcessColumns = config.ProcessColumns;
const Tui = tui.Tui;

pub const ProcessTableLayout = struct {
    columns: [config.process_column_order.len]ProcessColumn = undefined,
    column_widths: [config.process_column_order.len]usize = undefined,
    count: usize = 0,
    name_width: usize = 0,
    name_column_index: usize = 0,
    dropped_count: usize = 0,
    launch_path_extra: usize = 0,
};

pub const min_process_name_width: usize = 8;
pub const default_process_name_width: usize = 20;

pub fn processColumnWidth(column: ProcessColumn) usize {
    return switch (column) {
        .pid => 6,
        .ppid => 6,
        .launch_path => 24,
        .state => 9,
        .cpu => 10,
        .mem => 10,
        .threads => 8,
        .disk_read => 13,
        .disk_write => 13,
        .wakeups => 14,
        .energy => 9,
    };
}

pub fn formatProcessRate(buf: []u8, label: u8, bytes_per_second: u64) []const u8 {
    const rate = util.formatUnit(bytes_per_second);
    const unit_padding = if (rate.unit.len < 2) " " else "";
    return std.fmt.bufPrint(buf, " {c} {d:6.1}{s}{s}/s", .{ label, rate.value, unit_padding, rate.unit }) catch "";
}

/// Very rough estimate of a process's share of the system's total power draw.
fn estimateProcessPowerW(proc: *const sysinfo.ProcStats, cpu_cores: u32, system_power_w: f32) f32 {
    const cores: f32 = @floatFromInt(@max(cpu_cores, 1));
    const cpu_budget = system_power_w * 0.70;
    const per_core_w = cpu_budget / cores;
    const cores_used = @min(proc.cpu_percent, cores * 100.0) / 100.0;
    const cpu_power = std.math.pow(f32, cores_used, 1.15) * per_core_w;

    const mem_power = (@min(proc.mem_percent, 100.0) / 100.0) * system_power_w * 0.10;

    const wake_activity: f32 = @as(f32, @floatFromInt(proc.wakeups_ps)) + @as(f32, @floatFromInt(proc.context_switches_ps)) / 4.0;
    const wake_frac = wake_activity / (wake_activity + 100.0);
    const wake_power = wake_frac * system_power_w * 0.10;

    const disk_bytes_ps: f32 = @floatFromInt(proc.disk_read_ps + proc.disk_write_ps);
    const disk_frac = disk_bytes_ps / (disk_bytes_ps + 5.0 * 1024.0 * 1024.0);
    const disk_power = disk_frac * system_power_w * 0.10;

    return @min(cpu_power + mem_power + wake_power + disk_power, system_power_w);
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

    layout.name_column_index = layout.count;
    for (layout.columns[0..layout.count], 0..) |column, index| {
        layout.column_widths[index] = processColumnWidth(column);
        if (layout.name_column_index == layout.count and column != .pid and column != .ppid) {
            layout.name_column_index = index;
        }
    }

    const remaining = available_width -| fixed_width;
    const has_launch_path = std.mem.indexOfScalar(ProcessColumn, layout.columns[0..layout.count], .launch_path) != null;

    if (has_launch_path and remaining > default_process_name_width) {
        layout.name_width = default_process_name_width;
        layout.launch_path_extra = remaining - default_process_name_width;
        for (layout.columns[0..layout.count], 0..) |column, index| {
            if (column == .launch_path) {
                layout.column_widths[index] += layout.launch_path_extra;
                break;
            }
        }
    } else {
        layout.name_width = remaining;
    }

    return layout;
}

fn renderProcessNameCell(
    app_tui: *Tui,
    style: Tui.Style,
    width: usize,
    prefix: []const u8,
    prefix_width: usize,
    name: []const u8,
) !void {
    if (width == 0) return;

    if (prefix_width >= width) {
        const clipped_len = if (width > 2 and name.len > width - 2) width - 2 else @min(name.len, width);
        try app_tui.writeStyled(style, name[0..clipped_len]);
        if (width > 2 and name.len > clipped_len) {
            try app_tui.bufWrite("..");
        }
        const used = clipped_len + if (width > 2 and name.len > clipped_len) @as(usize, 2) else 0;
        try app_tui.writeStyledSpaces(style, width - used);
        return;
    }

    const available_name_width = width - prefix_width;
    const clipped_name_len = if (available_name_width > 2 and name.len > available_name_width)
        available_name_width - 2
    else
        @min(name.len, available_name_width);

    try app_tui.writeStyled(style, prefix);
    try app_tui.bufWrite(name[0..clipped_name_len]);
    var used = prefix_width + clipped_name_len;

    if (name.len > clipped_name_len and available_name_width > 2) {
        try app_tui.bufWrite("..");
        used += 2;
    }

    try app_tui.writeStyledSpaces(style, width - used);
}

pub fn renderProcessRow(
    app_tui: *Tui,
    theme: *const config.Theme,
    layout: *const ProcessTableLayout,
    proc: *const sysinfo.ProcStats,
    is_selected: bool,
    prefix: []const u8,
    prefix_width: usize,
    cpu_cores: u32,
    system_power_w: ?f32,
) !void {
    var buf: [48]u8 = undefined;
    const pid_style: Tui.Style = if (is_selected) .{ .bg = theme.selection_bg, .fg = theme.selection_fg } else .{ .fg = theme.muted };
    const ppid_style: Tui.Style = if (is_selected) .{ .bg = theme.selection_bg, .fg = theme.selection_fg } else .{ .fg = theme.muted };
    const name_style: Tui.Style = if (is_selected) .{ .bg = theme.selection_bg, .fg = theme.selection_fg } else .{ .fg = theme.text };

    for (layout.columns[0..layout.count], 0..) |column, column_index| {
        if (column_index == layout.name_column_index) {
            try renderProcessNameCell(app_tui, name_style, layout.name_width, prefix, prefix_width, proc.name());
        }
        const column_width = layout.column_widths[column_index];

        switch (column) {
            .pid => {
                const text = std.fmt.bufPrint(&buf, "{d}", .{proc.pid}) catch "";
                try util.writeAlignedCell(app_tui, pid_style, column_width, .left, text);
            },
            .ppid => {
                const text = std.fmt.bufPrint(&buf, "{d}", .{proc.ppid}) catch "";
                try util.writeAlignedCell(app_tui, ppid_style, column_width, .right, text);
            },
            .launch_path => {
                const style: Tui.Style = if (is_selected) .{ .bg = theme.selection_bg, .fg = theme.muted } else .{ .fg = theme.muted };
                const launch = proc.launchCommand();
                const text = if (launch.len > 0) launch else "-";
                try util.writeAlignedCell(app_tui, style, column_width, .left, text);
            },
            .state => {
                const style: Tui.Style = if (is_selected)
                    .{ .bg = theme.selection_bg, .fg = util.procStateColor(theme.*, proc.state) }
                else
                    .{ .fg = util.procStateColor(theme.*, proc.state) };
                try util.writeAlignedCell(app_tui, style, column_width, .left, util.procStateLabel(proc.state));
            },
            .cpu => {
                const text = std.fmt.bufPrint(&buf, "{d:4.1}% CPU", .{proc.cpu_percent}) catch "";
                const style: Tui.Style = if (is_selected)
                    .{ .bg = theme.selection_bg, .fg = util.usageColor(theme.*, proc.cpu_percent), .bold = proc.cpu_percent >= 70 }
                else
                    .{ .fg = util.usageColor(theme.*, proc.cpu_percent), .bold = proc.cpu_percent >= 70 };
                try util.writeAlignedCell(app_tui, style, column_width, .right, text);
            },
            .mem => {
                const text = std.fmt.bufPrint(&buf, "{d:4.1}% MEM", .{proc.mem_percent}) catch "";
                const style: Tui.Style = if (is_selected)
                    .{ .bg = theme.selection_bg, .fg = util.memoryColor(theme.*, proc.mem_percent), .bold = proc.mem_percent >= 10 }
                else
                    .{ .fg = util.memoryColor(theme.*, proc.mem_percent), .bold = proc.mem_percent >= 10 };
                try util.writeAlignedCell(app_tui, style, column_width, .right, text);
            },
            .threads => {
                const text = std.fmt.bufPrint(&buf, "{d} THR", .{proc.threads}) catch "";
                const style: Tui.Style = if (is_selected) .{ .bg = theme.selection_bg, .fg = theme.brand } else .{ .fg = theme.brand };
                try util.writeAlignedCell(app_tui, style, column_width, .right, text);
            },
            .disk_read => {
                const text = formatProcessRate(&buf, 'R', proc.disk_read_ps);
                const style: Tui.Style = if (is_selected) .{ .bg = theme.selection_bg, .fg = theme.disk_title } else .{ .fg = theme.disk_title };
                try util.writeAlignedCell(app_tui, style, column_width, .right, text);
            },
            .disk_write => {
                const text = formatProcessRate(&buf, 'W', proc.disk_write_ps);
                const style: Tui.Style = if (is_selected) .{ .bg = theme.selection_bg, .fg = theme.io_rate } else .{ .fg = theme.io_rate };
                try util.writeAlignedCell(app_tui, style, column_width, .right, text);
            },
            .wakeups => {
                const text = std.fmt.bufPrint(&buf, "W{d:5} C{d:5}", .{ proc.wakeups_ps, proc.context_switches_ps }) catch "";
                const activity = @as(f32, @floatFromInt(proc.wakeups_ps / 20 + proc.context_switches_ps / 40));
                const style: Tui.Style = if (is_selected)
                    .{ .bg = theme.selection_bg, .fg = util.usageColor(theme.*, activity) }
                else
                    .{ .fg = util.usageColor(theme.*, activity) };
                try util.writeAlignedCell(app_tui, style, column_width, .right, text);
            },
            .energy => {
                const style: Tui.Style = if (is_selected)
                    .{ .bg = theme.selection_bg, .fg = theme.battery_title }
                else
                    .{ .fg = theme.battery_title };
                if (system_power_w) |watts| {
                    const est_w = estimateProcessPowerW(proc, cpu_cores, watts);
                    const text = std.fmt.bufPrint(&buf, "{d:.2}W", .{est_w}) catch "";
                    try util.writeAlignedCell(app_tui, style, column_width, .right, text);
                } else {
                    try util.writeAlignedCell(app_tui, style, column_width, .right, "--");
                }
            },
        }
    }

    if (layout.name_column_index == layout.count) {
        try renderProcessNameCell(app_tui, name_style, layout.name_width, prefix, prefix_width, proc.name());
    }
}
