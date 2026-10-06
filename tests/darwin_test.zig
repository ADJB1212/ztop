const std = @import("std");
const darwin = @import("ztop").sysinfo.sys_darwin;
const common = @import("ztop").sysinfo.common;
const c = darwin.c;

test "process rusage v2 binding matches the macOS ABI" {
    const Rusage = darwin.bindings.rusage_info_v2;

    try std.testing.expectEqual(@as(usize, 160), @sizeOf(Rusage));
    try std.testing.expectEqual(@as(usize, 144), @offsetOf(Rusage, "ri_diskio_bytesread"));
    try std.testing.expectEqual(@as(usize, 152), @offsetOf(Rusage, "ri_diskio_byteswritten"));

    var usage: Rusage = undefined;
    const result = darwin.bindings.proc_pid_rusage(std.c.getpid(), darwin.bindings.RUSAGE_INFO_V2, @ptrCast(&usage));
    try std.testing.expectEqual(@as(c_int, 0), result);
    try std.testing.expect(usage.ri_proc_start_abstime > 0);
}

test "parseSocketFdInfo extracts IPv4 TCP endpoints" {
    var socket_info: c.struct_socket_fdinfo = std.mem.zeroes(c.struct_socket_fdinfo);
    socket_info.psi.soi_kind = c.SOCKINFO_TCP;
    socket_info.psi.soi_proto.pri_tcp.tcpsi_ini.insi_vflag = c.INI_IPV4;
    socket_info.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport = @as(c_int, std.mem.nativeToBig(u16, 8080));
    socket_info.psi.soi_proto.pri_tcp.tcpsi_ini.insi_fport = @as(c_int, std.mem.nativeToBig(u16, 443));
    socket_info.psi.soi_proto.pri_tcp.tcpsi_state = c.TSI_S_ESTABLISHED;
    socket_info.psi.soi_proto.pri_tcp.tcpsi_ini.insi_laddr.ina_46.i46a_addr4.s_addr = @bitCast(@as([4]u8, .{ 127, 0, 0, 1 }));
    socket_info.psi.soi_proto.pri_tcp.tcpsi_ini.insi_faddr.ina_46.i46a_addr4.s_addr = @bitCast(@as([4]u8, .{ 1, 1, 1, 1 }));

    var process_name: [64]u8 = std.mem.zeroes([64]u8);
    @memcpy(process_name[0..4], "curl");

    const conn = darwin.parseSocketFdInfo(42, process_name, 4, &socket_info).?;

    try std.testing.expectEqual(common.NetProtocol.tcp, conn.protocol);
    try std.testing.expectEqual(@as(u16, 8080), conn.local_port);
    try std.testing.expectEqual(@as(u16, 443), conn.remote_port);
    try std.testing.expectEqual(common.NetConnState.established, conn.state);
    try std.testing.expectEqualStrings("127.0.0.1", std.mem.sliceTo(&conn.local_addr, 0));
    try std.testing.expectEqualStrings("1.1.1.1", std.mem.sliceTo(&conn.remote_addr, 0));
    try std.testing.expectEqualStrings("curl", conn.name());
}

test "parseSocketFdInfo extracts IPv6 UDP endpoints" {
    var socket_info: c.struct_socket_fdinfo = std.mem.zeroes(c.struct_socket_fdinfo);
    socket_info.psi.soi_kind = c.SOCKINFO_IN;
    socket_info.psi.soi_proto.pri_in.insi_vflag = c.INI_IPV6;
    socket_info.psi.soi_proto.pri_in.insi_lport = @as(c_int, std.mem.nativeToBig(u16, 5353));
    socket_info.psi.soi_proto.pri_in.insi_fport = @as(c_int, std.mem.nativeToBig(u16, 5354));

    const local_addr = [_]u8{ 0x20, 0x01, 0x0d, 0xb8, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01 };
    const remote_addr = [_]u8{ 0x20, 0x01, 0x0d, 0xb8, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02 };
    @memcpy(std.mem.asBytes(&socket_info.psi.soi_proto.pri_in.insi_laddr.ina_6)[0..16], local_addr[0..]);
    @memcpy(std.mem.asBytes(&socket_info.psi.soi_proto.pri_in.insi_faddr.ina_6)[0..16], remote_addr[0..]);

    var process_name: [64]u8 = std.mem.zeroes([64]u8);
    @memcpy(process_name[0..3], "dns");

    const conn = darwin.parseSocketFdInfo(77, process_name, 3, &socket_info).?;

    try std.testing.expectEqual(common.NetProtocol.udp6, conn.protocol);
    try std.testing.expectEqual(@as(u16, 5353), conn.local_port);
    try std.testing.expectEqual(@as(u16, 5354), conn.remote_port);
    try std.testing.expectEqual(common.NetConnState.unknown, conn.state);
    try std.testing.expectEqualStrings("2001:db8::1", std.mem.sliceTo(&conn.local_addr, 0));
    try std.testing.expectEqualStrings("2001:db8::2", std.mem.sliceTo(&conn.remote_addr, 0));
    try std.testing.expectEqualStrings("dns", conn.name());
}

