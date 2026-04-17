const std = @import("std");
const ztop = @import("ztop");
const build_options = @import("build_options");
const cli = ztop.cli;
const render = ztop.render;
const input_handler = ztop.input_handler;
const process_commands = ztop.process_commands;
const Tui = ztop.tui.Tui;
const SysInfo = ztop.sysinfo.SysInfo;
const posix = std.posix;
const repo_url = "https://github.com/ADJB1212/ztop";
const repo_label = "github.com/ADJB1212/ztop";

var quit_flag = false;
var sigwinch_flag = false;

fn handleSigInt(sig: posix.SIG) callconv(.c) void {
    _ = sig;
    quit_flag = true;
}

fn handleSigWinch(sig: posix.SIG) callconv(.c) void {
    _ = sig;
    sigwinch_flag = true;
}

fn memoryUsagePercent(mem: ztop.sysinfo.MemStats) f32 {
    if (mem.total == 0) return 0;
    return @as(f32, @floatFromInt(mem.used)) / @as(f32, @floatFromInt(mem.total)) * 100.0;
}

fn batteryStatusLabel(status: ztop.sysinfo.BatteryStatus) []const u8 {
    return switch (status) {
        .charging => "Charging",
        .discharging => "Discharging",
        .full => "Full",
        .unknown => "Unknown",
    };
}

fn aggregateGpuTemp(thermal: ztop.sysinfo.ThermalStats, gpus: []const ztop.sysinfo.GpuStats) ?f32 {
    for (gpus) |gpu| {
        if (gpu.temperature_c) |temp_c| return temp_c;
    }
    return thermal.gpu_temp;
}

fn gpuVendorLabel(vendor: ztop.sysinfo.GpuVendor) []const u8 {
    return switch (vendor) {
        .nvidia => "NVIDIA",
        .amd => "AMD",
        .apple => "Apple",
        .intel => "Intel",
        .unknown => "Unknown",
    };
}

fn nowMs(io: std.Io) i64 {
    return std.Io.Clock.now(.real, io).toMilliseconds();
}

fn activeProcessColumns(
    current_tab: u8,
    process_columns: *ztop.config.ProcessColumns,
    io_process_columns: *ztop.config.ProcessColumns,
) *ztop.config.ProcessColumns {
    if (current_tab == 2) return io_process_columns;
    return process_columns;
}

fn renderProcessNameCell(
    app_tui: *Tui,
    style: Tui.Style,
    width: usize,
    prefix: []const u8,
    prefix_width: usize,
    name: []const u8,
) !void {
    if (width == 0) return;

    if (prefix_width >= width) {
        const clipped_len = if (width > 2 and name.len > width - 2) width - 2 else @min(name.len, width);
        try app_tui.writeStyled(style, name[0..clipped_len]);
        if (width > 2 and name.len > clipped_len) {
            try app_tui.writeStyled(style, "..");
        }
        const used = clipped_len + if (width > 2 and name.len > clipped_len) @as(usize, 2) else 0;
        for (used..width) |_| try app_tui.writeStyled(style, " ");
        return;
    }

    const available_name_width = width - prefix_width;
    const clipped_name_len = if (available_name_width > 2 and name.len > available_name_width)
        available_name_width - 2
    else
        @min(name.len, available_name_width);

    try app_tui.writeStyled(style, prefix);
    try app_tui.writeStyled(style, name[0..clipped_name_len]);
    var used = prefix_width + clipped_name_len;

    if (name.len > clipped_name_len and available_name_width > 2) {
        try app_tui.writeStyled(style, "..");
        used += 2;
    }

    for (used..width) |_| try app_tui.writeStyled(style, " ");
}

