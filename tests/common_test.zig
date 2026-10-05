const std = @import("std");
const common = @import("ztop").sysinfo.common;

test "kbToBytes conversion" {
    try std.testing.expectEqual(1024, common.kbToBytes(1));
    try std.testing.expectEqual(2048, common.kbToBytes(2));
    try std.testing.expectEqual(0, common.kbToBytes(0));
}

test "ProcStats name slice" {
    var proc = common.ProcStats{
        .pid = 1234,
        .name_len = 4,
        .name_buf = std.mem.zeroes([64]u8),
    };
    std.mem.copyForwards(u8, &proc.name_buf, "test");

    try std.testing.expectEqualStrings("test", proc.name());
}

test "ProcStats defaults" {
    const proc = common.ProcStats{
        .pid = 1234,
    };
    try std.testing.expectEqual(@as(u32, 1234), proc.pid);
    try std.testing.expectEqual(@as(u32, 0), proc.ppid);
    try std.testing.expectEqual(common.ProcState.unknown, proc.state);
}

test "ProcStats has no padding" {
    const field_bytes = comptime blk: {
        var total: usize = 0;
        for (@typeInfo(common.ProcStats).@"struct".field_types) |Field| {
            total += @sizeOf(Field);
        }
        break :blk total;
    };
    try std.testing.expectEqual(field_bytes, @sizeOf(common.ProcStats));
}

test "ProcStats launch command slice" {
    var proc = common.ProcStats{
        .pid = 4321,
        .launch_cmd_len = 13,
        .launch_cmd_buf = std.mem.zeroes([256]u8),
    };
    std.mem.copyForwards(u8, proc.launch_cmd_buf[0..13], "google-chrome");

    try std.testing.expectEqualStrings("google-chrome", proc.launchCommand());
}

test "CpuTopology defaults" {
    const topology = common.CpuTopology{};
    try std.testing.expectEqual(@as(usize, 0), topology.logical_cores.len);
    try std.testing.expectEqual(@as(usize, 0), topology.physical_rows.len);
    try std.testing.expectEqual(@as(usize, 0), topology.lines.len);
    try std.testing.expectEqual(@as(u16, 0), topology.physical_cores);
    try std.testing.expectEqual(@as(u16, 1), topology.package_count);
    try std.testing.expect(!topology.has_numa);
    try std.testing.expect(!topology.has_smt);
}

test "topology cache deduplicates cores and groups sorted rows into sections" {
    const cores = [_]common.CpuLogicalCore{
        .{ .logical_id = 0, .physical_id = 0, .package_id = 1 },
        .{ .logical_id = 1, .physical_id = 2, .efficiency_class = .efficiency },
        .{ .logical_id = 2, .physical_id = 3, .efficiency_class = .performance },
        .{ .logical_id = 3, .physical_id = 1, .efficiency_class = .performance },
        .{ .logical_id = 4, .physical_id = 1, .efficiency_class = .performance, .thread_index = 1 },
        .{ .logical_id = 5, .physical_id = 4, .numa_node_id = 0 },
        .{ .logical_id = 6, .physical_id = common.MAX_CORES },
    };
    var cache: common.CpuTopologyCache = .{};
    cache.build(&cores);

    const expected_ids = [_]u16{ 4, 1, 3, 2, 0 };
    try std.testing.expectEqual(expected_ids.len, cache.row_count);
    for (expected_ids, cache.rows[0..cache.row_count]) |id, row| {
        try std.testing.expectEqual(id, row.physical_id);
    }
    const expected_line_ids = [_]u16{ 4, 4, 1, 1, 3, 2, 2, 0, 0 };
    const expected_headers = [_]bool{ true, false, true, false, false, true, false, true, false };
    try std.testing.expectEqual(expected_line_ids.len, cache.line_count);
    for (expected_line_ids, expected_headers, cache.lines[0..cache.line_count]) |id, header, line| {
        switch (line) {
            .header => |row| {
                try std.testing.expectEqual(true, header);
                try std.testing.expectEqual(id, row.physical_id);
            },
            .row => |row| {
                try std.testing.expectEqual(false, header);
                try std.testing.expectEqual(id, row.physical_id);
            },
        }
    }
}

