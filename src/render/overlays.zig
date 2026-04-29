const std = @import("std");
const config = @import("../config.zig");
const tui = @import("../tui.zig");
const util = @import("util.zig");

const Tui = tui.Tui;

const HelpItem = struct {
    key: []const u8,
    description: []const u8,
};

const help_items = [_]HelpItem{
    .{ .key = "1–5", .description = "Switch tabs (5 = Diagnostics)" },
    .{ .key = "j/k, Up/Down", .description = "Navigate processes" },
    .{ .key = "c,m,p,n,u", .description = "Sort by CPU/Mem/PID/Name/Wakeups" },
    .{ .key = "v", .description = "Toggle tree view" },
    .{ .key = "C", .description = "Process column picker" },
    .{ .key = "/", .description = "Filter processes" },
    .{ .key = "Enter", .description = "View threads of selected" },
    .{ .key = "t", .description = "Send SIGTERM to selected" },
    .{ .key = "K", .description = "Send SIGKILL to selected" },
    .{ .key = "g", .description = "Resource causality graph" },
    .{ .key = "5", .description = "Diagnostics tab (why busy + pressure hints)" },
    .{ .key = "u", .description = "Wakeup attribution sort" },
    .{ .key = "l", .description = "Follow selected process" },
    .{ .key = "T", .description = "Timeline scrub (←→ step, [] jump)" },
    .{ .key = "b/B, {}/{}", .description = "Bookmark add/del, jump prev/next" },
    .{ .key = "d", .description = "Diff view (compare two moments)" },
    .{ .key = "L", .description = "View process lifeline" },
    .{ .key = "q", .description = "Quit" },
    .{ .key = ":", .description = "Command mode (pid/signal/renice/interval/top...)" },
};

fn textWidth(text: []const u8) usize {
    return std.unicode.utf8CountCodepoints(text) catch text.len;
}

fn maxKeyWidth(items: []const HelpItem) usize {
    var width: usize = 0;
    for (items) |item| {
        width = @max(width, textWidth(item.key));
    }
    return width;
}

fn maxDescriptionWidth(items: []const HelpItem) usize {
    var width: usize = 0;
    for (items) |item| {
        width = @max(width, textWidth(item.description));
    }
    return width;
}

fn writeTextCell(app_tui: *Tui, style: Tui.Style, text: []const u8, width: usize) !void {
    if (width == 0) return;

    const full_width = textWidth(text);
    if (full_width <= width) {
        try app_tui.writeStyled(style, text);
        for (full_width..width) |_| try app_tui.writeStyled(style, " ");
        return;
    }

    if (width == 1) {
        try app_tui.writeStyled(style, ".");
        return;
    }

    const clipped = util.clipUtf8(text, width - 1);
    const clipped_width = textWidth(clipped);
    try app_tui.writeStyled(style, clipped);
    try app_tui.writeStyled(style, ".");
    const used = @min(width, clipped_width + 1);
    for (used..width) |_| try app_tui.writeStyled(style, " ");
}

fn renderHelpItemCell(
    app_tui: *Tui,
    theme: config.Theme,
    item: ?HelpItem,
    column_width: usize,
    key_width: usize,
) !void {
    if (column_width == 0) return;

    if (item) |entry| {
        const effective_key_width = @min(key_width, column_width);
        const remaining_after_key = column_width -| effective_key_width;
        const separator_width: usize = if (remaining_after_key > 0) 1 else 0;
        const description_width = remaining_after_key -| separator_width;

        try writeTextCell(app_tui, .{ .fg = theme.text }, entry.key, effective_key_width);

        if (separator_width > 0) {
            try app_tui.writeStyled(.{ .fg = theme.muted }, " ");
        }

        if (description_width > 0) {
            try writeTextCell(app_tui, .{ .fg = theme.muted }, entry.description, description_width);
        }
    } else {
        for (0..column_width) |_| try app_tui.bufWrite(" ");
    }
}