fn renderProcessRow(
    app_tui: *Tui,
    theme: ztop.config.Theme,
    layout: render.ProcessTableLayout,
    proc: ztop.sysinfo.ProcStats,
    is_selected: bool,
    prefix: []const u8,
    prefix_width: usize,
) !void {
    var buf: [32]u8 = undefined;
    const pid_style: Tui.Style = if (is_selected) .{ .bg = theme.selection_bg, .fg = theme.selection_fg } else .{ .fg = theme.muted };
    const ppid_style: Tui.Style = if (is_selected) .{ .bg = theme.selection_bg, .fg = theme.selection_fg } else .{ .fg = theme.muted };
    const name_style: Tui.Style = if (is_selected) .{ .bg = theme.selection_bg, .fg = theme.selection_fg } else .{ .fg = theme.text };

    var rendered_name = false;
    for (layout.columns[0..layout.count]) |column| {
        if (!rendered_name and switch (column) {
            .state, .cpu, .mem, .threads, .disk_read, .disk_write => true,
            .pid, .ppid => false,
        }) {
            try renderProcessNameCell(app_tui, name_style, layout.name_width, prefix, prefix_width, proc.name());
            rendered_name = true;
        }

        switch (column) {
            .pid => {
                const text = std.fmt.bufPrint(&buf, "{d}", .{proc.pid}) catch "";
                try render.writeAlignedCell(app_tui, pid_style, render.processColumnWidth(.pid), .right, text);
            },
            .ppid => {
                const text = std.fmt.bufPrint(&buf, "{d}", .{proc.ppid}) catch "";
                try render.writeAlignedCell(app_tui, ppid_style, render.processColumnWidth(.ppid), .right, text);
            },
            .state => {
                const style: Tui.Style = if (is_selected)
                    .{ .bg = theme.selection_bg, .fg = render.procStateColor(theme, proc.state) }
                else
                    .{ .fg = render.procStateColor(theme, proc.state) };
                try render.writeAlignedCell(app_tui, style, render.processColumnWidth(.state), .left, render.procStateLabel(proc.state));
            },
            .cpu => {
                const text = std.fmt.bufPrint(&buf, "{d:4.1}% CPU", .{proc.cpu_percent}) catch "";
                const style: Tui.Style = if (is_selected)
                    .{ .bg = theme.selection_bg, .fg = render.usageColor(theme, proc.cpu_percent), .bold = proc.cpu_percent >= 70 }
                else
                    .{ .fg = render.usageColor(theme, proc.cpu_percent), .bold = proc.cpu_percent >= 70 };
                try render.writeAlignedCell(app_tui, style, render.processColumnWidth(.cpu), .right, text);
            },
            .mem => {
                const text = std.fmt.bufPrint(&buf, "{d:4.1}% MEM", .{proc.mem_percent}) catch "";
                const style: Tui.Style = if (is_selected)
                    .{ .bg = theme.selection_bg, .fg = render.memoryColor(theme, proc.mem_percent), .bold = proc.mem_percent >= 10 }
                else
                    .{ .fg = render.memoryColor(theme, proc.mem_percent), .bold = proc.mem_percent >= 10 };
                try render.writeAlignedCell(app_tui, style, render.processColumnWidth(.mem), .right, text);
            },
            .threads => {
                const text = std.fmt.bufPrint(&buf, "{d} THR", .{proc.threads}) catch "";
                const style: Tui.Style = if (is_selected) .{ .bg = theme.selection_bg, .fg = theme.brand } else .{ .fg = theme.brand };
                try render.writeAlignedCell(app_tui, style, render.processColumnWidth(.threads), .right, text);
            },
            .disk_read => {
                const rate = render.formatUnit(proc.disk_read_ps);
                const text = std.fmt.bufPrint(&buf, "R {d:4.1}{s}/s", .{ rate.value, rate.unit }) catch "";
                const style: Tui.Style = if (is_selected) .{ .bg = theme.selection_bg, .fg = theme.disk_title } else .{ .fg = theme.disk_title };
                try render.writeAlignedCell(app_tui, style, render.processColumnWidth(.disk_read), .right, text);
            },
            .disk_write => {
                const rate = render.formatUnit(proc.disk_write_ps);
                const text = std.fmt.bufPrint(&buf, "W {d:4.1}{s}/s", .{ rate.value, rate.unit }) catch "";
                const style: Tui.Style = if (is_selected) .{ .bg = theme.selection_bg, .fg = theme.io_rate } else .{ .fg = theme.io_rate };
                try render.writeAlignedCell(app_tui, style, render.processColumnWidth(.disk_write), .right, text);
            },
        }
    }

    if (!rendered_name) {
        try renderProcessNameCell(app_tui, name_style, layout.name_width, prefix, prefix_width, proc.name());
    }
}

