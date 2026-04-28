const std = @import("std");
const tui = @import("../tui.zig");
const sysinfo = @import("../sysinfo.zig");
const config = @import("../config.zig");
const util = @import("util.zig");
const timeline_mod = @import("../timeline.zig");
const Tui = tui.Tui;

pub const MAX_HINTS = 10;

pub const HintSeverity = enum { info, warn, critical };

pub const PatternKind = enum {
    swap_storm,
    swap_pressure,
    runaway_writer,
    runaway_cpu,
    reconnect_loop,
    fd_pressure,
    memory_leak,
    thermal_throttle,
    cache_starvation,
};

pub const PressureHint = struct {
    severity: HintSeverity = .info,
    pattern: PatternKind,
    title: [52]u8 = std.mem.zeroes([52]u8),
    title_len: u8 = 0,
    detail: [128]u8 = std.mem.zeroes([128]u8),
    detail_len: u8 = 0,
    culprit_pid: u32 = 0,
    culprit_name: [32]u8 = std.mem.zeroes([32]u8),
    culprit_name_len: u8 = 0,

    pub fn titleSlice(self: *const PressureHint) []const u8 {
        return self.title[0..self.title_len];
    }

    pub fn detailSlice(self: *const PressureHint) []const u8 {
        return self.detail[0..self.detail_len];
    }

    pub fn culpritNameSlice(self: *const PressureHint) []const u8 {
        return self.culprit_name[0..self.culprit_name_len];
    }
};

pub const PressureHintsData = struct {
    hints: [MAX_HINTS]PressureHint = undefined,
    hint_count: usize = 0,
    mem: sysinfo.common.MemStats = .{ .total = 0, .used = 0, .free = 0 },
    mem_pct: f32 = 0,
    cpu_pct: f32 = 0,
    disk_rate: u64 = 0,
    net_rate: u64 = 0,
    thermal: sysinfo.common.ThermalStats = .{},
};

fn addHint(
    data: *PressureHintsData,
    pattern: PatternKind,
    severity: HintSeverity,
    title: []const u8,
    detail: []const u8,
    culprit_pid: u32,
    culprit_name: []const u8,
) void {
    if (data.hint_count >= MAX_HINTS) return;
    var hint = PressureHint{ .pattern = pattern, .severity = severity, .culprit_pid = culprit_pid };
    const tl = @min(title.len, hint.title.len);
    @memcpy(hint.title[0..tl], title[0..tl]);
    hint.title_len = @intCast(tl);
    const dl = @min(detail.len, hint.detail.len);
    @memcpy(hint.detail[0..dl], detail[0..dl]);
    hint.detail_len = @intCast(dl);
    const nl = @min(culprit_name.len, hint.culprit_name.len);
    @memcpy(hint.culprit_name[0..nl], culprit_name[0..nl]);
    hint.culprit_name_len = @intCast(nl);
    data.hints[data.hint_count] = hint;
    data.hint_count += 1;
}

