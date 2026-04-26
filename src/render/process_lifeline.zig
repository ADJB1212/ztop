const std = @import("std");
const tui = @import("../tui.zig");
const config = @import("../config.zig");
const util = @import("util.zig");
const graphs = @import("graphs.zig");
const why_busy = @import("why_busy.zig");
const ProcessTracer = @import("../process_tracer.zig").ProcessTracer;
const Tui = tui.Tui;

pub fn renderLifelineView(
    app_tui: *Tui,
    theme: config.Theme,
    x: u16,
    y: u16,
    width: u16,
    height: u16,
    tracer: *ProcessTracer,
    proc_name: []const u8,
    scroll_offset: usize,
) !void {
    if (height < 10 or width < 40) return;

    var title_buf: [128]u8 = undefined;
    const title = std.fmt.bufPrint(&title_buf, "Lifeline: {s} (PID: {d}) - {s}", .{ proc_name, tracer.pid, if (tracer.is_dead) "Dead" else "Alive" }) catch "Lifeline View";

    try app_tui.drawBoxStyled(x, y, width, height, title, .{ .fg = theme.border }, .{ .fg = theme.process_title, .bold = true });

    const inner_x = x + 2;
    const inner_width = width -| 4;
    const inner_height = height -| 2;

    // Layout: Top 5 rows for graphs (CPU and Mem sparklines)
    const graph_height: u16 = 5;
    const graph_width = inner_width / 2;
    const right_graph_x = inner_x + graph_width + 1;

    // CPU Graph
    try app_tui.moveCursor(inner_x, y + 1);
    try app_tui.printStyled(.{ .fg = theme.usage_warn, .bold = true }, "CPU History", .{});
    try graphs.renderHistoryGraph(app_tui, theme, inner_x, y + 2, graph_width -| 2, graph_height -| 1, &tracer.cpu_history, .cpu);

    // Mem Graph
    try app_tui.moveCursor(right_graph_x, y + 1);
    try app_tui.printStyled(.{ .fg = theme.memory_mid, .bold = true }, "Memory History", .{});
    try graphs.renderHistoryGraph(app_tui, theme, right_graph_x, y + 2, graph_width -| 2, graph_height -| 1, &tracer.mem_history, .memory);

    // Divider
    const div_y = y + 1 + graph_height;
    try app_tui.moveCursor(x + 1, div_y);
    for (0..width -| 2) |_| try app_tui.writeStyled(.{ .fg = theme.border, .dim = true }, "─");

    // Events List
    const event_header_y = div_y + 1;
    try app_tui.moveCursor(inner_x, event_header_y);
    try app_tui.printStyled(.{ .fg = theme.text, .bold = true }, "Event Log", .{});

    const event_list_y = event_header_y + 1;
    const event_list_height = inner_height -| graph_height -| 2;

    if (event_list_height == 0) return;

    if (tracer.ev_count == 0) {
        try app_tui.moveCursor(inner_x, event_list_y);
        try app_tui.printStyled(.{ .fg = theme.muted, .dim = true }, "No lifeline events recorded yet. Polling...", .{});
        return;
    }

    var row: u16 = 0;
    // Iterate backwards (newest first)
    var i: usize = tracer.ev_count;
    while (i > 0) {
        i -= 1;
        if (tracer.ev_count - 1 - i < scroll_offset) continue;
        if (row >= event_list_height) break;

        const ev = tracer.getEvent(i) orelse continue;

        try app_tui.moveCursor(inner_x, event_list_y + row);

        var ts_buf: [12]u8 = undefined;
        const time_str = why_busy.fmtTimestamp(ev.timestamp_ms, &ts_buf);
        try app_tui.printStyled(.{ .fg = theme.muted }, "{s} ", .{time_str});

        const kind_color: Tui.Color = switch (ev.kind) {
            .state_transition => theme.text,
            .cpu_burst => theme.usage_warn,
            .memory_growth => theme.memory_mid,
            .thread_spawn => theme.io_rate,
            .thread_exit => theme.muted,
            .socket_open => theme.usage_good,
            .socket_close => theme.muted,
            .proc_exit => theme.usage_critical,
        };

        const kind_label = switch (ev.kind) {
            .state_transition => "STATE",
            .cpu_burst => "CPU  ",
            .memory_growth => "MEM  ",
            .thread_spawn => "THRD+",
            .thread_exit => "THRD-",
            .socket_open => "SOCK+",
            .socket_close => "SOCK-",
            .proc_exit => "EXIT ",
        };

        try app_tui.printStyled(.{ .fg = kind_color, .bold = true }, "{s} ", .{kind_label});

        const detail = ev.detail();
        const max_detail_width = inner_width -| 20;
        if (detail.len > max_detail_width) {
            try app_tui.printStyled(.{ .fg = theme.text }, "{s}..", .{detail[0..max_detail_width -| 2]});
        } else {
            try app_tui.printStyled(.{ .fg = theme.text }, "{s}", .{detail});
        }

        row += 1;
    }
}
