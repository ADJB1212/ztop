const std = @import("std");
const ztop = @import("ztop");
const config = ztop.config;
const input_handler = ztop.input_handler;
const render = ztop.render;
const sysinfo = ztop.sysinfo;
const tui_mod = ztop.tui;

const Tui = tui_mod.Tui;

pub fn memoryUsagePercent(mem: sysinfo.MemStats) f32 {
    if (mem.total == 0) return 0;
    return @as(f32, @floatFromInt(mem.used)) / @as(f32, @floatFromInt(mem.total)) * 100.0;
}

pub fn diskUsagePercent(disk: sysinfo.DiskStats) f32 {
    return sysinfo.common.diskUsagePercent(disk);
}

pub fn batteryStatusLabel(status: sysinfo.BatteryStatus) []const u8 {
    return switch (status) {
        .charging => "Charging",
        .discharging => "Discharging",
        .full => "Full",
        .unknown => "Unknown",
    };
}

pub fn aggregateGpuTemp(thermal: sysinfo.ThermalStats, gpus: []const sysinfo.GpuStats) ?f32 {
    for (gpus) |gpu| {
        if (gpu.temperature_c) |temp_c| return temp_c;
    }
    return thermal.gpu_temp;
}

pub fn gpuVendorLabel(vendor: sysinfo.GpuVendor) []const u8 {
    return switch (vendor) {
        .apple => "Apple",
        .unknown => "Unknown",
    };
}

pub fn formatWifiSsidLine(net: sysinfo.NetStats, buf: []u8) ?[]const u8 {
    const ssid = net.wifi.ssid();
    if (ssid.len == 0) return null;
    return std.fmt.bufPrint(buf, "WiFi: {s}", .{ssid}) catch null;
}

pub fn formatWifiGenerationLine(net: sysinfo.NetStats, buf: []u8) ?[]const u8 {
    const generation = net.wifi.generation.label() orelse return null;
    return std.fmt.bufPrint(buf, "WiFi Generation: {s}", .{generation}) catch null;
}

pub fn displayWidth(text: []const u8) usize {
    return std.unicode.utf8CountCodepoints(text) catch text.len;
}

pub fn activeProcessColumns(current_tab: u8, process_columns: *config.ProcessColumns, io_process_columns: *config.ProcessColumns) *config.ProcessColumns {
    if (current_tab == 2) return io_process_columns;
    return process_columns;
}

const TabDef = struct {
    tab: u8,
    label: []const u8,
    icon: []const u8,
};

const tab_defs = [_]TabDef{
    .{ .tab = 1, .label = "MAIN", .icon = "\u{f4bc} " },
    .{ .tab = 2, .label = "I/O", .icon = "\u{f0655} " },
    .{ .tab = 3, .label = "SENSORS", .icon = "\u{f2c9} " },
    .{ .tab = 4, .label = "NETWORK", .icon = "\u{f0200} " },
    .{ .tab = 5, .label = "DIAGNOSTICS", .icon = "\u{f0b1} " },
};

fn tabLabel(app_tui: *Tui, def: TabDef, buf: []u8) []const u8 {
    if (!app_tui.hasNerdFonts()) return def.label;
    return std.fmt.bufPrint(buf, "{s}{s}", .{ def.icon, def.label }) catch def.label;
}

pub fn renderHeader(
    app_tui: *Tui,
    theme: config.Theme,
    width: u16,
    current_tab: u8,
    sysname: []const u8,
    release: []const u8,
    machine: []const u8,
    nodename: []const u8,
    mouse_regions: *input_handler.MouseRegions,
) !void {
    try app_tui.moveCursor(1, 1);
    try app_tui.printStyled(.{ .fg = theme.brand, .bold = true }, " ztop ", .{});
    try app_tui.printStyled(.{ .fg = theme.text, .dim = true }, "- {s} {s} {s} - {s}", .{ sysname, release, machine, nodename });

    const gap: u16 = 1;
    var label_bufs: [tab_defs.len][32]u8 = undefined;
    var labels: [tab_defs.len][]const u8 = undefined;
    var chip_widths: [tab_defs.len]u16 = undefined;
    var tabs_width: usize = 0;

    for (tab_defs, 0..) |def, i| {
        labels[i] = tabLabel(app_tui, def, &label_bufs[i]);
        // Active tabs render as rounded pills
        const is_active = current_tab == def.tab;
        const extra: u16 = if (is_active and app_tui.hasNerdFonts()) 4 else 2;
        chip_widths[i] = @intCast(displayWidth(labels[i]) + extra);
        tabs_width += chip_widths[i];
        if (i > 0) tabs_width += gap;
    }

    if (width <= tabs_width + 30) return;

    var tab_x = width - @as(u16, @intCast(tabs_width)) - 2;
    try app_tui.moveCursor(tab_x, 1);

    for (tab_defs, 0..) |def, i| {
        if (i > 0) {
            for (0..gap) |_| try app_tui.bufWrite(" ");
            tab_x += gap;
        }

        const is_active = current_tab == def.tab;
        const style: Tui.Style = if (is_active)
            .{ .bg = theme.tab_active, .fg = theme.selection_fg, .bold = true }
        else
            .{ .fg = theme.muted };
        _ = try render.writePill(app_tui, style, labels[i]);

        mouse_regions.addTab(def.tab, .{ .x = tab_x, .y = 1, .width = chip_widths[i], .height = 1 });
        tab_x += chip_widths[i];
    }
}

