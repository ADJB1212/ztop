const std = @import("std");
const common = @import("../../sysinfo/common.zig");
const io_util = @import("io_util.zig");

const MemStats = common.MemStats;

pub fn readMemInfoTotal(io: std.Io) !u64 {
    const mem_info = try readMemInfo(io);
    return mem_info.total;
}

pub fn readMemInfo(io: std.Io) !MemStats {
    var buf: [4096]u8 = undefined;
    const contents = try io_util.readAbsoluteFile(io, "/proc/meminfo", &buf);

    var total_kb: ?u64 = null;
    var available_kb: ?u64 = null;
    var cached_kb: ?u64 = null;
    var buffered_kb: ?u64 = null;
    var swap_total_kb: ?u64 = null;
    var swap_free_kb: ?u64 = null;

    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "MemTotal:")) {
            total_kb = parseMemInfoValue(line);
        } else if (std.mem.startsWith(u8, line, "MemAvailable:")) {
            available_kb = parseMemInfoValue(line);
        } else if (std.mem.startsWith(u8, line, "Cached:")) {
            cached_kb = parseMemInfoValue(line);
        } else if (std.mem.startsWith(u8, line, "Buffers:")) {
            buffered_kb = parseMemInfoValue(line);
        } else if (std.mem.startsWith(u8, line, "SwapTotal:")) {
            swap_total_kb = parseMemInfoValue(line);
        } else if (std.mem.startsWith(u8, line, "SwapFree:")) {
            swap_free_kb = parseMemInfoValue(line);
        }
    }

    const total = common.kbToBytes(total_kb orelse return error.UnexpectedProcMemInfo);
    const free = common.kbToBytes(available_kb orelse return error.UnexpectedProcMemInfo);
    const used = total -| free;
    const cached = common.kbToBytes(cached_kb orelse 0);
    const buffered = common.kbToBytes(buffered_kb orelse 0);
    const swap_total = common.kbToBytes(swap_total_kb orelse 0);
    const swap_free = common.kbToBytes(swap_free_kb orelse 0);
    const swap_used = swap_total -| swap_free;

    return .{
        .total = total,
        .used = used,
        .free = free,
        .cached = cached,
        .buffered = buffered,
        .swap_total = swap_total,
        .swap_used = swap_used,
    };
}

fn parseMemInfoValue(line: []const u8) ?u64 {
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return null;
    var fields = std.mem.tokenizeAny(u8, line[colon + 1 ..], " \t");
    const value = fields.next() orelse return null;
    return std.fmt.parseInt(u64, value, 10) catch null;
}
