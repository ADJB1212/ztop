const std = @import("std");
const tui = @import("../tui.zig");
const sysinfo = @import("../sysinfo.zig");
const config = @import("../config.zig");
const util = @import("util.zig");
const Tui = tui.Tui;

const MAX_TOP = 8;

/// Which resource spike to explain. `.auto` means detect from current metrics.
pub const SpikeKind = enum { auto, cpu, mem, disk, net, thermal };

/// All data needed for the "Why is this busy?" view.
pub const WhyBusyData = struct {
    kind: SpikeKind,
    /// Current (at-spike) metric values
    cpu_pct: f32,
    mem_pct: f32,
    disk_rate: u64,
    net_rate: u64,
    /// Baseline metrics ~5 ticks before spike (null if unavailable)
    cpu_pct_before: ?f32 = null,
    mem_pct_before: ?f32 = null,
    disk_rate_before: ?u64 = null,
    net_rate_before: ?u64 = null,
    /// Processes at spike time (top N by sort order)
    procs: []const sysinfo.ProcStats,
    /// Processes before spike (for delta calculation; may be empty)
    procs_before: []const sysinfo.ProcStats = &.{},
    /// Unix timestamp in ms (0 = live)
    timestamp_ms: i64 = 0,
};

pub const ProcMetric = enum { cpu, mem, disk };

fn procMetricValue(proc: sysinfo.ProcStats, metric: ProcMetric) f64 {
    return switch (metric) {
        .cpu => @floatCast(proc.cpu_percent),
        .mem => @floatCast(proc.mem_percent),
        .disk => @floatFromInt(proc.disk_read_ps + proc.disk_write_ps),
    };
}

/// Find up to MAX_TOP indices of top processes by metric, descending.
pub fn topProcIndices(procs: []const sysinfo.ProcStats, metric: ProcMetric, out: []usize) usize {
    var selected: [MAX_TOP]usize = undefined;
    var sel_count: usize = 0;
    const n = @min(out.len, MAX_TOP);

    for (0..n) |_| {
        var best_idx: ?usize = null;
        var best_val: f64 = 0;
        for (procs, 0..) |proc, i| {
            var already = false;
            for (selected[0..sel_count]) |s| {
                if (s == i) {
                    already = true;
                    break;
                }
            }
            if (already) continue;
            const v = procMetricValue(proc, metric);
            if (v > best_val) {
                best_val = v;
                best_idx = i;
            }
        }
        if (best_val <= 0) break;
        if (best_idx) |idx| {
            selected[sel_count] = idx;
            out[sel_count] = idx;
            sel_count += 1;
        } else break;
    }
    return sel_count;
}

/// Look up a process by PID in a slice. Returns null if not found.
pub fn findProcByPid(procs: []const sysinfo.ProcStats, pid: u32) ?sysinfo.ProcStats {
    for (procs) |p| {
        if (p.pid == pid) return p;
    }
    return null;
}

pub fn fmtTimestamp(ms: i64, buf: []u8) []u8 {
    if (ms == 0) return buf[0..0];
    const secs = @divTrunc(ms, 1000);
    const h: u64 = @intCast(@mod(@divTrunc(secs, 3600), 24));
    const m: u64 = @intCast(@mod(@divTrunc(secs, 60), 60));
    const s: u64 = @intCast(@mod(secs, 60));
    return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}:{d:0>2}", .{ h, m, s }) catch buf[0..0];
}

/// Render delta indicator: "→ X%" or "was X%" or nothing.
fn renderDelta(app_tui: *Tui, theme: config.Theme, before_val: ?f32, now_val: f32, comptime suffix: []const u8) !void {
    const before = before_val orelse return;
    const delta = now_val - before;
    if (@abs(delta) < 0.5) return; // ignore noise
    const color = if (delta > 0) theme.usage_warn else theme.usage_good;
    const sign: u8 = if (delta > 0) '+' else '-';
    try app_tui.printStyled(.{ .fg = color }, " {c}{d:.1}" ++ suffix, .{ sign, @abs(delta) });
}