test "parseSocketFdInfo rejects unsupported socket kind" {
    var socket_info: c.struct_socket_fdinfo = std.mem.zeroes(c.struct_socket_fdinfo);
    socket_info.psi.soi_kind = c.SOCKINFO_UN;

    var process_name: [64]u8 = std.mem.zeroes([64]u8);
    @memcpy(process_name[0..4], "unix");

    try std.testing.expectEqual(@as(?common.NetConnection, null), darwin.parseSocketFdInfo(9, process_name, 4, &socket_info));
}

test "mapTcpState covers expected transitions" {
    try std.testing.expectEqual(common.NetConnState.listen, darwin.mapTcpState(c.TSI_S_LISTEN));
    try std.testing.expectEqual(common.NetConnState.close_wait, darwin.mapTcpState(c.TSI_S__CLOSE_WAIT));
    try std.testing.expectEqual(common.NetConnState.time_wait, darwin.mapTcpState(c.TSI_S_TIME_WAIT));
    try std.testing.expectEqual(common.NetConnState.unknown, darwin.mapTcpState(999));
}

test "mapWifiGeneration maps modern WiFi generations" {
    try std.testing.expectEqual(common.WifiGeneration.wifi5, darwin.mapWifiGeneration(5, 2));
    try std.testing.expectEqual(common.WifiGeneration.wifi6, darwin.mapWifiGeneration(6, 2));
    try std.testing.expectEqual(common.WifiGeneration.wifi6e, darwin.mapWifiGeneration(6, 3));
    try std.testing.expectEqual(common.WifiGeneration.wifi7, darwin.mapWifiGeneration(7, 3));
    try std.testing.expectEqual(common.WifiGeneration.legacy, darwin.mapWifiGeneration(3, 1));
    try std.testing.expectEqual(common.WifiGeneration.unknown, darwin.mapWifiGeneration(0, 0));
}

test "getBatteryStats does not crash" {
    var si = darwin.SysInfo.init(std.testing.io);
    defer si.deinit();
    const stats = si.getBatteryStats();
    if (stats.charge_percent) |charge| {
        try std.testing.expect(charge >= 0 and charge <= 100);
    }
}

test "getThermalStats does not crash and respects valid bounds" {
    var si = darwin.SysInfo.init(std.testing.io);
    defer si.deinit();
    try std.testing.expect(si.hid_client != null);
    const thermal = si.getThermalStats();
    if (thermal.cpu_temp) |c_temp| {
        try std.testing.expect(c_temp > 5.0 and c_temp < 130.0);
    }
    if (thermal.gpu_temp) |g_temp| {
        try std.testing.expect(g_temp > 5.0 and g_temp < 130.0);
    }
}

test "power sampling init, sample, and deinit" {
    var si = darwin.SysInfo.init(std.testing.io);
    defer si.deinit();

    const stats = si.getBatteryStats();
    _ = stats;
    if (si.power_handle) |handle| {
        const reading = darwin.bindings.ztop_power_sample(handle, 1.0);
        try std.testing.expect(reading.soc_watts >= 0.0);
    }
}

test "thermal results are sampled immediately then cached for two seconds" {
    var si = darwin.SysInfo.init(std.testing.io);
    defer si.deinit();
    const sentinel: common.ThermalStats = .{ .cpu_temp = -1, .gpu_temp = -1 };
    si.thermal_stats = sentinel;
    try std.testing.expectEqual(@as(?i64, null), si.prev_thermal_ms);

    const first = si.getThermalStats();
    try std.testing.expect(!std.meta.eql(sentinel, first));
    try std.testing.expectEqual(first, si.thermal_stats);
    const sampled_at = si.prev_thermal_ms.?;
    try std.testing.expect(si.sensors_initialized);

    si.thermal_stats = sentinel;
    try std.testing.expectEqual(sentinel, si.getThermalStats());
    try std.testing.expectEqual(sampled_at, si.prev_thermal_ms.?);

    si.prev_thermal_ms = std.Io.Clock.now(.real, std.testing.io).toMilliseconds() - 2_000;
    const refreshed = si.getThermalStats();
    try std.testing.expect(!std.meta.eql(sentinel, refreshed));
    try std.testing.expectEqual(refreshed, si.thermal_stats);
    try std.testing.expect(si.prev_thermal_ms.? >= sampled_at);
}

