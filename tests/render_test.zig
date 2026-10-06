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

test "frames buffer output with and without terminal synchronization" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    for ([_]bool{ false, true }) |synchronized| {
        const out = try tmp.dir.createFile(std.testing.io, "frame", .{});
        defer out.close(std.testing.io);
        var buf: [128]u8 = undefined;
        var app_tui = testTui(&buf);
        app_tui.out = out;
        app_tui.frame_active = false;
        app_tui.features.synchronized_output = synchronized;

        try app_tui.beginFrame();
        try app_tui.beginFrame();
        try app_tui.bufWrite("hello");
        try app_tui.bufWrite(" world");
        var actual: [128]u8 = undefined;
        try std.testing.expectEqualStrings("", try tmp.dir.readFile(std.testing.io, "frame", &actual));
        try app_tui.endFrame();
        try app_tui.endFrame();
        try std.testing.expectEqualStrings(
            if (synchronized) "\x1b[?2026hhello world\x1b[?2026l" else "hello world",
            try tmp.dir.readFile(std.testing.io, "frame", &actual),
        );
        try std.testing.expectEqual(false, app_tui.frame_active);
        try std.testing.expectEqual(@as(usize, 0), app_tui.frame_len);
    }
}

test "synchronized frames preserve markers across buffer flushes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const out = try tmp.dir.createFile(std.testing.io, "frame", .{});
    defer out.close(std.testing.io);
    var buf: [12]u8 = undefined;
    var app_tui = testTui(&buf);
    app_tui.out = out;
    app_tui.frame_active = false;
    app_tui.features.synchronized_output = true;
    try app_tui.beginFrame();
    try app_tui.bufWrite("abc");
    try app_tui.bufWrite("longer than the frame buffer");
    try app_tui.bufWrite("xyz");
    try app_tui.endFrame();
    var actual: [128]u8 = undefined;
    try std.testing.expectEqualStrings("\x1b[?2026habclonger than the frame bufferxyz\x1b[?2026l", try tmp.dir.readFile(std.testing.io, "frame", &actual));
}

test "repeated UTF-8 glyphs and padding preserve style transitions" {
    var buf: [1024]u8 = undefined;
    var app_tui = testTui(&buf);
    const style: tui.Tui.Style = .{ .fg = .cyan };

    try app_tui.writeRepeated(style, "─", 3);
    try app_tui.writeRepeated(style, "█", 2);
    try app_tui.writeSpaces(4);
    try app_tui.writeRepeated(.{ .fg = .red }, ".", 2);

    try std.testing.expectEqualStrings("\x1b[0;36m───██    \x1b[0;31m..", buf[0..app_tui.frame_len]);
    try std.testing.expectEqual(tui.Tui.Style{ .fg = .red }, app_tui.current_style.?);
}

test "empty repeated runs leave output and style unchanged" {
    var buf: [128]u8 = undefined;
    var app_tui = testTui(&buf);

    try app_tui.writeRepeated(.{ .fg = .red }, "─", 0);
    try app_tui.writeRepeated(.{ .fg = .red }, "", 10);
    try app_tui.writeSpaces(0);

    try std.testing.expectEqual(@as(usize, 0), app_tui.frame_len);
    try std.testing.expectEqual(@as(?tui.Tui.Style, null), app_tui.current_style);
}

test "repeated glyphs and spaces handle multiple chunks" {
    var buf: [4096]u8 = undefined;
    var app_tui = testTui(&buf);

    try app_tui.writeRepeated(.{}, "─", 513);
    try app_tui.writeSpaces(257);

    try std.testing.expectEqual(@as(usize, 4 + 513 * 3 + 257), app_tui.frame_len);
    try std.testing.expectEqualStrings("\x1b[0m", buf[0..4]);
    for (0..513) |i| {
        try std.testing.expectEqualStrings("─", buf[4 + i * 3 ..][0..3]);
    }
    for (buf[4 + 513 * 3 .. app_tui.frame_len]) |byte| {
        try std.testing.expectEqual(@as(u8, ' '), byte);
    }
}

