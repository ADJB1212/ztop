const std = @import("std");
const config = @import("../config.zig");
const tui = @import("../tui.zig");

const Tui = tui.Tui;

pub fn renderHelpOverlay(
    app_tui: *Tui,
    theme: config.Theme,
    width: u16,
    height: u16,
    repo_url: []const u8,
    repo_label: []const u8,
) !void {
    const help_width = 60;
    const help_height = 24;
    const h_x = if (width > help_width) (width - help_width) / 2 else 1;
    const h_y = if (height > help_height) (height - help_height) / 2 else 1;

    for (0..help_height) |i| {
        try app_tui.moveCursor(h_x, h_y + @as(u16, @intCast(i)));
        for (0..help_width) |_| try app_tui.bufWrite(" ");
    }

    try app_tui.drawBoxStyled(h_x, h_y, help_width, help_height, "Help", .{ .fg = theme.border }, .{ .fg = theme.text, .bold = true });
    try app_tui.moveCursor(h_x + 2, h_y + 2);
    try app_tui.printStyled(.{ .fg = theme.text }, "1, 2, 3, 4:   ", .{});
    try app_tui.printStyled(.{ .fg = theme.muted }, "Switch Tabs", .{});

    try app_tui.moveCursor(h_x + 2, h_y + 3);
    try app_tui.printStyled(.{ .fg = theme.text }, "j/k, Up/Down: ", .{});
    try app_tui.printStyled(.{ .fg = theme.muted }, "Navigate processes", .{});

    try app_tui.moveCursor(h_x + 2, h_y + 4);
    try app_tui.printStyled(.{ .fg = theme.text }, "c,m,p,n,u:    ", .{});
    try app_tui.printStyled(.{ .fg = theme.muted }, "Sort by CPU/Mem/PID/Name/Wakeups", .{});

    try app_tui.moveCursor(h_x + 2, h_y + 5);
    try app_tui.printStyled(.{ .fg = theme.text }, "v:            ", .{});
    try app_tui.printStyled(.{ .fg = theme.muted }, "Toggle Tree View", .{});

    try app_tui.moveCursor(h_x + 2, h_y + 6);
    try app_tui.printStyled(.{ .fg = theme.text }, "C:            ", .{});
    try app_tui.printStyled(.{ .fg = theme.muted }, "Process column picker", .{});

    try app_tui.moveCursor(h_x + 2, h_y + 7);
    try app_tui.printStyled(.{ .fg = theme.text }, "/:            ", .{});
    try app_tui.printStyled(.{ .fg = theme.muted }, "Filter processes", .{});

    try app_tui.moveCursor(h_x + 2, h_y + 8);
    try app_tui.printStyled(.{ .fg = theme.text }, "Enter:        ", .{});
    try app_tui.printStyled(.{ .fg = theme.muted }, "View threads of selected", .{});

    try app_tui.moveCursor(h_x + 2, h_y + 9);
    try app_tui.printStyled(.{ .fg = theme.text }, "t:            ", .{});
    try app_tui.printStyled(.{ .fg = theme.muted }, "Send SIGTERM to selected", .{});

    try app_tui.moveCursor(h_x + 2, h_y + 10);
    try app_tui.printStyled(.{ .fg = theme.text }, "K:            ", .{});
    try app_tui.printStyled(.{ .fg = theme.muted }, "Send SIGKILL to selected", .{});

    try app_tui.moveCursor(h_x + 2, h_y + 11);
    try app_tui.printStyled(.{ .fg = theme.text }, "g:            ", .{});
    try app_tui.printStyled(.{ .fg = theme.muted }, "Resource causality graph", .{});

    try app_tui.moveCursor(h_x + 2, h_y + 12);
    try app_tui.printStyled(.{ .fg = theme.text }, "w:            ", .{});
    try app_tui.printStyled(.{ .fg = theme.muted }, "Why is this busy? (ranked explanation)", .{});

    try app_tui.moveCursor(h_x + 2, h_y + 13);
    try app_tui.printStyled(.{ .fg = theme.text }, "P:            ", .{});
    try app_tui.printStyled(.{ .fg = theme.muted }, "Pressure root-cause hints (swap/log/fd)", .{});

    try app_tui.moveCursor(h_x + 2, h_y + 14);
    try app_tui.printStyled(.{ .fg = theme.text }, "u:            ", .{});
    try app_tui.printStyled(.{ .fg = theme.muted }, "Wakeup attribution sort", .{});

    try app_tui.moveCursor(h_x + 2, h_y + 15);
    try app_tui.printStyled(.{ .fg = theme.text }, "l:            ", .{});
    try app_tui.printStyled(.{ .fg = theme.muted }, "Follow selected process", .{});

    try app_tui.moveCursor(h_x + 2, h_y + 16);
    try app_tui.printStyled(.{ .fg = theme.text }, "T:            ", .{});
    try app_tui.printStyled(.{ .fg = theme.muted }, "Timeline scrub (←→ step, [] jump)", .{});

    try app_tui.moveCursor(h_x + 2, h_y + 17);
    try app_tui.printStyled(.{ .fg = theme.text }, "b/B, {{}}/{{}}:   ", .{});
    try app_tui.printStyled(.{ .fg = theme.muted }, "Bookmark add/del, jump prev/next", .{});

    try app_tui.moveCursor(h_x + 2, h_y + 18);
    try app_tui.printStyled(.{ .fg = theme.text }, "d:            ", .{});
    try app_tui.printStyled(.{ .fg = theme.muted }, "Diff view (compare two moments)", .{});

    try app_tui.moveCursor(h_x + 2, h_y + 19);
    try app_tui.printStyled(.{ .fg = theme.text }, "L:            ", .{});
    try app_tui.printStyled(.{ .fg = theme.muted }, "View process's lifeline", .{});

    try app_tui.moveCursor(h_x + 2, h_y + 20);
    try app_tui.printStyled(.{ .fg = theme.text }, "q:            ", .{});
    try app_tui.printStyled(.{ .fg = theme.muted }, "Quit", .{});

    try app_tui.moveCursor(h_x + 2, h_y + 21);
    try app_tui.printStyled(.{ .fg = theme.text }, ":             ", .{});
    try app_tui.printStyled(.{ .fg = theme.muted }, "Command mode (show zombie)", .{});

    try app_tui.moveCursor(h_x + 2, h_y + 22);
    try app_tui.printStyled(.{ .fg = theme.text }, "Repo: ", .{});
    try app_tui.writeStyledHyperlink(.{ .fg = theme.tab_active, .underline = true }, repo_url, repo_label);

    try app_tui.moveCursor(h_x + 2, h_y + 23);
    try app_tui.printStyled(.{ .fg = theme.muted }, "Press any key to close...", .{});
}

