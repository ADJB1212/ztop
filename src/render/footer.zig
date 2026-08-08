const std = @import("std");
const config = @import("../config.zig");
const timeline_mod = @import("../timeline.zig");
const tui = @import("../tui.zig");
const util = @import("util.zig");

const Tui = tui.Tui;

pub const FooterState = struct {
    diff_active: bool,
    is_scrubbing: bool,
    is_cmd_mode: bool,
    cmd: []const u8,
    is_filtering: bool,
    filter: []const u8,
    show_column_picker: bool,
    thread_view: bool,
    thread_view_name: []const u8,
    status: []const u8,
    dropped_column_count: usize,
    timeline: *timeline_mod.Timeline,
    scrub_offset: usize,
};

/// Renders a single key-hint as a small filled badge
fn key(app_tui: *Tui, theme: config.Theme, label: []const u8) !void {
    _ = try util.writePill(app_tui, .{ .bg = theme.border, .fg = theme.text, .bold = true }, label);
}

fn modeBadge(app_tui: *Tui, theme: config.Theme, label: []const u8) !void {
    _ = try util.writePill(app_tui, .{ .bg = theme.usage_warn, .fg = theme.selection_fg, .bold = true }, label);
}

pub fn renderFooter(app_tui: *Tui, theme: config.Theme, width: u16, height: u16, state: FooterState) !void {
    _ = width;

    try app_tui.moveCursor(1, height);
    if (state.diff_active) {
        try modeBadge(app_tui, theme, if (app_tui.hasNerdFonts()) "󰛿 DIFF" else "◆ DIFF");
        try app_tui.printStyled(.{ .fg = theme.muted }, "  ←/→ move compare point  ", .{});
        try key(app_tui, theme, "d");
        try app_tui.printStyled(.{ .fg = theme.muted }, "/", .{});
        try key(app_tui, theme, "Esc");
        try app_tui.printStyled(.{ .fg = theme.muted }, " close diff", .{});
    } else if (state.is_scrubbing) {
        try modeBadge(app_tui, theme, if (app_tui.hasNerdFonts()) "󱊓 SCRUB" else "◀◀ SCRUB");
        try app_tui.bufWrite("  ");

        var ev_out: [4]timeline_mod.TimelineEvent = undefined;
        const ev_n = state.timeline.getEventsNearSnapshot(state.scrub_offset, &ev_out);
        if (ev_n > 0) {
            for (ev_out[0..ev_n]) |ev| {
                try app_tui.printStyled(.{ .fg = theme.usage_warn }, "[", .{});
                try app_tui.printStyled(.{ .fg = theme.text, .bold = true }, "{s}", .{ev.kindLabel()});
                if (ev.detail_len > 0) {
                    try app_tui.printStyled(.{ .fg = theme.muted }, " {s}", .{ev.detail()});
                }
                try app_tui.printStyled(.{ .fg = theme.usage_warn }, "] ", .{});
            }
        } else {
            try app_tui.printStyled(.{ .fg = theme.muted }, "←/→ scrub  [/] fast  ", .{});
            try key(app_tui, theme, "b");
            try app_tui.printStyled(.{ .fg = theme.muted }, " mark  ", .{});
            if (state.timeline.bookmark_count > 0) {
                try key(app_tui, theme, "B");
                try app_tui.printStyled(.{ .fg = theme.muted }, " del  ", .{});
                try key(app_tui, theme, "{}");
                try app_tui.printStyled(.{ .fg = theme.muted }, " jump  ", .{});
            }
        }
        try key(app_tui, theme, "d");
        try app_tui.printStyled(.{ .fg = theme.muted }, " diff  ", .{});
        try key(app_tui, theme, "T");
        try app_tui.printStyled(.{ .fg = theme.muted }, "/", .{});
        try key(app_tui, theme, "Esc");
        try app_tui.printStyled(.{ .fg = theme.muted }, " resume", .{});
    } else if (state.is_cmd_mode) {
        try app_tui.printStyled(.{ .fg = theme.command_prompt, .bold = true }, ":", .{});
        try app_tui.printStyled(.{ .fg = theme.text }, "{s}", .{state.cmd});
        try app_tui.printStyled(.{ .fg = theme.muted }, " (Press Enter to execute, Esc to cancel)", .{});
    } else if (state.is_filtering) {
        try app_tui.printStyled(.{ .fg = theme.filter_prompt, .bold = true }, "Filter: ", .{});
        try app_tui.printStyled(.{ .fg = theme.text }, "{s}", .{state.filter});
        try app_tui.printStyled(.{ .fg = theme.muted }, " (Press Enter to apply, Esc to cancel)", .{});
    } else if (state.show_column_picker) {
        try app_tui.printStyled(.{ .fg = theme.muted }, "Process columns: ", .{});
        var picker_range_buf: [16]u8 = undefined;
        const last_idx = config.process_column_order.len - 1;
        const picker_range = if (config.process_column_order.len <= 9)
            std.fmt.bufPrint(&picker_range_buf, "1-{d}", .{config.process_column_order.len}) catch "1-n"
        else if (config.process_column_order.len <= 10)
            "1-9,0"
        else
            std.fmt.bufPrint(&picker_range_buf, "1-9,0,a-{c}", .{config.columnPickerKey(last_idx)}) catch "1-9,0,a-z";
        try key(app_tui, theme, picker_range);
        try app_tui.printStyled(.{ .fg = theme.muted }, " toggle, ", .{});
        try key(app_tui, theme, "Enter/Esc");
        try app_tui.printStyled(.{ .fg = theme.muted }, " close", .{});
    } else if (state.filter.len > 0) {
        try app_tui.printStyled(.{ .fg = theme.filter_prompt, .bold = true }, "Filter active: ", .{});
        try app_tui.printStyled(.{ .fg = theme.text }, "{s}", .{state.filter});
        try app_tui.printStyled(.{ .fg = theme.muted }, " (Press / to edit, Esc to clear) | Press ", .{});
        try key(app_tui, theme, "?");
        try app_tui.printStyled(.{ .fg = theme.muted }, " for help", .{});
    } else if (state.thread_view) {
        try app_tui.printStyled(.{ .fg = theme.muted }, "Viewing threads of ", .{});
        try app_tui.printStyled(.{ .fg = theme.text, .bold = true }, "{s}", .{state.thread_view_name});
        try app_tui.printStyled(.{ .fg = theme.muted }, " | Press ", .{});
        try key(app_tui, theme, "Esc");
        try app_tui.printStyled(.{ .fg = theme.muted }, " to go back", .{});
    } else if (state.status.len > 0) {
        try app_tui.printStyled(.{ .fg = theme.muted }, "{s}", .{state.status});
    } else if (state.dropped_column_count > 0) {
        try app_tui.printStyled(.{ .fg = theme.muted }, "{d} column(s) hidden by width | Press ", .{state.dropped_column_count});
        try key(app_tui, theme, "C");
        try app_tui.printStyled(.{ .fg = theme.muted }, " to adjust", .{});
    } else {
        try app_tui.printStyled(.{ .fg = theme.muted }, "Press ", .{});
        try key(app_tui, theme, "?");
        try app_tui.printStyled(.{ .fg = theme.muted }, " for help, ", .{});
        try key(app_tui, theme, "C");
        try app_tui.printStyled(.{ .fg = theme.muted }, " for columns, ", .{});
        try key(app_tui, theme, "q");
        try app_tui.printStyled(.{ .fg = theme.muted }, " to quit", .{});
    }
}
