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
