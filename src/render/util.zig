const std = @import("std");
const tui = @import("../tui.zig");
const sysinfo = @import("../sysinfo.zig");
const config = @import("../config.zig");
const Tui = tui.Tui;

pub fn usageColor(theme: config.Theme, percent: f32) Tui.Color {
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

pub fn memoryColor(theme: config.Theme, percent: f32) Tui.Color {
    if (percent >= 80) return theme.memory_critical;
    if (percent >= 60) return theme.memory_warn;
    if (percent >= 35) return theme.memory_mid;
    return theme.memory_low;
}

pub fn procStateLabel(state: sysinfo.ProcState) []const u8 {
    return switch (state) {
        .running => "running",
        .sleeping => "sleeping",
        .disk_sleep => "disk_slp",
        .stopped => "stopped",
        .tracing_stop => "tracing",
        .zombie => "zombie",
        .dead => "dead",
        .idle => "idle",
        .unknown => "unknown",
    };
}

pub fn procStateColor(theme: config.Theme, state: sysinfo.ProcState) Tui.Color {
    return switch (state) {
        .running => theme.usage_good,
        .sleeping => theme.muted,
        .disk_sleep => theme.usage_warn,
        .stopped => theme.usage_critical,
        .tracing_stop => theme.usage_warn,
        .zombie => theme.usage_critical,
        .dead => theme.usage_critical,
        .idle => theme.memory_low,
        .unknown => theme.muted,
    };
}

pub const TextAlign = enum {
    left,
    right,
};

pub fn clipUtf8(text: []const u8, max_codepoints: usize) []const u8 {
    if (max_codepoints == 0) return text[0..0];

    var view = std.unicode.Utf8View.init(text) catch {
        return if (text.len > max_codepoints) text[0..max_codepoints] else text;
    };
    var iter = view.iterator();
    var count: usize = 0;
    var end: usize = 0;

    while (count < max_codepoints) : (count += 1) {
        const slice = iter.nextCodepointSlice() orelse break;
        end += slice.len;
    }

    return text[0..end];
}

pub fn writeAlignedCell(app_tui: *Tui, style: Tui.Style, width: usize, text_align: TextAlign, text: []const u8) !void {
    if (width == 0) return;

    const clipped = if (text.len > width) text[0..width] else text;
    const padding = width - clipped.len;

    if (text_align == .right) {
        for (0..padding) |_| {
            try app_tui.writeStyled(style, " ");
        }
    }

    try app_tui.writeStyled(style, clipped);

    if (text_align == .left) {
        for (0..padding) |_| {
            try app_tui.writeStyled(style, " ");
        }
    }
}

pub fn writeChip(app_tui: *Tui, style: Tui.Style, label: []const u8) !usize {
    try app_tui.printStyled(style, " {s} ", .{label});
    return label.len + 2;
}

/// A filled badge/chip (status pill)
pub fn writePill(app_tui: *Tui, style: Tui.Style, label: []const u8) !usize {
    if (app_tui.hasNerdFonts()) {
        if (style.bg) |bg| {
            try app_tui.printStyled(.{ .fg = bg }, "\u{e0b6}", .{});
            try app_tui.printStyled(style, " {s} ", .{label});
            try app_tui.printStyled(.{ .fg = bg }, "\u{e0b4}", .{});
            return label.len + 4;
        }
    }
    return writeChip(app_tui, style, label);
}

const meter_blocks = [_][]const u8{ " ", "▏", "▎", "▍", "▌", "▋", "▊", "▉", "█" };

pub fn renderMeter(
    app_tui: *Tui,
    width: u16,
    percent: f32,
    fill_style: Tui.Style,
    empty_style: Tui.Style,
) !void {
    if (width == 0) return;

    const clamped = @max(0.0, @min(percent, 100.0));
    const total_eighths = @as(usize, width) * 8;
    const filled_eighths = @min(
        total_eighths,
        @as(usize, @intFromFloat(@round((clamped / 100.0) * @as(f32, @floatFromInt(total_eighths))))),
    );
    const full_blocks = filled_eighths / 8;
    const partial_block = filled_eighths % 8;

    for (0..width) |idx| {
        if (idx < full_blocks) {
            try app_tui.writeStyled(fill_style, meter_blocks[8]);
        } else if (idx == full_blocks and partial_block > 0) {
            try app_tui.writeStyled(fill_style, meter_blocks[partial_block]);
        } else {
            try app_tui.writeStyled(empty_style, "─");
        }
    }
}
