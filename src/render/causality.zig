const std = @import("std");
const tui = @import("../tui.zig");
const sysinfo = @import("../sysinfo.zig");
const config = @import("../config.zig");
const util = @import("util.zig");
const Tui = tui.Tui;

fn writeProtoPill(app_tui: *Tui, style: Tui.Style, label: []const u8) !void {
    const written = try util.writePill(app_tui, style, label);
    const total: usize = 6;
    if (written < total) {
        for (0..total - written) |_| try app_tui.bufWrite(" ");
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
            const cpu_style: Tui.Style = .{ .fg = util.usageColor(theme, proc.cpu_percent), .bold = proc.cpu_percent >= 50 };
            try app_tui.printStyled(cpu_style, " {d:5.1}%", .{proc.cpu_percent});

            // MEM%
            try app_tui.printStyled(.{ .fg = util.memoryColor(theme, proc.mem_percent) }, " {d:5.1}%", .{proc.mem_percent});
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
            try writeProtoPill(app_tui, .{ .bg = proto_color, .fg = theme.selection_fg, .bold = true }, @tagName(conn.protocol));

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
                    try app_tui.bufWrite(" ");
                    _ = try util.writePill(app_tui, .{ .bg = state_color, .fg = theme.selection_fg }, state_str);
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
            try util.renderMeter(
                app_tui,
                meter_width,
                proc.cpu_percent,
                .{ .fg = util.usageColor(theme, proc.cpu_percent) },
                .{ .fg = theme.muted, .dim = true },
            );
            try app_tui.printStyled(.{ .fg = util.usageColor(theme, proc.cpu_percent), .bold = true }, " {d:5.1}%", .{proc.cpu_percent});

            // Stats on same row, right side
            const stats_x = inner_x + meter_width + 14;
            if (stats_x + 20 < x + width) {
                try app_tui.moveCursor(stats_x, div_y);
                try app_tui.printStyled(.{ .fg = util.procStateColor(theme, proc.state) }, "{s}", .{util.procStateLabel(proc.state)});
                try app_tui.printStyled(.{ .fg = theme.muted }, "  threads:", .{});
                try app_tui.printStyled(.{ .fg = theme.text, .bold = true }, "{d}", .{proc.threads});
            }

            // MEM row
            if (summary_rows >= 2) {
                try app_tui.moveCursor(inner_x, div_y + 1);
                try app_tui.printStyled(.{ .fg = theme.text, .bold = true }, "MEM ", .{});
                try util.renderMeter(
                    app_tui,
                    meter_width,
                    proc.mem_percent,
                    .{ .fg = util.memoryColor(theme, proc.mem_percent) },
                    .{ .fg = theme.muted, .dim = true },
                );
                try app_tui.printStyled(.{ .fg = util.memoryColor(theme, proc.mem_percent), .bold = true }, " {d:5.1}%", .{proc.mem_percent});

                // Disk I/O on same row
                if (stats_x + 20 < x + width) {
                    try app_tui.moveCursor(stats_x, div_y + 1);
                    const dr = util.formatUnit(proc.disk_read_ps);
                    const dw = util.formatUnit(proc.disk_write_ps);
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