pub fn renderMemoryBox(app_tui: *Tui, theme: config.Theme, x: u16, y: u16, width: u16, height: u16, mem: sysinfo.MemStats) !void {
    try app_tui.drawBoxStyled(x, y, width, height, "Memory", .{ .fg = theme.border }, .{ .fg = theme.memory_title, .bold = true });

    if (height < 3) return;

    const mem_used_percent = memoryUsagePercent(mem);
    try app_tui.moveCursor(x + 2, y + 1);
    try app_tui.printStyled(.{ .fg = theme.text, .dim = true }, "Used: ", .{});
    try app_tui.printStyled(.{ .fg = render.memoryColor(theme, mem_used_percent), .bold = true }, "{d} GB", .{mem.used / 1024 / 1024 / 1024});
    try app_tui.printStyled(.{ .fg = theme.muted }, " (C: {d}M B: {d}M)", .{ mem.cached / 1024 / 1024, mem.buffered / 1024 / 1024 });

    try app_tui.moveCursor(x + 2, y + 2);
    try app_tui.printStyled(.{ .fg = theme.text, .dim = true }, "Free: ", .{});
    try app_tui.printStyled(.{ .fg = theme.usage_good, .bold = true }, "{d} GB", .{mem.free / 1024 / 1024 / 1024});

    if (mem.swap_total > 0 and height >= 4) {
        try app_tui.moveCursor(x + 2, y + 3);
        try app_tui.printStyled(.{ .fg = theme.text, .dim = true }, "Swap: ", .{});
        try app_tui.printStyled(.{ .fg = theme.memory_mid }, "{d} MB / {d} MB", .{ mem.swap_used / 1024 / 1024, mem.swap_total / 1024 / 1024 });
    }
}

