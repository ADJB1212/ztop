const std = @import("std");
const bindings = @import("bindings.zig");
const c = bindings.c;
const common = @import("../../sysinfo/common.zig");

pub const NetTotals = struct {
    rx_bytes: u64,
    tx_bytes: u64,
    wifi: common.WifiDetails = .{},
};

var static_net_buf: []u8 = &[_]u8{};

pub fn readNetTotals() !NetTotals {
    var mib = [_]c_int{ c.CTL_NET, c.PF_ROUTE, 0, 0, c.NET_RT_IFLIST2, 0 };
    var len: usize = 0;
    if (c.sysctl(&mib, mib.len, null, &len, null, 0) != 0) return error.SysctlFailed;

    if (len > static_net_buf.len) {
        if (static_net_buf.len > 0) std.heap.page_allocator.free(static_net_buf);
        static_net_buf = try std.heap.page_allocator.alloc(u8, len);
    }

    if (c.sysctl(&mib, mib.len, static_net_buf.ptr, &len, null, 0) != 0) return error.SysctlFailed;

    var rx: u64 = 0;
    var tx: u64 = 0;
    var offset: usize = 0;

    while (offset + @sizeOf(c.struct_if_msghdr2) <= len) {
        const hdr: *align(1) const c.struct_if_msghdr2 = @ptrCast(static_net_buf.ptr + offset);
        const msg_len: usize = hdr.ifm_msglen;
        if (msg_len == 0) break;

        if (msg_len >= @sizeOf(c.struct_if_msghdr2) and hdr.ifm_type == c.RTM_IFINFO2 and (hdr.ifm_flags & c.IFF_LOOPBACK) == 0) {
            rx +|= hdr.ifm_data.ifi_ibytes;
            tx +|= hdr.ifm_data.ifi_obytes;
        }

        offset += msg_len;
    }

    return .{
        .rx_bytes = rx,
        .tx_bytes = tx,
        .wifi = readWifiDetails(),
    };
}

pub fn mapWifiGeneration(phy_mode: i64, channel_band: i64) common.WifiGeneration {
    return switch (phy_mode) {
        7 => .wifi7,
        6 => if (channel_band == 3) .wifi6e else .wifi6,
        5 => .wifi5,
        4 => .wifi4,
        1, 2, 3 => .legacy,
        else => .unknown,
    };
}

fn readWifiDetails() common.WifiDetails {
    var wifi: common.WifiDetails = .{};
    const raw = bindings.ztop_read_wifi_snapshot(&wifi.ssid_buf, wifi.ssid_buf.len);
    wifi.ssid_len = @intCast(@min(raw.ssid_len, wifi.ssid_buf.len - 1));
    wifi.generation = mapWifiGeneration(raw.phy_mode, raw.channel_band);
    return wifi;
}

pub fn parseSocketFdInfo(pid: u32, process_name: [64]u8, name_len: u8, socket_info: *const c.struct_socket_fdinfo) ?common.NetConnection {
    const kind = socket_info.psi.soi_kind;
    const in_info: c.struct_in_sockinfo = switch (kind) {
        c.SOCKINFO_IN => socket_info.psi.soi_proto.pri_in,
        c.SOCKINFO_TCP => socket_info.psi.soi_proto.pri_tcp.tcpsi_ini,
        else => return null,
    };

    var conn = common.NetConnection{
        .protocol = protocolForSocketKind(kind, in_info.insi_vflag),
        .pid = pid,
        .process_name = process_name,
        .process_name_len = name_len,
    };
    conn.local_port = decodeSocketPort(in_info.insi_lport);
    conn.remote_port = decodeSocketPort(in_info.insi_fport);
    formatSocketAddress(&conn.local_addr, in_info, true);
    formatSocketAddress(&conn.remote_addr, in_info, false);

    if (kind == c.SOCKINFO_TCP) {
        conn.state = mapTcpState(socket_info.psi.soi_proto.pri_tcp.tcpsi_state);
    }

    return conn;
}

pub fn mapTcpState(state: c_int) common.NetConnState {
    return switch (state) {
        c.TSI_S_CLOSED => .closed,
        c.TSI_S_LISTEN => .listen,
        c.TSI_S_SYN_SENT => .syn_sent,
        c.TSI_S_SYN_RECEIVED => .syn_recv,
        c.TSI_S_ESTABLISHED => .established,
        c.TSI_S__CLOSE_WAIT => .close_wait,
        c.TSI_S_FIN_WAIT_1 => .fin_wait1,
        c.TSI_S_CLOSING => .closing,
        c.TSI_S_LAST_ACK => .last_ack,
        c.TSI_S_FIN_WAIT_2 => .fin_wait2,
        c.TSI_S_TIME_WAIT => .time_wait,
        else => .unknown,
    };
}

fn protocolForSocketKind(kind: c_int, vflag: u8) common.NetProtocol {
    const is_ipv6 = (vflag & c.INI_IPV6) != 0;
    return switch (kind) {
        c.SOCKINFO_TCP => if (is_ipv6) .tcp6 else .tcp,
        c.SOCKINFO_IN => if (is_ipv6) .udp6 else .udp,
        else => .unknown,
    };
}

fn decodeSocketPort(port: c_int) u16 {
    if (port <= 0) return 0;
    return std.mem.nativeToBig(u16, @intCast(port));
}

fn formatSocketAddress(dest: *[46]u8, in_info: c.struct_in_sockinfo, is_local: bool) void {
    dest.* = std.mem.zeroes([46]u8);

    if ((in_info.insi_vflag & c.INI_IPV4) != 0) {
        const addr = if (is_local) in_info.insi_laddr.ina_46.i46a_addr4 else in_info.insi_faddr.ina_46.i46a_addr4;
        const octets: [4]u8 = @bitCast(addr.s_addr);
        _ = std.fmt.bufPrint(dest, "{}.{}.{}.{}", .{ octets[0], octets[1], octets[2], octets[3] }) catch {};
        return;
    }

    if ((in_info.insi_vflag & c.INI_IPV6) != 0) {
        const addr = if (is_local) in_info.insi_laddr.ina_6 else in_info.insi_faddr.ina_6;
        const octets = std.mem.asBytes(&addr);
        _ = std.fmt.bufPrint(
            dest,
            "{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}",
            .{
                octets[0],  octets[1],  octets[2],  octets[3],
                octets[4],  octets[5],  octets[6],  octets[7],
                octets[8],  octets[9],  octets[10], octets[11],
                octets[12], octets[13], octets[14], octets[15],
            },
        ) catch {};
    }
}
