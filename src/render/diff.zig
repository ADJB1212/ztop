const std = @import("std");
const tui = @import("../tui.zig");
const config = @import("../config.zig");
const timeline_mod = @import("../timeline.zig");
const util = @import("util.zig");
const Tui = tui.Tui;

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
        try app_tui.printStyled(.{ .fg = util.usageColor(theme, diff.cpu_before) }, "{d:5.1}%", .{diff.cpu_before});
        try app_tui.printStyled(.{ .fg = theme.muted }, " → ", .{});
        try app_tui.printStyled(.{ .fg = util.usageColor(theme, diff.cpu_after) }, "{d:5.1}%", .{diff.cpu_after});
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
        try app_tui.printStyled(.{ .fg = util.memoryColor(theme, diff.mem_before_pct) }, "{d:5.1}%", .{diff.mem_before_pct});
        try app_tui.printStyled(.{ .fg = theme.muted }, " → ", .{});
        try app_tui.printStyled(.{ .fg = util.memoryColor(theme, diff.mem_after_pct) }, "{d:5.1}%", .{diff.mem_after_pct});
        const mem_delta = diff.mem_after_pct - diff.mem_before_pct;
        const mem_sign: []const u8 = if (mem_delta >= 0) "+" else "-";
        try app_tui.printStyled(.{ .fg = theme.muted }, "  ", .{});
        try app_tui.printStyled(.{ .fg = deltaColor(theme, diff.mem_after_pct, diff.mem_before_pct), .bold = true }, "{s} {s}{d:.1}%", .{ deltaSign(diff.mem_after_pct, diff.mem_before_pct), mem_sign, @abs(mem_delta) });
        row += 1;
    }

    // Disk I/O
    if (row < max_row) {
        const rb = util.formatUnit(diff.disk_read_before);
        const ra = util.formatUnit(diff.disk_read_after);
        try app_tui.moveCursor(inner_x, row);
        try app_tui.printStyled(.{ .fg = theme.text, .dim = true }, "Disk  ", .{});
        try app_tui.printStyled(.{ .fg = theme.disk_title }, "R ", .{});
        try app_tui.printStyled(.{ .fg = theme.text }, "{d:4.1}{s}/s", .{ rb.value, rb.unit });
        try app_tui.printStyled(.{ .fg = theme.muted }, "→", .{});
        try app_tui.printStyled(.{ .fg = theme.text }, "{d:4.1}{s}/s", .{ ra.value, ra.unit });
        try app_tui.printStyled(.{ .fg = rateDeltaColor(theme, diff.disk_read_after, diff.disk_read_before) }, " {s}", .{rateDeltaSign(diff.disk_read_after, diff.disk_read_before)});

        if (inner_width >= 50) {
            const wb = util.formatUnit(diff.disk_write_before);
            const wa = util.formatUnit(diff.disk_write_after);
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
        const rxb = util.formatUnit(diff.net_rx_before);
        const rxa = util.formatUnit(diff.net_rx_after);
        try app_tui.moveCursor(inner_x, row);
        try app_tui.printStyled(.{ .fg = theme.text, .dim = true }, "Net   ", .{});
        try app_tui.printStyled(.{ .fg = theme.network_title }, "↓ ", .{});
        try app_tui.printStyled(.{ .fg = theme.text }, "{d:4.1}{s}/s", .{ rxb.value, rxb.unit });
        try app_tui.printStyled(.{ .fg = theme.muted }, "→", .{});
        try app_tui.printStyled(.{ .fg = theme.text }, "{d:4.1}{s}/s", .{ rxa.value, rxa.unit });
        try app_tui.printStyled(.{ .fg = rateDeltaColor(theme, diff.net_rx_after, diff.net_rx_before) }, " {s}", .{rateDeltaSign(diff.net_rx_after, diff.net_rx_before)});

        if (inner_width >= 50) {
            const txb = util.formatUnit(diff.net_tx_before);
            const txa = util.formatUnit(diff.net_tx_after);
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
                    try app_tui.bufWrite(" ");
                }
            }

            // CPU change
            switch (entry.kind) {
                .appeared => {
                    try app_tui.printStyled(.{ .fg = theme.muted }, "     → ", .{});
                    try app_tui.printStyled(.{ .fg = util.usageColor(theme, entry.cpu_after), .bold = true }, "{d:5.1}%", .{entry.cpu_after});
                },
                .disappeared => {
                    try app_tui.printStyled(.{ .fg = util.usageColor(theme, entry.cpu_before) }, "{d:5.1}%", .{entry.cpu_before});
                    try app_tui.printStyled(.{ .fg = theme.muted }, " →      ", .{});
                },
                .changed => {
                    try app_tui.printStyled(.{ .fg = util.usageColor(theme, entry.cpu_before) }, "{d:5.1}%", .{entry.cpu_before});
                    try app_tui.printStyled(.{ .fg = theme.muted }, "→", .{});
                    try app_tui.printStyled(.{ .fg = util.usageColor(theme, entry.cpu_after) }, "{d:5.1}%", .{entry.cpu_after});
                },
            }

            // MEM change (if width allows)
            if (inner_width >= 50) {
                try app_tui.printStyled(.{ .fg = theme.muted }, " ", .{});
                switch (entry.kind) {
                    .appeared => {
                        try app_tui.printStyled(.{ .fg = theme.muted }, "     → ", .{});
                        try app_tui.printStyled(.{ .fg = util.memoryColor(theme, entry.mem_after) }, "{d:5.1}%", .{entry.mem_after});
                    },
                    .disappeared => {
                        try app_tui.printStyled(.{ .fg = util.memoryColor(theme, entry.mem_before) }, "{d:5.1}%", .{entry.mem_before});
                        try app_tui.printStyled(.{ .fg = theme.muted }, " →      ", .{});
                    },
                    .changed => {
                        try app_tui.printStyled(.{ .fg = util.memoryColor(theme, entry.mem_before) }, "{d:5.1}%", .{entry.mem_before});
                        try app_tui.printStyled(.{ .fg = theme.muted }, "→", .{});
                        try app_tui.printStyled(.{ .fg = util.memoryColor(theme, entry.mem_after) }, "{d:5.1}%", .{entry.mem_after});
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