test "box borders support widths larger than the repeat buffer" {
    var buf: [8192]u8 = undefined;
    var app_tui = testTui(&buf);

    try app_tui.drawBoxStyled(1, 1, 600, 2, "", .{}, .{});

    const prefix = "\x1b[0m\x1b[1;1H╭";
    const middle = "╮\x1b[2;1H╰";
    const suffix = "╯\x1b[0m";
    const border_len = 598 * 3;
    const bottom_start = prefix.len + border_len + middle.len;
    try std.testing.expectEqual(prefix.len + border_len * 2 + middle.len + suffix.len, app_tui.frame_len);
    try std.testing.expectEqualStrings(prefix, buf[0..prefix.len]);
    try std.testing.expectEqualStrings(middle, buf[prefix.len + border_len .. bottom_start]);
    try std.testing.expectEqualStrings(suffix, buf[bottom_start + border_len .. app_tui.frame_len]);
    for (0..598) |i| {
        try std.testing.expectEqualStrings("─", buf[prefix.len + i * 3 ..][0..3]);
        try std.testing.expectEqualStrings("─", buf[bottom_start + i * 3 ..][0..3]);
    }
}

fn expectCursorBeforeText(output: []const u8, cursor: []const u8, text: []const u8) !void {
    const cursor_index = std.mem.indexOf(u8, output, cursor) orelse return error.MissingCursor;
    const text_index = std.mem.indexOfPos(u8, output, cursor_index, text) orelse return error.MissingText;
    try std.testing.expect(text_index > cursor_index);
}

test "process row cache skips unchanged visible content and preserves style" {
    var buf: [8192]u8 = undefined;
    var app_tui = testTui(&buf);
    var cache = render.ProcessTableCache.init(std.testing.allocator);
    defer cache.deinit();
    const region: render.ProcessTableCache.Region = .{ .x = 3, .y = 10, .width = 76, .height = 2 };
    const theme = config.themePreset(.default);
    const layout = render.planProcessTableLayout(config.ProcessColumns.defaultsMain(), region.width);
    var proc: ztop.sysinfo.ProcStats = .{ .pid = 42, .name_len = 4, .cpu_percent = 1.01 };
    @memcpy(proc.name_buf[0..4], "test");

    try cache.clearFrame(&app_tui, 80, 24, region);
    app_tui.frame_len = 0;
    try cache.renderRow(&app_tui, 3, 10, &theme, &layout, &proc, false, "", 0, 8, null);
    try expectCursorBeforeText(buf[0..app_tui.frame_len], "\x1b[10;3H", "test");

    try cache.clearFrame(&app_tui, 80, 24, region);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..app_tui.frame_len], "\x1b[2J") == null);
    app_tui.frame_len = 0;
    app_tui.current_style = .{ .fg = .magenta };
    try cache.renderRow(&app_tui, 3, 10, &theme, &layout, &proc, false, "", 0, 8, null);
    try std.testing.expectEqual(@as(usize, 0), app_tui.frame_len);
    proc.ppid = 100;
    proc.cpu_percent = 1.02;
    try cache.renderRow(&app_tui, 3, 10, &theme, &layout, &proc, false, "", 0, 8, null);
    try std.testing.expectEqual(@as(usize, 0), app_tui.frame_len);
    try std.testing.expectEqual(tui.Tui.Style{ .fg = .magenta }, app_tui.current_style.?);

    proc.cpu_percent = 2;
    try cache.renderRow(&app_tui, 3, 10, &theme, &layout, &proc, false, "", 0, 8, null);
    try expectCursorBeforeText(buf[0..app_tui.frame_len], "\x1b[10;3H", "2.0% CPU");
}