fn detectSwapPatterns(data: *PressureHintsData, mem: sysinfo.common.MemStats, procs: []const sysinfo.ProcStats, timeline: *const timeline_mod.Timeline) void {
    if (mem.swap_total == 0) return;
    const swap_pct = @as(f32, @floatFromInt(mem.swap_used)) / @as(f32, @floatFromInt(mem.swap_total)) * 100.0;
    if (swap_pct < 15.0) return;

    const growing = blk: {
        const old = timeline.getSnapshot(30) orelse break :blk false;
        if (old.mem.swap_total == 0) break :blk false;
        const old_pct = @as(f32, @floatFromInt(old.mem.swap_used)) / @as(f32, @floatFromInt(old.mem.swap_total)) * 100.0;
        break :blk swap_pct > old_pct + 5.0;
    };

    var top_pid: u32 = 0;
    var top_name: []const u8 = &.{};
    var top_mem: f32 = 0;
    for (procs) |p| {
        if (p.mem_percent > top_mem) {
            top_mem = p.mem_percent;
            top_pid = p.pid;
            top_name = p.name();
        }
    }

    var title_buf: [52]u8 = undefined;
    var detail_buf: [128]u8 = undefined;
    const sv: HintSeverity = if (swap_pct > 70.0) .critical else .warn;
    const su = util.formatUnit(mem.swap_used);
    const st = util.formatUnit(mem.swap_total);

    if (growing) {
        const title = std.fmt.bufPrint(&title_buf, "Swap storm ({d:.0}% used, rising)", .{swap_pct}) catch "Swap storm";
        const detail = std.fmt.bufPrint(&detail_buf, "{d:.1}{s} of {d:.1}{s} swap in use and growing. Physical RAM exhausted — paging under pressure.", .{ su.value, su.unit, st.value, st.unit }) catch "";
        addHint(data, .swap_storm, sv, title, detail, top_pid, top_name);
    } else {
        const title = std.fmt.bufPrint(&title_buf, "Swap pressure ({d:.0}% used)", .{swap_pct}) catch "Swap pressure";
        const detail = std.fmt.bufPrint(&detail_buf, "{d:.1}{s} of {d:.1}{s} swap in use. System is paging — potential latency spikes.", .{ su.value, su.unit, st.value, st.unit }) catch "";
        addHint(data, .swap_pressure, sv, title, detail, top_pid, top_name);
    }
}

fn detectRunawayWriter(data: *PressureHintsData, procs: []const sysinfo.ProcStats, disk_total: u64) void {
    if (disk_total < 5 * 1024 * 1024) return;

    var top_pid: u32 = 0;
    var top_name: []const u8 = &.{};
    var top_write: u64 = 0;
    for (procs) |p| {
        if (p.disk_write_ps > top_write) {
            top_write = p.disk_write_ps;
            top_pid = p.pid;
            top_name = p.name();
        }
    }

    if (top_write < 8 * 1024 * 1024) return;

    const log_patterns = [_][]const u8{ "log", "journal", "syslog", "rsyslog", "logd", "logger", "fluent", "filebeat", "splunk" };
    var is_log_writer = false;
    for (log_patterns) |pat| {
        if (std.ascii.indexOfIgnoreCase(top_name, pat) != null) {
            is_log_writer = true;
            break;
        }
    }

    const share_pct: f32 = @as(f32, @floatFromInt(top_write)) / @as(f32, @floatFromInt(disk_total)) * 100.0;
    if (share_pct < 40.0 and !is_log_writer) return;

    var title_buf: [52]u8 = undefined;
    var detail_buf: [128]u8 = undefined;
    const wfmt = util.formatUnit(top_write);
    const sv: HintSeverity = if (top_write > 50 * 1024 * 1024) .critical else .warn;
    const label = if (is_log_writer) "Log writer runaway" else "Disk write storm";
    const title = std.fmt.bufPrint(&title_buf, "{s}: {d:.1}{s}/s", .{ label, wfmt.value, wfmt.unit }) catch "Runaway writer";
    const detail = std.fmt.bufPrint(&detail_buf, "{d:.0}% of total disk writes. Check for log rotation loop, unbounded output, or missing write throttle.", .{share_pct}) catch "";
    addHint(data, .runaway_writer, sv, title, detail, top_pid, top_name);
}

fn detectReconnectLoop(data: *PressureHintsData, connections: []const sysinfo.common.NetConnection) void {
    if (connections.len == 0) return;

    const MAX_TRACKED = 32;
    var pids: [MAX_TRACKED]u32 = undefined;
    var tw_counts: [MAX_TRACKED]u32 = std.mem.zeroes([MAX_TRACKED]u32);
    var pid_count: usize = 0;

    for (connections) |conn| {
        if (conn.state != .time_wait and conn.state != .close_wait) continue;
        if (conn.pid == 0) continue;
        var found = false;
        for (pids[0..pid_count], 0..) |p, i| {
            if (p == conn.pid) {
                tw_counts[i] += 1;
                found = true;
                break;
            }
        }
        if (!found and pid_count < MAX_TRACKED) {
            pids[pid_count] = conn.pid;
            tw_counts[pid_count] = 1;
            pid_count += 1;
        }
    }

    var worst_idx: usize = 0;
    var worst_count: u32 = 0;
    for (0..pid_count) |i| {
        if (tw_counts[i] > worst_count) {
            worst_count = tw_counts[i];
            worst_idx = i;
        }
    }
    if (worst_count < 15) return;

    const culprit_pid = pids[worst_idx];
    var culprit_name: []const u8 = &.{};
    for (connections) |conn| {
        if (conn.pid == culprit_pid) {
            culprit_name = conn.name();
            break;
        }
    }

    var title_buf: [52]u8 = undefined;
    var detail_buf: [128]u8 = undefined;
    const title = std.fmt.bufPrint(&title_buf, "Reconnect loop ({d} TIME_WAIT)", .{worst_count}) catch "Reconnect loop";
    const detail = std.fmt.bufPrint(&detail_buf, "{d} TIME_WAIT/CLOSE_WAIT sockets. Process connects and drops rapidly — check retry logic or backoff.", .{worst_count}) catch "";
    addHint(data, .reconnect_loop, if (worst_count > 50) .critical else .warn, title, detail, culprit_pid, culprit_name);
}

