const std = @import("std");
const ztop = @import("ztop");
const config = @import("ztop").config;
const render = @import("ztop").render;
const tui = @import("ztop").tui;

fn testTui(frame_buf: []u8) tui.Tui {
    return .{
        .original_termios = std.mem.zeroes(std.posix.termios),
        .io = std.testing.io,
        .in = std.Io.File.stdin(),
        .out = std.Io.File.stdout(),
        .features = .{ .synchronized_output = false },
        .cursor_visible = false,
        .cursor_style = .steady_block,
        .frame_active = true,
        .nerd_fonts = false,
        .current_style = null,
        .frame_buf = frame_buf,
        .frame_len = 0,
        .allocator = std.testing.allocator,
        .cursor_buf = undefined,
        .style_buf = undefined,
        .print_buf = undefined,
    };
}

fn expectCursorBeforeText(output: []const u8, cursor: []const u8, text: []const u8) !void {
    const cursor_index = std.mem.indexOf(u8, output, cursor) orelse return error.MissingCursor;
    const text_index = std.mem.indexOfPos(u8, output, cursor_index, text) orelse return error.MissingText;
    try std.testing.expect(text_index > cursor_index);
}

test "planProcessTableLayout keeps enabled columns when width allows" {
    var columns = config.ProcessColumns.defaultsMain();
    columns.ppid = true;

    const layout = render.planProcessTableLayout(columns, 48);

    try std.testing.expectEqual(@as(usize, 5), layout.count);
    try std.testing.expectEqual(@as(usize, 8), layout.name_width);
    try std.testing.expectEqual(@as(usize, 0), layout.dropped_count);
    try std.testing.expectEqual(config.ProcessColumn.pid, layout.columns[0]);
    try std.testing.expectEqual(config.ProcessColumn.ppid, layout.columns[1]);
    try std.testing.expectEqual(config.ProcessColumn.cpu, layout.columns[2]);
    try std.testing.expectEqual(config.ProcessColumn.mem, layout.columns[3]);
    try std.testing.expectEqual(config.ProcessColumn.threads, layout.columns[4]);
}

test "planProcessTableLayout drops trailing columns to preserve name width" {
    const layout = render.planProcessTableLayout(config.ProcessColumns.all(), 40);

    try std.testing.expectEqual(@as(usize, 2), layout.count);
    try std.testing.expectEqual(@as(usize, 28), layout.name_width);
    try std.testing.expectEqual(@as(usize, 9), layout.dropped_count);
    try std.testing.expect(layout.name_width >= render.min_process_name_width);
    try std.testing.expectEqual(config.ProcessColumn.pid, layout.columns[0]);
    try std.testing.expectEqual(config.ProcessColumn.ppid, layout.columns[1]);
}

test "planProcessTableLayout gives launch_path extra width from leftover space" {
    var columns = config.ProcessColumns.none();
    columns.pid = true;
    columns.launch_path = true;
    columns.cpu = true;

    const layout = render.planProcessTableLayout(columns, 80);

    // fixed_width = pid(6) + launch_path(24) + cpu(10) = 40, remaining = 40
    // remaining > default_process_name_width(20), so name gets 20 and launch_path gets the rest.
    try std.testing.expectEqual(@as(usize, 20), layout.name_width);
    try std.testing.expectEqual(@as(usize, 20), layout.launch_path_extra);
}

test "diskUsagePercent reports used out of total capacity" {
    try std.testing.expectEqual(@as(f32, 0), ztop.sysinfo.common.diskUsagePercent(.{}));
    try std.testing.expectEqual(@as(f32, 25), ztop.sysinfo.common.diskUsagePercent(.{
        .capacity_used_bytes = 256,
        .capacity_total_bytes = 1024,
    }));
}

test "renderDualRateBox shows disk usage as static row with spacer before live rates" {
    var read_history: ztop.history.RateHistory = .{};
    var write_history: ztop.history.RateHistory = .{};
    read_history.append(512);
    write_history.append(256);

    var frame_buf: [32 * 1024]u8 = undefined;
    var app_tui = testTui(&frame_buf);

    try render.renderDualRateBox(
        &app_tui,
        config.themePreset(.default),
        1,
        1,
        80,
        12,
        "Disk I/O",
        .bright_blue,
        .{
            .label = "READ",
            .short_label = "R ",
            .rate_bytes_ps = 512,
            .history = &read_history,
            .color = .bright_blue,
        },
        .{
            .label = "WRITE",
            .short_label = "W ",
            .rate_bytes_ps = 256,
            .history = &write_history,
            .color = .bright_cyan,
        },
        &.{},
        .{
            .label = "USED",
            .short_label = "U ",
            .used_bytes = 256 * 1024 * 1024 * 1024,
            .total_bytes = 1024 * 1024 * 1024 * 1024,
            .color = .bright_blue,
        },
        false,
    );

    const output = app_tui.frame_buf[0..app_tui.frame_len];
    try expectCursorBeforeText(output, "\x1b[2;3H", "USED ");
    try expectCursorBeforeText(output, "\x1b[4;3H", "READ ");
    try expectCursorBeforeText(output, "\x1b[5;3H", "WRITE ");
    try std.testing.expect(std.mem.indexOf(u8, output, "U ") == null);
}
