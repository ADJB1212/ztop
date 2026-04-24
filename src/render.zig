const std = @import("std");
const tui = @import("tui.zig");
const sysinfo = @import("sysinfo.zig");
const config = @import("config.zig");
const Tui = tui.Tui;
const SysInfo = sysinfo.SysInfo;

const util = @import("render/util.zig");
const graphs = @import("render/graphs.zig");
const process_table = @import("render/process_table.zig");
const rate_box = @import("render/rate_box.zig");
const cpu_topology = @import("render/cpu_topology.zig");
const timeline = @import("render/timeline.zig");
const diff = @import("render/diff.zig");
const causality = @import("render/causality.zig");

// Re-exports from util.zig
pub const UnitValue = util.UnitValue;
pub const formatUnit = util.formatUnit;
pub const usageColor = util.usageColor;
pub const memoryColor = util.memoryColor;
pub const procStateLabel = util.procStateLabel;
pub const procStateColor = util.procStateColor;
pub const TextAlign = util.TextAlign;
pub const writeAlignedCell = util.writeAlignedCell;
pub const writeChip = util.writeChip;
pub const renderMeter = util.renderMeter;

// Re-exports from graphs.zig
pub const MetricColorMode = graphs.MetricColorMode;
pub const historyGraphRows = graphs.historyGraphRows;
pub const suggestedHistoryGraphRows = graphs.suggestedHistoryGraphRows;
pub const renderHistoryGraph = graphs.renderHistoryGraph;
pub const renderRateHistoryGraph = graphs.renderRateHistoryGraph;

// Re-exports from process_table.zig
pub const ProcessTableLayout = process_table.ProcessTableLayout;
pub const min_process_name_width = process_table.min_process_name_width;
pub const processColumnWidth = process_table.processColumnWidth;
pub const planProcessTableLayout = process_table.planProcessTableLayout;

// Re-exports from rate_box.zig
pub const RateSeries = rate_box.RateSeries;
pub const renderDualRateBox = rate_box.renderDualRateBox;

// Re-exports from cpu_topology.zig
pub const renderCpuTopologyBox = cpu_topology.renderCpuTopologyBox;

// Re-exports from timeline.zig
pub const renderTimelineBar = timeline.renderTimelineBar;

// Re-exports from diff.zig
pub const renderDiffView = diff.renderDiffView;

// Re-exports from causality.zig
pub const renderCausalityGraph = causality.renderCausalityGraph;

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