pub fn main(main_init: std.process.Init) !void {
    const allocator = main_init.gpa;
    const io = main_init.io;
    const args = try main_init.minimal.args.toSlice(main_init.arena.allocator());

    if (cli.detectAction(args) == .print_version) {
        var stdout_buffer: [64]u8 = undefined;
        var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
        try stdout_writer.interface.print("{s}\n", .{build_options.version});
        try stdout_writer.interface.flush();
        return;
    }

    const app_config = ztop.config.load(allocator, io, main_init.environ_map) catch |err| {
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

    var app_tui = try Tui.init(io, app_config.nerd_fonts, main_init.environ_map.get("TERM_PROGRAM"));
    defer app_tui.deinit();

    var sys_info = SysInfo.init(io);

    var cached_procs: []ztop.sysinfo.ProcStats = &.{};
    defer if (cached_procs.len > 0) allocator.free(cached_procs);

    var sort_by: ztop.sysinfo.SortBy = app_config.default_sort;
    var selected_idx: usize = 0;
    var scroll_offset: usize = 0;
    var show_help: bool = app_config.show_help_on_startup;
    var show_column_picker: bool = false;
    var process_columns = app_config.process_columns;
    var io_process_columns = app_config.io_process_columns;

    var filter_buf: [32]u8 = std.mem.zeroes([32]u8);
    var filter_len: usize = 0;
    var is_filtering: bool = false;

    var cmd_buf: [128]u8 = std.mem.zeroes([128]u8);
    var cmd_len: usize = 0;
    var is_cmd_mode: bool = false;

    var filtered_indices: [2048]usize = undefined;
    var filtered_depths: [2048]u8 = std.mem.zeroes([2048]u8);
    var filtered_is_lasts: [2048]u16 = std.mem.zeroes([2048]u16);
    var filtered_count: usize = 0;
    var tree_view: bool = app_config.default_tree_view;

    var zombie_parents: [ztop.sysinfo.common.MAX_PROCS]process_commands.ZombieParentEntry = undefined;
    var zombie_summary: process_commands.ZombieParentSummary = .{};
    var show_zombie_parents: bool = false;

    var thread_view: bool = false;
    var thread_view_pid: u32 = 0;
    var thread_view_name_buf: [64]u8 = std.mem.zeroes([64]u8);
    var thread_view_name_len: u8 = 0;
    var cached_threads: []ztop.sysinfo.common.ThreadStats = &.{};
    defer if (cached_threads.len > 0) allocator.free(cached_threads);

    var cached_connections: []ztop.sysinfo.common.NetConnection = &.{};
    defer if (cached_connections.len > 0) allocator.free(cached_connections);

    var cached_gpus: []ztop.sysinfo.GpuStats = &.{};
    defer if (cached_gpus.len > 0) allocator.free(cached_gpus);

    var status_buf: [160]u8 = std.mem.zeroes([160]u8);
    var status_len: usize = 0;

    var cpu_history: ztop.history.MetricHistory = .{};
    var mem_history: ztop.history.MetricHistory = .{};
    var disk_read_history: ztop.history.RateHistory = .{};
    var disk_write_history: ztop.history.RateHistory = .{};
    var net_rx_history: ztop.history.RateHistory = .{};
    var net_tx_history: ztop.history.RateHistory = .{};

    var cpu = sys_info.getCpuStats();
    var cpu_topology = sys_info.getCpuTopology();
    var mem = sys_info.getMemStats();
    var disk = sys_info.getDiskStats();
    var net = sys_info.getNetStats();
    var thermal = sys_info.getThermalStats();
    cached_gpus = try sys_info.getGpuStats(allocator);
    var battery = sys_info.getBatteryStats();
    cached_procs = try sys_info.getProcStats(allocator, sort_by);
    cached_procs = ztop.sysinfo.common.filterProcStatsByLaunchCommandSubstring(cached_procs, app_config.ignoredLaunchCommandSubstr());
    cpu_history.append(cpu.usage_percent);
    mem_history.append(memoryUsagePercent(mem));
    disk_read_history.append(disk.read_bytes_ps);
    disk_write_history.append(disk.write_bytes_ps);
    net_rx_history.append(net.rx_bytes_ps);
    net_tx_history.append(net.tx_bytes_ps);

    var last_fetch_time = nowMs(io);
    const fetch_interval_ms: i64 = @intCast(app_config.update_interval_ms);

    var force_redraw = true;
    var current_tab: u8 = app_config.default_tab;
    var mouse_regions: input_handler.MouseRegions = .{};
    var input_buf: [128]u8 = undefined;
    var input_len: usize = 0;

    if (current_tab == 4) {
        try render.refreshConnections(allocator, &sys_info, &cached_connections);
    }

    try app_tui.out.writeStreamingAll(io, "\x1b]2;ztop\x1b\\");

    while (!quit_flag) {
        if (sigwinch_flag) {
            sigwinch_flag = false;
            force_redraw = true;
        }

        const current_time = nowMs(io);
        const elapsed = current_time - last_fetch_time;

        if (elapsed >= fetch_interval_ms) {
            cpu = sys_info.getCpuStats();
            cpu_topology = sys_info.getCpuTopology();
            mem = sys_info.getMemStats();
            disk = sys_info.getDiskStats();
            net = sys_info.getNetStats();
            thermal = sys_info.getThermalStats();
            if (cached_gpus.len > 0) {
                allocator.free(cached_gpus);
            }
            cached_gpus = try sys_info.getGpuStats(allocator);
            battery = sys_info.getBatteryStats();
            cpu_history.append(cpu.usage_percent);
            mem_history.append(memoryUsagePercent(mem));
            disk_read_history.append(disk.read_bytes_ps);
            disk_write_history.append(disk.write_bytes_ps);
            net_rx_history.append(net.rx_bytes_ps);
            net_tx_history.append(net.tx_bytes_ps);

            if (cached_procs.len > 0) {
                allocator.free(cached_procs);
            }
            cached_procs = try sys_info.getProcStats(allocator, sort_by);
            cached_procs = ztop.sysinfo.common.filterProcStatsByLaunchCommandSubstring(cached_procs, app_config.ignoredLaunchCommandSubstr());

            if (current_tab == 4) {
                try render.refreshConnections(allocator, &sys_info, &cached_connections);
            }

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
            mouse_regions.reset();
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

                const tabs_str = "[1] Main  [2] I/O  [3] Sensors  [4] Network";
                if (size.width > tabs_str.len + 30) {
                    const tabs_x = size.width - @as(u16, @intCast(tabs_str.len)) - 2;
                    const tab1_label = "[1] Main";
                    const tab2_label = "[2] I/O";
                    const tab3_label = "[3] Sensors";
                    const tab4_label = "[4] Network";
                    const gap: u16 = 2;
                    const tab2_x = tabs_x + @as(u16, @intCast(tab1_label.len)) + gap;
                    const tab3_x = tab2_x + @as(u16, @intCast(tab2_label.len)) + gap;
                    const tab4_x = tab3_x + @as(u16, @intCast(tab3_label.len)) + gap;

                    mouse_regions.addTab(1, .{ .x = tabs_x, .y = 1, .width = tab1_label.len, .height = 1 });
                    mouse_regions.addTab(2, .{ .x = tab2_x, .y = 1, .width = tab2_label.len, .height = 1 });
                    mouse_regions.addTab(3, .{ .x = tab3_x, .y = 1, .width = tab3_label.len, .height = 1 });
                    mouse_regions.addTab(4, .{ .x = tab4_x, .y = 1, .width = tab4_label.len, .height = 1 });

                    try app_tui.moveCursor(tabs_x, 1);
                    if (current_tab == 1) try app_tui.printStyled(.{ .fg = theme.tab_active, .bold = true }, "{s}", .{tab1_label}) else try app_tui.printStyled(.{ .fg = theme.text, .dim = true }, "{s}", .{tab1_label});
                    try app_tui.out.writeStreamingAll(io, "  ");
                    if (current_tab == 2) try app_tui.printStyled(.{ .fg = theme.tab_active, .bold = true }, "{s}", .{tab2_label}) else try app_tui.printStyled(.{ .fg = theme.text, .dim = true }, "{s}", .{tab2_label});
                    try app_tui.out.writeStreamingAll(io, "  ");
                    if (current_tab == 3) try app_tui.printStyled(.{ .fg = theme.tab_active, .bold = true }, "{s}", .{tab3_label}) else try app_tui.printStyled(.{ .fg = theme.text, .dim = true }, "{s}", .{tab3_label});
                    try app_tui.out.writeStreamingAll(io, "  ");
                    if (current_tab == 4) try app_tui.printStyled(.{ .fg = theme.tab_active, .bold = true }, "{s}", .{tab4_label}) else try app_tui.printStyled(.{ .fg = theme.text, .dim = true }, "{s}", .{tab4_label});
                }

                const available_height = size.height -| 2;
                const is_small_width = size.width < 80;
                const top_boxes_height = if (current_tab == 1 and !is_small_width)
                    @max(available_height / 2, 6)
                else if (is_small_width)
                    available_height / 4
                else
                    available_height / 3;

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
                var process_layout: render.ProcessTableLayout = .{};

                if (current_tab == 1) {
                    try render.renderCpuTopologyBox(&app_tui, theme, cpu_box_x, cpu_box_y, cpu_box_width, cpu_box_height, cpu, cpu_topology, &cpu_history);

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
                        const mem_used_percent = memoryUsagePercent(mem);
                        try app_tui.moveCursor(mem_box_x + 2, mem_box_y + 1);
                        try app_tui.printStyled(.{ .fg = theme.text, .dim = true }, "Used: ", .{});
                        try app_tui.printStyled(.{ .fg = render.memoryColor(theme, mem_used_percent), .bold = true }, "{d} GB", .{mem.used / 1024 / 1024 / 1024});
                        try app_tui.printStyled(.{ .fg = theme.muted }, " (C: {d}M B: {d}M)", .{ mem.cached / 1024 / 1024, mem.buffered / 1024 / 1024 });
                        try app_tui.moveCursor(mem_box_x + 2, mem_box_y + 2);
                        try app_tui.printStyled(.{ .fg = theme.text, .dim = true }, "Free: ", .{});
                        try app_tui.printStyled(.{ .fg = theme.usage_good, .bold = true }, "{d} GB", .{mem.free / 1024 / 1024 / 1024});
                        if (mem.swap_total > 0 and mem_box_height >= 4) {
                            try app_tui.moveCursor(mem_box_x + 2, mem_box_y + 3);
                            try app_tui.printStyled(.{ .fg = theme.text, .dim = true }, "Swap: ", .{});
                            try app_tui.printStyled(.{ .fg = theme.memory_mid }, "{d} MB / {d} MB", .{ mem.swap_used / 1024 / 1024, mem.swap_total / 1024 / 1024 });
                        }

                        const stats_rows: u16 = if (mem.swap_total > 0 and mem_box_height >= 4) 3 else 2;
                        const graph_height = @min(
                            render.suggestedHistoryGraphRows(mem_box_height),
                            mem_box_height -| (stats_rows + 2),
                        );
                        if (graph_height > 0 and mem_box_width > 10 and mem_history.len() > 1) {
                            try render.renderHistoryGraph(
                                &app_tui,
                                theme,
                                mem_box_x + 2,
                                mem_box_y + 1 + stats_rows,
                                mem_box_width -| 4,
                                graph_height,
                                &mem_history,
                                .memory,
                            );
                        }
                    }
                } else if (current_tab == 2) {
                    try render.renderDualRateBox(
                        &app_tui,
                        theme,
                        cpu_box_x,
                        cpu_box_y,
                        cpu_box_width,
                        cpu_box_height,
                        "Disk I/O",
                        theme.disk_title,
                        .{
                            .label = "READ",
                            .short_label = "R ",
                            .rate_bytes_ps = disk.read_bytes_ps,
                            .history = &disk_read_history,
                            .color = theme.disk_title,
                        },
                        .{
                            .label = "WRITE",
                            .short_label = "W ",
                            .rate_bytes_ps = disk.write_bytes_ps,
                            .history = &disk_write_history,
                            .color = theme.io_rate,
                        },
                    );

                    try render.renderDualRateBox(
                        &app_tui,
                        theme,
                        mem_box_x,
                        mem_box_y,
                        mem_box_width,
                        mem_box_height,
                        "Network I/O",
                        theme.network_title,
                        .{
                            .label = "RX",
                            .short_label = "RX ",
                            .rate_bytes_ps = net.rx_bytes_ps,
                            .total_bytes = net.rx_bytes,
                            .history = &net_rx_history,
                            .color = theme.network_title,
                        },
                        .{
                            .label = "TX",
                            .short_label = "TX ",
                            .rate_bytes_ps = net.tx_bytes_ps,
                            .total_bytes = net.tx_bytes,
                            .history = &net_tx_history,
                            .color = theme.io_rate,
                        },
                    );
                } else if (current_tab == 3) {
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
                        if (cpu_box_height >= 4) {
                            try app_tui.moveCursor(cpu_box_x + 2, cpu_box_y + 2);
                            try app_tui.printStyled(.{ .fg = theme.text, .dim = true }, "GPU Temp: ", .{});
                            if (aggregateGpuTemp(thermal, cached_gpus)) |t| {
                                try app_tui.printStyled(.{ .fg = theme.io_rate, .bold = true }, "{d:4.1} C", .{t});
                            } else {
                                try app_tui.printStyled(.{ .fg = theme.muted }, "N/A", .{});
                            }
                        }
                        if (cpu_box_height >= 5) {
                            try app_tui.moveCursor(cpu_box_x + 2, cpu_box_y + 3);
                            try app_tui.printStyled(.{ .fg = theme.text, .dim = true }, "Charge: ", .{});
                            if (battery.charge_percent) |c| {
                                try app_tui.printStyled(.{ .fg = theme.io_rate, .bold = true }, "{d:4.1}%", .{c});
                            } else {
                                try app_tui.printStyled(.{ .fg = theme.muted }, "N/A", .{});
                            }
                        }
                        if (cpu_box_height >= 6) {
                            try app_tui.moveCursor(cpu_box_x + 2, cpu_box_y + 4);
                            try app_tui.printStyled(.{ .fg = theme.text, .dim = true }, "Power: ", .{});
                            if (battery.power_draw_w) |w| {
                                try app_tui.printStyled(.{ .fg = theme.io_rate, .bold = true }, "{d:4.2} W", .{w});
                            } else {
                                try app_tui.printStyled(.{ .fg = theme.muted }, "N/A", .{});
                            }
                        }
                        if (cpu_box_height >= 7) {
                            try app_tui.moveCursor(cpu_box_x + 2, cpu_box_y + 5);
                            try app_tui.printStyled(.{ .fg = theme.text, .dim = true }, "Status: ", .{});
                            try app_tui.printStyled(.{ .fg = theme.text }, "{s}", .{batteryStatusLabel(battery.status)});
                        }
                    }

                    try app_tui.drawBoxStyled(
                        mem_box_x,
                        mem_box_y,
                        mem_box_width,
                        mem_box_height,
                        "GPU Monitoring",
                        .{ .fg = theme.border },
                        .{ .fg = theme.sensor_title, .bold = true },
                    );
                    if (mem_box_height >= 3) {
                        if (cached_gpus.len == 0) {
                            try app_tui.moveCursor(mem_box_x + 2, mem_box_y + 1);
                            try app_tui.printStyled(.{ .fg = theme.muted }, "No supported GPU metrics detected", .{});
                        } else {
                            const rows_per_gpu: u16 = if (mem_box_height >= 7 and mem_box_width >= 42) 2 else 1;
                            const available_rows = mem_box_height - 2;
                            const visible_gpu_count = @min(cached_gpus.len, @as(usize, @intCast(available_rows / rows_per_gpu)));

                            for (cached_gpus[0..visible_gpu_count], 0..) |gpu, gpu_idx| {
                                const row_y = mem_box_y + 1 + @as(u16, @intCast(gpu_idx)) * rows_per_gpu;
                                const gpu_name = gpu.name();
                                const name_limit: usize = if (mem_box_width > 38) @as(usize, mem_box_width - 30) else 12;
                                const display_name = if (gpu_name.len > name_limit) gpu_name[0..name_limit] else gpu_name;

                                try app_tui.moveCursor(mem_box_x + 2, row_y);
                                try app_tui.printStyled(.{ .fg = theme.text, .bold = true }, "{s}", .{if (display_name.len > 0) display_name else "GPU"});
                                try app_tui.printStyled(.{ .fg = theme.muted }, " [{s}]", .{gpuVendorLabel(gpu.vendor)});
                                if (gpu.core_count) |core_count| {
                                    try app_tui.printStyled(.{ .fg = theme.muted }, " {d} cores", .{core_count});
                                }
                                try app_tui.printStyled(.{ .fg = theme.text, .dim = true }, "  Util: ", .{});
                                if (gpu.utilization_percent) |util| {
                                    try app_tui.printStyled(.{ .fg = render.usageColor(theme, util), .bold = true }, "{d:4.1}%", .{util});
                                } else {
                                    try app_tui.printStyled(.{ .fg = theme.muted }, "N/A", .{});
                                }

                                if (rows_per_gpu == 2 and row_y + 1 < mem_box_y + mem_box_height - 1) {
                                    try app_tui.moveCursor(mem_box_x + 2, row_y + 1);
                                    var wrote_detail = false;

                                    if (gpu.memory_used_bytes) |used_bytes| {
                                        const used_value = render.formatUnit(used_bytes);
                                        try app_tui.printStyled(.{ .fg = theme.text, .dim = true }, "Mem: ", .{});
                                        if (gpu.memory_total_bytes) |total_bytes| {
                                            const total_value = render.formatUnit(total_bytes);
                                            try app_tui.printStyled(.{ .fg = theme.memory_mid }, "{d:4.1} {s} / {d:4.1} {s}", .{ used_value.value, used_value.unit, total_value.value, total_value.unit });
                                        } else {
                                            try app_tui.printStyled(.{ .fg = theme.memory_mid }, "{d:4.1} {s}", .{ used_value.value, used_value.unit });
                                        }
                                        wrote_detail = true;
                                    }

                                    if (gpu.temperature_c) |temp_c| {
                                        if (wrote_detail) try app_tui.printStyled(.{ .fg = theme.muted }, "  ", .{});
                                        try app_tui.printStyled(.{ .fg = theme.text, .dim = true }, "Temp: ", .{});
                                        try app_tui.printStyled(.{ .fg = theme.io_rate }, "{d:4.1} C", .{temp_c});
                                        wrote_detail = true;
                                    }

                                    if (gpu.power_draw_w) |power_w| {
                                        if (wrote_detail) try app_tui.printStyled(.{ .fg = theme.muted }, "  ", .{});
                                        try app_tui.printStyled(.{ .fg = theme.text, .dim = true }, "Power: ", .{});
                                        try app_tui.printStyled(.{ .fg = theme.io_rate }, "{d:4.1} W", .{power_w});
                                        wrote_detail = true;
                                    }

                                    if (!wrote_detail) {
                                        try app_tui.printStyled(.{ .fg = theme.muted }, "No additional counters exposed", .{});
                                    }
                                }
                            }

                            if (visible_gpu_count < cached_gpus.len and mem_box_height >= 4) {
                                try app_tui.moveCursor(mem_box_x + 2, mem_box_y + mem_box_height - 2);
                                try app_tui.printStyled(.{ .fg = theme.muted }, "+{d} more GPU(s)", .{cached_gpus.len - visible_gpu_count});
                            }
                        }
                    }
                } else if (current_tab == 4) {
                    // Network Totals Box
                    try app_tui.drawBoxStyled(
                        cpu_box_x,
                        cpu_box_y,
                        size.width, // Full width for top box
                        cpu_box_height,
                        "Network Overview",
                        .{ .fg = theme.border },
                        .{ .fg = theme.sensor_title, .bold = true },
                    );
                    if (cpu_box_height >= 3) {
                        try app_tui.moveCursor(cpu_box_x + 2, cpu_box_y + 1);
                        try app_tui.printStyled(.{ .fg = theme.text, .dim = true }, "Rx: ", .{});
                        const rx_ps = render.formatUnit(net.rx_bytes_ps);
                        try app_tui.printStyled(.{ .fg = theme.io_rate, .bold = true }, "{d:4.1} {s}/s", .{ rx_ps.value, rx_ps.unit });

                        try app_tui.moveCursor(cpu_box_x + 22, cpu_box_y + 1);
                        try app_tui.printStyled(.{ .fg = theme.text, .dim = true }, "Tx: ", .{});
                        const tx_ps = render.formatUnit(net.tx_bytes_ps);
                        try app_tui.printStyled(.{ .fg = theme.io_rate, .bold = true }, "{d:4.1} {s}/s", .{ tx_ps.value, tx_ps.unit });
                    }
                }

                // Bottom Box: Processes, Threads, or Connections
                if (current_tab == 4) {
                    // Connections Box
                    if (procs_box_height >= 3) {
                        try app_tui.drawBoxStyled(
                            procs_box_x,
                            procs_box_y,
                            procs_box_width,
                            procs_box_height,
                            "Network Connections",
                            .{ .fg = theme.border },
                            .{ .fg = theme.process_title, .bold = true },
                        );
                        const visible_rows = procs_box_height - 2;
                        mouse_regions.list_rect = .{
                            .x = procs_box_x + 1,
                            .y = procs_box_y + 1,
                            .width = procs_box_width -| 2,
                            .height = visible_rows,
                        };
                        const conn_count = cached_connections.len;
                        if (conn_count == 0) {
                            selected_idx = 0;
                            scroll_offset = 0;
                        } else {
                            if (selected_idx >= conn_count) selected_idx = conn_count - 1;
                        }

                        if (selected_idx < scroll_offset) {
                            scroll_offset = selected_idx;
                        } else if (selected_idx >= scroll_offset + visible_rows) {
                            scroll_offset = selected_idx - visible_rows + 1;
                        }

                        if (conn_count == 0) {
                            try app_tui.moveCursor(procs_box_x + 2, procs_box_y + 1);
                            try app_tui.printStyled(.{ .fg = theme.muted }, "No active connections detected", .{});
                        }

                        for (0..visible_rows) |row| {
                            const idx = scroll_offset + row;
                            if (idx >= conn_count) break;
                            const conn = cached_connections[idx];

                            const is_selected = (idx == selected_idx) and !show_help;

                            try app_tui.moveCursor(procs_box_x + 2, procs_box_y + 1 + @as(u16, @intCast(row)));

                            if (is_selected) {
                                try app_tui.setStyle(.{ .bg = theme.selection_bg });
                                for (0..procs_box_width - 4) |_| try app_tui.out.writeStreamingAll(io, " ");
                                try app_tui.moveCursor(procs_box_x + 2, procs_box_y + 1 + @as(u16, @intCast(row)));
                            }

                            try app_tui.printStyled(if (is_selected) .{ .bg = theme.selection_bg, .fg = theme.selection_fg } else .{ .fg = theme.text }, "{s:4} ", .{@tagName(conn.protocol)});

                            const local_str = std.mem.sliceTo(&conn.local_addr, 0);
                            if (conn.local_port > 0) {
                                try app_tui.printStyled(if (is_selected) .{ .bg = theme.selection_bg, .fg = theme.selection_fg } else .{ .fg = theme.text }, "{s}:{d:<5} ", .{ local_str, conn.local_port });
                            } else {
                                try app_tui.printStyled(if (is_selected) .{ .bg = theme.selection_bg, .fg = theme.selection_fg } else .{ .fg = theme.text }, "{s:<11} ", .{local_str});
                            }
                            try app_tui.printStyled(if (is_selected) .{ .bg = theme.selection_bg, .fg = theme.muted } else .{ .fg = theme.muted }, "-> ", .{});

                            const remote_str = std.mem.sliceTo(&conn.remote_addr, 0);
                            if (conn.remote_port > 0) {
                                try app_tui.printStyled(if (is_selected) .{ .bg = theme.selection_bg, .fg = theme.selection_fg } else .{ .fg = theme.text }, "{s}:{d:<5} ", .{ remote_str, conn.remote_port });
                            } else {
                                try app_tui.printStyled(if (is_selected) .{ .bg = theme.selection_bg, .fg = theme.selection_fg } else .{ .fg = theme.text }, "{s:<11} ", .{remote_str});
                            }

                            if (conn.protocol == .tcp or conn.protocol == .tcp6) {
                                try app_tui.printStyled(if (is_selected) .{ .bg = theme.selection_bg, .fg = theme.muted } else .{ .fg = theme.muted }, "[{s:<11}] ", .{@tagName(conn.state)});
                            } else {
                                try app_tui.printStyled(if (is_selected) .{ .bg = theme.selection_bg, .fg = theme.muted } else .{ .fg = theme.muted }, "[{s:<11}] ", .{"-"});
                            }

                            try app_tui.printStyled(if (is_selected) .{ .bg = theme.selection_bg, .fg = theme.process_title } else .{ .fg = theme.process_title }, "{s} (PID: {d})", .{ conn.name(), conn.pid });

                            if (is_selected) {
                                try app_tui.resetStyle();
                            }
                        }
                    }
                } else if (procs_box_height >= 3) {
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
                        mouse_regions.list_rect = .{
                            .x = procs_box_x + 1,
                            .y = procs_box_y + 1,
                            .width = procs_box_width -| 2,
                            .height = visible_rows,
                        };
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
                                for (0..procs_box_width - 4) |_| try app_tui.out.writeStreamingAll(io, " ");
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

                            const c_style: Tui.Style = if (is_selected) .{ .bg = theme.selection_bg, .fg = render.usageColor(theme, thr.cpu_percent), .bold = thr.cpu_percent >= 70 } else .{ .fg = render.usageColor(theme, thr.cpu_percent), .bold = thr.cpu_percent >= 70 };
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
                        const current_process_columns = activeProcessColumns(current_tab, &process_columns, &io_process_columns);
                        const visible_column_count = current_process_columns.countVisible() + 1; // Name is always visible.
                        const title = if (show_zombie_parents)
                            std.fmt.bufPrint(
                                &title_buf,
                                "Zombie Parents ({d} parents / {d} zombies)",
                                .{ zombie_summary.parent_count, zombie_summary.zombie_count },
                            ) catch "Zombie Parents"
                        else
                            std.fmt.bufPrint(&title_buf, "Processes (Sort: {s} | Cols: {d})", .{ sort_name, visible_column_count }) catch "Processes";

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

                        if (tree_view and filter_len == 0 and !show_zombie_parents) {
                            filtered_count = process_commands.buildTreeView(
                                allocator,
                                cached_procs,
                                &filtered_indices,
                                &filtered_depths,
                                &filtered_is_lasts,
                            );
                        } else {
                            var pid_buf2: [32]u8 = undefined;
                            var l_name: [64]u8 = undefined;
                            var l_filter: [32]u8 = undefined;
                            // Pre-compute lowercased filter string once outside the loop
                            if (filter_len > 0) {
                                @memcpy(l_filter[0..filter_len], filter_str);
                                for (l_filter[0..filter_len]) |*ch| ch.* = std.ascii.toLower(ch.*);
                            }
                            const f_str = l_filter[0..filter_len];

                            for (cached_procs, 0..) |proc, i| {
                                if (show_zombie_parents and !process_commands.containsParentPid(zombie_parents[0..zombie_summary.parent_count], proc.pid)) {
                                    continue;
                                }

                                if (filter_len > 0) {
                                    const pid_str = std.fmt.bufPrint(&pid_buf2, "{d}", .{proc.pid}) catch "";
                                    const name_len = proc.name().len;
                                    @memcpy(l_name[0..name_len], proc.name());
                                    const n_str = l_name[0..name_len];
                                    for (n_str) |*ch| ch.* = std.ascii.toLower(ch.*);

                                    const name_matches = std.mem.indexOf(u8, n_str, f_str) != null;
                                    const pid_matches = std.mem.indexOf(u8, pid_str, filter_str) != null;
                                    if (!name_matches and !pid_matches) continue;
                                }
                                filtered_indices[filtered_count] = i;
                                filtered_depths[filtered_count] = 0;
                                filtered_is_lasts[filtered_count] = 0;
                                filtered_count += 1;
                                if (filtered_count >= filtered_indices.len) break;
                            }
                        }

                        if (filtered_count == 0) {
                            selected_idx = 0;
                            scroll_offset = 0;
                        } else {
                            if (selected_idx >= filtered_count) selected_idx = filtered_count - 1;
                        }

                        const visible_rows = procs_box_height - 2;
                        mouse_regions.list_rect = .{
                            .x = procs_box_x + 1,
                            .y = procs_box_y + 1,
                            .width = procs_box_width -| 2,
                            .height = visible_rows,
                        };
                        if (selected_idx < scroll_offset) {
                            scroll_offset = selected_idx;
                        } else if (selected_idx >= scroll_offset + visible_rows) {
                            scroll_offset = selected_idx - visible_rows + 1;
                        }

                        process_layout = render.planProcessTableLayout(current_process_columns.*, procs_box_width -| 4);

                        var prefix_buf: [256]u8 = undefined;
                        for (0..visible_rows) |row| {
                            const idx = scroll_offset + row;
                            if (idx >= filtered_count) break;
                            const proc_idx = filtered_indices[idx];
                            const proc = cached_procs[proc_idx];

                            const is_selected = (idx == selected_idx) and !show_help;

                            try app_tui.moveCursor(procs_box_x + 2, procs_box_y + 1 + @as(u16, @intCast(row)));

                            if (is_selected) {
                                try app_tui.setStyle(.{ .bg = theme.selection_bg });
                                for (0..procs_box_width - 4) |_| try app_tui.out.writeStreamingAll(io, " ");
                                try app_tui.moveCursor(procs_box_x + 2, procs_box_y + 1 + @as(u16, @intCast(row)));
                            }

                            var prefix_len: usize = 0;
                            var prefix_width: usize = 0;
                            if (tree_view and filter_len == 0 and !show_zombie_parents) {
                                const depth = filtered_depths[idx];
                                const is_last_mask = filtered_is_lasts[idx];
                                for (0..depth) |d| {
                                    const d_is_last = (is_last_mask & (@as(u16, 1) << @as(u4, @intCast(d)))) != 0;
                                    if (d == depth - 1) {
                                        const branch = if (d_is_last) "└─ " else "├─ ";
                                        @memcpy(prefix_buf[prefix_len .. prefix_len + branch.len], branch);
                                        prefix_len += branch.len;
                                        prefix_width += 3;
                                    } else {
                                        const branch = if (d_is_last) "   " else "│  ";
                                        @memcpy(prefix_buf[prefix_len .. prefix_len + branch.len], branch);
                                        prefix_len += branch.len;
                                        prefix_width += 3;
                                    }
                                }
                            }

                            try renderProcessRow(
                                &app_tui,
                                theme,
                                process_layout,
                                proc,
                                is_selected,
                                prefix_buf[0..prefix_len],
                                prefix_width,
                            );

                            if (is_selected) {
                                try app_tui.resetStyle();
                            }
                        }
                    }
                }

                // Help Overlay
                if (show_help) {
                    const help_width = 48;
                    const help_height = 16;
                    const h_x = if (size.width > help_width) (size.width - help_width) / 2 else 1;
                    const h_y = if (size.height > help_height) (size.height - help_height) / 2 else 1;

                    // Clear background for overlay
                    for (0..help_height) |i| {
                        try app_tui.moveCursor(h_x, h_y + @as(u16, @intCast(i)));
                        for (0..help_width) |_| try app_tui.out.writeStreamingAll(io, " ");
                    }

                    try app_tui.drawBoxStyled(h_x, h_y, help_width, help_height, "Help", .{ .fg = theme.border }, .{ .fg = theme.text, .bold = true });
                    try app_tui.moveCursor(h_x + 2, h_y + 2);
                    try app_tui.printStyled(.{ .fg = theme.text }, "1, 2, 3, 4:   ", .{});
                    try app_tui.printStyled(.{ .fg = theme.muted }, "Switch Tabs", .{});

                    try app_tui.moveCursor(h_x + 2, h_y + 3);
                    try app_tui.printStyled(.{ .fg = theme.text }, "j/k, Up/Down: ", .{});
                    try app_tui.printStyled(.{ .fg = theme.muted }, "Navigate processes", .{});

                    try app_tui.moveCursor(h_x + 2, h_y + 4);
                    try app_tui.printStyled(.{ .fg = theme.text }, "c, m, p, n:   ", .{});
                    try app_tui.printStyled(.{ .fg = theme.muted }, "Sort by CPU/Mem/PID/Name", .{});

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
                    try app_tui.printStyled(.{ .fg = theme.text }, "q:            ", .{});
                    try app_tui.printStyled(.{ .fg = theme.muted }, "Quit", .{});

                    try app_tui.moveCursor(h_x + 2, h_y + 12);
                    try app_tui.printStyled(.{ .fg = theme.text }, ":             ", .{});
                    try app_tui.printStyled(.{ .fg = theme.muted }, "Command mode (show zombie)", .{});

                    try app_tui.moveCursor(h_x + 2, h_y + 13);
                    try app_tui.printStyled(.{ .fg = theme.text }, "Repo: ", .{});
                    try app_tui.writeStyledHyperlink(.{ .fg = theme.tab_active, .underline = true }, repo_url, repo_label);

                    try app_tui.moveCursor(h_x + 2, h_y + 14);
                    try app_tui.printStyled(.{ .fg = theme.muted }, "Press any key to close...", .{});
                }

                if (show_column_picker) {
                    const picker_width = 40;
                    const picker_height = 14;
                    const picker_x = if (size.width > picker_width) (size.width - picker_width) / 2 else 1;
                    const picker_y = if (size.height > picker_height) (size.height - picker_height) / 2 else 1;
                    const picker_columns = activeProcessColumns(current_tab, &process_columns, &io_process_columns);
                    const picker_title = if (current_tab == 2) "I/O Columns" else "Process Columns";

                    for (0..picker_height) |i| {
                        try app_tui.moveCursor(picker_x, picker_y + @as(u16, @intCast(i)));
                        for (0..picker_width) |_| try app_tui.out.writeStreamingAll(io, " ");
                    }

                    try app_tui.drawBoxStyled(picker_x, picker_y, picker_width, picker_height, picker_title, .{ .fg = theme.border }, .{ .fg = theme.text, .bold = true });
                    try app_tui.moveCursor(picker_x + 2, picker_y + 2);
                    try app_tui.printStyled(.{ .fg = theme.muted }, "Name is always visible.", .{});

                    for (ztop.config.process_column_order, 0..) |column, idx| {
                        try app_tui.moveCursor(picker_x + 2, picker_y + 4 + @as(u16, @intCast(idx)));
                        try app_tui.printStyled(.{ .fg = theme.text, .bold = true }, "{d}. ", .{idx + 1});
                        try app_tui.printStyled(
                            .{ .fg = if (picker_columns.isVisible(column)) theme.usage_good else theme.muted, .bold = picker_columns.isVisible(column) },
                            "[{c}]",
                            .{if (picker_columns.isVisible(column)) @as(u8, 'x') else @as(u8, ' ')},
                        );
                        try app_tui.printStyled(.{ .fg = theme.text }, " {s}", .{column.label()});
                    }

                    try app_tui.moveCursor(picker_x + 2, picker_y + 12);
                    try app_tui.printStyled(.{ .fg = theme.muted }, "Press 1-8 to toggle, Enter/Esc to close", .{});
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
                } else if (show_column_picker) {
                    try app_tui.printStyled(.{ .fg = theme.muted }, "Process columns: ", .{});
                    try app_tui.printStyled(.{ .fg = theme.text, .bold = true }, "1-8", .{});
                    try app_tui.printStyled(.{ .fg = theme.muted }, " toggle, ", .{});
                    try app_tui.printStyled(.{ .fg = theme.text, .bold = true }, "Enter/Esc", .{});
                    try app_tui.printStyled(.{ .fg = theme.muted }, " close", .{});
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
                } else if (process_layout.dropped_count > 0) {
                    try app_tui.printStyled(.{ .fg = theme.muted }, "{d} column(s) hidden by width | Press ", .{process_layout.dropped_count});
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

                try render.updateFooterCursor(&app_tui, size.width, size.height, is_cmd_mode, cmd_len, is_filtering, filter_len);
            }
        } // end force_redraw

        var fds = [_]posix.pollfd{.{ .fd = app_tui.in.handle, .events = posix.POLL.IN, .revents = 0 }};
        const now = nowMs(io);
        var remaining_ms = fetch_interval_ms - (now - last_fetch_time);
        if (remaining_ms < 0) remaining_ms = 0;

        const poll_res = posix.poll(&fds, @intCast(remaining_ms)) catch 0;

        if (poll_res > 0 and (fds[0].revents & posix.POLL.IN) != 0) {
            var input_ctx: input_handler.Context = .{
                .allocator = allocator,
                .sys_info = &sys_info,
                .app_tui = &app_tui,
                .cached_procs = cached_procs,
                .cached_threads = &cached_threads,
                .cached_connections = &cached_connections,
                .sort_by = &sort_by,
                .selected_idx = &selected_idx,
                .scroll_offset = &scroll_offset,
                .show_help = &show_help,
                .show_column_picker = &show_column_picker,
                .filter_buf = &filter_buf,
                .filter_len = &filter_len,
                .is_filtering = &is_filtering,
                .cmd_buf = &cmd_buf,
                .cmd_len = &cmd_len,
                .is_cmd_mode = &is_cmd_mode,
                .filtered_indices = filtered_indices[0..],
                .filtered_count = &filtered_count,
                .tree_view = &tree_view,
                .zombie_parents = zombie_parents[0..],
                .zombie_summary = &zombie_summary,
                .show_zombie_parents = &show_zombie_parents,
                .thread_view = &thread_view,
                .thread_view_pid = &thread_view_pid,
                .thread_view_name_buf = &thread_view_name_buf,
                .thread_view_name_len = &thread_view_name_len,
                .status_buf = &status_buf,
                .status_len = &status_len,
                .current_tab = &current_tab,
                .mouse_regions = &mouse_regions,
                .quit_flag = &quit_flag,
                .input_buf = &input_buf,
                .input_len = &input_len,
                .process_columns = &process_columns,
                .io_process_columns = &io_process_columns,
            };
            force_redraw = try input_handler.handleAvailableInput(&input_ctx);
        }
    }
}