test "topology cache handles maximum capacity and resets on rebuild" {
    var cores: [common.MAX_CORES]common.CpuLogicalCore = undefined;
    for (&cores, 0..) |*core, idx| {
        core.* = .{
            .logical_id = @intCast(idx),
            .physical_id = @intCast(common.MAX_CORES - idx - 1),
            .package_id = @intCast(idx),
        };
    }
    var cache: common.CpuTopologyCache = .{};
    cache.build(&cores);
    try std.testing.expectEqual(common.MAX_CORES, cache.row_count);
    try std.testing.expectEqual(common.MAX_CORES * 2, cache.line_count);
    try std.testing.expectEqual(@as(u16, common.MAX_CORES - 1), cache.rows[0].physical_id);
    try std.testing.expectEqual(@as(u16, 0), cache.rows[cache.row_count - 1].physical_id);

    cache.build(&.{});
    try std.testing.expectEqual(@as(usize, 0), cache.row_count);
    try std.testing.expectEqual(@as(usize, 0), cache.line_count);
}

test "CpuLogicalCore defaults" {
    const logical = common.CpuLogicalCore{
        .logical_id = 3,
        .physical_id = 1,
    };
    try std.testing.expectEqual(@as(u16, 3), logical.logical_id);
    try std.testing.expectEqual(@as(u16, 1), logical.physical_id);
    try std.testing.expectEqual(@as(i16, -1), logical.numa_node_id);
    try std.testing.expectEqual(@as(u8, 1), logical.threads_per_core);
    try std.testing.expectEqual(common.CpuEfficiencyClass.unknown, logical.efficiency_class);
}

test "sortProcStats by cpu" {
    var procs = [_]common.ProcStats{
        .{ .pid = 1, .cpu_percent = 5.0 },
        .{ .pid = 2, .cpu_percent = 20.0 },
        .{ .pid = 3, .cpu_percent = 10.0 },
    };

    common.sortProcStats(&procs, .cpu);

    try std.testing.expectEqual(@as(u32, 2), procs[0].pid);
    try std.testing.expectEqual(@as(u32, 3), procs[1].pid);
    try std.testing.expectEqual(@as(u32, 1), procs[2].pid);
}

test "sortProcStats by mem" {
    var procs = [_]common.ProcStats{
        .{ .pid = 1, .mem_percent = 5.0 },
        .{ .pid = 2, .mem_percent = 20.0 },
        .{ .pid = 3, .mem_percent = 10.0 },
    };

    common.sortProcStats(&procs, .mem);

    try std.testing.expectEqual(@as(u32, 2), procs[0].pid);
    try std.testing.expectEqual(@as(u32, 3), procs[1].pid);
    try std.testing.expectEqual(@as(u32, 1), procs[2].pid);
}

test "sortProcStats by pid" {
    var procs = [_]common.ProcStats{
        .{ .pid = 3, .cpu_percent = 5.0 },
        .{ .pid = 1, .cpu_percent = 20.0 },
        .{ .pid = 2, .cpu_percent = 10.0 },
    };

    common.sortProcStats(&procs, .pid);

    try std.testing.expectEqual(@as(u32, 1), procs[0].pid);
    try std.testing.expectEqual(@as(u32, 2), procs[1].pid);
    try std.testing.expectEqual(@as(u32, 3), procs[2].pid);
}

test "ThreadStats name slice" {
    var thr = common.ThreadStats{
        .tid = 5678,
        .name_len = 6,
        .name_buf = std.mem.zeroes([64]u8),
    };
    std.mem.copyForwards(u8, &thr.name_buf, "worker");

    try std.testing.expectEqualStrings("worker", thr.name());
}

test "ThreadStats defaults" {
    const thr = common.ThreadStats{
        .tid = 42,
    };
    try std.testing.expectEqual(@as(u64, 42), thr.tid);
    try std.testing.expectEqual(@as(f32, 0), thr.cpu_percent);
    try std.testing.expectEqual(common.ProcState.unknown, thr.state);
    try std.testing.expectEqual(@as(u8, 0), thr.name_len);
}

test "sortThreadStats by cpu descending" {
    var threads = [_]common.ThreadStats{
        .{ .tid = 1, .cpu_percent = 5.0 },
        .{ .tid = 2, .cpu_percent = 20.0 },
        .{ .tid = 3, .cpu_percent = 10.0 },
    };

    common.sortThreadStats(&threads);

    try std.testing.expectEqual(@as(u64, 2), threads[0].tid);
    try std.testing.expectEqual(@as(u64, 3), threads[1].tid);
    try std.testing.expectEqual(@as(u64, 1), threads[2].tid);
}