fn detectFdPressure(data: *PressureHintsData, procs: []const sysinfo.ProcStats) void {
    var top_pid: u32 = 0;
    var top_name: []const u8 = &.{};
    var top_threads: u32 = 0;
    for (procs) |p| {
        if (p.threads > top_threads) {
            top_threads = p.threads;
            top_pid = p.pid;
            top_name = p.name();
        }
    }
    if (top_threads < 400) return;

    var title_buf: [52]u8 = undefined;
    var detail_buf: [128]u8 = undefined;
    const sv: HintSeverity = if (top_threads > 1000) .critical else .warn;
    const title = std.fmt.bufPrint(&title_buf, "FD pressure risk ({d} threads)", .{top_threads}) catch "FD pressure";
    const detail = std.fmt.bufPrint(&detail_buf, "{d} threads — likely high file descriptor usage. May be approaching ulimit. Verify /proc/{d}/fd count.", .{ top_threads, top_pid }) catch "";
    addHint(data, .fd_pressure, sv, title, detail, top_pid, top_name);
}

fn detectMemoryLeak(data: *PressureHintsData, procs: []const sysinfo.ProcStats, timeline: *const timeline_mod.Timeline) void {
    if (timeline.snapshotCount() < 30) return;
    if (data.mem_pct < 50.0) return;

    const old = timeline.getSnapshot(60) orelse return;
    const old_procs = old.procs[0..@min(old.proc_count, timeline_mod.MAX_SNAPSHOT_PROCS)];

    var worst_pid: u32 = 0;
    var worst_name: []const u8 = &.{};
    var worst_growth: f32 = 0;
    var worst_current: f32 = 0;

    for (procs) |curr| {
        if (curr.mem_percent < 1.0) continue;
        for (old_procs) |prev| {
            if (prev.pid != curr.pid) continue;
            const growth = curr.mem_percent - prev.mem_percent;
            if (growth > worst_growth) {
                worst_growth = growth;
                worst_pid = curr.pid;
                worst_name = curr.name();
                worst_current = curr.mem_percent;
            }
            break;
        }
    }

    if (worst_growth < 3.0) return;

    var title_buf: [52]u8 = undefined;
    var detail_buf: [128]u8 = undefined;
    const sv: HintSeverity = if (worst_growth > 8.0) .critical else .warn;
    const title = std.fmt.bufPrint(&title_buf, "Memory leak suspect (+{d:.1}pp / 60s)", .{worst_growth}) catch "Memory leak suspect";
    const detail = std.fmt.bufPrint(&detail_buf, "Memory grew {d:.1}pp over ~60s, now {d:.1}%. Monitor for continued growth or heap dump.", .{ worst_growth, worst_current }) catch "";
    addHint(data, .memory_leak, sv, title, detail, worst_pid, worst_name);
}

