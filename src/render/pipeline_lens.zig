const std = @import("std");
const tui = @import("../tui.zig");
const sysinfo = @import("../sysinfo.zig");
const config = @import("../config.zig");
const util = @import("util.zig");
const process_commands = @import("../process_commands.zig");
const Tui = tui.Tui;

const HEADER_IDX: usize = std.math.maxInt(usize);

const FlatRow = struct {
    group_idx: usize,
    child_idx: usize,
};

const MAX_ROWS = process_commands.MAX_PIPELINE_GROUPS * (process_commands.MAX_PIPELINE_CHILDREN + 1);

pub fn renderPipelineLensView(
    app_tui: *Tui,
    theme: config.Theme,
    x: u16,
    y: u16,
    width: u16,
    height: u16,
    allocator: std.mem.Allocator,
    cached_procs: []const sysinfo.ProcStats,
    selected_idx: usize,
    scroll_offset: *usize,
) !usize {
    if (height < 4 or width < 30) return 0;

    try app_tui.drawBoxStyled(
        x,
        y,
        width,
        height,
        "Build/Test Pipeline Lens",
        .{ .fg = theme.border },
        .{ .fg = theme.process_title, .bold = true },
    );

    const inner_x = x + 2;
    const inner_width = width -| 4;
    const inner_height = height -| 2;
    if (inner_width < 10 or inner_height < 2) return 0;

    var groups_buf: [process_commands.MAX_PIPELINE_GROUPS]process_commands.PipelineGroup = undefined;
    const group_count = process_commands.buildPipelineGroups(allocator, cached_procs, &groups_buf);
    const groups = groups_buf[0..group_count];

    if (group_count == 0) {
        try app_tui.moveCursor(inner_x, y + 2);
        try app_tui.printStyled(.{ .fg = theme.muted, .dim = true }, "No active build or test processes detected.", .{});
        if (inner_height >= 3) {
            try app_tui.moveCursor(inner_x, y + 3);
            try app_tui.printStyled(.{ .fg = theme.muted, .dim = true }, "Detects: make, cargo, cmake, ninja, go, zig, npm, pytest...", .{});
        }
        return 0;
    }

    // Build flat row list: one header row per group, then child rows
    var rows_buf: [MAX_ROWS]FlatRow = undefined;
    var row_count: usize = 0;
    for (groups, 0..) |g, gi| {
        if (row_count >= rows_buf.len) break;
        rows_buf[row_count] = .{ .group_idx = gi, .child_idx = HEADER_IDX };
        row_count += 1;
        for (0..g.child_count) |ci| {
            if (row_count >= rows_buf.len) break;
            rows_buf[row_count] = .{ .group_idx = gi, .child_idx = ci };
            row_count += 1;
        }
    }

    const visible_rows = if (inner_height > 1) inner_height - 1 else inner_height;
    const clamped_sel = if (row_count > 0) @min(selected_idx, row_count - 1) else 0;
    if (clamped_sel < scroll_offset.*) {
        scroll_offset.* = clamped_sel;
    } else if (row_count > 0 and clamped_sel >= scroll_offset.* + visible_rows) {
        scroll_offset.* = clamped_sel - visible_rows + 1;
    }

    const cpu_w: usize = 10;
    const mem_w: usize = 8;
    const disk_w: usize = 12;
    const fixed_w = cpu_w + mem_w + disk_w;
    const name_w = if (inner_width > fixed_w) inner_width - fixed_w else inner_width;

    for (0..visible_rows) |row| {
        const idx = scroll_offset.* + row;
        if (idx >= row_count) break;

        const flat = rows_buf[idx];
        const g = &groups[flat.group_idx];
        const is_sel = idx == clamped_sel;
        const row_y = y + 1 + @as(u16, @intCast(row));

        try app_tui.moveCursor(inner_x, row_y);

        if (is_sel) {
            try app_tui.setStyle(.{ .bg = theme.selection_bg });
            for (0..inner_width) |_| try app_tui.bufWrite(" ");
            try app_tui.moveCursor(inner_x, row_y);
        }

        if (flat.child_idx == HEADER_IDX) {
            var name_buf: [96]u8 = undefined;
            const grp_name = std.fmt.bufPrint(&name_buf, "{s} (PID {d})", .{ g.rootName(), g.root_pid }) catch g.rootName();
            try util.writeAlignedCell(app_tui, .{ .fg = theme.process_title, .bold = true }, name_w, .left, grp_name);
            try renderStats(app_tui, theme, g.total_cpu, g.total_mem, g.total_disk_read_ps + g.total_disk_write_ps, cpu_w, mem_w, disk_w);
        } else {
            const ci = flat.child_idx;
            const child_pid = g.child_pids[ci];
            const stage = g.child_stages[ci];

            var child_cpu: f32 = 0;
            var child_mem: f32 = 0;
            var child_disk: u64 = 0;
            var child_name: []const u8 = "?";
            for (cached_procs) |p| {
                if (p.pid == child_pid) {
                    child_cpu = p.cpu_percent;
                    child_mem = p.mem_percent;
                    child_disk = p.disk_read_ps + p.disk_write_ps;
                    child_name = p.name();
                    break;
                }
            }

            const is_last_child = ci + 1 == g.child_count;
            const branch = if (is_last_child) "└─ " else "├─ ";
            const stage_color = stageColor(theme, stage);
            const child_style: Tui.Style = .{ .fg = stage_color };
            const pill_label = stage.label();
            const pill_width: usize = pill_label.len + 2;
            const branch_width: usize = 3;

            if (name_w >= branch_width + pill_width + 4) {
                try app_tui.printStyled(child_style, "{s}", .{branch});
                _ = try util.writePill(app_tui, .{ .bg = stage_color, .fg = theme.selection_fg, .bold = true }, pill_label);
                try app_tui.bufWrite(" ");
                const name_avail = name_w -| (branch_width + pill_width + 1);
                try util.writeAlignedCell(app_tui, child_style, name_avail, .left, child_name);
            } else {
                var label_buf: [96]u8 = undefined;
                const row_label = std.fmt.bufPrint(&label_buf, "{s}[{s}] {s}", .{ branch, pill_label, child_name }) catch child_name;
                try util.writeAlignedCell(app_tui, child_style, name_w, .left, row_label);
            }
            try renderStats(app_tui, theme, child_cpu, child_mem, child_disk, cpu_w, mem_w, disk_w);
        }

        if (is_sel) try app_tui.resetStyle();
    }

    // Summary line at bottom of box
    var child_total: usize = 0;
    for (groups) |g| child_total += g.child_count;
    try app_tui.moveCursor(inner_x, y + height -| 2);
    try app_tui.printStyled(
        .{ .fg = theme.muted, .dim = true },
        "{d} group{s} · {d} child process{s}  [P] close",
        .{
            group_count,
            if (group_count == 1) @as([]const u8, "") else "s",
            child_total,
            if (child_total == 1) @as([]const u8, "") else "es",
        },
    );

    return row_count;
}