test "sortProcStats by name" {
    var procs = [_]common.ProcStats{
        .{ .pid = 1, .name_buf = std.mem.zeroes([64]u8), .name_len = 1 },
        .{ .pid = 2, .name_buf = std.mem.zeroes([64]u8), .name_len = 1 },
        .{ .pid = 3, .name_buf = std.mem.zeroes([64]u8), .name_len = 1 },
    };
    procs[0].name_buf[0] = 'C';
    procs[1].name_buf[0] = 'A';
    procs[2].name_buf[0] = 'B';

    common.sortProcStats(&procs, .name);

    try std.testing.expectEqual(@as(u32, 2), procs[0].pid);
    try std.testing.expectEqual(@as(u32, 3), procs[1].pid);
    try std.testing.expectEqual(@as(u32, 1), procs[2].pid);
}

test "sortProcStats by disk read" {
    var procs = [_]common.ProcStats{
        .{ .pid = 1, .disk_read_ps = 512 },
        .{ .pid = 2, .disk_read_ps = 4096 },
        .{ .pid = 3, .disk_read_ps = 1024 },
    };

    common.sortProcStats(&procs, .disk_read);

    try std.testing.expectEqual(@as(u32, 2), procs[0].pid);
    try std.testing.expectEqual(@as(u32, 3), procs[1].pid);
    try std.testing.expectEqual(@as(u32, 1), procs[2].pid);
}

test "sortProcStats by disk write" {
    var procs = [_]common.ProcStats{
        .{ .pid = 1, .disk_write_ps = 8 * 1024 },
        .{ .pid = 2, .disk_write_ps = 512 },
        .{ .pid = 3, .disk_write_ps = 2 * 1024 },
    };

    common.sortProcStats(&procs, .disk_write);

    try std.testing.expectEqual(@as(u32, 1), procs[0].pid);
    try std.testing.expectEqual(@as(u32, 3), procs[1].pid);
    try std.testing.expectEqual(@as(u32, 2), procs[2].pid);
}

test "sortProcStats by wakeups" {
    var procs = [_]common.ProcStats{
        .{ .pid = 1, .wakeups_ps = 120, .context_switches_ps = 20 },
        .{ .pid = 2, .wakeups_ps = 40, .context_switches_ps = 200 },
        .{ .pid = 3, .wakeups_ps = 80, .context_switches_ps = 40 },
    };

    common.sortProcStats(&procs, .wakeups);

    try std.testing.expectEqual(@as(u32, 2), procs[0].pid);
    try std.testing.expectEqual(@as(u32, 1), procs[1].pid);
    try std.testing.expectEqual(@as(u32, 3), procs[2].pid);
}

test "sortProcStats preserves input order for equal metrics" {
    var procs = [_]common.ProcStats{
        .{ .pid = 30, .cpu_percent = 5.0 },
        .{ .pid = 10, .cpu_percent = 5.0 },
        .{ .pid = 40, .cpu_percent = 20.0 },
        .{ .pid = 20, .cpu_percent = 5.0 },
    };

    common.sortProcStats(&procs, .cpu);

    try std.testing.expectEqual(@as(u32, 40), procs[0].pid);
    try std.testing.expectEqual(@as(u32, 30), procs[1].pid);
    try std.testing.expectEqual(@as(u32, 10), procs[2].pid);
    try std.testing.expectEqual(@as(u32, 20), procs[3].pid);
}

test "filterProcStatsByLaunchCommandSubstring removes matches in place" {
    var procs = [_]common.ProcStats{
        .{ .pid = 1, .launch_cmd_len = 22 },
        .{ .pid = 2, .launch_cmd_len = 13 },
        .{ .pid = 3, .launch_cmd_len = 12 },
    };
    std.mem.copyForwards(u8, procs[0].launch_cmd_buf[0..22], "/usr/bin/google-chrome");
    std.mem.copyForwards(u8, procs[1].launch_cmd_buf[0..13], "/usr/bin/zsh");
    std.mem.copyForwards(u8, procs[2].launch_cmd_buf[0..12], "chrome_crash");

    const filtered = common.filterProcStatsByLaunchCommandSubstring(&procs, "chrome");

    try std.testing.expectEqual(@as(usize, 1), filtered.len);
    try std.testing.expectEqual(@as(u32, 2), filtered[0].pid);
}

