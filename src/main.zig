const std = @import("std");
const ztop = @import("ztop");
const Tui = ztop.tui.Tui;
const SysInfo = ztop.sysinfo.SysInfo;

fn usageColor(percent: f32) Tui.Color {
    if (percent >= 90) return .bright_red;
    if (percent >= 70) return .bright_yellow;
    if (percent >= 40) return .bright_green;
    return .bright_cyan;
}

fn memoryColor(percent: f32) Tui.Color {
    if (percent >= 80) return .bright_red;
    if (percent >= 60) return .bright_yellow;
    if (percent >= 35) return .bright_magenta;
    return .bright_blue;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app_tui = try Tui.init();
    defer app_tui.deinit();

    var sys_info = SysInfo.init();

    while (true) {
        const size = try app_tui.getWinSize();
        try app_tui.clear();

        // Status Bar
        const uname = std.posix.uname();
        const sysname = std.mem.sliceTo(&uname.sysname, 0);
        const release = std.mem.sliceTo(&uname.release, 0);
        const machine = std.mem.sliceTo(&uname.machine, 0);
        const nodename = std.mem.sliceTo(&uname.nodename, 0);
        
        try app_tui.moveCursor(1, 1);
        try app_tui.printStyled(.{ .fg = .bright_cyan, .bold = true }, " ztop ", .{});
        try app_tui.printStyled(.{ .fg = .white, .dim = true }, "- {s} {s} {s} - {s}", .{ sysname, release, machine, nodename });

        const available_height = size.height -| 2; // Subtract top bar and footer
        const top_boxes_height = available_height / 3;
        const bottom_box_height = available_height - top_boxes_height;

        // CPU Box
        const cpu_box_width = size.width / 2;
        const cpu_box_height = top_boxes_height;
        try app_tui.drawBoxStyled(
            1,
            2,
            cpu_box_width,
            cpu_box_height,
            "CPU",
            .{ .fg = .bright_black },
            .{ .fg = .bright_cyan, .bold = true },
        );
        const cpu = sys_info.getCpuStats();
        try app_tui.moveCursor(3, 3);
        try app_tui.printStyled(.{ .fg = .white, .dim = true }, "Usage: ", .{});
        try app_tui.printStyled(.{ .fg = usageColor(cpu.usage_percent), .bold = true }, "{d:4.1}%", .{cpu.usage_percent});
        try app_tui.printStyled(.{ .fg = .bright_black }, " ({d} cores)", .{cpu.cores});

        if (cpu_box_height > 3 and cpu.per_core_usage.len > 0) {
            const rows_available: usize = cpu_box_height - 3;
            const columns: usize = if (cpu_box_width >= 40 and cpu.per_core_usage.len > rows_available) 2 else 1;
            const entries_per_column = rows_available;
            const visible_cores = @min(cpu.per_core_usage.len, entries_per_column * columns);
            const column_width: u16 = if (columns == 1) cpu_box_width - 4 else cpu_box_width / 2;

            for (0..visible_cores) |i| {
                const row = i % entries_per_column;
                const column = i / entries_per_column;
                const x = 3 + @as(u16, @intCast(column)) * column_width;
                const y = 4 + @as(u16, @intCast(row));
                try app_tui.moveCursor(x, y);
                try app_tui.printStyled(.{ .fg = .bright_black }, "CPU{d:>2}: ", .{i});
                try app_tui.printStyled(.{ .fg = usageColor(cpu.per_core_usage[i]), .bold = cpu.per_core_usage[i] >= 70 }, "{d:5.1}%", .{cpu.per_core_usage[i]});
            }
        }

        // Memory Box
        try app_tui.drawBoxStyled(
            size.width / 2 + 1,
            2,
            size.width / 2,
            top_boxes_height,
            "Memory",
            .{ .fg = .bright_black },
            .{ .fg = .bright_yellow, .bold = true },
        );
        const mem = sys_info.getMemStats();
        const mem_used_percent: f32 = if (mem.total > 0)
            @as(f32, @floatFromInt(mem.used)) / @as(f32, @floatFromInt(mem.total)) * 100.0
        else
            0;
        try app_tui.moveCursor(size.width / 2 + 3, 3);
        try app_tui.printStyled(.{ .fg = .white, .dim = true }, "Used: ", .{});
        try app_tui.printStyled(.{ .fg = memoryColor(mem_used_percent), .bold = true }, "{d} GB", .{mem.used / 1024 / 1024 / 1024});
        try app_tui.moveCursor(size.width / 2 + 3, 4);
        try app_tui.printStyled(.{ .fg = .white, .dim = true }, "Free: ", .{});
        try app_tui.printStyled(.{ .fg = .bright_green, .bold = true }, "{d} GB", .{mem.free / 1024 / 1024 / 1024});

        // Processes Box
        try app_tui.drawBoxStyled(
            1,
            2 + top_boxes_height,
            size.width,
            bottom_box_height,
            "Processes",
            .{ .fg = .bright_black },
            .{ .fg = .bright_magenta, .bold = true },
        );
        const procs = try sys_info.getProcStats(allocator);
        defer allocator.free(procs);

        for (procs, 0..) |proc, i| {
            if (i >= bottom_box_height - 2) break;
            try app_tui.moveCursor(3, 2 + top_boxes_height + 1 + @as(u16, @intCast(i)));
            try app_tui.printStyled(.{ .fg = .bright_black }, "{d:5} ", .{proc.pid});
            try app_tui.printStyled(.{ .fg = .bright_white }, "{s:16} ", .{proc.name()});
            try app_tui.printStyled(.{ .fg = usageColor(proc.cpu_percent), .bold = proc.cpu_percent >= 70 }, "{d:5.1}% CPU ", .{proc.cpu_percent});
            try app_tui.printStyled(.{ .fg = memoryColor(proc.mem_percent), .bold = proc.mem_percent >= 10 }, "{d:5.1}% MEM", .{proc.mem_percent});
        }

        // Footer
        try app_tui.moveCursor(1, size.height);
        try app_tui.printStyled(.{ .fg = .bright_black }, "Press ", .{});
        try app_tui.printStyled(.{ .fg = .bright_white, .bold = true }, "'q'", .{});
        try app_tui.printStyled(.{ .fg = .bright_black }, " to quit", .{});

        // Read input (non-blocking because of TUI settings)
        var buf: [1]u8 = undefined;
        const n = try app_tui.in.read(&buf);
        if (n > 0 and buf[0] == 'q') {
            break;
        }

        std.Thread.sleep(500 * std.time.ns_per_ms);
    }
}