test "thermal cache retains unavailable results and refreshes after clock rollback" {
    var si = darwin.SysInfo.init(std.testing.io);
    defer si.deinit();
    const now = std.Io.Clock.now(.real, std.testing.io).toMilliseconds();
    si.prev_thermal_ms = now;
    si.thermal_stats = .{};
    try std.testing.expectEqual(common.ThermalStats{}, si.getThermalStats());
    try std.testing.expectEqual(now, si.prev_thermal_ms.?);

    si.thermal_stats = .{ .cpu_temp = -1, .gpu_temp = -1 };
    si.prev_thermal_ms = now + 60_000;
    const refreshed = si.getThermalStats();
    try std.testing.expect(refreshed.cpu_temp == null or refreshed.cpu_temp.? >= 0);
    try std.testing.expect(refreshed.gpu_temp == null or refreshed.gpu_temp.? >= 0);
    try std.testing.expect(si.prev_thermal_ms.? < now + 60_000);
}

test "SysInfo deinit releases owned clients and collectors" {
    var si = darwin.SysInfo.init(std.testing.io);
    _ = si.getDiskStats();
    const gpus = try si.getGpuStats(std.testing.allocator);
    defer std.testing.allocator.free(gpus);

    si.deinit();
    try std.testing.expectEqual(@as(?c.IOHIDEventSystemClientRef, null), si.hid_client);
    try std.testing.expectEqual(@as(?*anyopaque, null), si.power_handle);
    try std.testing.expect(!si.disk_collector.initialized);
    try std.testing.expect(!si.gpu_collector.initialized);

    // Cleanup is safe to call from multiple error/exit paths.
    si.deinit();
}

test "cached proc stats preserves ppid and launch_cmd_fetched across polls" {
    var si = darwin.SysInfo.init(std.testing.io);
    defer si.deinit();

    var buf1: [common.MAX_PROCS]common.ProcStats = undefined;
    var buf2: [common.MAX_PROCS]common.ProcStats = undefined;

    const p1 = try si.getProcStats(&buf1, .cpu);
    try std.testing.expect(p1.len > 0);
    try std.testing.expect(si.prev_proc_count > 0);

    for (si.proc_buffers[si.prev_proc_buffer][0..si.prev_proc_count]) |entry| {
        try std.testing.expect(entry.launch_cmd_fetched);
    }

    const p2 = try si.getProcStats(&buf2, .cpu);
    try std.testing.expect(p2.len > 0);

    const p3 = try si.getProcStats(&buf1, .cpu);
    try std.testing.expect(p3.len > 0);
    try std.testing.expectEqual(p3.len, si.prev_proc_count);
    const cached = si.proc_buffers[si.prev_proc_buffer][0..si.prev_proc_count];
    for (cached, 0..) |entry, i| {
        try std.testing.expect(entry.launch_cmd_fetched);
        if (i > 0) try std.testing.expect(cached[i - 1].pid < entry.pid);
    }
}

fn cachedCurrentProcess(si: *darwin.SysInfo) !*common.ProcCpuEntry {
    const pid: u32 = @intCast(std.c.getpid());
    for (si.proc_buffers[si.prev_proc_buffer][0..si.prev_proc_count]) |*entry| {
        if (entry.pid == pid) return entry;
    }
    return error.CurrentProcessNotFound;
}

fn currentProcess(procs: []const common.ProcStats) !*const common.ProcStats {
    const pid: u32 = @intCast(std.c.getpid());
    for (procs) |*proc| {
        if (proc.pid == pid) return proc;
    }
    return error.CurrentProcessNotFound;
}