fn renderDeltaRate(app_tui: *Tui, theme: config.Theme, before_val: ?u64, now_val: u64) !void {
    const before = before_val orelse return;
    if (now_val == before) return;
    const grew = now_val > before;
    const delta = if (grew) now_val - before else before - now_val;
    if (delta < 256 * 1024) return; // < 256 KB/s delta — skip
    const color = if (grew) theme.usage_warn else theme.usage_good;
    const dv = util.formatUnit(delta);
    try app_tui.printStyled(.{ .fg = color }, " {s}{d:.1}{s}/s", .{ if (grew) "+" else "-", dv.value, dv.unit });
}

/// Detect the most prominent metric kind when kind == .auto.
pub fn detectKind(data: WhyBusyData) SpikeKind {
    // Simple heuristic: highest relative busyness wins
    var best = SpikeKind.cpu;
    var best_score: f32 = data.cpu_pct;

    if (data.mem_pct > best_score) {
        best = .mem;
        best_score = data.mem_pct;
    }
    // Disk: treat 10 MB/s = 10% for comparison
    const disk_score = @as(f32, @floatFromInt(data.disk_rate)) / (1024.0 * 1024.0 * 10.0) * 10.0;
    if (disk_score > best_score) {
        best = .disk;
    }
    return best;
}

fn spikeLabel(kind: SpikeKind) []const u8 {
    return switch (kind) {
        .auto => "System",
        .cpu => "CPU",
        .mem => "Memory",
        .disk => "Disk I/O",
        .net => "Network",
        .thermal => "Thermal",
    };
}

fn spikeProcMetric(kind: SpikeKind) ProcMetric {
    return switch (kind) {
        .auto, .cpu, .thermal => .cpu,
        .mem => .mem,
        .disk, .net => .disk,
    };
}

/// Render a single process contribution row.
fn renderProcRow(
    app_tui: *Tui,
    theme: config.Theme,
    x: u16,
    y: u16,
    width: u16,
    proc: sysinfo.ProcStats,
    metric: ProcMetric,
    proc_before: ?sysinfo.ProcStats,
    total: f64,
) !void {
    try app_tui.moveCursor(x, y);

    const name_width: usize = if (width > 55) 18 else if (width > 40) 14 else 10;
    const meter_w: u16 = if (width > 60) 12 else if (width > 45) 9 else 6;

    // Name
    const pname = proc.name();
    if (pname.len >= name_width) {
        try app_tui.printStyled(.{ .fg = theme.text }, "{s}..", .{pname[0..name_width -| 2]});
    } else {
        try app_tui.printStyled(.{ .fg = theme.text }, "{s}", .{pname});
        for (pname.len..name_width) |_| try app_tui.bufWrite(" ");
    }
    try app_tui.bufWrite(" ");

    switch (metric) {
        .cpu => {
            const val = proc.cpu_percent;
            try util.renderMeter(app_tui, meter_w, @min(val, 100.0), .{ .fg = util.usageColor(theme, val) }, .{ .fg = theme.muted, .dim = true });
            try app_tui.printStyled(.{ .fg = util.usageColor(theme, val), .bold = val >= 50 }, " {d:5.1}%", .{val});
            // Delta vs before
            const val_before = if (proc_before) |pb| pb.cpu_percent else null;
            try renderDelta(app_tui, theme, val_before, val, "pp");
            // Contribution share
            if (total > 0) {
                const share: f32 = @as(f32, @floatCast(val)) / @as(f32, @floatCast(total)) * 100.0;
                if (share >= 2.0) {
                    try app_tui.printStyled(.{ .fg = theme.muted }, " ({d:.0}%)", .{share});
                }
            }
        },
        .mem => {
            const val = proc.mem_percent;
            try util.renderMeter(app_tui, meter_w, @min(val, 100.0), .{ .fg = util.memoryColor(theme, val) }, .{ .fg = theme.muted, .dim = true });
            try app_tui.printStyled(.{ .fg = util.memoryColor(theme, val), .bold = val >= 50 }, " {d:5.1}%", .{val});
            const val_before = if (proc_before) |pb| pb.mem_percent else null;
            try renderDelta(app_tui, theme, val_before, val, "pp");
            if (total > 0) {
                const share: f32 = @as(f32, @floatCast(val)) / @as(f32, @floatCast(total)) * 100.0;
                if (share >= 2.0) {
                    try app_tui.printStyled(.{ .fg = theme.muted }, " ({d:.0}%)", .{share});
                }
            }
        },
        .disk => {
            const total_io = proc.disk_read_ps + proc.disk_write_ps;
            const pct = @as(f32, @floatFromInt(total_io)) / (100.0 * 1024.0 * 1024.0) * 100.0;
            try util.renderMeter(app_tui, meter_w, @min(pct, 100.0), .{ .fg = theme.io_rate }, .{ .fg = theme.muted, .dim = true });
            const tv = util.formatUnit(total_io);
            try app_tui.printStyled(.{ .fg = theme.io_rate }, " {d:.1}{s}/s", .{ tv.value, tv.unit });
            if (proc_before) |pb| {
                const before_io = pb.disk_read_ps + pb.disk_write_ps;
                try renderDeltaRate(app_tui, theme, before_io, total_io);
            }
        },
    }
}

