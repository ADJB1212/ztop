const std = @import("std");
const ztop = @import("ztop");
const build_options = @import("build_options");
const main_view = @import("main_view.zig");
const cli = ztop.cli;
const render = ztop.render;
const input_handler = ztop.input_handler;
const process_commands = ztop.process_commands;
const timeline_mod = ztop.timeline;
const Tui = ztop.tui.Tui;
const SysInfo = ztop.sysinfo.SysInfo;
const posix = std.posix;
const memoryUsagePercent = main_view.memoryUsagePercent;
const formatWifiSsidLine = main_view.formatWifiSsidLine;
const formatWifiGenerationLine = main_view.formatWifiGenerationLine;
const activeProcessColumns = main_view.activeProcessColumns;
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

fn nowMs(io: std.Io) i64 {
    return std.Io.Clock.now(.real, io).toMilliseconds();
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

    const app_config = ztop.config.load(allocator, io, main_init.environ_map);
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

    var app_tui = try Tui.init(allocator, io, app_config.nerd_fonts, main_init.environ_map.get("TERM_PROGRAM"));
    defer app_tui.deinit();

    var sys_info = SysInfo.init(io);

    // Pre-allocate proc buffer once — reused every tick, no per-tick alloc/free
    const proc_buf = try allocator.alloc(ztop.sysinfo.ProcStats, ztop.sysinfo.common.MAX_PROCS);
    defer allocator.free(proc_buf);
    var cached_procs: []ztop.sysinfo.ProcStats = &.{};

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
    var is_following: bool = false;
    var follow_pid: u32 = 0;
    var thread_view_name_buf: [64]u8 = std.mem.zeroes([64]u8);
    var thread_view_name_len: u8 = 0;
    var cached_threads: []ztop.sysinfo.common.ThreadStats = &.{};
    defer if (cached_threads.len > 0) allocator.free(cached_threads);

    var causality_view: bool = false;
    var causality_pid: u32 = 0;
    var causality_name_buf: [64]u8 = std.mem.zeroes([64]u8);
    var causality_name_len: u8 = 0;
    var causality_connections: []ztop.sysinfo.common.NetConnection = &.{};

    var lifeline_view: bool = false;
    var lifeline_name_buf: [64]u8 = std.mem.zeroes([64]u8);
    var lifeline_name_len: u8 = 0;
    var pipeline_view: bool = false;
    var pipeline_row_count: usize = 0;
    var active_tracer: ?*ztop.process_tracer.ProcessTracer = null;
    defer {
        if (active_tracer) |tracer| tracer.deinit();
    }

    defer if (causality_connections.len > 0) allocator.free(causality_connections);

    var cached_connections: std.ArrayList(ztop.sysinfo.common.NetConnection) = .empty;
    defer cached_connections.deinit(allocator);

    var cached_gpus: []ztop.sysinfo.GpuStats = &.{};
    defer if (cached_gpus.len > 0) allocator.free(cached_gpus);

    var status_buf: [160]u8 = std.mem.zeroes([160]u8);
    var status_len: usize = 0;

    var cpu_history: ztop.history.MetricHistory = .{};
    var disk_read_history: ztop.history.RateHistory = .{};
    var disk_write_history: ztop.history.RateHistory = .{};
    var net_rx_history: ztop.history.RateHistory = .{};
    var net_tx_history: ztop.history.RateHistory = .{};

    // Timeline scrubber: heap-allocated (~2MB struct)
    const timeline = try allocator.create(timeline_mod.Timeline);
    defer allocator.destroy(timeline);
    timeline.* = timeline_mod.Timeline.init();
    var is_scrubbing: bool = false;
    var scrub_offset: usize = 0;
    var diff_anchor: ?usize = null;
    var refresh_interval_ms: ?u32 = null;
    var top_n: ?usize = null;
    // Buffer for snapshot procs when displaying scrubbed view
    var scrub_proc_buf: [timeline_mod.MAX_SNAPSHOT_PROCS]ztop.sysinfo.ProcStats = undefined;
    var scrub_proc_count: usize = 0;

    // ── Crash-adjacent session recovery ──────────────────────────────────────
    // Compute the session file path once; reused on clean exit to persist data.
    const session_path: ?[]u8 = if (app_config.persist_session)
        ztop.config.defaultSessionPath(allocator, main_init.environ_map) catch null
    else
        null;
    defer if (session_path) |p| allocator.free(p);

    // Try to restore the previous session. On success the user starts in scrub
    // mode so they can inspect what happened before the last exit/crash.
    if (session_path) |sp| {
        timeline.loadFromDisk(io, allocator, sp) catch {};
        if (timeline.snapshotCount() > 0) {
            is_scrubbing = true;
            scrub_offset = 0;
            render.setStatus(&status_buf, &status_len, "Session recovered ({d} snapshots). Scrubbing — press Esc to resume live view.", .{timeline.snapshotCount()});
        }
    }
    // ─────────────────────────────────────────────────────────────────────────

    var cpu = sys_info.getCpuStats();
    const cpu_topology = sys_info.getCpuTopology();
    var mem = sys_info.getMemStats();
    var disk = sys_info.getDiskStats();
    var net = sys_info.getNetStats();
    var thermal = sys_info.getThermalStats();
    if (app_config.default_tab == 3) {
        cached_gpus = try sys_info.getGpuStats(allocator);
    }
    var battery = sys_info.getBatteryStats();
    cached_procs = try sys_info.getProcStats(proc_buf, sort_by);
    cached_procs = ztop.sysinfo.common.filterProcStatsByLaunchCommandSubstring(cached_procs, app_config.ignoredLaunchCommandSubstr());
    cpu_history.append(cpu.usage_percent);
    disk_read_history.append(disk.read_bytes_ps);
    disk_write_history.append(disk.write_bytes_ps);
    net_rx_history.append(net.rx_bytes_ps);
    net_tx_history.append(net.tx_bytes_ps);

    var last_fetch_time = nowMs(io);

    // Cache uname once — kernel info never changes at runtime
    const uname = posix.uname();
    const sysname = std.mem.sliceTo(&uname.sysname, 0);
    const release = std.mem.sliceTo(&uname.release, 0);
    const machine = std.mem.sliceTo(&uname.machine, 0);
    const nodename = std.mem.sliceTo(&uname.nodename, 0);

    var force_redraw = true;
    var current_tab: u8 = app_config.default_tab;
    var mouse_regions: input_handler.MouseRegions = .{};
    var input_buf: [128]u8 = undefined;
    var input_len: usize = 0;

    if (current_tab == 4) {
        try render.refreshConnections(allocator, &sys_info, &cached_connections);
    }

    try app_tui.bufWrite("\x1b]2;ztop\x1b\\");

    while (!quit_flag) {
        if (sigwinch_flag) {
            sigwinch_flag = false;
            force_redraw = true;
        }

        const current_time = nowMs(io);
        const elapsed = current_time - last_fetch_time;
        const fetch_interval_ms: i64 = @intCast(refresh_interval_ms orelse app_config.effectiveIntervalMs(current_tab));

        if (elapsed >= fetch_interval_ms) {
            cpu = sys_info.getCpuStats();
            mem = sys_info.getMemStats();
            disk = sys_info.getDiskStats();
            net = sys_info.getNetStats();
            thermal = sys_info.getThermalStats();
            if (current_tab == 3) {
                if (cached_gpus.len > 0) {
                    allocator.free(cached_gpus);
                }
                cached_gpus = try sys_info.getGpuStats(allocator);
            }
            battery = sys_info.getBatteryStats();
            if (!is_scrubbing) {
                cpu_history.append(cpu.usage_percent);
                disk_read_history.append(disk.read_bytes_ps);
                disk_write_history.append(disk.write_bytes_ps);
                net_rx_history.append(net.rx_bytes_ps);
                net_tx_history.append(net.tx_bytes_ps);
            }

            cached_procs = try sys_info.getProcStats(proc_buf, sort_by);
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

            if (causality_view) {
                if (causality_connections.len > 0) {
                    allocator.free(causality_connections);
                }
                causality_connections = input_handler.fetchProcConnections(allocator, &sys_info, causality_pid) catch &.{};
            }

            if (lifeline_view) {
                if (active_tracer) |tracer| {
                    var target_proc: ?ztop.sysinfo.ProcStats = null;
                    for (cached_procs) |p| {
                        if (p.pid == tracer.pid) {
                            target_proc = p;
                            break;
                        }
                    }
                    tracer.update(&sys_info, current_time, target_proc);
                }
            }

            last_fetch_time = current_time;
            force_redraw = true;

            // Record snapshot for timeline scrubber
            const tl_snap = timeline_mod.SystemSnapshot{
                .timestamp_ms = current_time,
                .cpu_usage_pct = cpu.usage_percent,
                .cpu_cores = cpu.cores,
                .mem = mem,
                .mem_usage_pct = memoryUsagePercent(mem),
                .disk = disk,
                .net = net,
                .thermal = thermal,
                .battery = battery,
            };
            timeline.detectAndRecordEvents(&tl_snap, cached_procs, app_config.temperature_unit);
            // Only grow ring when not scrubbing; scrub_offset is relative to
            // snap_count, so adding snapshots while scrubbing drifts the view.
            if (!is_scrubbing) {
                timeline.recordSnapshot(tl_snap, cached_procs);
            }
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
                try main_view.renderHeader(
                    &app_tui,
                    theme,
                    size.width,
                    current_tab,
                    sysname,
                    release,
                    machine,
                    nodename,
                    &mouse_regions,
                );

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
                // Reserve 1 row for the timeline bar when we have snapshot data
                const timeline_bar_active = timeline.snapshotCount() >= 2;
                const timeline_bar_y: u16 = size.height -| 1;
                const procs_box_height: u16 = size.height -| procs_box_y -| 1 -| @as(u16, if (timeline_bar_active) 1 else 0);
                var process_layout: render.ProcessTableLayout = .{};

                // Build display state (live or from scrubbed snapshot)
                var display_cpu = cpu;
                var display_mem = mem;
                var display_disk = disk;
                var display_net = net;
                var display_thermal = thermal;
                var display_battery = battery;
                var wifi_ssid_buf: [96]u8 = undefined;
                var wifi_generation_buf: [96]u8 = undefined;
                var wifi_detail_lines: [2]render.DetailLine = undefined;
                scrub_proc_count = 0;

                if (is_scrubbing) {
                    if (timeline.getSnapshot(scrub_offset)) |snap| {
                        display_cpu = .{
                            .usage_percent = snap.cpu_usage_pct,
                            .cores = snap.cpu_cores,
                            .per_core_usage = &.{},
                        };
                        display_mem = snap.mem;
                        display_disk = snap.disk;
                        display_net = snap.net;
                        display_thermal = snap.thermal;
                        display_battery = snap.battery;
                        scrub_proc_count = snap.proc_count;
                        for (0..scrub_proc_count) |i| {
                            scrub_proc_buf[i] = snap.procs[i];
                        }
                    }
                }
                const wifi_ssid_line = formatWifiSsidLine(display_net, &wifi_ssid_buf);
                const wifi_generation_line = formatWifiGenerationLine(display_net, &wifi_generation_buf);
                var wifi_detail_count: usize = 0;
                if (wifi_ssid_line) |line| {
                    wifi_detail_lines[wifi_detail_count] = .{
                        .text = line,
                        .style = .{ .fg = theme.text, .dim = true },
                    };
                    wifi_detail_count += 1;
                }
                if (wifi_generation_line) |line| {
                    wifi_detail_lines[wifi_detail_count] = .{
                        .text = line,
                        .style = .{ .fg = theme.text, .dim = true },
                    };
                    wifi_detail_count += 1;
                }

                // Before/After Diff View (replaces normal content when active)
                const diff_active = is_scrubbing and diff_anchor != null;
                if (diff_active) {
                    if (timeline.computeDiff(diff_anchor.?, scrub_offset)) |snap_diff| {
                        const diff_box_height = size.height -| 2 -| 1 -| @as(u16, if (timeline_bar_active) 1 else 0);
                        try render.renderDiffView(&app_tui, theme, 1, 2, size.width, diff_box_height, snap_diff.*, app_config.temperature_unit);
                    }
                }

                if (diff_active) {
                    // Diff view already rendered above; skip normal tab content
                } else if (current_tab == 1) {
                    try render.renderCpuTopologyBox(&app_tui, theme, cpu_box_x, cpu_box_y, cpu_box_width, cpu_box_height, display_cpu, cpu_topology, &cpu_history, app_config.disable_history);
                    try main_view.renderMemoryBox(
                        &app_tui,
                        theme,
                        mem_box_x,
                        mem_box_y,
                        mem_box_width,
                        mem_box_height,
                        display_mem,
                    );
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
                            .rate_bytes_ps = display_disk.read_bytes_ps,
                            .history = &disk_read_history,
                            .color = theme.disk_title,
                        },
                        .{
                            .label = "WRITE",
                            .short_label = "W ",
                            .rate_bytes_ps = display_disk.write_bytes_ps,
                            .history = &disk_write_history,
                            .color = theme.io_rate,
                        },
                        &.{},
                        .{
                            .label = "USED",
                            .short_label = "U ",
                            .used_bytes = display_disk.capacity_used_bytes,
                            .total_bytes = display_disk.capacity_total_bytes,
                            .color = theme.disk_title,
                        },
                        app_config.disable_history,
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
                            .rate_bytes_ps = display_net.rx_bytes_ps,
                            .total_bytes = display_net.rx_bytes,
                            .history = &net_rx_history,
                            .color = theme.network_title,
                        },
                        .{
                            .label = "TX",
                            .short_label = "TX ",
                            .rate_bytes_ps = display_net.tx_bytes_ps,
                            .total_bytes = display_net.tx_bytes,
                            .history = &net_tx_history,
                            .color = theme.io_rate,
                        },
                        wifi_detail_lines[0..wifi_detail_count],
                        null,
                        app_config.disable_history,
                    );
                } else if (current_tab == 3) {
                    try main_view.renderSensorsTab(
                        &app_tui,
                        theme,
                        cpu_box_x,
                        cpu_box_y,
                        cpu_box_width,
                        cpu_box_height,
                        mem_box_x,
                        mem_box_y,
                        mem_box_width,
                        mem_box_height,
                        display_thermal,
                        display_battery,
                        cached_gpus,
                        app_config.temperature_unit,
                    );
                } else if (current_tab == 4) {
                    try main_view.renderNetworkTotalsBox(
                        &app_tui,
                        theme,
                        cpu_box_x,
                        cpu_box_y,
                        size.width,
                        cpu_box_height,
                        display_net,
                        wifi_ssid_line,
                        wifi_generation_line,
                    );
                } else if (current_tab == 5 and cpu_box_height >= 5) {
                    const ph_data = render.buildPressureHints(
                        display_mem,
                        memoryUsagePercent(display_mem),
                        display_cpu.usage_percent,
                        display_disk.read_bytes_ps + display_disk.write_bytes_ps,
                        display_net.rx_bytes_ps + display_net.tx_bytes_ps,
                        display_thermal,
                        cached_procs,
                        cached_connections.items,
                        timeline,
                        app_config.temperature_unit,
                    );
                    try render.renderPressureHintsView(
                        &app_tui,
                        theme,
                        cpu_box_x,
                        cpu_box_y,
                        size.width,
                        cpu_box_height,
                        ph_data,
                    );
                }

                // Bottom Box: Processes, Threads, or Connections
                if (current_tab == 4) {
                    try main_view.renderConnectionsTable(
                        &app_tui,
                        theme,
                        procs_box_x,
                        procs_box_y,
                        procs_box_width,
                        procs_box_height,
                        cached_connections.items,
                        show_help,
                        &selected_idx,
                        &scroll_offset,
                        &mouse_regions,
                    );
                } else if (current_tab == 5 and procs_box_height >= 5) {
                    // Current procs: use scrubbed snapshot procs if scrubbing
                    const wb_procs: []const ztop.sysinfo.ProcStats = if (is_scrubbing and scrub_proc_count > 0)
                        scrub_proc_buf[0..scrub_proc_count]
                    else
                        cached_procs;

                    // "Before" snapshot: 5 ticks earlier than current view position
                    const before_offset = (if (is_scrubbing) scrub_offset else 0) + 5;
                    var before_snap_buf: [timeline_mod.MAX_SNAPSHOT_PROCS]ztop.sysinfo.ProcStats = undefined;
                    var before_snap_count: usize = 0;
                    var before_cpu_pct: ?f32 = null;
                    var before_mem_pct: ?f32 = null;
                    var before_disk_rate: ?u64 = null;
                    var before_net_rate: ?u64 = null;

                    if (timeline.getSnapshot(before_offset)) |bsnap| {
                        before_cpu_pct = bsnap.cpu_usage_pct;
                        before_mem_pct = bsnap.mem_usage_pct;
                        before_disk_rate = bsnap.disk.read_bytes_ps + bsnap.disk.write_bytes_ps;
                        before_net_rate = bsnap.net.rx_bytes_ps + bsnap.net.tx_bytes_ps;
                        const cnt = @min(bsnap.proc_count, timeline_mod.MAX_SNAPSHOT_PROCS);
                        for (0..cnt) |bi| before_snap_buf[bi] = bsnap.procs[bi];
                        before_snap_count = cnt;
                    }

                    const cur_ts: i64 = if (is_scrubbing)
                        (if (timeline.getSnapshot(scrub_offset)) |s| s.timestamp_ms else 0)
                    else
                        0;

                    try render.renderWhyBusyView(
                        &app_tui,
                        theme,
                        procs_box_x,
                        procs_box_y,
                        procs_box_width,
                        procs_box_height,
                        .{
                            .kind = .auto,
                            .enable_ai = app_config.enable_ai,
                            .cpu_pct = display_cpu.usage_percent,
                            .mem_pct = memoryUsagePercent(display_mem),
                            .disk_rate = display_disk.read_bytes_ps + display_disk.write_bytes_ps,
                            .net_rate = display_net.rx_bytes_ps + display_net.tx_bytes_ps,
                            .cpu_pct_before = before_cpu_pct,
                            .mem_pct_before = before_mem_pct,
                            .disk_rate_before = before_disk_rate,
                            .net_rate_before = before_net_rate,
                            .procs = wb_procs,
                            .procs_before = before_snap_buf[0..before_snap_count],
                            .timestamp_ms = cur_ts,
                        },
                    );
                } else if (causality_view and procs_box_height >= 5) {
                    try render.renderCausalityGraph(
                        &app_tui,
                        theme,
                        procs_box_x,
                        procs_box_y,
                        procs_box_width,
                        procs_box_height,
                        causality_pid,
                        causality_name_buf[0..causality_name_len],
                        cached_procs,
                        causality_connections,
                    );
                } else if (lifeline_view and procs_box_height >= 5) {
                    if (active_tracer) |tracer| {
                        try render.renderLifelineView(
                            &app_tui,
                            theme,
                            procs_box_x,
                            procs_box_y,
                            procs_box_width,
                            procs_box_height,
                            tracer,
                            lifeline_name_buf[0..lifeline_name_len],
                            scroll_offset,
                        );
                    }
                } else if (procs_box_height >= 3) {
                    if (thread_view) {
                        try main_view.renderThreadTable(
                            &app_tui,
                            theme,
                            procs_box_x,
                            procs_box_y,
                            procs_box_width,
                            procs_box_height,
                            thread_view_name_buf[0..thread_view_name_len],
                            thread_view_pid,
                            cached_threads,
                            show_help,
                            &selected_idx,
                            &scroll_offset,
                            &mouse_regions,
                        );
                    } else if (pipeline_view and !is_scrubbing) {
                        pipeline_row_count = try render.renderPipelineLensView(
                            &app_tui,
                            theme,
                            procs_box_x,
                            procs_box_y,
                            procs_box_width,
                            procs_box_height,
                            cached_procs,
                            selected_idx,
                            &scroll_offset,
                        );
                    } else {
                        var title_buf: [96]u8 = undefined;
                        const sort_name = switch (sort_by) {
                            .cpu => "CPU%",
                            .mem => "MEM%",
                            .pid => "PID",
                            .name => "NAME",
                            .wakeups => "Wakeups",
                        };
                        const current_process_columns = activeProcessColumns(current_tab, &process_columns, &io_process_columns);
                        const visible_column_count = current_process_columns.countVisible() + 1; // Name is always visible.
                        const title = if (is_scrubbing) blk: {
                            const newest = timeline.getSnapshot(0);
                            const cur = timeline.getSnapshot(scrub_offset);
                            if (newest != null and cur != null) {
                                const delta_s = @divTrunc(newest.?.timestamp_ms - cur.?.timestamp_ms, 1000);
                                var dur_buf: [16]u8 = undefined;
                                const dur = timeline_mod.Timeline.formatDuration(&dur_buf, delta_s);
                                break :blk std.fmt.bufPrint(&title_buf, "Processes [SCRUB T-{s}] ({d} procs)", .{ dur, scrub_proc_count }) catch "Processes [SCRUB]";
                            }
                            break :blk @as([]const u8, "Processes [SCRUB]");
                        } else if (show_zombie_parents)
                            std.fmt.bufPrint(
                                &title_buf,
                                "Zombie Parents ({d} parents / {d} zombies)",
                                .{ zombie_summary.parent_count, zombie_summary.zombie_count },
                            ) catch "Zombie Parents"
                        else if (is_following)
                            std.fmt.bufPrint(&title_buf, "Processes (Sort: {s} | Cols: {d}) [FOLLOW]", .{ sort_name, visible_column_count }) catch "Processes [FOLLOW]"
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

                        // Filtering / proc source selection
                        filtered_count = 0;

                        if (is_scrubbing) {
                            // In scrub mode: show snapshot procs directly, no filtering
                            for (0..scrub_proc_count) |i| {
                                filtered_indices[i] = i;
                            }
                            filtered_count = scrub_proc_count;
                        } else {
                            const filter_str = filter_buf[0..filter_len];

                            if (tree_view and filter_len == 0 and !show_zombie_parents) {
                                filtered_count = process_commands.buildTreeView(
                                    cached_procs,
                                    &filtered_indices,
                                    &filtered_depths,
                                    &filtered_is_lasts,
                                );
                            } else {
                                for (cached_procs, 0..) |*proc, i| {
                                    if (show_zombie_parents and !process_commands.containsParentPid(zombie_parents[0..zombie_summary.parent_count], proc.pid)) {
                                        continue;
                                    }

                                    if (!process_commands.matchesProcessFilter(proc, filter_str)) continue;
                                    filtered_indices[filtered_count] = i;
                                    filtered_count += 1;
                                    if (filtered_count >= filtered_indices.len) break;
                                }
                            }

                            if (top_n) |n| {
                                filtered_count = @min(filtered_count, n);
                            }

                            if (is_following and follow_pid != 0) {
                                var found = false;
                                for (0..filtered_count) |fi| {
                                    if (cached_procs[filtered_indices[fi]].pid == follow_pid) {
                                        selected_idx = fi;
                                        found = true;
                                        break;
                                    }
                                }
                                if (!found) {
                                    is_following = false;
                                    follow_pid = 0;
                                    render.setStatus(&status_buf, &status_len, "Followed process no longer visible", .{});
                                }
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
                            const proc = if (is_scrubbing) &scrub_proc_buf[proc_idx] else &cached_procs[proc_idx];

                            const is_selected = (idx == selected_idx) and !show_help;

                            try app_tui.moveCursor(procs_box_x + 2, procs_box_y + 1 + @as(u16, @intCast(row)));

                            if (is_selected) {
                                try app_tui.setStyle(.{ .bg = theme.selection_bg });
                                try app_tui.writeSpaces(procs_box_width - 4);
                                try app_tui.moveCursor(procs_box_x + 2, procs_box_y + 1 + @as(u16, @intCast(row)));
                            }

                            var prefix_len: usize = 0;
                            var prefix_width: usize = 0;
                            if (!is_scrubbing and tree_view and filter_len == 0 and !show_zombie_parents) {
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

                            try render.renderProcessRow(
                                &app_tui,
                                &theme,
                                &process_layout,
                                proc,
                                is_selected,
                                prefix_buf[0..prefix_len],
                                prefix_width,
                                display_cpu.cores,
                                display_battery.power_draw_w,
                            );

                            if (is_selected) {
                                try app_tui.resetStyle();
                            }
                        }
                    }
                }

                // Help Overlay
                if (show_help) {
                    try render.renderHelpOverlay(&app_tui, theme, size.width, size.height, repo_url, repo_label);
                }

                if (show_column_picker) {
                    const picker_columns = activeProcessColumns(current_tab, &process_columns, &io_process_columns);
                    try render.renderColumnPickerOverlay(&app_tui, theme, size.width, size.height, current_tab, picker_columns.*);
                }

                // Timeline bar (above footer when snapshot data exists)
                if (timeline_bar_active) {
                    try render.renderTimelineBar(
                        &app_tui,
                        theme,
                        1,
                        timeline_bar_y,
                        size.width,
                        timeline,
                        scrub_offset,
                        is_scrubbing,
                        diff_anchor,
                    );
                }

                // Footer
                try render.renderFooter(&app_tui, theme, size.width, size.height, .{
                    .diff_active = diff_active,
                    .is_scrubbing = is_scrubbing,
                    .is_cmd_mode = is_cmd_mode,
                    .cmd = cmd_buf[0..cmd_len],
                    .is_filtering = is_filtering,
                    .filter = filter_buf[0..filter_len],
                    .show_column_picker = show_column_picker,
                    .thread_view = thread_view,
                    .thread_view_name = thread_view_name_buf[0..thread_view_name_len],
                    .status = status_buf[0..status_len],
                    .dropped_column_count = process_layout.dropped_count,
                    .timeline = timeline,
                    .scrub_offset = scrub_offset,
                });

                try render.updateFooterCursor(&app_tui, size.width, size.height, is_cmd_mode, cmd_len, is_filtering, filter_len);
            }
        } // end force_redraw

        var fds = [_]posix.pollfd{.{ .fd = app_tui.in.handle, .events = posix.POLL.IN, .revents = 0 }};
        const now = nowMs(io);
        var remaining_ms = fetch_interval_ms - (now - last_fetch_time);
        if (remaining_ms < 0) remaining_ms = 0;
        if (render.isAiQuerying() and remaining_ms > 80) {
            remaining_ms = 80;
        }

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
                .causality_view = &causality_view,
                .causality_pid = &causality_pid,
                .causality_name_buf = &causality_name_buf,
                .causality_name_len = &causality_name_len,
                .causality_connections = &causality_connections,
                .lifeline_view = &lifeline_view,
                .lifeline_name_buf = &lifeline_name_buf,
                .lifeline_name_len = &lifeline_name_len,
                .active_tracer = &active_tracer,
                .is_following = &is_following,
                .follow_pid = &follow_pid,
                .status_buf = &status_buf,
                .status_len = &status_len,
                .current_tab = &current_tab,
                .mouse_regions = &mouse_regions,
                .quit_flag = &quit_flag,
                .input_buf = &input_buf,
                .input_len = &input_len,
                .process_columns = &process_columns,
                .io_process_columns = &io_process_columns,
                .is_scrubbing = &is_scrubbing,
                .scrub_offset = &scrub_offset,
                .timeline = timeline,
                .diff_anchor = &diff_anchor,
                .refresh_interval_ms = &refresh_interval_ms,
                .top_n = &top_n,
                .pipeline_view = &pipeline_view,
                .pipeline_row_count = &pipeline_row_count,
            };
            force_redraw = try input_handler.handleAvailableInput(&input_ctx);
        } else if (render.isAiQuerying()) {
            force_redraw = true;
        }
    }

    // ── Persist timeline on clean exit ────────────────────────────────────────
    if (session_path) |sp| {
        // Best-effort: ignore errors (disk full, permission denied, etc.)
        timeline.saveToDisk(io, allocator, sp) catch {};
    }
    // ─────────────────────────────────────────────────────────────────────────
}
