const std = @import("std");
const io_util = @import("io_util.zig");

pub fn readDiskStats(io: std.Io) !struct { read_bytes: u64, write_bytes: u64 } {
    var buf: [4096]u8 = undefined;
    const contents = io_util.readAbsoluteFile(io, "/proc/diskstats", &buf) catch return .{ .read_bytes = 0, .write_bytes = 0 };
    var lines = std.mem.splitScalar(u8, contents, '\n');
    var read_sectors: u64 = 0;
    var write_sectors: u64 = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        _ = fields.next();
        _ = fields.next();
        const dev = fields.next() orelse continue;
        if (std.mem.startsWith(u8, dev, "loop") or std.mem.startsWith(u8, dev, "ram")) continue;

        _ = fields.next();
        _ = fields.next();
        const rs = fields.next() orelse continue;
        _ = fields.next();
        _ = fields.next();
        _ = fields.next();
        const ws = fields.next() orelse continue;

        read_sectors += std.fmt.parseInt(u64, rs, 10) catch 0;
        write_sectors += std.fmt.parseInt(u64, ws, 10) catch 0;
    }
    return .{ .read_bytes = read_sectors * 512, .write_bytes = write_sectors * 512 };
}
