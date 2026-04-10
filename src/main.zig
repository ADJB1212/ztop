const std = @import("std");
const ztop = @import("ztop");
const process_commands = ztop.process_commands;
const text_input = ztop.text_input;
const Tui = ztop.tui.Tui;
const SysInfo = ztop.sysinfo.SysInfo;
const posix = std.posix;
const repo_url = "https://github.com/ADJB1212/ztop";
const repo_label = "github.com/ADJB1212/ztop";

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

fn usageColor(theme: ztop.config.Theme, percent: f32) Tui.Color {
    if (percent >= 90) return theme.usage_critical;
    if (percent >= 70) return theme.usage_warn;
    if (percent >= 40) return theme.usage_good;
    return theme.usage_idle;
}

const UnitValue = struct {
    value: f32,
    unit: []const u8,
};

fn formatUnit(bytes: u64) UnitValue {
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

fn memoryColor(theme: ztop.config.Theme, percent: f32) Tui.Color {
    if (percent >= 80) return theme.memory_critical;
    if (percent >= 60) return theme.memory_warn;
    if (percent >= 35) return theme.memory_mid;
    return theme.memory_low;
}

fn setStatus(status_buf: *[160]u8, status_len: *usize, comptime fmt: []const u8, args: anytype) void {
    const msg = std.fmt.bufPrint(status_buf, fmt, args) catch {
        status_len.* = 0;
        return;
    };
    status_len.* = msg.len;
}

fn footerCursorColumn(prompt_len: usize, input_len: usize, width: u16) u16 {
    if (width == 0) return 1;

    const col = prompt_len + input_len + 1;
    return @as(u16, @intCast(@min(col, @as(usize, width))));
}

fn updateFooterCursor(app_tui: *Tui, width: u16, height: u16, is_cmd_mode: bool, cmd_len: usize, is_filtering: bool, filter_len: usize) !void {
    if (is_cmd_mode) {
        try app_tui.setCursorStyle(.steady_bar);
        try app_tui.setCursorVisible(true);
        try app_tui.moveCursor(footerCursorColumn(1, cmd_len, width), height);
    } else if (is_filtering) {
        try app_tui.setCursorStyle(.steady_bar);
        try app_tui.setCursorVisible(true);
        try app_tui.moveCursor(footerCursorColumn("Filter: ".len, filter_len, width), height);
    } else {
        try app_tui.setCursorStyle(.steady_block);
        try app_tui.setCursorVisible(false);
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const app_config = ztop.config.load(allocator) catch |err| {
        std.debug.print("ztop: failed to load config: {s}\n", .{@errorName(err)});
        return err;
    };
    const theme = app_config.theme;

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

    var sort_by: ztop.sysinfo.SortBy = app_config.default_sort;
    var selected_idx: usize = 0;
    var scroll_offset: usize = 0;
    var show_help: bool = false;

    var filter_buf: [32]u8 = std.mem.zeroes([32]u8);
    var filter_len: usize = 0;
    var is_filtering: bool = false;

    var cmd_buf: [128]u8 = std.mem.zeroes([128]u8);
    var cmd_len: usize = 0;
    var is_cmd_mode: bool = false;

    var filtered_indices: [2048]usize = undefined;
    var filtered_count: usize = 0;

    var zombie_parents: [ztop.sysinfo.common.MAX_PROCS]process_commands.ZombieParentEntry = undefined;
    var zombie_summary: process_commands.ZombieParentSummary = .{};
    var show_zombie_parents: bool = false;

    var thread_view: bool = false;
    var thread_view_pid: u32 = 0;
    var thread_view_name_buf: [64]u8 = std.mem.zeroes([64]u8);
    var thread_view_name_len: u8 = 0;
    var cached_threads: []ztop.sysinfo.common.ThreadStats = &.{};
    defer if (cached_threads.len > 0) allocator.free(cached_threads);

    var status_buf: [160]u8 = std.mem.zeroes([160]u8);
    var status_len: usize = 0;

    var cpu = sys_info.getCpuStats();
    var mem = sys_info.getMemStats();
    var disk = sys_info.getDiskStats();
    var net = sys_info.getNetStats();
    var thermal = sys_info.getThermalStats();
    var battery = sys_info.getBatteryStats();
    cached_procs = try sys_info.getProcStats(allocator, sort_by);

    var last_fetch_time = std.time.milliTimestamp();
    const fetch_interval_ms: i64 = @intCast(app_config.update_interval_ms);

    var force_redraw = true;
    var current_tab: u8 = 1;

    try app_tui.out.writeAll("\x1b]2;ztop\x1b\\");

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

            if (thread_view) {
                if (cached_threads.len > 0) {
                    allocator.free(cached_threads);
                }
                cached_threads = try sys_info.getThreadStats(allocator, thread_view_pid);
            }

            last_fetch_time = current_time;
            force_redraw = true;
        }

        if (force_redraw) {
            force_redraw = false;
            const size = try app_tui.getWinSize();
            try app_tui.beginFrame();
            defer app_tui.endFrame() catch {};
            try app_tui.clear();

            if (size.width < 40 or size.height < 15) {
                const msg = "Terminal too small";
                const x = if (size.width > msg.len) (size.width - @as(u16, @intCast(msg.len))) / 2 else 1;
                const y = size.height / 2;
                try app_tui.moveCursor(x, y);
                try app_tui.printStyled(.{ .fg = theme.usage_critical, .bold = true }, "{s}", .{msg});
                try app_tui.setCursorStyle(.steady_block);
                try app_tui.setCursorVisible(false);
            } else {
                // Status Bar
                const uname = posix.uname();
                const sysname = std.mem.sliceTo(&uname.sysname, 0);
                const release = std.mem.sliceTo(&uname.release, 0);
                const machine = std.mem.sliceTo(&uname.machine, 0);
                const nodename = std.mem.sliceTo(&uname.nodename, 0);

                try app_tui.moveCursor(1, 1);
                try app_tui.printStyled(.{ .fg = theme.brand, .bold = true }, " ztop ", .{});
                try app_tui.printStyled(.{ .fg = theme.text, .dim = true }, "- {s} {s} {s} - {s}", .{ sysname, release, machine, nodename });

                const tabs_str = "[1] Main  [2] I/O  [3] Sensors";
                if (size.width > tabs_str.len + 30) {
                    try app_tui.moveCursor(size.width - @as(u16, @intCast(tabs_str.len)) - 2, 1);
                    if (current_tab == 1) try app_tui.printStyled(.{ .fg = theme.tab_active, .bold = true }, "[1] Main", .{}) else try app_tui.printStyled(.{ .fg = theme.text, .dim = true }, "[1] Main", .{});
                    try app_tui.out.writeAll("  ");
                    if (current_tab == 2) try app_tui.printStyled(.{ .fg = theme.tab_active, .bold = true }, "[2] I/O", .{}) else try app_tui.printStyled(.{ .fg = theme.text, .dim = true }, "[2] I/O", .{});
                    try app_tui.out.writeAll("  ");
                    if (current_tab == 3) try app_tui.printStyled(.{ .fg = theme.tab_active, .bold = true }, "[3] Sensors", .{}) else try app_tui.printStyled(.{ .fg = theme.text, .dim = true }, "[3] Sensors", .{});
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
                        cpu_box_x,
                        cpu_box_y,
                        cpu_box_width,
                        cpu_box_height,
                        "CPU",
                        .{ .fg = theme.border },
                        .{ .fg = theme.cpu_title, .bold = true },
                    );

                    if (cpu_box_height >= 3) {
                        try app_tui.moveCursor(cpu_box_x + 2, cpu_box_y + 1);
                        try app_tui.printStyled(.{ .fg = theme.text, .dim = true }, "Usage: ", .{});
                        try app_tui.printStyled(.{ .fg = usageColor(theme, cpu.usage_percent), .bold = true }, "{d:4.1}%", .{cpu.usage_percent});
                        try app_tui.printStyled(.{ .fg = theme.muted }, " ({d} cores)", .{cpu.cores});

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
                                try app_tui.printStyled(.{ .fg = theme.muted }, "CPU{d:>2}: ", .{i});
                                try app_tui.printStyled(.{ .fg = usageColor(theme, cpu.per_core_usage[i]), .bold = cpu.per_core_usage[i] >= 70 }, "{d:5.1}%", .{cpu.per_core_usage[i]});
                            }
                        }
                    }

                    // Memory Box
                    try app_tui.drawBoxStyled(
                        mem_box_x,
                        mem_box_y,
                        mem_box_width,
                        mem_box_height,
                        "Memory",
                        .{ .fg = theme.border },
                        .{ .fg = theme.memory_title, .bold = true },
                    );

                    if (mem_box_height >= 3) {
                        const mem_used_percent: f32 = if (mem.total > 0)
                            @as(f32, @floatFromInt(mem.used)) / @as(f32, @floatFromInt(mem.total)) * 100.0
                        else
                            0;
                        try app_tui.moveCursor(mem_box_x + 2, mem_box_y + 1);
                        try app_tui.printStyled(.{ .fg = theme.text, .dim = true }, "Used: ", .{});
                        try app_tui.printStyled(.{ .fg = memoryColor(theme, mem_used_percent), .bold = true }, "{d} GB", .{mem.used / 1024 / 1024 / 1024});
                        try app_tui.printStyled(.{ .fg = theme.muted }, " (C: {d}M B: {d}M)", .{ mem.cached / 1024 / 1024, mem.buffered / 1024 / 1024 });
                        try app_tui.moveCursor(mem_box_x + 2, mem_box_y + 2);
                        try app_tui.printStyled(.{ .fg = theme.text, .dim = true }, "Free: ", .{});
                        try app_tui.printStyled(.{ .fg = theme.usage_good, .bold = true }, "{d} GB", .{mem.free / 1024 / 1024 / 1024});
                        if (mem.swap_total > 0 and mem_box_height >= 4) {
                            try app_tui.moveCursor(mem_box_x + 2, mem_box_y + 3);
                            try app_tui.printStyled(.{ .fg = theme.text, .dim = true }, "Swap: ", .{});
                            try app_tui.printStyled(.{ .fg = theme.memory_mid }, "{d} MB / {d} MB", .{ mem.swap_used / 1024 / 1024, mem.swap_total / 1024 / 1024 });
                        }
                    }
                } else if (current_tab == 2) {
                    // Disk Box
                    try app_tui.drawBoxStyled(
                        cpu_box_x,
                        cpu_box_y,
                        cpu_box_width,
                        cpu_box_height,
                        "Disk I/O",
                        .{ .fg = theme.border },
                        .{ .fg = theme.disk_title, .bold = true },
                    );
                    if (cpu_box_height >= 3) {
                        try app_tui.moveCursor(cpu_box_x + 2, cpu_box_y + 1);
                        try app_tui.printStyled(.{ .fg = theme.text, .dim = true }, "Read: ", .{});
                        const r = formatUnit(disk.read_bytes_ps);
                        try app_tui.printStyled(.{ .fg = theme.io_rate, .bold = true }, "{d:4.1} {s}/s", .{ r.value, r.unit });
                        try app_tui.moveCursor(cpu_box_x + 2, cpu_box_y + 2);
                        try app_tui.printStyled(.{ .fg = theme.text, .dim = true }, "Write: ", .{});
                        const w = formatUnit(disk.write_bytes_ps);
                        try app_tui.printStyled(.{ .fg = theme.io_rate, .bold = true }, "{d:4.1} {s}/s", .{ w.value, w.unit });
                    }

                    // Network Box
                    try app_tui.drawBoxStyled(
                        mem_box_x,
                        mem_box_y,
                        mem_box_width,
                        mem_box_height,
                        "Network I/O",
                        .{ .fg = theme.border },
                        .{ .fg = theme.network_title, .bold = true },
                    );
                    if (mem_box_height >= 3) {
                        try app_tui.moveCursor(mem_box_x + 2, mem_box_y + 1);
                        try app_tui.printStyled(.{ .fg = theme.text, .dim = true }, "Rx: ", .{});
                        const rx_ps = formatUnit(net.rx_bytes_ps);
                        try app_tui.printStyled(.{ .fg = theme.io_rate, .bold = true }, "{d:4.1} {s}/s", .{ rx_ps.value, rx_ps.unit });

                        try app_tui.moveCursor(mem_box_x + 22, mem_box_y + 1);
                        try app_tui.printStyled(.{ .fg = theme.text, .dim = true }, "Total: ", .{});
                        const rx_total = formatUnit(net.rx_bytes);
                        try app_tui.printStyled(.{ .fg = theme.io_rate, .bold = true }, "{d:4.1} {s}", .{ rx_total.value, rx_total.unit });

                        try app_tui.moveCursor(mem_box_x + 2, mem_box_y + 2);
                        try app_tui.printStyled(.{ .fg = theme.text, .dim = true }, "Tx: ", .{});
                        const tx_ps = formatUnit(net.tx_bytes_ps);
                        try app_tui.printStyled(.{ .fg = theme.io_rate, .bold = true }, "{d:4.1} {s}/s", .{ tx_ps.value, tx_ps.unit });

                        try app_tui.moveCursor(mem_box_x + 22, mem_box_y + 2);
                        try app_tui.printStyled(.{ .fg = theme.text, .dim = true }, "Total: ", .{});
                        const tx_total = formatUnit(net.tx_bytes);
                        try app_tui.printStyled(.{ .fg = theme.io_rate, .bold = true }, "{d:4.1} {s}", .{ tx_total.value, tx_total.unit });
                    }
                } else if (current_tab == 3) {
                    // Thermal Box
                    try app_tui.drawBoxStyled(
                        cpu_box_x,
                        cpu_box_y,
                        cpu_box_width,
                        cpu_box_height,
                        "Sensors",
                        .{ .fg = theme.border },
                        .{ .fg = theme.sensor_title, .bold = true },
                    );
                    if (cpu_box_height >= 3) {
                        try app_tui.moveCursor(cpu_box_x + 2, cpu_box_y + 1);
                        try app_tui.printStyled(.{ .fg = theme.text, .dim = true }, "CPU Temp: ", .{});
                        if (thermal.cpu_temp) |t| {
                            try app_tui.printStyled(.{ .fg = theme.io_rate, .bold = true }, "{d:4.1} C", .{t});
                        } else {
                            try app_tui.printStyled(.{ .fg = theme.muted }, "N/A", .{});
                        }
                        try app_tui.moveCursor(cpu_box_x + 2, cpu_box_y + 2);
                        try app_tui.printStyled(.{ .fg = theme.text, .dim = true }, "GPU Temp: ", .{});
                        if (thermal.gpu_temp) |t| {
                            try app_tui.printStyled(.{ .fg = theme.io_rate, .bold = true }, "{d:4.1} C", .{t});
                        } else {
                            try app_tui.printStyled(.{ .fg = theme.muted }, "N/A", .{});
                        }
                    }

                    // Battery Box
                    try app_tui.drawBoxStyled(
                        mem_box_x,
                        mem_box_y,
                        mem_box_width,
                        mem_box_height,
                        "Battery",
                        .{ .fg = theme.border },
                        .{ .fg = theme.battery_title, .bold = true },
                    );
                    if (mem_box_height >= 3) {
                        try app_tui.moveCursor(mem_box_x + 2, mem_box_y + 1);
                        try app_tui.printStyled(.{ .fg = theme.text, .dim = true }, "Charge: ", .{});
                        if (battery.charge_percent) |c| {
                            try app_tui.printStyled(.{ .fg = theme.io_rate, .bold = true }, "{d:4.1}%", .{c});
                        } else {
                            try app_tui.printStyled(.{ .fg = theme.muted }, "N/A", .{});
                        }
                        try app_tui.moveCursor(mem_box_x + 2, mem_box_y + 2);
                        try app_tui.printStyled(.{ .fg = theme.text, .dim = true }, "Power: ", .{});
                        if (battery.power_draw_w) |w| {
                            try app_tui.printStyled(.{ .fg = theme.io_rate, .bold = true }, "{d:4.2} W", .{w});
                        } else {
                            try app_tui.printStyled(.{ .fg = theme.muted }, "N/A", .{});
                        }

                        if (mem_box_height >= 4) {
                            try app_tui.moveCursor(mem_box_x + 2, mem_box_y + 3);
                            try app_tui.printStyled(.{ .fg = theme.text, .dim = true }, "Status: ", .{});
                            const status_str = switch (battery.status) {
                                .charging => "Charging",
                                .discharging => "Discharging",
                                .full => "Full",
                                .unknown => "Unknown",
                            };
                            try app_tui.printStyled(.{ .fg = theme.text }, "{s}", .{status_str});
                        }
                    }
                }

                // Processes / Threads Box
                if (procs_box_height >= 3) {
                    var title_buf: [96]u8 = undefined;

                    if (thread_view) {
                        const tv_name = thread_view_name_buf[0..thread_view_name_len];
                        const title = std.fmt.bufPrint(
                            &title_buf,
                            "Threads of {s} (PID: {d}) - {d} threads",
                            .{ tv_name, thread_view_pid, cached_threads.len },
                        ) catch "Threads";

                        try app_tui.drawBoxStyled(
                            procs_box_x,
                            procs_box_y,
                            procs_box_width,
                            procs_box_height,
                            title,
                            .{ .fg = theme.border },
                            .{ .fg = theme.process_title, .bold = true },
                        );

                        const thread_count = cached_threads.len;
                        if (thread_count == 0) {
                            selected_idx = 0;
                            scroll_offset = 0;
                        } else {
                            if (selected_idx >= thread_count) selected_idx = thread_count - 1;
                        }

                        const visible_rows = procs_box_height - 2;
                        if (selected_idx < scroll_offset) {
                            scroll_offset = selected_idx;
                        } else if (selected_idx >= scroll_offset + visible_rows) {
                            scroll_offset = selected_idx - visible_rows + 1;
                        }

                        for (0..visible_rows) |row| {
                            const idx = scroll_offset + row;
                            if (idx >= thread_count) break;
                            const thr = cached_threads[idx];

                            const is_selected = (idx == selected_idx) and !show_help;

                            try app_tui.moveCursor(procs_box_x + 2, procs_box_y + 1 + @as(u16, @intCast(row)));

                            if (is_selected) {
                                try app_tui.setStyle(.{ .bg = theme.selection_bg });
                                for (0..procs_box_width - 4) |_| try app_tui.out.writeAll(" ");
                                try app_tui.moveCursor(procs_box_x + 2, procs_box_y + 1 + @as(u16, @intCast(row)));
                            }

                            try app_tui.printStyled(if (is_selected) .{ .bg = theme.selection_bg, .fg = theme.selection_fg } else .{ .fg = theme.muted }, "{d:7} ", .{thr.tid});

                            const name_width: usize = if (procs_box_width > 40) 16 else 8;
                            if (thr.name().len > name_width) {
                                try app_tui.printStyled(if (is_selected) .{ .bg = theme.selection_bg, .fg = theme.selection_fg } else .{ .fg = theme.text }, "{s}.. ", .{thr.name()[0 .. name_width - 2]});
                            } else if (thr.name().len > 0) {
                                try app_tui.printStyled(if (is_selected) .{ .bg = theme.selection_bg, .fg = theme.selection_fg } else .{ .fg = theme.text }, "{s} ", .{thr.name()});
                                for (thr.name().len..name_width) |_| try app_tui.printStyled(if (is_selected) .{ .bg = theme.selection_bg } else .{}, " ", .{});
                            } else {
                                for (0..name_width) |_| try app_tui.printStyled(if (is_selected) .{ .bg = theme.selection_bg } else .{}, " ", .{});
                                try app_tui.printStyled(if (is_selected) .{ .bg = theme.selection_bg } else .{}, " ", .{});
                            }

                            const c_style: Tui.Style = if (is_selected) .{ .bg = theme.selection_bg, .fg = usageColor(theme, thr.cpu_percent), .bold = thr.cpu_percent >= 70 } else .{ .fg = usageColor(theme, thr.cpu_percent), .bold = thr.cpu_percent >= 70 };
                            try app_tui.printStyled(c_style, "{d:5.1}% CPU ", .{thr.cpu_percent});

                            const state_str = switch (thr.state) {
                                .running => "running",
                                .sleeping => "sleeping",
                                .disk_sleep => "disk_slp",
                                .stopped => "stopped",
                                .zombie => "zombie",
                                .dead => "dead",
                                .idle => "idle",
                                else => "unknown",
                            };
                            const state_color: Tui.Color = switch (thr.state) {
                                .running => theme.usage_good,
                                .sleeping => theme.muted,
                                .disk_sleep => theme.usage_warn,
                                .stopped => theme.usage_critical,
                                .zombie => theme.usage_critical,
                                else => theme.muted,
                            };
                            try app_tui.printStyled(if (is_selected) .{ .bg = theme.selection_bg, .fg = state_color } else .{ .fg = state_color }, "{s}", .{state_str});

                            if (is_selected) {
                                try app_tui.resetStyle();
                            }
                        }
                    } else {
                        const sort_name = switch (sort_by) {
                            .cpu => "CPU%",
                            .mem => "MEM%",
                            .pid => "PID",
                            .name => "NAME",
                        };
                        const title = if (show_zombie_parents)
                            std.fmt.bufPrint(
                                &title_buf,
                                "Zombie Parents ({d} parents / {d} zombies)",
                                .{ zombie_summary.parent_count, zombie_summary.zombie_count },
                            ) catch "Zombie Parents"
                        else
                            std.fmt.bufPrint(&title_buf, "Processes (Sort: {s})", .{sort_name}) catch "Processes";

                        try app_tui.drawBoxStyled(
                            procs_box_x,
                            procs_box_y,
                            procs_box_width,
                            procs_box_height,
                            title,
                            .{ .fg = theme.border },
                            .{ .fg = theme.process_title, .bold = true },
                        );

                        // Filtering
                        filtered_count = 0;
                        const filter_str = filter_buf[0..filter_len];
                        for (cached_procs, 0..) |proc, i| {
                            if (show_zombie_parents and !process_commands.containsParentPid(zombie_parents[0..zombie_summary.parent_count], proc.pid)) {
                                continue;
                            }

                            if (filter_len > 0) {
                                var pid_buf2: [32]u8 = undefined;
                                const pid_str = std.fmt.bufPrint(&pid_buf2, "{d}", .{proc.pid}) catch "";
                                var l_name: [64]u8 = undefined;
                                const name_len = proc.name().len;
                                @memcpy(l_name[0..name_len], proc.name());
                                const n_str = l_name[0..name_len];
                                for (n_str) |*ch| ch.* = std.ascii.toLower(ch.*);

                                var l_filter: [32]u8 = undefined;
                                @memcpy(l_filter[0..filter_len], filter_str);
                                const f_str = l_filter[0..filter_len];
                                for (f_str) |*ch| ch.* = std.ascii.toLower(ch.*);

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
                                try app_tui.setStyle(.{ .bg = theme.selection_bg });
                                for (0..procs_box_width - 4) |_| try app_tui.out.writeAll(" ");
                                try app_tui.moveCursor(procs_box_x + 2, procs_box_y + 1 + @as(u16, @intCast(row)));
                            }

                            try app_tui.printStyled(if (is_selected) .{ .bg = theme.selection_bg, .fg = theme.selection_fg } else .{ .fg = theme.muted }, "{d:5} ", .{proc.pid});

                            const name_width: usize = if (procs_box_width > 40) 16 else 8;
                            if (proc.name().len > name_width) {
                                try app_tui.printStyled(if (is_selected) .{ .bg = theme.selection_bg, .fg = theme.selection_fg } else .{ .fg = theme.text }, "{s}.. ", .{proc.name()[0 .. name_width - 2]});
                            } else {
                                try app_tui.printStyled(if (is_selected) .{ .bg = theme.selection_bg, .fg = theme.selection_fg } else .{ .fg = theme.text }, "{s} ", .{proc.name()});
                                for (proc.name().len..name_width) |_| try app_tui.printStyled(if (is_selected) .{ .bg = theme.selection_bg } else .{}, " ", .{});
                            }

                            if (current_tab == 2) {
                                const dr = formatUnit(proc.disk_read_ps);
                                const dw = formatUnit(proc.disk_write_ps);
                                try app_tui.printStyled(if (is_selected) .{ .bg = theme.selection_bg, .fg = theme.disk_title } else .{ .fg = theme.disk_title }, "{d:5.1} {s}/s R ", .{ dr.value, dr.unit });
                                try app_tui.printStyled(if (is_selected) .{ .bg = theme.selection_bg, .fg = theme.disk_title } else .{ .fg = theme.disk_title }, "{d:5.1} {s}/s W ", .{ dw.value, dw.unit });
                            } else {
                                const c_style: Tui.Style = if (is_selected) .{ .bg = theme.selection_bg, .fg = usageColor(theme, proc.cpu_percent), .bold = proc.cpu_percent >= 70 } else .{ .fg = usageColor(theme, proc.cpu_percent), .bold = proc.cpu_percent >= 70 };
                                try app_tui.printStyled(c_style, "{d:5.1}% CPU ", .{proc.cpu_percent});

                                const m_style: Tui.Style = if (is_selected) .{ .bg = theme.selection_bg, .fg = memoryColor(theme, proc.mem_percent), .bold = proc.mem_percent >= 10 } else .{ .fg = memoryColor(theme, proc.mem_percent), .bold = proc.mem_percent >= 10 };
                                try app_tui.printStyled(m_style, "{d:5.1}% MEM ", .{proc.mem_percent});

                                try app_tui.printStyled(if (is_selected) .{ .bg = theme.selection_bg, .fg = theme.brand } else .{ .fg = theme.brand }, "{d:4} THR", .{proc.threads});
                            }

                            if (is_selected) {
                                try app_tui.resetStyle();
                            }
                        }
                    }
                }

                // Help Overlay
                if (show_help) {
                    const help_width = 48;
                    const help_height = 13;
                    const h_x = if (size.width > help_width) (size.width - help_width) / 2 else 1;
                    const h_y = if (size.height > help_height) (size.height - help_height) / 2 else 1;

                    // Clear background for overlay
                    for (0..help_height) |i| {
                        try app_tui.moveCursor(h_x, h_y + @as(u16, @intCast(i)));
                        for (0..help_width) |_| try app_tui.out.writeAll(" ");
                    }

                    try app_tui.drawBoxStyled(h_x, h_y, help_width, help_height, "Help", .{ .fg = theme.border }, .{ .fg = theme.text, .bold = true });
                    try app_tui.moveCursor(h_x + 2, h_y + 2);
                    try app_tui.printStyled(.{ .fg = theme.text }, "j/k, Up/Down: ", .{});
                    try app_tui.printStyled(.{ .fg = theme.muted }, "Navigate processes", .{});

                    try app_tui.moveCursor(h_x + 2, h_y + 3);
                    try app_tui.printStyled(.{ .fg = theme.text }, "c, m, p, n:   ", .{});
                    try app_tui.printStyled(.{ .fg = theme.muted }, "Sort by CPU/Mem/PID/Name", .{});

                    try app_tui.moveCursor(h_x + 2, h_y + 4);
                    try app_tui.printStyled(.{ .fg = theme.text }, "/:            ", .{});
                    try app_tui.printStyled(.{ .fg = theme.muted }, "Filter processes", .{});

                    try app_tui.moveCursor(h_x + 2, h_y + 5);
                    try app_tui.printStyled(.{ .fg = theme.text }, "Enter:        ", .{});
                    try app_tui.printStyled(.{ .fg = theme.muted }, "View threads of selected", .{});

                    try app_tui.moveCursor(h_x + 2, h_y + 6);
                    try app_tui.printStyled(.{ .fg = theme.text }, "t:            ", .{});
                    try app_tui.printStyled(.{ .fg = theme.muted }, "Send SIGTERM to selected", .{});

                    try app_tui.moveCursor(h_x + 2, h_y + 7);
                    try app_tui.printStyled(.{ .fg = theme.text }, "K:            ", .{});
                    try app_tui.printStyled(.{ .fg = theme.muted }, "Send SIGKILL to selected", .{});

                    try app_tui.moveCursor(h_x + 2, h_y + 8);
                    try app_tui.printStyled(.{ .fg = theme.text }, "q:            ", .{});
                    try app_tui.printStyled(.{ .fg = theme.muted }, "Quit", .{});

                    try app_tui.moveCursor(h_x + 2, h_y + 9);
                    try app_tui.printStyled(.{ .fg = theme.text }, ":             ", .{});
                    try app_tui.printStyled(.{ .fg = theme.muted }, "Command mode (show zombie)", .{});

                    try app_tui.moveCursor(h_x + 2, h_y + 10);
                    try app_tui.printStyled(.{ .fg = theme.text }, "Repo: ", .{});
                    try app_tui.writeStyledHyperlink(.{ .fg = theme.tab_active, .underline = true }, repo_url, repo_label);

                    try app_tui.moveCursor(h_x + 2, h_y + 11);
                    try app_tui.printStyled(.{ .fg = theme.muted }, "Press any key to close...", .{});
                }

                // Footer
                try app_tui.moveCursor(1, size.height);
                if (is_cmd_mode) {
                    try app_tui.printStyled(.{ .fg = theme.command_prompt, .bold = true }, ":", .{});
                    try app_tui.printStyled(.{ .fg = theme.text }, "{s}", .{cmd_buf[0..cmd_len]});
                    try app_tui.printStyled(.{ .fg = theme.muted }, " (Press Enter to execute, Esc to cancel)", .{});
                } else if (is_filtering) {
                    try app_tui.printStyled(.{ .fg = theme.filter_prompt, .bold = true }, "Filter: ", .{});
                    try app_tui.printStyled(.{ .fg = theme.text }, "{s}", .{filter_buf[0..filter_len]});
                    try app_tui.printStyled(.{ .fg = theme.muted }, " (Press Enter to apply, Esc to cancel)", .{});
                } else if (filter_len > 0) {
                    try app_tui.printStyled(.{ .fg = theme.filter_prompt, .bold = true }, "Filter active: ", .{});
                    try app_tui.printStyled(.{ .fg = theme.text }, "{s}", .{filter_buf[0..filter_len]});
                    try app_tui.printStyled(.{ .fg = theme.muted }, " (Press / to edit, Esc to clear) | ", .{});
                    try app_tui.printStyled(.{ .fg = theme.muted }, "Press ", .{});
                    try app_tui.printStyled(.{ .fg = theme.text, .bold = true }, "'?'", .{});
                    try app_tui.printStyled(.{ .fg = theme.muted }, " for help", .{});
                } else if (thread_view) {
                    try app_tui.printStyled(.{ .fg = theme.muted }, "Viewing threads of ", .{});
                    try app_tui.printStyled(.{ .fg = theme.text, .bold = true }, "{s}", .{thread_view_name_buf[0..thread_view_name_len]});
                    try app_tui.printStyled(.{ .fg = theme.muted }, " | Press ", .{});
                    try app_tui.printStyled(.{ .fg = theme.text, .bold = true }, "Esc", .{});
                    try app_tui.printStyled(.{ .fg = theme.muted }, " to go back", .{});
                } else if (status_len > 0) {
                    try app_tui.printStyled(.{ .fg = theme.muted }, "{s}", .{status_buf[0..status_len]});
                } else {
                    try app_tui.printStyled(.{ .fg = theme.muted }, "Press ", .{});
                    try app_tui.printStyled(.{ .fg = theme.text, .bold = true }, "'?'", .{});
                    try app_tui.printStyled(.{ .fg = theme.muted }, " for help, ", .{});
                    try app_tui.printStyled(.{ .fg = theme.text, .bold = true }, "'q'", .{});
                    try app_tui.printStyled(.{ .fg = theme.muted }, " to quit", .{});
                }

                try updateFooterCursor(&app_tui, size.width, size.height, is_cmd_mode, cmd_len, is_filtering, filter_len);
            }
        } // end force_redraw

        var fds = [_]posix.pollfd{.{ .fd = app_tui.in.handle, .events = posix.POLL.IN, .revents = 0 }};
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
                } else if (is_cmd_mode) {
                    switch (text_input.applyInputBytes(&cmd_buf, &cmd_len, buf[0..n])) {
                        .submit => {
                            is_cmd_mode = false;
                            const cmd = cmd_buf[0..cmd_len];
                            if (std.mem.eql(u8, cmd, "show zombie")) {
                                zombie_summary = process_commands.collectZombieParents(cached_procs, zombie_parents[0..]);
                                show_zombie_parents = true;
                                filter_len = 0;
                                selected_idx = 0;
                                scroll_offset = 0;

                                if (zombie_summary.zombie_count == 0) {
                                    setStatus(&status_buf, &status_len, "No zombie processes found", .{});
                                } else if (zombie_summary.parent_count == 0) {
                                    setStatus(&status_buf, &status_len, "Found {d} zombies, but no visible parent processes", .{zombie_summary.zombie_count});
                                } else {
                                    const parent_label = if (zombie_summary.parent_count == 1) "parent process" else "parent processes";
                                    const zombie_label = if (zombie_summary.zombie_count == 1) "zombie" else "zombies";
                                    setStatus(
                                        &status_buf,
                                        &status_len,
                                        "Showing {d} {s} for {d} {s}. Esc clears",
                                        .{ zombie_summary.parent_count, parent_label, zombie_summary.zombie_count, zombie_label },
                                    );
                                }
                            } else if (std.mem.startsWith(u8, cmd, "killall ")) {
                                const target = cmd[8..];
                                var matches: usize = 0;
                                for (cached_procs) |proc| {
                                    var l_name: [64]u8 = undefined;
                                    const name_len = proc.name().len;
                                    @memcpy(l_name[0..name_len], proc.name());
                                    const n_str = l_name[0..name_len];
                                    for (n_str) |*c| c.* = std.ascii.toLower(c.*);

                                    var l_target: [64]u8 = undefined;
                                    const target_len = @min(target.len, 64);
                                    @memcpy(l_target[0..target_len], target[0..target_len]);
                                    const t_str = l_target[0..target_len];
                                    for (t_str) |*c| c.* = std.ascii.toLower(c.*);

                                    if (std.mem.indexOf(u8, n_str, t_str) != null) {
                                        _ = posix.kill(@intCast(proc.pid), posix.SIG.TERM) catch {};
                                        matches += 1;
                                    }
                                }

                                if (matches == 0) {
                                    setStatus(&status_buf, &status_len, "No processes matched '{s}'", .{target});
                                } else {
                                    setStatus(&status_buf, &status_len, "Sent SIGTERM to {d} matching processes", .{matches});
                                }
                            } else if (std.mem.startsWith(u8, cmd, "search ")) {
                                const target = cmd[7..];
                                is_filtering = true;
                                filter_len = @min(target.len, filter_buf.len);
                                @memcpy(filter_buf[0..filter_len], target[0..filter_len]);
                                status_len = 0;
                            } else if (std.mem.eql(u8, cmd, "q") or std.mem.eql(u8, cmd, "quit")) {
                                quit_flag = true;
                            } else if (cmd.len > 0) {
                                setStatus(&status_buf, &status_len, "Unknown command: {s}", .{cmd});
                            }
                            cmd_len = 0;
                            handled = true;
                        },
                        .cancel => {
                            is_cmd_mode = false;
                            cmd_len = 0;
                            handled = true;
                        },
                        .none => handled = true,
                    }
                } else if (is_filtering) {
                    switch (text_input.applyInputBytes(&filter_buf, &filter_len, buf[0..n])) {
                        .submit => {
                            is_filtering = false;
                            handled = true;
                        },
                        .cancel => {
                            is_filtering = false;
                            filter_len = 0;
                            handled = true;
                        },
                        .none => handled = true,
                    }
                } else {
                    const list_count = if (thread_view) cached_threads.len else filtered_count;

                    if (n == 1) {
                        switch (buf[0]) {
                            '1' => {
                                current_tab = 1;
                                handled = true;
                            },
                            '2' => {
                                current_tab = 2;
                                handled = true;
                            },
                            '3' => {
                                current_tab = 3;
                                handled = true;
                            },
                            'q' => quit_flag = true,
                            '?' => {
                                show_help = true;
                                handled = true;
                            },
                            'h' => {
                                show_help = true;
                                handled = true;
                            },
                            'j' => {
                                if (selected_idx + 1 < list_count) selected_idx += 1;
                                handled = true;
                            },
                            'k' => {
                                if (selected_idx > 0) selected_idx -= 1;
                                handled = true;
                            },
                            'c' => {
                                if (!thread_view) {
                                    sort_by = .cpu;
                                }
                                handled = true;
                            },
                            'm' => {
                                if (!thread_view) {
                                    sort_by = .mem;
                                }
                                handled = true;
                            },
                            'p' => {
                                if (!thread_view) {
                                    sort_by = .pid;
                                }
                                handled = true;
                            },
                            'n' => {
                                if (!thread_view) {
                                    sort_by = .name;
                                }
                                handled = true;
                            },
                            '/' => {
                                if (!thread_view) {
                                    is_filtering = true;
                                }
                                handled = true;
                            },
                            ':' => {
                                if (!thread_view) {
                                    is_cmd_mode = true;
                                }
                                handled = true;
                            },
                            '\r', '\n' => {
                                if (!thread_view and filtered_count > 0 and selected_idx < filtered_count) {
                                    const proc = cached_procs[filtered_indices[selected_idx]];
                                    thread_view_pid = proc.pid;
                                    thread_view_name_len = proc.name_len;
                                    @memcpy(thread_view_name_buf[0..proc.name_len], proc.name());
                                    thread_view = true;
                                    selected_idx = 0;
                                    scroll_offset = 0;

                                    if (cached_threads.len > 0) {
                                        allocator.free(cached_threads);
                                    }
                                    cached_threads = sys_info.getThreadStats(allocator, thread_view_pid) catch &.{};
                                }
                                handled = true;
                            },
                            '\x1b' => {
                                if (thread_view) {
                                    thread_view = false;
                                    if (cached_threads.len > 0) {
                                        allocator.free(cached_threads);
                                        cached_threads = &.{};
                                    }
                                    selected_idx = 0;
                                    scroll_offset = 0;
                                } else {
                                    filter_len = 0;
                                    status_len = 0;
                                    zombie_summary = .{};
                                    show_zombie_parents = false;
                                }
                                handled = true;
                            },
                            't' => {
                                if (!thread_view and filtered_count > 0 and selected_idx < filtered_count) {
                                    const pid = cached_procs[filtered_indices[selected_idx]].pid;
                                    _ = posix.kill(@intCast(pid), posix.SIG.TERM) catch {};
                                }
                                handled = true;
                            },
                            'K' => {
                                if (!thread_view and filtered_count > 0 and selected_idx < filtered_count) {
                                    const pid = cached_procs[filtered_indices[selected_idx]].pid;
                                    _ = posix.kill(@intCast(pid), posix.SIG.KILL) catch {};
                                }
                                handled = true;
                            },
                            else => {},
                        }
                    } else if (n == 3 and buf[0] == '\x1b' and buf[1] == '[') {
                        switch (buf[2]) {
                            'A' => {
                                if (selected_idx > 0) selected_idx -= 1;
                                handled = true;
                            },
                            'B' => {
                                if (selected_idx + 1 < list_count) selected_idx += 1;
                                handled = true;
                            },
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
