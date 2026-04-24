const std = @import("std");
const common = @import("../../sysinfo/common.zig");
const io_util = @import("io_util.zig");

const MAX_CORES = common.MAX_CORES;

pub const CpuTick = struct {
    total: u64 = 0,
    active: u64 = 0,
};

pub const CpuSnapshot = struct {
    overall: CpuTick = .{},
    cores: [MAX_CORES]CpuTick = undefined,
    core_count: usize = 0,
};

fn parseCpuStatLine(line: []const u8) ?struct { label: []const u8, tick: CpuTick } {
    var fields = std.mem.tokenizeAny(u8, line, " \t");
    const label = fields.next() orelse return null;
    if (!std.mem.startsWith(u8, label, "cpu")) return null;

    var total: u64 = 0;
    var idle: u64 = 0;
    var iowait: u64 = 0;
    var value_index: usize = 0;

    while (fields.next()) |field| : (value_index += 1) {
        const value = std.fmt.parseInt(u64, field, 10) catch return null;
        total += value;
        if (value_index == 3) idle = value;
        if (value_index == 4) iowait = value;
    }

    if (value_index < 4) return null;

    return .{
        .label = label,
        .tick = .{
            .total = total,
            .active = total -| (idle + iowait),
        },
    };
}

pub fn readCpuSnapshot(io: std.Io) !CpuSnapshot {
    var buf: [16384]u8 = undefined;
    const contents = try io_util.readAbsoluteFile(io, "/proc/stat", &buf);

    var snapshot = CpuSnapshot{};
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        const parsed = parseCpuStatLine(line) orelse continue;
        if (std.mem.eql(u8, parsed.label, "cpu")) {
            snapshot.overall = parsed.tick;
            continue;
        }

        if (snapshot.core_count >= MAX_CORES) continue;
        if (parsed.label.len > 3 and std.ascii.isDigit(parsed.label[3])) {
            snapshot.cores[snapshot.core_count] = parsed.tick;
            snapshot.core_count += 1;
        }
    }

    return snapshot;
}
