const std = @import("std");
const speed_test = @import("ztop").network_speed_test;

test "speed test parses final capacity in Mbps" {
    const result = try speed_test.parseResult("Uplink capacity: 12.500 Mbps\r\nDownlink capacity: 250.000 Mbps\r\n");
    try std.testing.expectEqual(@as(f64, 250), result.download_mbps);
    try std.testing.expectEqual(@as(f64, 12.5), result.upload_mbps);
}

test "speed test rejects incomplete and invalid results" {
    try std.testing.expectError(error.MissingField, speed_test.parseResult("==== SUMMARY ===="));
    try std.testing.expectError(error.InvalidThroughput, speed_test.parseResult("Downlink capacity: -1 Mbps"));
    try std.testing.expectError(error.InvalidThroughput, speed_test.parseResult("Downlink capacity: inf Mbps"));
    try std.testing.expectError(error.InvalidThroughput, speed_test.parseResult("Downlink capacity: nan Mbps"));
    try std.testing.expectError(error.InvalidThroughput, speed_test.parseResult("Downlink capacity: 12"));
}

test "speed test parses terminal progress and unavailable measurements" {
    const progress = try speed_test.parseProgress("\x1b[2K\rDownlink: 21.305 Mbps, 0 RPM - Uplink: 72.705 Mbps, 0 RPM");
    try std.testing.expectEqual(@as(?f64, 21.305), progress.download_mbps);
    try std.testing.expectEqual(@as(?f64, 72.705), progress.upload_mbps);
    const partial = try speed_test.parseProgress("Downlink: 0.000 Mbps, 0 RPM");
    try std.testing.expectEqual(@as(?f64, 0), partial.download_mbps);
    try std.testing.expectEqual(@as(?f64, null), partial.upload_mbps);
    const waiting = try speed_test.parseProgress("Connecting...");
    try std.testing.expectEqual(@as(?f64, null), waiting.download_mbps);
    try std.testing.expectEqual(@as(?f64, null), waiting.upload_mbps);
    try std.testing.expectError(error.InvalidThroughput, speed_test.parseProgress("Downlink: -1 Mbps"));
}

fn spawnTestChild(test_state: *speed_test.SpeedTest, command: []const u8) !void {
    const io = std.testing.io;
    test_state.child = try std.process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-c", command },
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
}

test "speed test publishes fragmented live output before final results and releases resources" {
    const io = std.testing.io;
    var test_state: speed_test.SpeedTest = .{};
    defer test_state.deinit(io);
    try spawnTestChild(
        &test_state,
        "printf '\\033[2K\rDownlink: 25'; sleep 0.05; " ++
            "printf '0.000 Mbps, 0 RPM - Uplink: 12.500 Mbps, 0 RPM\r'; sleep 0.2; " ++
            "printf 'Uplink capacity: 15.000 Mbps\nDownlink capacity: 275.000 Mbps\n'",
    );
    var saw_live = false;
    for (0..2000) |_| {
        const changed = test_state.poll(io);
        if (test_state.state != .running) break;
        if (changed) {
            saw_live = true;
            try std.testing.expectEqual(@as(?f64, 250), test_state.live.download_mbps);
            try std.testing.expectEqual(@as(?f64, 12.5), test_state.live.upload_mbps);
        }
        try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    }
    try std.testing.expect(saw_live);
    try std.testing.expectEqual(speed_test.State.ready, test_state.state);
    try std.testing.expectEqual(@as(f64, 275), test_state.result.download_mbps);
    try std.testing.expectEqual(@as(f64, 15), test_state.result.upload_mbps);
    try std.testing.expect(test_state.child == null);
    try std.testing.expect(!test_state.poll(io));
}

test "speed test drains long progress streams without filling its output buffer" {
    const io = std.testing.io;
    var test_state: speed_test.SpeedTest = .{};
    defer test_state.deinit(io);
    try spawnTestChild(
        &test_state,
        "i=0; while [ $i -lt 1000 ]; do " ++
            "printf 'Downlink: 25.000 Mbps, 0 RPM - Uplink: 10.000 Mbps, 0 RPM\r'; i=$((i+1)); done; " ++
            "printf 'Uplink capacity: 10.000 Mbps\nDownlink capacity: 25.000 Mbps'",
    );
    for (0..2000) |_| {
        _ = test_state.poll(io);
        if (test_state.state != .running) break;
        try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    }
    try std.testing.expectEqual(speed_test.State.ready, test_state.state);
    try std.testing.expectEqual(@as(f64, 25), test_state.result.download_mbps);
    try std.testing.expectEqual(@as(f64, 10), test_state.result.upload_mbps);
}

test "speed test requires a complete successful summary" {
    const io = std.testing.io;
    for ([_][]const u8{
        "printf 'Downlink: 25.000 Mbps - Uplink: 10.000 Mbps\r'",
        "printf 'Downlink capacity: 25.000 Mbps\nUplink capacity: 10.000 Mbps\n'; exit 1",
    }) |command| {
        var test_state: speed_test.SpeedTest = .{};
        defer test_state.deinit(io);
        try spawnTestChild(&test_state, command);
        for (0..2000) |_| {
            _ = test_state.poll(io);
            if (test_state.state != .running) break;
            try std.Io.sleep(io, .fromMilliseconds(1), .awake);
        }
        try std.testing.expectEqual(speed_test.State.failed, test_state.state);
        try std.testing.expect(test_state.child == null);
    }
}