test "proc name and launch command results are reused across ticks including empty commands" {
    var si = darwin.SysInfo.init(std.testing.io);
    defer si.deinit();
    var buf: [common.MAX_PROCS]common.ProcStats = undefined;
    _ = try si.getProcStats(&buf, .cpu);

    const cached = try cachedCurrentProcess(&si);
    const name = "cached-name";
    const command = "cached-command --arg";
    @memcpy(cached.name_buf[0..name.len], name);
    cached.name_len = name.len;
    @memcpy(cached.launch_cmd_buf[0..command.len], command);
    cached.launch_cmd_len = command.len;
    cached.launch_cmd_fetched = true;

    for (0..2) |_| {
        const proc = try currentProcess(try si.getProcStats(&buf, .cpu));
        try std.testing.expectEqualStrings(name, proc.name());
        try std.testing.expectEqualStrings(command, proc.launchCommand());
    }

    (try cachedCurrentProcess(&si)).launch_cmd_len = 0;
    const proc = try currentProcess(try si.getProcStats(&buf, .cpu));
    try std.testing.expectEqualStrings(name, proc.name());
    try std.testing.expectEqualStrings("", proc.launchCommand());
    try std.testing.expect((try cachedCurrentProcess(&si)).launch_cmd_fetched);
}

test "proc metadata cache is discarded when the process start time changes" {
    var si = darwin.SysInfo.init(std.testing.io);
    defer si.deinit();
    var buf: [common.MAX_PROCS]common.ProcStats = undefined;
    const original = (try currentProcess(try si.getProcStats(&buf, .cpu))).*;

    const cached = try cachedCurrentProcess(&si);
    try std.testing.expect(cached.proc_start_abstime > 0);
    cached.proc_start_abstime += 1;
    const stale = "stale-metadata";
    @memcpy(cached.name_buf[0..stale.len], stale);
    cached.name_len = stale.len;
    @memcpy(cached.launch_cmd_buf[0..stale.len], stale);
    cached.launch_cmd_len = stale.len;
    cached.launch_cmd_fetched = true;

    const proc = try currentProcess(try si.getProcStats(&buf, .cpu));
    try std.testing.expectEqualStrings(original.name(), proc.name());
    try std.testing.expectEqualStrings(original.launchCommand(), proc.launchCommand());
    try std.testing.expectEqual(@as(f32, 0), proc.cpu_percent);
}

test "battery results are sampled immediately then cached for five seconds" {
    var si = darwin.SysInfo.init(std.testing.io);
    defer si.deinit();
    const sentinel: common.BatteryStats = .{ .charge_percent = -1, .power_draw_w = -1, .status = .charging };
    si.battery_stats = sentinel;
    try std.testing.expectEqual(@as(?i64, null), si.prev_battery_ms);

    const first = si.getBatteryStats();
    try std.testing.expect(!std.meta.eql(sentinel, first));
    try std.testing.expectEqual(first, si.battery_stats);
    const sampled_at = si.prev_battery_ms.?;

    si.battery_stats = sentinel;
    try std.testing.expectEqual(sentinel, si.getBatteryStats());
    try std.testing.expectEqual(sampled_at, si.prev_battery_ms.?);

    si.prev_battery_ms = std.Io.Clock.now(.real, std.testing.io).toMilliseconds() - 5_000;
    const refreshed = si.getBatteryStats();
    try std.testing.expect(!std.meta.eql(sentinel, refreshed));
    try std.testing.expectEqual(refreshed, si.battery_stats);
    try std.testing.expect(si.prev_battery_ms.? >= sampled_at);
}

test "battery cache retains unavailable results and refreshes after clock rollback" {
    var si = darwin.SysInfo.init(std.testing.io);
    defer si.deinit();
    const now = std.Io.Clock.now(.real, std.testing.io).toMilliseconds();
    si.prev_battery_ms = now;
    si.battery_stats = .{};
    try std.testing.expectEqual(common.BatteryStats{}, si.getBatteryStats());
    try std.testing.expectEqual(now, si.prev_battery_ms.?);

    si.battery_stats = .{ .charge_percent = -1, .power_draw_w = -1 };
    si.prev_battery_ms = now + 60_000;
    const refreshed = si.getBatteryStats();
    try std.testing.expect(refreshed.charge_percent == null or refreshed.charge_percent.? >= 0);
    try std.testing.expect(refreshed.power_draw_w == null or refreshed.power_draw_w.? >= 0);
    try std.testing.expect(si.prev_battery_ms.? < now + 60_000);
}