fn stageColor(theme: config.Theme, stage: process_commands.BuildStage) Tui.Color {
    return switch (stage) {
        .compile => theme.cpu_title,
        .link => theme.io_rate,
        .test_run => theme.usage_good,
        .package => theme.usage_warn,
        .other => theme.muted,
    };
}

fn renderStats(
    app_tui: *Tui,
    theme: config.Theme,
    cpu: f32,
    mem: f32,
    disk_bytes_ps: u64,
    cpu_w: usize,
    mem_w: usize,
    disk_w: usize,
) !void {
    var buf: [32]u8 = undefined;

    const cpu_str = std.fmt.bufPrint(&buf, "{d:.1}%", .{cpu}) catch "?.?%";
    try util.writeAlignedCell(app_tui, .{ .fg = util.usageColor(theme, cpu) }, cpu_w, .right, cpu_str);

    const mem_str = std.fmt.bufPrint(&buf, "{d:.1}%", .{mem}) catch "?.?%";
    try util.writeAlignedCell(app_tui, .{ .fg = util.memoryColor(theme, mem) }, mem_w, .right, mem_str);

    if (disk_bytes_ps > 0) {
        const unit = util.formatUnit(disk_bytes_ps);
        const disk_str = std.fmt.bufPrint(&buf, "{d:.1}{s}/s", .{ unit.value, unit.unit }) catch "";
        try util.writeAlignedCell(app_tui, .{ .fg = theme.disk_title }, disk_w, .right, disk_str);
    } else {
        try util.writeAlignedCell(app_tui, .{}, disk_w, .right, "");
    }
}
