const std = @import("std");
const speed_test = @import("ztop").network_speed_test;

test "speed test parses capacity in bits per second into Mbps" {
    const result = try speed_test.parseResult(std.testing.allocator,
        \\{"dl_throughput":250000000,"ul_throughput":12500000,"responsiveness":300}
    );
    try std.testing.expectEqual(@as(f64, 250), result.download_mbps);
    try std.testing.expectEqual(@as(f64, 12.5), result.upload_mbps);
}

test "speed test rejects incomplete and invalid results" {
    try std.testing.expectError(error.MissingField, speed_test.parseResult(std.testing.allocator, "{}"));
    try std.testing.expectError(error.InvalidThroughput, speed_test.parseResult(std.testing.allocator,
        \\{"dl_throughput":-1,"ul_throughput":0}
    ));
    try std.testing.expectError(error.InvalidThroughput, speed_test.parseResult(std.testing.allocator,
        \\{"dl_throughput":1e999,"ul_throughput":0}
    ));
}

test "speed test collects child output and releases process resources" {
    const io = std.testing.io;
    var test_state: speed_test.SpeedTest = .{};
    defer test_state.deinit(io);
    test_state.child = try std.process.spawn(io, .{
        .argv = &.{ "/usr/bin/printf", "%s", "{\"dl_throughput\":250000000,\"ul_throughput\":12500000}" },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    const fd = test_state.child.?.stdout.?.handle;
    const flags = std.c.fcntl(fd, std.c.F.GETFL);
    const nonblock: std.c.O = .{ .NONBLOCK = true };
    try std.testing.expect(flags >= 0);
    try std.testing.expect(std.c.fcntl(fd, std.c.F.SETFL, flags | @as(c_int, @bitCast(nonblock))) >= 0);
    test_state.state = .running;
    test_state.started = std.Io.Clock.now(.awake, io);
    for (0..1000) |_| {
        if (test_state.poll(std.testing.allocator, io)) break;
        try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    }
    try std.testing.expectEqual(speed_test.State.ready, test_state.state);
    try std.testing.expectEqual(@as(f64, 250), test_state.result.download_mbps);
    try std.testing.expectEqual(@as(f64, 12.5), test_state.result.upload_mbps);
    try std.testing.expect(test_state.child == null);
    try std.testing.expect(!test_state.poll(std.testing.allocator, io));
}
