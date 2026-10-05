const std = @import("std");
const ztop = @import("ztop");
const common = ztop.sysinfo.common;
const ProcessTracer = ztop.process_tracer.ProcessTracer;

fn connection(port: u16) common.NetConnection {
    var conn: common.NetConnection = .{
        .protocol = .tcp,
        .local_port = port,
        .remote_port = 443,
    };
    @memcpy(conn.local_addr[0..9], "127.0.0.1");
    @memcpy(conn.remote_addr[0..7], "1.2.3.4");
    return conn;
}

test "socket diff preserves event order and ignores metadata and sampling order" {
    const tracer = try ProcessTracer.init(std.testing.allocator, 1);
    defer tracer.deinit();
    const first = connection(1000);
    const second = connection(2000);
    const third = connection(3000);
    try tracer.updateSockets(&.{ first, second }, 10);
    try std.testing.expectEqual(@as(usize, 2), tracer.ev_count);
    try std.testing.expectEqualStrings("Socket opened: tcp 127.0.0.1:1000 -> 1.2.3.4:443", tracer.getEvent(0).?.detail());
    try std.testing.expectEqualStrings("Socket opened: tcp 127.0.0.1:2000 -> 1.2.3.4:443", tracer.getEvent(1).?.detail());

    var metadata_changed = first;
    metadata_changed.state = .established;
    metadata_changed.pid = 42;
    metadata_changed.process_name[0] = 'x';
    metadata_changed.process_name_len = 1;
    try tracer.updateSockets(&.{ second, metadata_changed }, 20);
    try std.testing.expectEqual(@as(usize, 2), tracer.ev_count);

    try tracer.updateSockets(&.{ third, second }, 30);
    try std.testing.expectEqual(@as(usize, 4), tracer.ev_count);
    try std.testing.expectEqualStrings("Socket opened: tcp 127.0.0.1:3000 -> 1.2.3.4:443", tracer.getEvent(2).?.detail());
    try std.testing.expectEqualStrings("Socket closed: tcp 127.0.0.1:1000 -> 1.2.3.4:443", tracer.getEvent(3).?.detail());
    try std.testing.expectEqual(@as(i64, 30), tracer.getEvent(3).?.timestamp_ms);

    try tracer.updateSockets(&.{}, 40);
    try std.testing.expectEqual(@as(usize, 6), tracer.ev_count);
    try std.testing.expectEqualStrings("Socket closed: tcp 127.0.0.1:3000 -> 1.2.3.4:443", tracer.getEvent(4).?.detail());
    try std.testing.expectEqualStrings("Socket closed: tcp 127.0.0.1:2000 -> 1.2.3.4:443", tracer.getEvent(5).?.detail());
    try tracer.updateSockets(&.{}, 50);
    try std.testing.expectEqual(@as(usize, 6), tracer.ev_count);
}

test "socket identity includes protocol addresses and ports" {
    const base = connection(1000);
    var variants = [_]common.NetConnection{ base, base, base, base, base };
    variants[0].protocol = .udp;
    variants[1].local_port = 1001;
    variants[2].remote_port = 80;
    variants[3].local_addr[0] = '2';
    variants[4].remote_addr[0] = '2';
    for (variants) |variant| {
        const tracer = try ProcessTracer.init(std.testing.allocator, 1);
        defer tracer.deinit();
        try tracer.updateSockets(&.{base}, 10);
        try tracer.updateSockets(&.{variant}, 20);
        try std.testing.expectEqual(@as(usize, 3), tracer.ev_count);
        try std.testing.expectEqual(ztop.process_tracer.ProcessTraceEventKind.socket_open, tracer.getEvent(1).?.kind);
        try std.testing.expectEqual(ztop.process_tracer.ProcessTraceEventKind.socket_close, tracer.getEvent(2).?.kind);
    }
}

test "socket diff preserves duplicate endpoint membership behavior" {
    const tracer = try ProcessTracer.init(std.testing.allocator, 1);
    defer tracer.deinit();
    const conn = connection(1000);
    try tracer.updateSockets(&.{ conn, conn }, 10);
    try std.testing.expectEqual(@as(usize, 2), tracer.ev_count);
    try tracer.updateSockets(&.{ conn, conn }, 20);
    try std.testing.expectEqual(@as(usize, 2), tracer.ev_count);
    try tracer.updateSockets(&.{conn}, 30);
    try std.testing.expectEqual(@as(usize, 2), tracer.ev_count);
    try tracer.updateSockets(&.{ conn, conn }, 40);
    try std.testing.expectEqual(@as(usize, 2), tracer.ev_count);
    try tracer.updateSockets(&.{}, 50);
    try std.testing.expectEqual(@as(usize, 4), tracer.ev_count);
    try std.testing.expectEqual(ztop.process_tracer.ProcessTraceEventKind.socket_close, tracer.getEvent(2).?.kind);
    try std.testing.expectEqual(ztop.process_tracer.ProcessTraceEventKind.socket_close, tracer.getEvent(3).?.kind);
}

test "socket diff reuses warmed capacity and retains snapshot on allocation failure" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const tracer = try ProcessTracer.init(failing.allocator(), 1);
    defer tracer.deinit();
    const conn = connection(1000);
    try tracer.updateSockets(&.{conn}, 10);
    try tracer.updateSockets(&.{conn}, 20);
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;

    try tracer.updateSockets(&.{conn}, 30);
    try std.testing.expectEqual(@as(usize, 1), tracer.ev_count);
    var larger: [256]common.NetConnection = undefined;
    for (&larger, 0..) |*item, idx| item.* = connection(@intCast(idx));
    try std.testing.expectError(error.OutOfMemory, tracer.updateSockets(&larger, 40));
    try std.testing.expectEqual(@as(usize, 1), tracer.ev_count);
    try std.testing.expectEqual(@as(usize, 1), tracer.prev_sockets.items.len);
    try std.testing.expectEqual(conn.local_port, tracer.prev_sockets.items[0].local_port);
    try tracer.updateSockets(&.{conn}, 50);
    try std.testing.expectEqual(@as(usize, 1), tracer.ev_count);
    try tracer.updateSockets(&.{}, 60);
    try std.testing.expectEqual(@as(usize, 2), tracer.ev_count);
    try std.testing.expectEqualStrings("Socket closed: tcp 127.0.0.1:1000 -> 1.2.3.4:443", tracer.getEvent(1).?.detail());
}
