const std = @import("std");
const io_util = @import("io_util.zig");

pub const DiskUsage = struct {
    total_bytes: u64,
    used_bytes: u64,
};

const LinuxFsId = extern struct {
    val: [2]c_int,
};

const LinuxStatFs = extern struct {
    f_type: c_long,
    f_bsize: c_long,
    f_blocks: u64,
    f_bfree: u64,
    f_bavail: u64,
    f_files: u64,
    f_ffree: u64,
    f_fsid: LinuxFsId,
    f_namelen: c_long,
    f_frsize: c_long,
    f_flags: c_long,
    f_spare: [4]c_long,
};

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

pub fn readDiskUsage() !DiskUsage {
    const linux = std.os.linux;
    var stats: LinuxStatFs = std.mem.zeroes(LinuxStatFs);
    const rc = linux.syscall2(.statfs, @intFromPtr("/"), @intFromPtr(&stats));
    if (linux.errno(rc) != .SUCCESS) return error.StatFsFailed;

    const raw_block_size = if (stats.f_frsize > 0) stats.f_frsize else stats.f_bsize;
    if (raw_block_size <= 0) return error.InvalidStatFs;

    const block_size: u64 = @intCast(raw_block_size);
    const total = stats.f_blocks *| block_size;
    const used_blocks = stats.f_blocks -| stats.f_bfree;
    return .{
        .total_bytes = total,
        .used_bytes = used_blocks *| block_size,
    };
}
