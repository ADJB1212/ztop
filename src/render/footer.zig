const std = @import("std");
const config = @import("../config.zig");
const timeline_mod = @import("../timeline.zig");
const tui = @import("../tui.zig");

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

pub fn renderFooter(app_tui: *Tui, theme: config.Theme, width: u16, height: u16, state: FooterState) !void {
    _ = width;

    try app_tui.moveCursor(1, height);
    if (state.diff_active) {
        try app_tui.writeStyled(
            .{ .fg = theme.usage_warn, .bold = true },
            if (app_tui.hasNerdFonts()) "󰛿 DIFF  " else "◆ DIFF  ",
        );
        try app_tui.printStyled(.{ .fg = theme.muted }, "←/→ move compare point  ", .{});
        try app_tui.printStyled(.{ .fg = theme.text, .bold = true }, "d", .{});
        try app_tui.printStyled(.{ .fg = theme.muted }, "/", .{});
        try app_tui.printStyled(.{ .fg = theme.text, .bold = true }, "Esc", .{});
        try app_tui.printStyled(.{ .fg = theme.muted }, " close diff", .{});
    } else if (state.is_scrubbing) {
        try app_tui.writeStyled(
            .{ .fg = theme.usage_warn, .bold = true },
            if (app_tui.hasNerdFonts()) "󱊓 SCRUB  " else "◀◀ SCRUB  ",
        );

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
            try app_tui.printStyled(.{ .fg = theme.text, .bold = true }, "b", .{});
            try app_tui.printStyled(.{ .fg = theme.muted }, " mark  ", .{});
            if (state.timeline.bookmark_count > 0) {
                try app_tui.printStyled(.{ .fg = theme.text, .bold = true }, "B", .{});
                try app_tui.printStyled(.{ .fg = theme.muted }, " del  ", .{});
                try app_tui.printStyled(.{ .fg = theme.text, .bold = true }, "{{}}", .{});
                try app_tui.printStyled(.{ .fg = theme.muted }, " jump  ", .{});
            }
        }
        try app_tui.printStyled(.{ .fg = theme.text, .bold = true }, "d", .{});
        try app_tui.printStyled(.{ .fg = theme.muted }, " diff  ", .{});
        try app_tui.printStyled(.{ .fg = theme.text, .bold = true }, "T", .{});
        try app_tui.printStyled(.{ .fg = theme.muted }, "/", .{});
        try app_tui.printStyled(.{ .fg = theme.text, .bold = true }, "Esc", .{});
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
        const picker_range = std.fmt.bufPrint(&picker_range_buf, "1-{d}", .{config.process_column_order.len}) catch "1-n";
        try app_tui.printStyled(.{ .fg = theme.text, .bold = true }, "{s}", .{picker_range});
        try app_tui.printStyled(.{ .fg = theme.muted }, " toggle, ", .{});
        try app_tui.printStyled(.{ .fg = theme.text, .bold = true }, "Enter/Esc", .{});
        try app_tui.printStyled(.{ .fg = theme.muted }, " close", .{});
    } else if (state.filter.len > 0) {
        try app_tui.printStyled(.{ .fg = theme.filter_prompt, .bold = true }, "Filter active: ", .{});
        try app_tui.printStyled(.{ .fg = theme.text }, "{s}", .{state.filter});
        try app_tui.printStyled(.{ .fg = theme.muted }, " (Press / to edit, Esc to clear) | ", .{});
        try app_tui.printStyled(.{ .fg = theme.muted }, "Press ", .{});
        try app_tui.printStyled(.{ .fg = theme.text, .bold = true }, "'?'", .{});
        try app_tui.printStyled(.{ .fg = theme.muted }, " for help", .{});
    } else if (state.thread_view) {
        try app_tui.printStyled(.{ .fg = theme.muted }, "Viewing threads of ", .{});
        try app_tui.printStyled(.{ .fg = theme.text, .bold = true }, "{s}", .{state.thread_view_name});
        try app_tui.printStyled(.{ .fg = theme.muted }, " | Press ", .{});
        try app_tui.printStyled(.{ .fg = theme.text, .bold = true }, "Esc", .{});
        try app_tui.printStyled(.{ .fg = theme.muted }, " to go back", .{});
    } else if (state.status.len > 0) {
        try app_tui.printStyled(.{ .fg = theme.muted }, "{s}", .{state.status});
    } else if (state.dropped_column_count > 0) {
        try app_tui.printStyled(.{ .fg = theme.muted }, "{d} column(s) hidden by width | Press ", .{state.dropped_column_count});
        try app_tui.printStyled(.{ .fg = theme.text, .bold = true }, "'C'", .{});
        try app_tui.printStyled(.{ .fg = theme.muted }, " to adjust", .{});
    } else {
        try app_tui.printStyled(.{ .fg = theme.muted }, "Press ", .{});
        try app_tui.printStyled(.{ .fg = theme.text, .bold = true }, "'?'", .{});
        try app_tui.printStyled(.{ .fg = theme.muted }, " for help, ", .{});
        try app_tui.printStyled(.{ .fg = theme.text, .bold = true }, "'C'", .{});
        try app_tui.printStyled(.{ .fg = theme.muted }, " for columns, ", .{});
        try app_tui.printStyled(.{ .fg = theme.text, .bold = true }, "'q'", .{});
        try app_tui.printStyled(.{ .fg = theme.muted }, " to quit", .{});
    }
}