test "process row cache updates selection and clears removed rows once" {
    var buf: [8192]u8 = undefined;
    var app_tui = testTui(&buf);
    var cache = render.ProcessTableCache.init(std.testing.allocator);
    defer cache.deinit();
    const region: render.ProcessTableCache.Region = .{ .x = 3, .y = 10, .width = 76, .height = 3 };
    const theme = config.themePreset(.default);
    const layout = render.planProcessTableLayout(config.ProcessColumns.defaultsMain(), region.width);
    const first: ztop.sysinfo.ProcStats = .{ .pid = 42 };
    const second: ztop.sysinfo.ProcStats = .{ .pid = 43 };

    try cache.clearFrame(&app_tui, 80, 24, region);
    try cache.renderRow(&app_tui, 3, 10, &theme, &layout, &first, true, "", 0, 8, null);
    try cache.renderRow(&app_tui, 3, 11, &theme, &layout, &second, false, "", 0, 8, null);
    app_tui.frame_len = 0;
    try cache.renderRow(&app_tui, 3, 10, &theme, &layout, &first, false, "", 0, 8, null);
    try cache.renderRow(&app_tui, 3, 11, &theme, &layout, &second, true, "", 0, 8, null);
    try expectCursorBeforeText(buf[0..app_tui.frame_len], "\x1b[10;3H", "42");
    try expectCursorBeforeText(buf[0..app_tui.frame_len], "\x1b[11;3H", "43");

    app_tui.frame_len = 0;
    try cache.finishRows(&app_tui, 1);
    try std.testing.expect(std.mem.startsWith(u8, buf[0..app_tui.frame_len], "\x1b[11;3H"));
    try std.testing.expect(std.mem.indexOf(u8, buf[0..app_tui.frame_len], "43") == null);
    app_tui.frame_len = 0;
    try cache.finishRows(&app_tui, 1);
    try std.testing.expectEqual(@as(usize, 0), app_tui.frame_len);
    try cache.renderRow(&app_tui, 3, 10, &theme, &layout, &second, false, "", 0, 8, null);
    try expectCursorBeforeText(buf[0..app_tui.frame_len], "\x1b[10;3H", "43");
}

test "process row cache includes tree prefixes theme columns and power" {
    var buf: [8192]u8 = undefined;
    var app_tui = testTui(&buf);
    var cache = render.ProcessTableCache.init(std.testing.allocator);
    defer cache.deinit();
    const region: render.ProcessTableCache.Region = .{ .x = 3, .y = 10, .width = 76, .height = 2 };
    var theme = config.themePreset(.default);
    var columns = config.ProcessColumns.defaultsMain();
    var layout = render.planProcessTableLayout(columns, region.width);
    const proc: ztop.sysinfo.ProcStats = .{ .pid = 42, .cpu_percent = 100 };
    try cache.clearFrame(&app_tui, 80, 24, region);
    try cache.renderRow(&app_tui, 3, 10, &theme, &layout, &proc, false, "", 0, 8, 20);

    app_tui.frame_len = 0;
    try cache.renderRow(&app_tui, 3, 10, &theme, &layout, &proc, false, "|- ", 3, 8, 20);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..app_tui.frame_len], "|- ") != null);
    app_tui.frame_len = 0;
    theme.text = .magenta;
    try cache.renderRow(&app_tui, 3, 10, &theme, &layout, &proc, false, "|- ", 3, 8, 20);
    try std.testing.expect(app_tui.frame_len > 0);

    columns.energy = true;
    layout = render.planProcessTableLayout(columns, region.width);
    app_tui.frame_len = 0;
    try cache.renderRow(&app_tui, 3, 10, &theme, &layout, &proc, false, "|- ", 3, 8, 20);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..app_tui.frame_len], "1.75W") != null);
    app_tui.frame_len = 0;
    try cache.renderRow(&app_tui, 3, 10, &theme, &layout, &proc, false, "|- ", 3, 8, 40);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..app_tui.frame_len], "3.50W") != null);
}

test "process row cache invalidates after overlays and geometry changes" {
    var buf: [8192]u8 = undefined;
    var app_tui = testTui(&buf);
    var cache = render.ProcessTableCache.init(std.testing.allocator);
    defer cache.deinit();
    var region: render.ProcessTableCache.Region = .{ .x = 3, .y = 10, .width = 76, .height = 2 };
    const theme = config.themePreset(.default);
    const layout = render.planProcessTableLayout(config.ProcessColumns.defaultsMain(), region.width);
    const proc: ztop.sysinfo.ProcStats = .{ .pid = 42 };
    try cache.clearFrame(&app_tui, 80, 24, region);
    try cache.renderRow(&app_tui, 3, 10, &theme, &layout, &proc, false, "", 0, 8, null);

    try cache.clearFrame(&app_tui, 80, 24, null);
    try cache.clearFrame(&app_tui, 80, 24, region);
    app_tui.frame_len = 0;
    try cache.renderRow(&app_tui, 3, 10, &theme, &layout, &proc, false, "", 0, 8, null);
    try std.testing.expect(app_tui.frame_len > 0);

    region.y = 11;
    try cache.clearFrame(&app_tui, 80, 24, region);
    app_tui.frame_len = 0;
    try cache.renderRow(&app_tui, 3, 11, &theme, &layout, &proc, false, "", 0, 8, null);
    try expectCursorBeforeText(buf[0..app_tui.frame_len], "\x1b[11;3H", "42");
    try cache.clearFrame(&app_tui, 80, 25, region);
    app_tui.frame_len = 0;
    try cache.renderRow(&app_tui, 3, 11, &theme, &layout, &proc, false, "", 0, 8, null);
    try std.testing.expect(app_tui.frame_len > 0);
}