fn detectCpuRunaway(data: *PressureHintsData, procs: []const sysinfo.ProcStats) void {
    if (data.cpu_pct < 70.0) return;

    var top_pid: u32 = 0;
    var top_name: []const u8 = &.{};
    var top_cpu: f32 = 0;
    for (procs) |p| {
        if (p.cpu_percent > top_cpu) {
            top_cpu = p.cpu_percent;
            top_pid = p.pid;
            top_name = p.name();
        }
    }
    if (top_cpu < 85.0) return;

    var title_buf: [52]u8 = undefined;
    var detail_buf: [128]u8 = undefined;
    const sv: HintSeverity = if (top_cpu > 150.0) .critical else .warn;
    const title = std.fmt.bufPrint(&title_buf, "CPU runaway ({d:.0}% single process)", .{top_cpu}) catch "CPU runaway";
    const detail = std.fmt.bufPrint(&detail_buf, "{d:.0}% CPU, system at {d:.0}%. Likely infinite loop, hot path, or missing rate limit.", .{ top_cpu, data.cpu_pct }) catch "";
    addHint(data, .runaway_cpu, sv, title, detail, top_pid, top_name);
}

fn detectThermalThrottle(data: *PressureHintsData, thermal: sysinfo.common.ThermalStats, cpu_pct: f32) void {
    const temp = thermal.cpu_temp orelse return;
    if (temp < 85.0) return;

    var title_buf: [52]u8 = undefined;
    var detail_buf: [128]u8 = undefined;
    const sv: HintSeverity = if (temp >= 95.0) .critical else .warn;
    const title = std.fmt.bufPrint(&title_buf, "Thermal throttle risk ({d:.0}°C)", .{temp}) catch "Thermal throttle";
    const detail = std.fmt.bufPrint(&detail_buf, "CPU at {d:.0}°C with {d:.0}% utilization. Throttling may reduce throughput — check cooling.", .{ temp, cpu_pct }) catch "";
    addHint(data, .thermal_throttle, sv, title, detail, 0, "");
}

fn detectCacheStarvation(data: *PressureHintsData, mem: sysinfo.common.MemStats) void {
    if (mem.total == 0 or data.mem_pct < 80.0) return;
    const cache_pct = @as(f32, @floatFromInt(mem.cached)) / @as(f32, @floatFromInt(mem.total)) * 100.0;
    if (cache_pct > 5.0) return;

    var title_buf: [52]u8 = undefined;
    var detail_buf: [128]u8 = undefined;
    const title = std.fmt.bufPrint(&title_buf, "Cache starvation ({d:.1}% cache left)", .{cache_pct}) catch "Cache starvation";
    const detail = std.fmt.bufPrint(&detail_buf, "Page cache nearly evicted. Under severe memory pressure — I/O throughput will degrade significantly.", .{}) catch "";
    addHint(data, .cache_starvation, .warn, title, detail, 0, "");
}

/// Analyze current system state and build a set of pressure root-cause hints.
pub fn buildPressureHints(
    mem: sysinfo.common.MemStats,
    mem_pct: f32,
    cpu_pct: f32,
    disk_rate: u64,
    net_rate: u64,
    thermal: sysinfo.common.ThermalStats,
    procs: []const sysinfo.ProcStats,
    connections: []const sysinfo.common.NetConnection,
    timeline: *const timeline_mod.Timeline,
) PressureHintsData {
    var data = PressureHintsData{
        .mem = mem,
        .mem_pct = mem_pct,
        .cpu_pct = cpu_pct,
        .disk_rate = disk_rate,
        .net_rate = net_rate,
        .thermal = thermal,
    };

    detectSwapPatterns(&data, mem, procs, timeline);
    detectRunawayWriter(&data, procs, disk_rate);
    detectReconnectLoop(&data, connections);
    detectFdPressure(&data, procs);
    detectMemoryLeak(&data, procs, timeline);
    detectCpuRunaway(&data, procs);
    detectThermalThrottle(&data, thermal, cpu_pct);
    detectCacheStarvation(&data, mem);

    return data;
}

fn severityColor(theme: config.Theme, severity: HintSeverity) Tui.Color {
    return switch (severity) {
        .critical => theme.usage_critical,
        .warn => theme.usage_warn,
        .info => theme.io_rate,
    };
}

fn severityLabel(severity: HintSeverity) []const u8 {
    return switch (severity) {
        .critical => "!!",
        .warn => "! ",
        .info => "i ",
    };
}