test "filterProcStatsByLaunchCommandSubstring supports comma separated list" {
    var procs = [_]common.ProcStats{
        .{ .pid = 1, .launch_cmd_len = 22 },
        .{ .pid = 2, .launch_cmd_len = 19 },
        .{ .pid = 3, .launch_cmd_len = 13 },
    };
    std.mem.copyForwards(u8, procs[0].launch_cmd_buf[0..22], "/usr/bin/google-chrome");
    std.mem.copyForwards(u8, procs[1].launch_cmd_buf[0..19], "/Applications/Slack");
    std.mem.copyForwards(u8, procs[2].launch_cmd_buf[0..13], "/usr/bin/zsh");

    const filtered = common.filterProcStatsByLaunchCommandSubstring(&procs, "chrome, Slack");

    try std.testing.expectEqual(@as(usize, 1), filtered.len);
    try std.testing.expectEqual(@as(u32, 3), filtered[0].pid);
}

test "NetConnection name slice" {
    var conn = common.NetConnection{
        .protocol = .tcp,
        .process_name_len = 4,
        .process_name = std.mem.zeroes([64]u8),
    };
    @memcpy(conn.process_name[0..4], "curl");

    try std.testing.expectEqualStrings("curl", conn.name());
}

test "NetConnection defaults" {
    const conn = common.NetConnection{
        .protocol = .udp,
    };

    try std.testing.expectEqual(common.NetProtocol.udp, conn.protocol);
    try std.testing.expectEqual(@as(u16, 0), conn.local_port);
    try std.testing.expectEqual(@as(u16, 0), conn.remote_port);
    try std.testing.expectEqual(common.NetConnState.unknown, conn.state);
    try std.testing.expectEqual(@as(u32, 0), conn.pid);
    try std.testing.expectEqual(@as(u8, 0), conn.process_name_len);
    try std.testing.expectEqualStrings("", conn.name());
}

test "sortProcStats accepts empty and single-element slices" {
    var empty: [0]common.ProcStats = .{};
    common.sortProcStats(&empty, .cpu);

    var one = [_]common.ProcStats{.{ .pid = 42, .cpu_percent = 99 }};
    common.sortProcStats(&one, .mem);
    try std.testing.expectEqual(@as(u32, 42), one[0].pid);
}

test "sortProcStats wakeup score saturates at extreme counters" {
    var procs = [_]common.ProcStats{
        .{ .pid = 1, .wakeups_ps = std.math.maxInt(u64), .context_switches_ps = std.math.maxInt(u64) },
        .{ .pid = 2, .wakeups_ps = std.math.maxInt(u64) - 1 },
        .{ .pid = 3, .wakeups_ps = 0, .context_switches_ps = 0 },
    };

    common.sortProcStats(&procs, .wakeups);

    try std.testing.expectEqual(@as(u32, 1), procs[0].pid);
    try std.testing.expectEqual(@as(u32, 2), procs[1].pid);
    try std.testing.expectEqual(@as(u32, 3), procs[2].pid);
}

test "filterProcStats ignores empty comma-separated needles" {
    var procs = [_]common.ProcStats{
        .{ .pid = 1, .launch_cmd_len = 4 },
        .{ .pid = 2, .launch_cmd_len = 0 },
    };
    @memcpy(procs[0].launch_cmd_buf[0..4], "test");

    const filtered = common.filterProcStatsByLaunchCommandSubstring(&procs, " , \t, ");

    try std.testing.expectEqual(@as(usize, 2), filtered.len);
    try std.testing.expectEqual(@as(u32, 1), filtered[0].pid);
    try std.testing.expectEqual(@as(u32, 2), filtered[1].pid);
}

test "filterProcStats preserves order around adjacent removals" {
    var procs = [_]common.ProcStats{
        .{ .pid = 1, .launch_cmd_len = 3 },
        .{ .pid = 2, .launch_cmd_len = 3 },
        .{ .pid = 3, .launch_cmd_len = 4 },
        .{ .pid = 4, .launch_cmd_len = 4 },
    };
    @memcpy(procs[0].launch_cmd_buf[0..3], "bad");
    @memcpy(procs[1].launch_cmd_buf[0..3], "bad");
    @memcpy(procs[2].launch_cmd_buf[0..4], "keep");
    @memcpy(procs[3].launch_cmd_buf[0..4], "also");

    const filtered = common.filterProcStatsByLaunchCommandSubstring(&procs, "bad");

    try std.testing.expectEqual(@as(usize, 2), filtered.len);
    try std.testing.expectEqual(@as(u32, 3), filtered[0].pid);
    try std.testing.expectEqual(@as(u32, 4), filtered[1].pid);
}
