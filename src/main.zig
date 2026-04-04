const std = @import("std");
const ztop = @import("ztop");
const Tui = ztop.tui.Tui;
const SysInfo = ztop.sysinfo.SysInfo;
const posix = std.posix;

var quit_flag = false;
var sigwinch_flag = false;

fn handleSigInt(sig: c_int) callconv(.c) void {
    _ = sig;
    quit_flag = true;
}

fn handleSigWinch(sig: c_int) callconv(.c) void {
    _ = sig;
    sigwinch_flag = true;
}

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

    var act: posix.Sigaction = .{
        .handler = .{ .handler = handleSigInt },
        .mask = std.mem.zeroes(posix.sigset_t),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.INT, &act, null);
    posix.sigaction(posix.SIG.TERM, &act, null);

    var act_winch: posix.Sigaction = .{
        .handler = .{ .handler = handleSigWinch },
        .mask = std.mem.zeroes(posix.sigset_t),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.WINCH, &act_winch, null);

    var app_tui = try Tui.init();
    defer app_tui.deinit();

    var sys_info = SysInfo.init();

    var cached_procs: []ztop.sysinfo.ProcStats = &.{};
    defer if (cached_procs.len > 0) allocator.free(cached_procs);

    var sort_by: ztop.sysinfo.SortBy = .cpu;
    var selected_idx: usize = 0;
    var scroll_offset: usize = 0;
    var show_help: bool = false;
    
    var filter_buf: [32]u8 = std.mem.zeroes([32]u8);
    var filter_len: usize = 0;
    var is_filtering: bool = false;

    var filtered_indices: [2048]usize = undefined;
    var filtered_count: usize = 0;

    var cpu = sys_info.getCpuStats();
    var mem = sys_info.getMemStats();
    var disk = sys_info.getDiskStats();
    var net = sys_info.getNetStats();
    var thermal = sys_info.getThermalStats();
    var battery = sys_info.getBatteryStats();
    cached_procs = try sys_info.getProcStats(allocator, sort_by);

    var last_fetch_time = std.time.milliTimestamp();
    const fetch_interval_ms: i64 = 500;

    var force_redraw = true;
    var current_tab: u8 = 1;

    while (!quit_flag) {
        if (sigwinch_flag) {
            sigwinch_flag = false;
            force_redraw = true;
        }

        const current_time = std.time.milliTimestamp();
        const elapsed = current_time - last_fetch_time;

        if (elapsed >= fetch_interval_ms) {
            cpu = sys_info.getCpuStats();
            mem = sys_info.getMemStats();
            disk = sys_info.getDiskStats();
            net = sys_info.getNetStats();
            thermal = sys_info.getThermalStats();
            battery = sys_info.getBatteryStats();

            if (cached_procs.len > 0) {
                allocator.free(cached_procs);
            }
            cached_procs = try sys_info.getProcStats(allocator, sort_by);

            last_fetch_time = current_time;
            force_redraw = true;
        }

        if (force_redraw) {
            force_redraw = false;
            const size = try app_tui.getWinSize();
            try app_tui.clear();

            if (size.width < 40 or size.height < 15) {
                const msg = "Terminal too small";
                const x = if (size.width > msg.len) (size.width - @as(u16, @intCast(msg.len))) / 2 else 1;
                const y = size.height / 2;
                try app_tui.moveCursor(x, y);
                try app_tui.printStyled(.{ .fg = .bright_red, .bold = true }, "{s}", .{msg});
            } else {
                // Status Bar
                const uname = posix.uname();
                const sysname = std.mem.sliceTo(&uname.sysname, 0);
                const release = std.mem.sliceTo(&uname.release, 0);
                const machine = std.mem.sliceTo(&uname.machine, 0);
                const nodename = std.mem.sliceTo(&uname.nodename, 0);

                try app_tui.moveCursor(1, 1);
                try app_tui.printStyled(.{ .fg = .bright_cyan, .bold = true }, " ztop ", .{});
                try app_tui.printStyled(.{ .fg = .white, .dim = true }, "- {s} {s} {s} - {s}", .{ sysname, release, machine, nodename });

                const tabs_str = "[1] Main  [2] I/O  [3] Sensors";
                if (size.width > tabs_str.len + 30) {
                    try app_tui.moveCursor(size.width - @as(u16, @intCast(tabs_str.len)) - 2, 1);
                    if (current_tab == 1) try app_tui.printStyled(.{ .fg = .bright_cyan, .bold = true }, "[1] Main", .{}) else try app_tui.printStyled(.{ .fg = .white, .dim = true }, "[1] Main", .{});
                    try app_tui.out.writeAll("  ");
                    if (current_tab == 2) try app_tui.printStyled(.{ .fg = .bright_cyan, .bold = true }, "[2] I/O", .{}) else try app_tui.printStyled(.{ .fg = .white, .dim = true }, "[2] I/O", .{});
                    try app_tui.out.writeAll("  ");
                    if (current_tab == 3) try app_tui.printStyled(.{ .fg = .bright_cyan, .bold = true }, "[3] Sensors", .{}) else try app_tui.printStyled(.{ .fg = .white, .dim = true }, "[3] Sensors", .{});
                }

                const available_height = size.height -| 2;
                const is_small_width = size.width < 80;

                const top_boxes_height = if (is_small_width) available_height / 4 else available_height / 3;
                
                const cpu_box_x: u16 = 1;
                const cpu_box_y: u16 = 2;
                const cpu_box_width: u16 = if (is_small_width) size.width else size.width / 2;
                const cpu_box_height: u16 = top_boxes_height;

                const mem_box_x: u16 = if (is_small_width) 1 else size.width / 2 + 1;
                const mem_box_y: u16 = if (is_small_width) 2 + cpu_box_height else 2;
                const mem_box_width: u16 = if (is_small_width) size.width else size.width / 2;
                const mem_box_height: u16 = top_boxes_height;

                const procs_box_x: u16 = 1;
                const procs_box_y: u16 = if (is_small_width) mem_box_y + mem_box_height else 2 + top_boxes_height;
                const procs_box_width: u16 = size.width;
                const procs_box_height: u16 = size.height -| procs_box_y -| 1;

                if (current_tab == 1) {
                    // CPU Box
                    try app_tui.drawBoxStyled(
                        cpu_box_x, cpu_box_y, cpu_box_width, cpu_box_height,
                        "CPU", .{ .fg = .bright_black }, .{ .fg = .bright_cyan, .bold = true },
                    );
                    
                    if (cpu_box_height >= 3) {
                        try app_tui.moveCursor(cpu_box_x + 2, cpu_box_y + 1);
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
                                const x = cpu_box_x + 2 + @as(u16, @intCast(column)) * column_width;
                                const y = cpu_box_y + 2 + @as(u16, @intCast(row));
                                try app_tui.moveCursor(x, y);
                                try app_tui.printStyled(.{ .fg = .bright_black }, "CPU{d:>2}: ", .{i});
                                try app_tui.printStyled(.{ .fg = usageColor(cpu.per_core_usage[i]), .bold = cpu.per_core_usage[i] >= 70 }, "{d:5.1}%", .{cpu.per_core_usage[i]});
                            }
                        }
                    }

                    // Memory Box
                    try app_tui.drawBoxStyled(
                        mem_box_x, mem_box_y, mem_box_width, mem_box_height,
                        "Memory", .{ .fg = .bright_black }, .{ .fg = .bright_yellow, .bold = true },
                    );
                    
                    if (mem_box_height >= 3) {
                        const mem_used_percent: f32 = if (mem.total > 0)
                            @as(f32, @floatFromInt(mem.used)) / @as(f32, @floatFromInt(mem.total)) * 100.0
                        else
                            0;
                        try app_tui.moveCursor(mem_box_x + 2, mem_box_y + 1);
                        try app_tui.printStyled(.{ .fg = .white, .dim = true }, "Used: ", .{});
                        try app_tui.printStyled(.{ .fg = memoryColor(mem_used_percent), .bold = true }, "{d} GB", .{mem.used / 1024 / 1024 / 1024});
                        try app_tui.printStyled(.{ .fg = .bright_black }, " (C: {d}M B: {d}M)", .{mem.cached / 1024 / 1024, mem.buffered / 1024 / 1024});
                        try app_tui.moveCursor(mem_box_x + 2, mem_box_y + 2);
                        try app_tui.printStyled(.{ .fg = .white, .dim = true }, "Free: ", .{});
                        try app_tui.printStyled(.{ .fg = .bright_green, .bold = true }, "{d} GB", .{mem.free / 1024 / 1024 / 1024});
                        if (mem.swap_total > 0 and mem_box_height >= 4) {
                            try app_tui.moveCursor(mem_box_x + 2, mem_box_y + 3);
                            try app_tui.printStyled(.{ .fg = .white, .dim = true }, "Swap: ", .{});
                            try app_tui.printStyled(.{ .fg = .bright_magenta }, "{d} MB / {d} MB", .{mem.swap_used / 1024 / 1024, mem.swap_total / 1024 / 1024});
                        }
                    }
                } else if (current_tab == 2) {
                    // Disk Box
                    try app_tui.drawBoxStyled(
                        cpu_box_x, cpu_box_y, cpu_box_width, cpu_box_height,
                        "Disk I/O", .{ .fg = .bright_black }, .{ .fg = .bright_cyan, .bold = true },
                    );
                    if (cpu_box_height >= 3) {
                        try app_tui.moveCursor(cpu_box_x + 2, cpu_box_y + 1);
                        try app_tui.printStyled(.{ .fg = .white, .dim = true }, "Read: ", .{});
                        try app_tui.printStyled(.{ .fg = .bright_white, .bold = true }, "{d} B/s", .{disk.read_bytes_ps});
                        try app_tui.moveCursor(cpu_box_x + 2, cpu_box_y + 2);
                        try app_tui.printStyled(.{ .fg = .white, .dim = true }, "Write: ", .{});
                        try app_tui.printStyled(.{ .fg = .bright_white, .bold = true }, "{d} B/s", .{disk.write_bytes_ps});
                    }

                    // Network Box
                    try app_tui.drawBoxStyled(
                        mem_box_x, mem_box_y, mem_box_width, mem_box_height,
                        "Network I/O", .{ .fg = .bright_black }, .{ .fg = .bright_yellow, .bold = true },
                    );
                    if (mem_box_height >= 3) {
                        try app_tui.moveCursor(mem_box_x + 2, mem_box_y + 1);
                        try app_tui.printStyled(.{ .fg = .white, .dim = true }, "Rx: ", .{});
                        try app_tui.printStyled(.{ .fg = .bright_white, .bold = true }, "{d} B/s", .{net.rx_bytes_ps});
                        try app_tui.moveCursor(mem_box_x + 2, mem_box_y + 2);
                        try app_tui.printStyled(.{ .fg = .white, .dim = true }, "Tx: ", .{});
                        try app_tui.printStyled(.{ .fg = .bright_white, .bold = true }, "{d} B/s", .{net.tx_bytes_ps});
                    }
                } else if (current_tab == 3) {
                    // Thermal Box
                    try app_tui.drawBoxStyled(
                        cpu_box_x, cpu_box_y, cpu_box_width, cpu_box_height,
                        "Sensors", .{ .fg = .bright_black }, .{ .fg = .bright_red, .bold = true },
                    );
                    if (cpu_box_height >= 3) {
                        try app_tui.moveCursor(cpu_box_x + 2, cpu_box_y + 1);
                        try app_tui.printStyled(.{ .fg = .white, .dim = true }, "CPU Temp: ", .{});
                        if (thermal.cpu_temp) |t| {
                            try app_tui.printStyled(.{ .fg = .bright_white, .bold = true }, "{d:4.1} C", .{t});
                        } else {
                            try app_tui.printStyled(.{ .fg = .bright_black }, "N/A", .{});
                        }
                        try app_tui.moveCursor(cpu_box_x + 2, cpu_box_y + 2);
                        try app_tui.printStyled(.{ .fg = .white, .dim = true }, "GPU Temp: ", .{});
                        if (thermal.gpu_temp) |t| {
                            try app_tui.printStyled(.{ .fg = .bright_white, .bold = true }, "{d:4.1} C", .{t});
                        } else {
                            try app_tui.printStyled(.{ .fg = .bright_black }, "N/A", .{});
                        }
                    }

                    // Battery Box
                    try app_tui.drawBoxStyled(
                        mem_box_x, mem_box_y, mem_box_width, mem_box_height,
                        "Battery", .{ .fg = .bright_black }, .{ .fg = .bright_green, .bold = true },
                    );
                    if (mem_box_height >= 3) {
                        try app_tui.moveCursor(mem_box_x + 2, mem_box_y + 1);
                        try app_tui.printStyled(.{ .fg = .white, .dim = true }, "Charge: ", .{});
                        if (battery.charge_percent) |c| {
                            try app_tui.printStyled(.{ .fg = .bright_white, .bold = true }, "{d:4.1}%", .{c});
                        } else {
                            try app_tui.printStyled(.{ .fg = .bright_black }, "N/A", .{});
                        }
                        try app_tui.moveCursor(mem_box_x + 2, mem_box_y + 2);
                        try app_tui.printStyled(.{ .fg = .white, .dim = true }, "Power: ", .{});
                        if (battery.power_draw_w) |w| {
                            try app_tui.printStyled(.{ .fg = .bright_white, .bold = true }, "{d:4.2} W", .{w});
                        } else {
                            try app_tui.printStyled(.{ .fg = .bright_black }, "N/A", .{});
                        }
                        
                        if (mem_box_height >= 4) {
                            try app_tui.moveCursor(mem_box_x + 2, mem_box_y + 3);
                            try app_tui.printStyled(.{ .fg = .white, .dim = true }, "Status: ", .{});
                            const status_str = switch (battery.status) {
                                .charging => "Charging",
                                .discharging => "Discharging",
                                .full => "Full",
                                .unknown => "Unknown",
                            };
                            try app_tui.printStyled(.{ .fg = .bright_white }, "{s}", .{status_str});
                        }
                    }
                }

                // Processes Box
                if (procs_box_height >= 3) {
                    var title_buf: [64]u8 = undefined;
                    const sort_name = switch (sort_by) {
                        .cpu => "CPU%",
                        .mem => "MEM%",
                        .pid => "PID",
                        .name => "NAME",
                    };
                    const title = std.fmt.bufPrint(&title_buf, "Processes (Sort: {s})", .{sort_name}) catch "Processes";

                    try app_tui.drawBoxStyled(
                        procs_box_x, procs_box_y, procs_box_width, procs_box_height,
                        title, .{ .fg = .bright_black }, .{ .fg = .bright_magenta, .bold = true },
                    );

                    // Filtering
                    filtered_count = 0;
                    const filter_str = filter_buf[0..filter_len];
                    for (cached_procs, 0..) |proc, i| {
                        if (filter_len > 0) {
                            var pid_buf: [32]u8 = undefined;
                            const pid_str = std.fmt.bufPrint(&pid_buf, "{d}", .{proc.pid}) catch "";
                            var l_name: [64]u8 = undefined;
                            const name_len = proc.name().len;
                            @memcpy(l_name[0..name_len], proc.name());
                            const n_str = l_name[0..name_len];
                            for (n_str) |*c| c.* = std.ascii.toLower(c.*);

                            var l_filter: [32]u8 = undefined;
                            @memcpy(l_filter[0..filter_len], filter_str);
                            const f_str = l_filter[0..filter_len];
                            for (f_str) |*c| c.* = std.ascii.toLower(c.*);

                            const name_matches = std.mem.indexOf(u8, n_str, f_str) != null;
                            const pid_matches = std.mem.indexOf(u8, pid_str, filter_str) != null;
                            if (!name_matches and !pid_matches) continue;
                        }
                        filtered_indices[filtered_count] = i;
                        filtered_count += 1;
                        if (filtered_count >= filtered_indices.len) break;
                    }

                    if (filtered_count == 0) {
                        selected_idx = 0;
                        scroll_offset = 0;
                    } else {
                        if (selected_idx >= filtered_count) selected_idx = filtered_count - 1;
                    }

                    const visible_rows = procs_box_height - 2;
                    if (selected_idx < scroll_offset) {
                        scroll_offset = selected_idx;
                    } else if (selected_idx >= scroll_offset + visible_rows) {
                        scroll_offset = selected_idx - visible_rows + 1;
                    }

                    for (0..visible_rows) |row| {
                        const idx = scroll_offset + row;
                        if (idx >= filtered_count) break;
                        const proc_idx = filtered_indices[idx];
                        const proc = cached_procs[proc_idx];

                        const is_selected = (idx == selected_idx) and !show_help;
                        
                        try app_tui.moveCursor(procs_box_x + 2, procs_box_y + 1 + @as(u16, @intCast(row)));
                        
                        if (is_selected) {
                            try app_tui.setStyle(.{ .bg = .bright_black });
                            for (0..procs_box_width - 4) |_| try app_tui.out.writeAll(" ");
                            try app_tui.moveCursor(procs_box_x + 2, procs_box_y + 1 + @as(u16, @intCast(row)));
                        }
                        
                        try app_tui.printStyled(if(is_selected) .{ .bg = .bright_black, .fg = .bright_white } else .{ .fg = .bright_black }, "{d:5} ", .{proc.pid});
                        
                        const name_width: usize = if (procs_box_width > 40) 16 else 8;
                        if (proc.name().len > name_width) {
                            try app_tui.printStyled(if(is_selected) .{ .bg = .bright_black, .fg = .bright_white } else .{ .fg = .bright_white }, "{s}.. ", .{proc.name()[0..name_width-2]});
                        } else {
                            try app_tui.printStyled(if(is_selected) .{ .bg = .bright_black, .fg = .bright_white } else .{ .fg = .bright_white }, "{s} ", .{proc.name()});
                            for (proc.name().len..name_width) |_| try app_tui.printStyled(if(is_selected) .{ .bg = .bright_black } else .{}, " ", .{});
                        }

                        if (current_tab == 2) {
                            try app_tui.printStyled(if(is_selected) .{ .bg = .bright_black, .fg = .bright_yellow } else .{ .fg = .bright_yellow }, "{d:6} B/s R ", .{proc.disk_read_ps});
                            try app_tui.printStyled(if(is_selected) .{ .bg = .bright_black, .fg = .bright_yellow } else .{ .fg = .bright_yellow }, "{d:6} B/s W ", .{proc.disk_write_ps});
                        } else {
                            const c_style: Tui.Style = if(is_selected) .{ .bg = .bright_black, .fg = usageColor(proc.cpu_percent), .bold = proc.cpu_percent >= 70 } else .{ .fg = usageColor(proc.cpu_percent), .bold = proc.cpu_percent >= 70 };
                            try app_tui.printStyled(c_style, "{d:5.1}% CPU ", .{proc.cpu_percent});
                            
                            const m_style: Tui.Style = if(is_selected) .{ .bg = .bright_black, .fg = memoryColor(proc.mem_percent), .bold = proc.mem_percent >= 10 } else .{ .fg = memoryColor(proc.mem_percent), .bold = proc.mem_percent >= 10 };
                            try app_tui.printStyled(m_style, "{d:5.1}% MEM ", .{proc.mem_percent});

                            try app_tui.printStyled(if(is_selected) .{ .bg = .bright_black, .fg = .bright_cyan } else .{ .fg = .bright_cyan }, "{d:4} THR", .{proc.threads});
                        }

                        if (is_selected) {
                            try app_tui.resetStyle();
                        }
                    }
                }

                // Help Overlay
                if (show_help) {
                    const help_width = 40;
                    const help_height = 12;
                    const h_x = if (size.width > help_width) (size.width - help_width) / 2 else 1;
                    const h_y = if (size.height > help_height) (size.height - help_height) / 2 else 1;
                    
                    // Clear background for overlay
                    for (0..help_height) |i| {
                        try app_tui.moveCursor(h_x, h_y + @as(u16, @intCast(i)));
                        for (0..help_width) |_| try app_tui.out.writeAll(" ");
                    }

                    try app_tui.drawBoxStyled(h_x, h_y, help_width, help_height, "Help", .{ .fg = .bright_black }, .{ .fg = .bright_white, .bold = true });
                    try app_tui.moveCursor(h_x + 2, h_y + 2);
                    try app_tui.printStyled(.{ .fg = .bright_white }, "j/k, Up/Down: ", .{});
                    try app_tui.printStyled(.{ .fg = .bright_black }, "Navigate processes", .{});
                    
                    try app_tui.moveCursor(h_x + 2, h_y + 3);
                    try app_tui.printStyled(.{ .fg = .bright_white }, "c, m, p, n:   ", .{});
                    try app_tui.printStyled(.{ .fg = .bright_black }, "Sort by CPU/Mem/PID/Name", .{});

                    try app_tui.moveCursor(h_x + 2, h_y + 4);
                    try app_tui.printStyled(.{ .fg = .bright_white }, "/:            ", .{});
                    try app_tui.printStyled(.{ .fg = .bright_black }, "Filter processes", .{});

                    try app_tui.moveCursor(h_x + 2, h_y + 5);
                    try app_tui.printStyled(.{ .fg = .bright_white }, "t:            ", .{});
                    try app_tui.printStyled(.{ .fg = .bright_black }, "Send SIGTERM to selected", .{});

                    try app_tui.moveCursor(h_x + 2, h_y + 6);
                    try app_tui.printStyled(.{ .fg = .bright_white }, "K:            ", .{});
                    try app_tui.printStyled(.{ .fg = .bright_black }, "Send SIGKILL to selected", .{});

                    try app_tui.moveCursor(h_x + 2, h_y + 7);
                    try app_tui.printStyled(.{ .fg = .bright_white }, "q:            ", .{});
                    try app_tui.printStyled(.{ .fg = .bright_black }, "Quit", .{});

                    try app_tui.moveCursor(h_x + 2, h_y + 9);
                    try app_tui.printStyled(.{ .fg = .bright_black }, "Press any key to close...", .{});
                }

                // Footer
                try app_tui.moveCursor(1, size.height);
                if (is_filtering) {
                    try app_tui.printStyled(.{ .fg = .bright_yellow, .bold = true }, "Filter: ", .{});
                    try app_tui.printStyled(.{ .fg = .bright_white }, "{s}", .{filter_buf[0..filter_len]});
                    try app_tui.printStyled(.{ .fg = .bright_black }, " (Press Enter to apply, Esc to cancel)", .{});
                } else if (filter_len > 0) {
                    try app_tui.printStyled(.{ .fg = .bright_yellow, .bold = true }, "Filter active: ", .{});
                    try app_tui.printStyled(.{ .fg = .bright_white }, "{s}", .{filter_buf[0..filter_len]});
                    try app_tui.printStyled(.{ .fg = .bright_black }, " (Press / to edit, Esc to clear) | ", .{});
                    try app_tui.printStyled(.{ .fg = .bright_black }, "Press ", .{});
                    try app_tui.printStyled(.{ .fg = .bright_white, .bold = true }, "'?'", .{});
                    try app_tui.printStyled(.{ .fg = .bright_black }, " for help", .{});
                } else {
                    try app_tui.printStyled(.{ .fg = .bright_black }, "Press ", .{});
                    try app_tui.printStyled(.{ .fg = .bright_white, .bold = true }, "'?'", .{});
                    try app_tui.printStyled(.{ .fg = .bright_black }, " for help, ", .{});
                    try app_tui.printStyled(.{ .fg = .bright_white, .bold = true }, "'q'", .{});
                    try app_tui.printStyled(.{ .fg = .bright_black }, " to quit", .{});
                }
            }
        } // end force_redraw

        var fds = [_]posix.pollfd{ .{ .fd = app_tui.in.handle, .events = posix.POLL.IN, .revents = 0 } };
        const now = std.time.milliTimestamp();
        var remaining_ms = fetch_interval_ms - (now - last_fetch_time);
        if (remaining_ms < 0) remaining_ms = 0;

        const poll_res = posix.poll(&fds, @intCast(remaining_ms)) catch 0;
        
        if (poll_res > 0 and (fds[0].revents & posix.POLL.IN) != 0) {
            var buf: [16]u8 = undefined;
            const n = app_tui.in.read(&buf) catch 0;
            if (n > 0) {
                var handled = false;

                if (show_help) {
                    show_help = false;
                    handled = true;
                } else if (is_filtering) {
                    if (buf[0] == '\r' or buf[0] == '\n') {
                        is_filtering = false;
                        handled = true;
                    } else if (buf[0] == '\x1b') {
                        is_filtering = false;
                        filter_len = 0;
                        handled = true;
                    } else if (buf[0] == 127 or buf[0] == '\x08') {
                        if (filter_len > 0) filter_len -= 1;
                        handled = true;
                    } else if (buf[0] >= 32 and buf[0] <= 126 and filter_len < filter_buf.len) {
                        filter_buf[filter_len] = buf[0];
                        filter_len += 1;
                        handled = true;
                    }
                } else {
                    if (n == 1) {
                        switch (buf[0]) {
                            '1' => { current_tab = 1; handled = true; },
                            '2' => { current_tab = 2; handled = true; },
                            '3' => { current_tab = 3; handled = true; },
                            'q' => quit_flag = true,
                            '?' => { show_help = true; handled = true; },
                            'h' => { show_help = true; handled = true; },
                            'j' => { if (selected_idx + 1 < filtered_count) selected_idx += 1; handled = true; },
                            'k' => { if (selected_idx > 0) selected_idx -= 1; handled = true; },
                            'c' => { sort_by = .cpu; handled = true; },
                            'm' => { sort_by = .mem; handled = true; },
                            'p' => { sort_by = .pid; handled = true; },
                            'n' => { sort_by = .name; handled = true; },
                            '/' => { is_filtering = true; handled = true; },
                            '\x1b' => { filter_len = 0; handled = true; },
                            't' => {
                                if (filtered_count > 0 and selected_idx < filtered_count) {
                                    const pid = cached_procs[filtered_indices[selected_idx]].pid;
                                    _ = posix.kill(@intCast(pid), posix.SIG.TERM) catch {};
                                }
                                handled = true;
                            },
                            'K' => {
                                if (filtered_count > 0 and selected_idx < filtered_count) {
                                    const pid = cached_procs[filtered_indices[selected_idx]].pid;
                                    _ = posix.kill(@intCast(pid), posix.SIG.KILL) catch {};
                                }
                                handled = true;
                            },
                            else => {},
                        }
                    } else if (n == 3 and buf[0] == '\x1b' and buf[1] == '[') {
                        switch (buf[2]) {
                            'A' => { if (selected_idx > 0) selected_idx -= 1; handled = true; },
                            'B' => { if (selected_idx + 1 < filtered_count) selected_idx += 1; handled = true; },
                            else => {},
                        }
                    }
                }
                
                if (handled) {
                    force_redraw = true;
                    if (n == 1 and (buf[0] == 'c' or buf[0] == 'm' or buf[0] == 'p' or buf[0] == 'n')) {
                        ztop.sysinfo.sortProcStats(cached_procs, sort_by);
                    }
                } else if (!quit_flag) {
                    force_redraw = true;
                }
            }
        }
    }
}