pub fn renderColumnPickerOverlay(
    app_tui: *Tui,
    theme: config.Theme,
    width: u16,
    height: u16,
    current_tab: u8,
    picker_columns: config.ProcessColumns,
) !void {
    const picker_width = 45;
    const picker_height = 15;
    const picker_x = if (width > picker_width) (width - picker_width) / 2 else 1;
    const picker_y = if (height > picker_height) (height - picker_height) / 2 else 1;
    const picker_title = if (current_tab == 2) "I/O Columns" else "Process Columns";

    for (0..picker_height) |i| {
        try app_tui.moveCursor(picker_x, picker_y + @as(u16, @intCast(i)));
        for (0..picker_width) |_| try app_tui.bufWrite(" ");
    }

    try app_tui.drawBoxStyled(picker_x, picker_y, picker_width, picker_height, picker_title, .{ .fg = theme.border }, .{ .fg = theme.text, .bold = true });
    try app_tui.moveCursor(picker_x + 2, picker_y + 2);
    try app_tui.printStyled(.{ .fg = theme.muted }, "Name is always visible.", .{});

    for (config.process_column_order, 0..) |column, idx| {
        try app_tui.moveCursor(picker_x + 2, picker_y + 4 + @as(u16, @intCast(idx)));
        try app_tui.printStyled(.{ .fg = theme.text, .bold = true }, "{d}. ", .{idx + 1});
        try app_tui.printStyled(
            .{ .fg = if (picker_columns.isVisible(column)) theme.usage_good else theme.muted, .bold = picker_columns.isVisible(column) },
            "[{c}]",
            .{if (picker_columns.isVisible(column)) @as(u8, 'x') else @as(u8, ' ')},
        );
        try app_tui.printStyled(.{ .fg = theme.text }, " {s}", .{column.label()});
    }

    try app_tui.moveCursor(picker_x + 2, picker_y + picker_height - 2);
    var picker_help_buf: [64]u8 = undefined;
    const picker_help = std.fmt.bufPrint(&picker_help_buf, "Press 1-{d} to toggle, Enter/Esc to close", .{config.process_column_order.len}) catch "Press number to toggle, Enter/Esc to close";
    try app_tui.printStyled(.{ .fg = theme.muted }, "{s}", .{picker_help});
}