/// Render the "Why Is This Busy?" view.
/// Shows which resource is spiking, compares to baseline, and ranks
/// the processes most responsible, with delta indicators.
pub fn renderWhyBusyView(
    app_tui: *Tui,
    theme: config.Theme,
    x: u16,
    y: u16,
    width: u16,
    height: u16,
    data: WhyBusyData,
) !void {
    if (height < 5 or width < 30) return;

    const kind = if (data.kind == .auto) detectKind(data) else data.kind;

    // ── Title ──
    var title_buf: [80]u8 = undefined;
    var ts_buf: [12]u8 = undefined;
    const ts_str = fmtTimestamp(data.timestamp_ms, &ts_buf);
    const title = if (data.timestamp_ms != 0)
        std.fmt.bufPrint(&title_buf, "Why Was {s} Busy? [{s}]", .{ spikeLabel(kind), ts_str }) catch "Why Is This Busy?"
    else
        std.fmt.bufPrint(&title_buf, "Why Is {s} Busy?", .{spikeLabel(kind)}) catch "Why Is This Busy?";

    try app_tui.drawBoxStyled(x, y, width, height, title, .{ .fg = theme.border }, .{ .fg = theme.process_title, .bold = true });

    const inner_x = x + 2;
    const inner_width = width -| 4;
    const inner_height = height -| 2;
    if (inner_width < 10 or inner_height < 3) return;

    // ── System overview rows ──
    const meter_width: u16 = if (inner_width > 60) 14 else if (inner_width > 40) 10 else 6;
    // Right column: after "CPU " (4) + meter + " 100.0%" (7) + gap (2)
    const right_col_x = inner_x + 4 + meter_width + 9;
    const has_right_col = right_col_x + 18 < x + width;

    var cur_y: u16 = y + 1;

    // CPU row
    {
        try app_tui.moveCursor(inner_x, cur_y);
        const cpu_bold = kind == .cpu or kind == .thermal;
        try app_tui.printStyled(.{ .fg = theme.text, .bold = cpu_bold }, "CPU ", .{});
        try util.renderMeter(app_tui, meter_width, data.cpu_pct, .{ .fg = util.usageColor(theme, data.cpu_pct) }, .{ .fg = theme.muted, .dim = true });
        try app_tui.printStyled(.{ .fg = util.usageColor(theme, data.cpu_pct), .bold = data.cpu_pct >= 70 }, " {d:5.1}%", .{data.cpu_pct});
        try renderDelta(app_tui, theme, data.cpu_pct_before, data.cpu_pct, "pp");

        if (has_right_col and cur_y < y + height - 1) {
            try app_tui.moveCursor(right_col_x, cur_y);
            try app_tui.printStyled(.{ .fg = theme.text }, "NET ", .{});
            const nr = util.formatUnit(data.net_rate);
            const net_color: Tui.Color = if (data.net_rate >= 10 * 1024 * 1024) theme.usage_warn else theme.io_rate;
            try app_tui.printStyled(.{ .fg = net_color }, "{d:.1}{s}/s", .{ nr.value, nr.unit });
            try renderDeltaRate(app_tui, theme, data.net_rate_before, data.net_rate);
        }
        cur_y += 1;
    }

    // MEM row
    if (cur_y < y + height - 1) {
        try app_tui.moveCursor(inner_x, cur_y);
        const mem_bold = kind == .mem;
        try app_tui.printStyled(.{ .fg = theme.text, .bold = mem_bold }, "MEM ", .{});
        try util.renderMeter(app_tui, meter_width, data.mem_pct, .{ .fg = util.memoryColor(theme, data.mem_pct) }, .{ .fg = theme.muted, .dim = true });
        try app_tui.printStyled(.{ .fg = util.memoryColor(theme, data.mem_pct), .bold = data.mem_pct >= 70 }, " {d:5.1}%", .{data.mem_pct});
        try renderDelta(app_tui, theme, data.mem_pct_before, data.mem_pct, "pp");

        if (has_right_col and cur_y < y + height - 1) {
            try app_tui.moveCursor(right_col_x, cur_y);
            const disk_bold = kind == .disk;
            try app_tui.printStyled(.{ .fg = theme.text, .bold = disk_bold }, "DSK ", .{});
            const dr = util.formatUnit(data.disk_rate);
            const disk_color: Tui.Color = if (data.disk_rate >= 100 * 1024 * 1024) theme.usage_warn else theme.io_rate;
            try app_tui.printStyled(.{ .fg = disk_color }, "{d:.1}{s}/s", .{ dr.value, dr.unit });
            try renderDeltaRate(app_tui, theme, data.disk_rate_before, data.disk_rate);
        }
        cur_y += 1;
    }

    // Divider
    if (cur_y < y + height - 1) {
        try app_tui.moveCursor(x + 1, cur_y);
        for (0..width -| 2) |_| try app_tui.writeStyled(.{ .fg = theme.border, .dim = true }, "─");
        cur_y += 1;
    }

    // ── Process contributions ──
    if (cur_y >= y + height - 1 or data.procs.len == 0) return;

    const remaining: u16 = (y + height -| 1) -| cur_y;
    const proc_metric = spikeProcMetric(kind);

    // Section header
    const section_label: []const u8 = switch (kind) {
        .auto, .cpu, .thermal => "TOP CPU CONTRIBUTORS",
        .mem => "TOP MEMORY CONTRIBUTORS",
        .disk => "TOP DISK I/O",
        .net => "TOP DISK I/O (proxy — per-process net unavailable)",
    };

    try app_tui.moveCursor(inner_x, cur_y);
    try app_tui.printStyled(.{ .fg = theme.process_title, .bold = true }, "{s}", .{section_label});
    cur_y += 1;

    if (cur_y >= y + height - 1) return;

    // Get top process indices by the spike metric
    var indices: [MAX_TOP]usize = undefined;
    const count = topProcIndices(data.procs, proc_metric, &indices);

    // Compute total for share %
    var proc_total: f64 = 0;
    for (data.procs) |p| proc_total += procMetricValue(p, proc_metric);

    const proc_rows = remaining -| 1; // minus header row
    const show = @min(count, proc_rows);

    for (0..show) |si| {
        if (cur_y >= y + height - 1) break;
        const proc = data.procs[indices[si]];
        const proc_before = findProcByPid(data.procs_before, proc.pid);
        try renderProcRow(app_tui, theme, inner_x, cur_y, inner_width, proc, proc_metric, proc_before, proc_total);
        cur_y += 1;
    }

    if (count == 0 and cur_y < y + height - 1) {
        try app_tui.moveCursor(inner_x, cur_y);
        try app_tui.printStyled(.{ .fg = theme.muted, .dim = true }, "no significant process activity", .{});
    }
}