/// Render the Pressure Root-Cause Hints view.
pub fn renderPressureHintsView(
    app_tui: *Tui,
    theme: config.Theme,
    x: u16,
    y: u16,
    width: u16,
    height: u16,
    data: PressureHintsData,
) !void {
    if (height < 5 or width < 30) return;

    try app_tui.drawBoxStyled(x, y, width, height, "Pressure Root-Cause Hints", .{ .fg = theme.border }, .{ .fg = theme.process_title, .bold = true });

    const inner_x = x + 2;
    const inner_width = width -| 4;
    const inner_height = height -| 2;
    if (inner_width < 10 or inner_height < 3) return;

    var cur_y: u16 = y + 1;

    // ── System context row ──
    {
        try app_tui.moveCursor(inner_x, cur_y);
        const meter_w: u16 = if (inner_width > 55) 10 else 7;

        try app_tui.printStyled(.{ .fg = theme.text }, "MEM ", .{});
        try util.renderMeter(app_tui, meter_w, data.mem_pct, .{ .fg = util.memoryColor(theme, data.mem_pct) }, .{ .fg = theme.muted, .dim = true });
        try app_tui.printStyled(.{ .fg = util.memoryColor(theme, data.mem_pct) }, " {d:.0}%", .{data.mem_pct});

        if (data.mem.swap_total > 0) {
            const swap_pct = @as(f32, @floatFromInt(data.mem.swap_used)) / @as(f32, @floatFromInt(data.mem.swap_total)) * 100.0;
            try app_tui.printStyled(.{ .fg = theme.muted }, "  SWP ", .{});
            try util.renderMeter(app_tui, @min(meter_w, 8), swap_pct, .{ .fg = util.usageColor(theme, swap_pct) }, .{ .fg = theme.muted, .dim = true });
            try app_tui.printStyled(.{ .fg = util.usageColor(theme, swap_pct) }, " {d:.0}%", .{swap_pct});
        }

        // CPU and disk on right if width allows
        const right_x = x + width -| 31;
        if (right_x > inner_x + meter_w + 20) {
            try app_tui.moveCursor(right_x, cur_y);
            try app_tui.printStyled(.{ .fg = theme.text }, "CPU ", .{});
            try app_tui.printStyled(.{ .fg = util.usageColor(theme, data.cpu_pct) }, "{d:0>2.0}%", .{data.cpu_pct});
            const dr = util.formatUnit(data.disk_rate);
            try app_tui.printStyled(.{ .fg = theme.muted }, " DISK", .{});
            var value_buf: [16]u8 = undefined;
            const raw_slice = std.fmt.bufPrint(&value_buf, "{d:.2}", .{dr.value}) catch value_buf[0..0];
            const value_width: usize = 6;
            var aligned_buf: [6]u8 = .{ ' ', ' ', ' ', ' ', ' ', ' ' };
            if (raw_slice.len >= value_width) {
                const start = raw_slice.len - value_width;
                @memcpy(aligned_buf[0..], raw_slice[start..][0..value_width]);
            } else {
                const pad = value_width - raw_slice.len;
                @memcpy(aligned_buf[pad..], raw_slice);
            }
            var unit_buf: [2]u8 = .{ ' ', ' ' };
            if (dr.unit.len > 0) unit_buf[0] = dr.unit[0];
            if (dr.unit.len > 1) unit_buf[1] = dr.unit[1];
            try app_tui.printStyled(.{ .fg = theme.io_rate }, "{s}{s}/s", .{ aligned_buf[0..], unit_buf[0..] });
            if (data.thermal.cpu_temp) |temp| {
                const tc: Tui.Color = if (temp >= 95.0) theme.usage_critical else if (temp >= 85.0) theme.usage_warn else theme.usage_good;
                try app_tui.printStyled(.{ .fg = theme.muted }, "  ", .{});
                try app_tui.printStyled(.{ .fg = tc }, "{d:.0}°C", .{temp});
            }
        }
        cur_y += 1;
    }

    // ── Divider ──
    if (cur_y < y + height - 1) {
        try app_tui.moveCursor(x + 1, cur_y);
        for (0..width -| 2) |_| try app_tui.writeStyled(.{ .fg = theme.border, .dim = true }, "─");
        cur_y += 1;
    }

    if (cur_y >= y + height - 1) return;

    // ── No hints: clean bill of health ──
    if (data.hint_count == 0) {
        try app_tui.moveCursor(inner_x, cur_y);
        try app_tui.printStyled(.{ .fg = theme.usage_good, .bold = true }, "OK", .{});
        try app_tui.printStyled(.{ .fg = theme.muted }, "  No pressure patterns detected at this time.", .{});
        return;
    }

    // ── Section header ──
    try app_tui.moveCursor(inner_x, cur_y);
    try app_tui.printStyled(.{ .fg = theme.process_title, .bold = true }, "{d} PATTERN{s} DETECTED", .{ data.hint_count, if (data.hint_count == 1) "" else "S" });
    cur_y += 1;

    if (cur_y >= y + height - 1) return;

    // Decide layout: compact (1 row) vs expanded (2+ rows) based on available space
    const avail_rows = (y + height - 1) -| cur_y;
    const expanded_rows_per_hint: u16 = 3; // title + detail + blank
    const use_expanded = avail_rows >= @as(u16, @intCast(data.hint_count)) * expanded_rows_per_hint;

    for (data.hints[0..data.hint_count]) |hint| {
        if (cur_y >= y + height - 1) break;

        const sev_col = severityColor(theme, hint.severity);
        const sev_str = severityLabel(hint.severity);

        try app_tui.moveCursor(inner_x, cur_y);
        try app_tui.printStyled(.{ .fg = sev_col, .bold = true }, "{s}", .{sev_str});
        try app_tui.bufWrite(" ");

        // Title — clip to available width
        const title = hint.titleSlice();
        const title_avail = inner_width -| 5;
        const title_clip = @min(title.len, title_avail);
        try app_tui.printStyled(.{ .fg = theme.text, .bold = true }, "{s}", .{title[0..title_clip]});

        if (use_expanded) {
            cur_y += 1;
            if (cur_y < y + height - 1) {
                try app_tui.moveCursor(inner_x + 3, cur_y);
                const detail = hint.detailSlice();
                const detail_clip = @min(detail.len, inner_width -| 3);
                try app_tui.printStyled(.{ .fg = theme.muted }, "{s}", .{detail[0..detail_clip]});

                // Append culprit inline if it fits
                if (hint.culprit_pid > 0) {
                    const cname = hint.culpritNameSlice();
                    var culprit_buf: [48]u8 = undefined;
                    const culprit_str = std.fmt.bufPrint(&culprit_buf, "  → {s} [{d}]", .{ cname, hint.culprit_pid }) catch "";
                    const used = inner_x + 3 + detail_clip;
                    const remaining = (x + width -| 2) -| used;
                    if (remaining >= culprit_str.len) {
                        try app_tui.printStyled(.{ .fg = theme.process_title }, "{s}", .{culprit_str});
                    } else if (remaining > 6) {
                        var short_buf: [48]u8 = undefined;
                        const short_str = std.fmt.bufPrint(&short_buf, "  → {s}", .{cname}) catch "";
                        const short_clip = @min(short_str.len, remaining);
                        try app_tui.printStyled(.{ .fg = theme.process_title }, "{s}", .{short_str[0..short_clip]});
                    }
                }
                cur_y += 1;
            }
            // Blank separator between hints
            cur_y += 1;
        } else {
            // Compact: show culprit inline on title row
            if (hint.culprit_pid > 0) {
                const cname = hint.culpritNameSlice();
                const used_cols: usize = 3 + title_clip;
                const avail_cols = inner_width -| used_cols;
                if (avail_cols > 8) {
                    var tag_buf: [40]u8 = undefined;
                    const tag = std.fmt.bufPrint(&tag_buf, "  → {s}", .{cname}) catch "";
                    const tag_clip = @min(tag.len, avail_cols -| 2);
                    try app_tui.printStyled(.{ .fg = theme.muted }, "{s}", .{tag[0..tag_clip]});
                }
            }
            cur_y += 1;
        }
    }
}