pub fn renderHelpOverlay(
    app_tui: *Tui,
    theme: config.Theme,
    width: u16,
    height: u16,
    repo_url: []const u8,
    repo_label: []const u8,
) !void {
    const left_count: usize = (help_items.len + 1) / 2;
    const right_count: usize = help_items.len - left_count;
    const row_count: usize = @max(left_count, right_count);

    const left_items = help_items[0..left_count];
    const right_items = help_items[left_count..];

    const key_gap: usize = 1;
    const desired_column_gap: usize = 4;
    const desired_left_col_width = maxKeyWidth(left_items) + key_gap + maxDescriptionWidth(left_items);
    const desired_right_col_width = maxKeyWidth(right_items) + key_gap + maxDescriptionWidth(right_items);
    const desired_inner_width = desired_left_col_width + desired_column_gap + desired_right_col_width;
    const desired_help_width = desired_inner_width + 4;
    const desired_help_height = row_count + 6;

    const max_help_width: usize = if (width > 2) width - 2 else width;
    const max_help_height: usize = if (height > 2) height - 2 else height;
    if (max_help_width < 24 or max_help_height < 8) return;

    var help_width_usize = @min(desired_help_width, max_help_width);
    if (help_width_usize < 36) help_width_usize = @min(max_help_width, @as(usize, 36));

    var help_height_usize = @min(desired_help_height, max_help_height);
    if (help_height_usize < 10) help_height_usize = @min(max_help_height, @as(usize, 10));

    const help_width: u16 = @intCast(help_width_usize);
    const help_height: u16 = @intCast(help_height_usize);
    const h_x = if (width > help_width) (width - help_width) / 2 else 1;
    const h_y = if (height > help_height) (height - help_height) / 2 else 1;

    for (0..help_height) |i| {
        try app_tui.moveCursor(h_x, h_y + @as(u16, @intCast(i)));
        for (0..help_width) |_| try app_tui.bufWrite(" ");
    }

    try app_tui.drawBoxStyled(h_x, h_y, help_width, help_height, "Help", .{ .fg = theme.border }, .{ .fg = theme.text, .bold = true });

    const content_x = h_x + 2;
    const content_width = help_width_usize -| 4;
    const column_gap: usize = if (content_width >= 70) 4 else if (content_width >= 44) 3 else 2;
    const columns_width = content_width -| column_gap;
    const left_column_width = (columns_width + 1) / 2;
    const right_column_width = columns_width - left_column_width;

    const left_key_width = @min(maxKeyWidth(left_items), left_column_width -| 1);
    const right_key_width = @min(maxKeyWidth(right_items), right_column_width -| 1);

    const interior_height = help_height_usize -| 2;
    const top_padding_rows: usize = 1;
    const spacer_rows: usize = 1;
    const footer_rows: usize = 2;
    const max_rows_to_render = interior_height -| (top_padding_rows + spacer_rows + footer_rows);
    const rows_to_render = @min(row_count, max_rows_to_render);

    const row_start_y = h_y + 1 + @as(u16, @intCast(top_padding_rows));
    for (0..rows_to_render) |row_idx| {
        try app_tui.moveCursor(content_x, row_start_y + @as(u16, @intCast(row_idx)));
        try renderHelpItemCell(app_tui, theme, left_items[row_idx], left_column_width, left_key_width);
        for (0..column_gap) |_| try app_tui.bufWrite(" ");
        const right_item: ?HelpItem = if (row_idx < right_items.len) right_items[row_idx] else null;
        try renderHelpItemCell(app_tui, theme, right_item, right_column_width, right_key_width);
    }

    const info_y = row_start_y + @as(u16, @intCast(rows_to_render));
    const max_info_y = h_y + help_height - 3;
    if (info_y <= max_info_y) {
        try app_tui.moveCursor(content_x, info_y);
        if (rows_to_render < row_count) {
            const shown_right = @min(rows_to_render, right_items.len);
            const shown_entries = rows_to_render + shown_right;
            const hidden_entries = help_items.len -| shown_entries;
            var hidden_buf: [96]u8 = undefined;
            const hidden_msg = std.fmt.bufPrint(&hidden_buf, "{d} shortcut(s) hidden; enlarge terminal", .{hidden_entries}) catch "Some shortcuts hidden; enlarge terminal";
            try writeTextCell(app_tui, .{ .fg = theme.usage_warn }, hidden_msg, content_width);
        } else {
            try writeTextCell(app_tui, .{ .fg = theme.muted }, "", content_width);
        }
    }

    const footer_repo_y = h_y + help_height - 3;
    const footer_close_y = h_y + help_height - 2;
    const repo_prefix = "Repo: ";

    try app_tui.moveCursor(content_x, footer_repo_y);
    const repo_prefix_width = textWidth(repo_prefix);
    try app_tui.writeStyled(.{ .fg = theme.text }, repo_prefix);
    const repo_label_width = content_width -| repo_prefix_width;
    if (repo_label_width > 0) {
        const clipped_repo_label = util.clipUtf8(repo_label, repo_label_width);
        const clipped_repo_label_width = textWidth(clipped_repo_label);
        try app_tui.writeStyledHyperlink(.{ .fg = theme.tab_active, .underline = true }, repo_url, clipped_repo_label);
        for (clipped_repo_label_width..repo_label_width) |_| try app_tui.bufWrite(" ");
    }

    try app_tui.moveCursor(content_x, footer_close_y);
    try writeTextCell(app_tui, .{ .fg = theme.muted }, "Press any key to close...", content_width);
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
