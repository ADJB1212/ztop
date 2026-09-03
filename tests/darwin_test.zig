const std = @import("std");
const darwin = @import("ztop").sysinfo.sys_darwin;
const common = @import("ztop").sysinfo.common;
const c = darwin.c;

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
    try std.testing.expectEqualStrings("2001:0db8:0000:0000:0000:0000:0000:0001", std.mem.sliceTo(&conn.local_addr, 0));
    try std.testing.expectEqualStrings("2001:0db8:0000:0000:0000:0000:0000:0002", std.mem.sliceTo(&conn.remote_addr, 0));
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

test "cached thermal stats across multiple invocations" {
    var si = darwin.SysInfo.init(std.testing.io);
    defer si.deinit();

    const t1 = si.getThermalStats();
    const t2 = si.getThermalStats();
    _ = t1;
    _ = t2;
    try std.testing.expect(si.sensors_initialized);
}

test "cached proc stats preserves ppid and launch_cmd_fetched across polls" {
    var si = darwin.SysInfo.init(std.testing.io);
    defer si.deinit();

    var buf1: [common.MAX_PROCS]common.ProcStats = undefined;
    var buf2: [common.MAX_PROCS]common.ProcStats = undefined;

    const p1 = try si.getProcStats(&buf1, .cpu);
    try std.testing.expect(p1.len > 0);
    try std.testing.expect(si.prev_proc_count > 0);

    for (si.prev_procs[0..si.prev_proc_count]) |entry| {
        try std.testing.expect(entry.launch_cmd_fetched);
    }

    const p2 = try si.getProcStats(&buf2, .cpu);
    try std.testing.expect(p2.len > 0);
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