test "aggregate CPU stats avoid per-core sampling" {
    var si = darwin.SysInfo.init(std.testing.io);
    defer si.deinit();

    const aggregate = si.getCpuStatsAggregate();
    try std.testing.expectEqual(@as(usize, 0), aggregate.per_core_usage.len);
    try std.testing.expect(!si.per_core_sampled_last);

    const detailed = si.getCpuStats();
    try std.testing.expectEqual(@as(usize, detailed.cores), detailed.per_core_usage.len);
    try std.testing.expect(si.per_core_sampled_last);
}

test "single-process connection collection only returns the requested PID" {
    var si = darwin.SysInfo.init(std.testing.io);
    defer si.deinit();

    const pid: u32 = @intCast(std.c.getpid());
    const connections = try si.getProcNetConnections(std.testing.allocator, pid);
    defer std.testing.allocator.free(connections);
    for (connections) |connection| {
        try std.testing.expectEqual(pid, connection.pid);
    }
}

test "disk and GPU collectors retain discovered services" {
    var si = darwin.SysInfo.init(std.testing.io);
    defer si.deinit();

    _ = si.getDiskStats();
    try std.testing.expect(si.disk_collector.initialized);
    const disk_service_count = si.disk_collector.service_count;
    _ = si.getDiskStats();
    try std.testing.expectEqual(disk_service_count, si.disk_collector.service_count);

    const gpus = try si.getGpuStats(std.testing.allocator);
    defer std.testing.allocator.free(gpus);
    try std.testing.expect(si.gpu_collector.initialized);
}

test "GPU refresh reuses caller capacity without accumulating samples" {
    var si = darwin.SysInfo.init(std.testing.io);
    defer si.deinit();
    var gpus: std.ArrayList(common.GpuStats) = .empty;
    defer gpus.deinit(std.testing.allocator);
    try gpus.ensureTotalCapacity(std.testing.allocator, 64);
    const buffer = gpus.items.ptr;
    try si.refreshGpuStats(std.testing.allocator, &gpus);
    const count = gpus.items.len;
    try si.refreshGpuStats(std.testing.allocator, &gpus);
    try std.testing.expectEqual(count, gpus.items.len);
    try std.testing.expectEqual(buffer, gpus.items.ptr);
}

test "swap cache refreshes on expiry and clock rollback" {
    var si = darwin.SysInfo.init(std.testing.io);
    defer si.deinit();
    _ = si.getMemStats();
    const sampled_at = si.prev_swap_ms.?;
    si.swap_usage.xsu_total = 123;
    si.swap_usage.xsu_used = 45;
    const cached = si.getMemStats();
    try std.testing.expectEqual(@as(u64, 123), cached.swap_total);
    try std.testing.expectEqual(@as(u64, 45), cached.swap_used);
    try std.testing.expectEqual(sampled_at, si.prev_swap_ms.?);

    si.prev_swap_ms = std.Io.Clock.now(.real, std.testing.io).toMilliseconds() - 2_000;
    _ = si.getMemStats();
    try std.testing.expect(si.prev_swap_ms.? >= sampled_at);
    const future = std.Io.Clock.now(.real, std.testing.io).toMilliseconds() + 60_000;
    si.prev_swap_ms = future;
    _ = si.getMemStats();
    try std.testing.expect(si.prev_swap_ms.? < future);
}

test "connection refresh skips known empty descriptor tables and scans unknown ones" {
    var si = darwin.SysInfo.init(std.testing.io);
    defer si.deinit();
    const socket = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
    try std.testing.expect(socket >= 0);
    defer _ = std.c.close(socket);
    const pid: u32 = @intCast(std.c.getpid());
    si.prev_proc_count = 1;
    si.proc_buffers[si.prev_proc_buffer][0] = .{ .pid = pid, .cpu_total = 0, .open_files = 0 };
    var connections: std.ArrayList(common.NetConnection) = .empty;
    defer connections.deinit(std.testing.allocator);
    try si.refreshNetConnections(std.testing.allocator, &connections);
    try std.testing.expectEqual(@as(usize, 0), connections.items.len);

    si.proc_buffers[si.prev_proc_buffer][0].open_files = null;
    try si.refreshNetConnections(std.testing.allocator, &connections);
    try std.testing.expect(connections.items.len > 0);
    for (connections.items) |connection| try std.testing.expectEqual(pid, connection.pid);
    si.proc_buffers[si.prev_proc_buffer][0].open_files = 0;
    try si.refreshNetConnections(std.testing.allocator, &connections);
    try std.testing.expectEqual(@as(usize, 0), connections.items.len);
}
