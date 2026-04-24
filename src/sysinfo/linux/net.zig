const std = @import("std");
const io_util = @import("io_util.zig");

pub fn readNetStats(io: std.Io) !struct { rx_bytes: u64, tx_bytes: u64 } {
    var buf: [4096]u8 = undefined;
    const contents = io_util.readAbsoluteFile(io, "/proc/net/dev", &buf) catch return .{ .rx_bytes = 0, .tx_bytes = 0 };
    var lines = std.mem.splitScalar(u8, contents, '\n');
    _ = lines.next();
    _ = lines.next();

    var rx: u64 = 0;
    var tx: u64 = 0;

    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const dev = std.mem.trim(u8, line[0..colon], " \t");
        if (std.mem.eql(u8, dev, "lo")) continue;

        var fields = std.mem.tokenizeAny(u8, line[colon + 1 ..], " \t");
        const r_bytes = fields.next() orelse continue;
        rx += std.fmt.parseInt(u64, r_bytes, 10) catch 0;

        for (0..7) |_| {
            _ = fields.next();
        }
        const t_bytes = fields.next() orelse continue;
        tx += std.fmt.parseInt(u64, t_bytes, 10) catch 0;
    }
    return .{ .rx_bytes = rx, .tx_bytes = tx };
}