test "planProcessTableLayout keeps enabled columns when width allows" {
    var columns = config.ProcessColumns.defaultsMain();
    columns.ppid = true;

    const layout = render.planProcessTableLayout(columns, 48);

    try std.testing.expectEqual(@as(usize, 5), layout.count);
    try std.testing.expectEqual(@as(usize, 8), layout.name_width);
    try std.testing.expectEqual(@as(usize, 0), layout.dropped_count);
    try std.testing.expectEqual(@as(usize, 2), layout.name_column_index);
    try std.testing.expectEqual(config.ProcessColumn.pid, layout.columns[0]);
    try std.testing.expectEqual(config.ProcessColumn.ppid, layout.columns[1]);
    try std.testing.expectEqual(config.ProcessColumn.cpu, layout.columns[2]);
    try std.testing.expectEqual(config.ProcessColumn.mem, layout.columns[3]);
    try std.testing.expectEqual(config.ProcessColumn.threads, layout.columns[4]);
    try std.testing.expectEqual(render.processColumnWidth(.cpu), layout.column_widths[2]);
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
    try std.testing.expectEqual(@as(usize, 44), layout.column_widths[1]);
}

test "process disk rates use fixed-width aligned units" {
    var bytes_buf: [32]u8 = undefined;
    var kib_buf: [32]u8 = undefined;
    var mib_buf: [32]u8 = undefined;

    const bytes = render.formatProcessRate(&bytes_buf, 'R', 0);
    const kib = render.formatProcessRate(&kib_buf, 'R', 1024);
    const mib = render.formatProcessRate(&mib_buf, 'W', 2 * 1024 * 1024);

    try std.testing.expectEqualStrings(" R    0.0 B/s", bytes);
    try std.testing.expectEqualStrings(" R    1.0KB/s", kib);
    try std.testing.expectEqualStrings(" W    2.0MB/s", mib);
    try std.testing.expectEqual(render.processColumnWidth(.disk_read), bytes.len);
    try std.testing.expectEqual(render.processColumnWidth(.disk_read), kib.len);
    try std.testing.expectEqual(render.processColumnWidth(.disk_write), mib.len);
}

test "diskUsagePercent reports used out of total capacity" {
    try std.testing.expectEqual(@as(f32, 0), ztop.sysinfo.common.diskUsagePercent(.{}));
    try std.testing.expectEqual(@as(f32, 25), ztop.sysinfo.common.diskUsagePercent(.{
        .capacity_used_bytes = 256,
        .capacity_total_bytes = 1024,
    }));
}

test "planProcessTableLayout handles zero available width" {
    const layout = render.planProcessTableLayout(config.ProcessColumns.all(), 0);

    try std.testing.expectEqual(@as(usize, 0), layout.count);
    try std.testing.expectEqual(@as(usize, 0), layout.name_width);
    try std.testing.expectEqual(config.process_column_order.len, layout.dropped_count);
}

test "planProcessTableLayout with no fixed columns gives all width to name" {
    const layout = render.planProcessTableLayout(config.ProcessColumns.none(), 17);

    try std.testing.expectEqual(@as(usize, 0), layout.count);
    try std.testing.expectEqual(@as(usize, 17), layout.name_width);
    try std.testing.expectEqual(@as(usize, 0), layout.dropped_count);
}

test "formatProcessRate returns empty when destination is too small" {
    var tiny: [4]u8 = undefined;
    try std.testing.expectEqualStrings("", render.formatProcessRate(&tiny, 'R', std.math.maxInt(u64)));
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