pub fn renderSensorsTab(app_tui: *Tui, theme: config.Theme, cpu_box_x: u16, cpu_box_y: u16, cpu_box_width: u16, cpu_box_height: u16, gpu_box_x: u16, gpu_box_y: u16, gpu_box_width: u16, gpu_box_height: u16, thermal: sysinfo.ThermalStats, battery: sysinfo.BatteryStats, gpus: []const sysinfo.GpuStats, temp_unit: config.TemperatureUnit) !void {
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
            try app_tui.printStyled(.{ .fg = theme.io_rate, .bold = true }, "{d:4.1} {s}", .{ temp_unit.format(t), temp_unit.label() });
        } else {
            try app_tui.printStyled(.{ .fg = theme.muted }, "N/A", .{});
        }

        if (cpu_box_height >= 4) {
            try app_tui.moveCursor(cpu_box_x + 2, cpu_box_y + 2);
            try app_tui.printStyled(.{ .fg = theme.text, .dim = true }, "GPU Temp: ", .{});
            if (aggregateGpuTemp(thermal, gpus)) |t| {
                try app_tui.printStyled(.{ .fg = theme.io_rate, .bold = true }, "{d:4.1} {s}", .{ temp_unit.format(t), temp_unit.label() });
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
            const power_label = switch (battery.status) {
                .charging => "Input: ",
                .discharging => "Draw: ",
                .full => "Power: ",
                .unknown => "Power: ",
            };
            try app_tui.moveCursor(cpu_box_x + 2, cpu_box_y + 4);
            try app_tui.printStyled(.{ .fg = theme.text, .dim = true }, "{s}", .{power_label});
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
        gpu_box_x,
        gpu_box_y,
        gpu_box_width,
        gpu_box_height,
        "GPU",
        .{ .fg = theme.border },
        .{ .fg = theme.sensor_title, .bold = true },
    );

    if (gpu_box_height < 3) return;

    if (gpus.len == 0) {
        try app_tui.moveCursor(gpu_box_x + 2, gpu_box_y + 1);
        try app_tui.printStyled(.{ .fg = theme.muted }, "No supported GPU metrics detected", .{});
        return;
    }

    const rows_per_gpu: u16 = if (gpu_box_height >= 7 and gpu_box_width >= 42) 2 else 1;
    const available_rows = gpu_box_height - 2;
    const visible_gpu_count = @min(gpus.len, @as(usize, @intCast(available_rows / rows_per_gpu)));

    for (gpus[0..visible_gpu_count], 0..) |gpu, gpu_idx| {
        const row_y = gpu_box_y + 1 + @as(u16, @intCast(gpu_idx)) * rows_per_gpu;
        const gpu_name = gpu.name();
        const name_limit: usize = if (gpu_box_width > 38) @as(usize, gpu_box_width - 30) else 12;
        const display_name = if (gpu_name.len > name_limit) gpu_name[0..name_limit] else gpu_name;

        try app_tui.moveCursor(gpu_box_x + 2, row_y);
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

        if (rows_per_gpu == 2 and row_y + 1 < gpu_box_y + gpu_box_height - 1) {
            try app_tui.moveCursor(gpu_box_x + 2, row_y + 1);
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
                try app_tui.printStyled(.{ .fg = theme.io_rate }, "{d:4.1} {s}", .{ temp_unit.format(temp_c), temp_unit.label() });
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

    if (visible_gpu_count < gpus.len and gpu_box_height >= 4) {
        try app_tui.moveCursor(gpu_box_x + 2, gpu_box_y + gpu_box_height - 2);
        try app_tui.printStyled(.{ .fg = theme.muted }, "+{d} more GPU(s)", .{gpus.len - visible_gpu_count});
    }
}

pub fn renderNetworkTotalsBox(
    app_tui: *Tui,
    theme: config.Theme,
    box_x: u16,
    box_y: u16,
    box_width: u16,
    box_height: u16,
    net: sysinfo.NetStats,
    wifi_ssid_line: ?[]const u8,
    wifi_generation_line: ?[]const u8,
) !void {
    try app_tui.drawBoxStyled(
        box_x,
        box_y,
        box_width,
        box_height,
        "Network",
        .{ .fg = theme.border },
        .{ .fg = theme.sensor_title, .bold = true },
    );
    if (box_height < 3) return;

    try app_tui.moveCursor(box_x + 2, box_y + 1);
    try app_tui.printStyled(.{ .fg = theme.text, .dim = true }, "Rx: ", .{});
    const rx_ps = render.formatUnit(net.rx_bytes_ps);
    try app_tui.printStyled(.{ .fg = theme.io_rate, .bold = true }, "{d:4.1} {s}/s", .{ rx_ps.value, rx_ps.unit });

    try app_tui.moveCursor(box_x + 22, box_y + 1);
    try app_tui.printStyled(.{ .fg = theme.text, .dim = true }, "Tx: ", .{});
    const tx_ps = render.formatUnit(net.tx_bytes_ps);
    try app_tui.printStyled(.{ .fg = theme.io_rate, .bold = true }, "{d:4.1} {s}/s", .{ tx_ps.value, tx_ps.unit });

    var wifi_row: u16 = 2;
    if (wifi_ssid_line) |line| {
        if (box_height >= wifi_row + 2) {
            try app_tui.moveCursor(box_x + 2, box_y + wifi_row);
            try app_tui.printStyled(.{ .fg = theme.text, .dim = true }, "{s}", .{render.clipUtf8(line, box_width -| 4)});
            wifi_row += 1;
        }
    }

    if (wifi_generation_line) |line| {
        if (box_height >= wifi_row + 2) {
            try app_tui.moveCursor(box_x + 2, box_y + wifi_row);
            try app_tui.printStyled(.{ .fg = theme.text, .dim = true }, "{s}", .{render.clipUtf8(line, box_width -| 4)});
        }
    }
}

fn normalizeListWindow(selected_idx: *usize, scroll_offset: *usize, item_count: usize, visible_rows: u16) void {
    if (item_count == 0) {
        selected_idx.* = 0;
        scroll_offset.* = 0;
        return;
    }

    if (selected_idx.* >= item_count) selected_idx.* = item_count - 1;

    if (selected_idx.* < scroll_offset.*) {
        scroll_offset.* = selected_idx.*;
    } else {
        const visible_rows_usize: usize = visible_rows;
        if (visible_rows_usize > 0 and selected_idx.* >= scroll_offset.* + visible_rows_usize) {
            scroll_offset.* = selected_idx.* - visible_rows_usize + 1;
        }
    }
}

pub fn renderConnectionsTable(
    app_tui: *Tui,
    theme: config.Theme,
    box_x: u16,
    box_y: u16,
    box_width: u16,
    box_height: u16,
    connections: []const sysinfo.common.NetConnection,
    show_help: bool,
    selected_idx: *usize,
    scroll_offset: *usize,
    mouse_regions: *input_handler.MouseRegions,
) !void {
    if (box_height < 3) return;

    try app_tui.drawBoxStyled(
        box_x,
        box_y,
        box_width,
        box_height,
        "Connections",
        .{ .fg = theme.border },
        .{ .fg = theme.process_title, .bold = true },
    );

    const visible_rows = box_height - 2;
    mouse_regions.list_rect = .{
        .x = box_x + 1,
        .y = box_y + 1,
        .width = box_width -| 2,
        .height = visible_rows,
    };

    const conn_count = connections.len;
    normalizeListWindow(selected_idx, scroll_offset, conn_count, visible_rows);

    if (conn_count == 0) {
        try app_tui.moveCursor(box_x + 2, box_y + 1);
        try app_tui.printStyled(.{ .fg = theme.muted }, "No active connections detected", .{});
        return;
    }

    for (0..visible_rows) |row| {
        const idx = scroll_offset.* + row;
        if (idx >= conn_count) break;
        const conn = connections[idx];

        const is_selected = (idx == selected_idx.*) and !show_help;

        try app_tui.moveCursor(box_x + 2, box_y + 1 + @as(u16, @intCast(row)));

        if (is_selected) {
            try app_tui.setStyle(.{ .bg = theme.selection_bg });
            for (0..box_width - 4) |_| try app_tui.bufWrite(" ");
            try app_tui.moveCursor(box_x + 2, box_y + 1 + @as(u16, @intCast(row)));
        }

        try app_tui.printStyled(
            if (is_selected) .{ .bg = theme.selection_bg, .fg = theme.selection_fg } else .{ .fg = theme.text },
            "{s:4} ",
            .{@tagName(conn.protocol)},
        );

        const local_str = std.mem.sliceTo(&conn.local_addr, 0);
        if (conn.local_port > 0) {
            try app_tui.printStyled(
                if (is_selected) .{ .bg = theme.selection_bg, .fg = theme.selection_fg } else .{ .fg = theme.text },
                "{s}:{d:<5} ",
                .{ local_str, conn.local_port },
            );
        } else {
            try app_tui.printStyled(
                if (is_selected) .{ .bg = theme.selection_bg, .fg = theme.selection_fg } else .{ .fg = theme.text },
                "{s:<11} ",
                .{local_str},
            );
        }
        try app_tui.printStyled(if (is_selected) .{ .bg = theme.selection_bg, .fg = theme.muted } else .{ .fg = theme.muted }, "-> ", .{});

        const remote_str = std.mem.sliceTo(&conn.remote_addr, 0);
        if (conn.remote_port > 0) {
            try app_tui.printStyled(
                if (is_selected) .{ .bg = theme.selection_bg, .fg = theme.selection_fg } else .{ .fg = theme.text },
                "{s}:{d:<5} ",
                .{ remote_str, conn.remote_port },
            );
        } else {
            try app_tui.printStyled(
                if (is_selected) .{ .bg = theme.selection_bg, .fg = theme.selection_fg } else .{ .fg = theme.text },
                "{s:<11} ",
                .{remote_str},
            );
        }

        if (conn.protocol == .tcp or conn.protocol == .tcp6) {
            try app_tui.printStyled(
                if (is_selected) .{ .bg = theme.selection_bg, .fg = theme.muted } else .{ .fg = theme.muted },
                "[{s:<11}] ",
                .{@tagName(conn.state)},
            );
        } else {
            try app_tui.printStyled(
                if (is_selected) .{ .bg = theme.selection_bg, .fg = theme.muted } else .{ .fg = theme.muted },
                "[{s:<11}] ",
                .{"-"},
            );
        }

        try app_tui.printStyled(
            if (is_selected) .{ .bg = theme.selection_bg, .fg = theme.process_title } else .{ .fg = theme.process_title },
            "{s} (PID: {d})",
            .{ conn.name(), conn.pid },
        );

        if (is_selected) {
            try app_tui.resetStyle();
        }
    }
}

pub fn renderThreadTable(
    app_tui: *Tui,
    theme: config.Theme,
    box_x: u16,
    box_y: u16,
    box_width: u16,
    box_height: u16,
    thread_view_name: []const u8,
    thread_view_pid: u32,
    threads: []const sysinfo.ThreadStats,
    show_help: bool,
    selected_idx: *usize,
    scroll_offset: *usize,
    mouse_regions: *input_handler.MouseRegions,
) !void {
    var title_buf: [96]u8 = undefined;
    const title = std.fmt.bufPrint(
        &title_buf,
        "Threads of {s} (PID: {d}) - {d} threads",
        .{ thread_view_name, thread_view_pid, threads.len },
    ) catch "Threads";

    try app_tui.drawBoxStyled(
        box_x,
        box_y,
        box_width,
        box_height,
        title,
        .{ .fg = theme.border },
        .{ .fg = theme.process_title, .bold = true },
    );

    const visible_rows = box_height - 2;
    mouse_regions.list_rect = .{
        .x = box_x + 1,
        .y = box_y + 1,
        .width = box_width -| 2,
        .height = visible_rows,
    };

    const thread_count = threads.len;
    normalizeListWindow(selected_idx, scroll_offset, thread_count, visible_rows);

    for (0..visible_rows) |row| {
        const idx = scroll_offset.* + row;
        if (idx >= thread_count) break;
        const thr = threads[idx];

        const is_selected = (idx == selected_idx.*) and !show_help;

        try app_tui.moveCursor(box_x + 2, box_y + 1 + @as(u16, @intCast(row)));

        if (is_selected) {
            try app_tui.setStyle(.{ .bg = theme.selection_bg });
            for (0..box_width - 4) |_| try app_tui.bufWrite(" ");
            try app_tui.moveCursor(box_x + 2, box_y + 1 + @as(u16, @intCast(row)));
        }

        try app_tui.printStyled(
            if (is_selected) .{ .bg = theme.selection_bg, .fg = theme.selection_fg } else .{ .fg = theme.muted },
            "{d:7} ",
            .{thr.tid},
        );

        const name_width: usize = if (box_width > 40) 16 else 8;
        if (thr.name().len > name_width) {
            try app_tui.printStyled(
                if (is_selected) .{ .bg = theme.selection_bg, .fg = theme.selection_fg } else .{ .fg = theme.text },
                "{s}.. ",
                .{thr.name()[0 .. name_width - 2]},
            );
        } else if (thr.name().len > 0) {
            try app_tui.printStyled(
                if (is_selected) .{ .bg = theme.selection_bg, .fg = theme.selection_fg } else .{ .fg = theme.text },
                "{s} ",
                .{thr.name()},
            );
            for (thr.name().len..name_width) |_| {
                try app_tui.printStyled(if (is_selected) .{ .bg = theme.selection_bg } else .{}, " ", .{});
            }
        } else {
            for (0..name_width) |_| {
                try app_tui.printStyled(if (is_selected) .{ .bg = theme.selection_bg } else .{}, " ", .{});
            }
            try app_tui.printStyled(if (is_selected) .{ .bg = theme.selection_bg } else .{}, " ", .{});
        }

        const cpu_style: Tui.Style = if (is_selected)
            .{ .bg = theme.selection_bg, .fg = render.usageColor(theme, thr.cpu_percent), .bold = thr.cpu_percent >= 70 }
        else
            .{ .fg = render.usageColor(theme, thr.cpu_percent), .bold = thr.cpu_percent >= 70 };
        try app_tui.printStyled(cpu_style, "{d:5.1}% CPU ", .{thr.cpu_percent});

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
        try app_tui.printStyled(
            if (is_selected) .{ .bg = theme.selection_bg, .fg = state_color } else .{ .fg = state_color },
            "{s}",
            .{state_str},
        );

        if (is_selected) {
            try app_tui.resetStyle();
        }
    }
}
