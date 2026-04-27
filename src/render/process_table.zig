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
    count: usize = 0,
    name_width: usize = 0,
    dropped_count: usize = 0,
};

pub const min_process_name_width: usize = 8;

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
        .wakeups => 14,
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
            try app_tui.writeStyled(style, "..");
        }
        const used = clipped_len + if (width > 2 and name.len > clipped_len) @as(usize, 2) else 0;
        for (used..width) |_| try app_tui.writeStyled(style, " ");
        return;
    }

    const available_name_width = width - prefix_width;
    const clipped_name_len = if (available_name_width > 2 and name.len > available_name_width)
        available_name_width - 2
    else
        @min(name.len, available_name_width);

    try app_tui.writeStyled(style, prefix);
    try app_tui.writeStyled(style, name[0..clipped_name_len]);
    var used = prefix_width + clipped_name_len;

    if (name.len > clipped_name_len and available_name_width > 2) {
        try app_tui.writeStyled(style, "..");
        used += 2;
    }

    for (used..width) |_| try app_tui.writeStyled(style, " ");
}

pub fn renderProcessRow(
    app_tui: *Tui,
    theme: config.Theme,
    layout: ProcessTableLayout,
    proc: sysinfo.ProcStats,
    is_selected: bool,
    prefix: []const u8,
    prefix_width: usize,
) !void {
    var buf: [48]u8 = undefined;
    const pid_style: Tui.Style = if (is_selected) .{ .bg = theme.selection_bg, .fg = theme.selection_fg } else .{ .fg = theme.muted };
    const ppid_style: Tui.Style = if (is_selected) .{ .bg = theme.selection_bg, .fg = theme.selection_fg } else .{ .fg = theme.muted };
    const name_style: Tui.Style = if (is_selected) .{ .bg = theme.selection_bg, .fg = theme.selection_fg } else .{ .fg = theme.text };

    var rendered_name = false;
    for (layout.columns[0..layout.count]) |column| {
        if (!rendered_name and switch (column) {
            .state, .cpu, .mem, .threads, .disk_read, .disk_write, .wakeups => true,
            .pid, .ppid => false,
        }) {
            try renderProcessNameCell(app_tui, name_style, layout.name_width, prefix, prefix_width, proc.name());
            rendered_name = true;
        }

        switch (column) {
            .pid => {
                const text = std.fmt.bufPrint(&buf, "{d}", .{proc.pid}) catch "";
                try util.writeAlignedCell(app_tui, pid_style, processColumnWidth(.pid), .left, text);
            },
            .ppid => {
                const text = std.fmt.bufPrint(&buf, "{d}", .{proc.ppid}) catch "";
                try util.writeAlignedCell(app_tui, ppid_style, processColumnWidth(.ppid), .right, text);
            },
            .state => {
                const style: Tui.Style = if (is_selected)
                    .{ .bg = theme.selection_bg, .fg = util.procStateColor(theme, proc.state) }
                else
                    .{ .fg = util.procStateColor(theme, proc.state) };
                try util.writeAlignedCell(app_tui, style, processColumnWidth(.state), .left, util.procStateLabel(proc.state));
            },
            .cpu => {
                const text = std.fmt.bufPrint(&buf, "{d:4.1}% CPU", .{proc.cpu_percent}) catch "";
                const style: Tui.Style = if (is_selected)
                    .{ .bg = theme.selection_bg, .fg = util.usageColor(theme, proc.cpu_percent), .bold = proc.cpu_percent >= 70 }
                else
                    .{ .fg = util.usageColor(theme, proc.cpu_percent), .bold = proc.cpu_percent >= 70 };
                try util.writeAlignedCell(app_tui, style, processColumnWidth(.cpu), .right, text);
            },
            .mem => {
                const text = std.fmt.bufPrint(&buf, "{d:4.1}% MEM", .{proc.mem_percent}) catch "";
                const style: Tui.Style = if (is_selected)
                    .{ .bg = theme.selection_bg, .fg = util.memoryColor(theme, proc.mem_percent), .bold = proc.mem_percent >= 10 }
                else
                    .{ .fg = util.memoryColor(theme, proc.mem_percent), .bold = proc.mem_percent >= 10 };
                try util.writeAlignedCell(app_tui, style, processColumnWidth(.mem), .right, text);
            },
            .threads => {
                const text = std.fmt.bufPrint(&buf, "{d} THR", .{proc.threads}) catch "";
                const style: Tui.Style = if (is_selected) .{ .bg = theme.selection_bg, .fg = theme.brand } else .{ .fg = theme.brand };
                try util.writeAlignedCell(app_tui, style, processColumnWidth(.threads), .right, text);
            },
            .disk_read => {
                const rate = util.formatUnit(proc.disk_read_ps);
                const text = std.fmt.bufPrint(&buf, "R {d:4.1}{s}/s", .{ rate.value, rate.unit }) catch "";
                const style: Tui.Style = if (is_selected) .{ .bg = theme.selection_bg, .fg = theme.disk_title } else .{ .fg = theme.disk_title };
                try util.writeAlignedCell(app_tui, style, processColumnWidth(.disk_read), .right, text);
            },
            .disk_write => {
                const rate = util.formatUnit(proc.disk_write_ps);
                const text = std.fmt.bufPrint(&buf, "W {d:4.1}{s}/s", .{ rate.value, rate.unit }) catch "";
                const style: Tui.Style = if (is_selected) .{ .bg = theme.selection_bg, .fg = theme.io_rate } else .{ .fg = theme.io_rate };
                try util.writeAlignedCell(app_tui, style, processColumnWidth(.disk_write), .right, text);
            },
            .wakeups => {
                const text = std.fmt.bufPrint(&buf, "W{d:5} C{d:5}", .{ proc.wakeups_ps, proc.context_switches_ps }) catch "";
                const activity = @as(f32, @floatFromInt(proc.wakeups_ps / 20 + proc.context_switches_ps / 40));
                const style: Tui.Style = if (is_selected)
                    .{ .bg = theme.selection_bg, .fg = util.usageColor(theme, activity) }
                else
                    .{ .fg = util.usageColor(theme, activity) };
                try util.writeAlignedCell(app_tui, style, processColumnWidth(.wakeups), .right, text);
            },
        }
    }

    if (!rendered_name) {
        try renderProcessNameCell(app_tui, name_style, layout.name_width, prefix, prefix_width, proc.name());
    }
}
