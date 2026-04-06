const std = @import("std");
const common = @import("ztop").sysinfo.common;

test "kbToBytes conversion" {
    try std.testing.expectEqual(1024, common.kbToBytes(1));
    try std.testing.expectEqual(2048, common.kbToBytes(2));
    try std.testing.expectEqual(0, common.kbToBytes(0));
}

test "ProcStats name slice" {
    var proc = common.ProcStats{
        .pid = 1234,
        .name_len = 4,
        .name_buf = std.mem.zeroes([64]u8),
    };
    std.mem.copyForwards(u8, &proc.name_buf, "test");

    try std.testing.expectEqualStrings("test", proc.name());
}

test "ProcStats defaults" {
    const proc = common.ProcStats{
        .pid = 1234,
    };
    try std.testing.expectEqual(@as(u32, 1234), proc.pid);
    try std.testing.expectEqual(@as(u32, 0), proc.ppid);
    try std.testing.expectEqual(common.ProcState.unknown, proc.state);
}

test "sortProcStats by cpu" {
    var procs = [_]common.ProcStats{
        .{ .pid = 1, .cpu_percent = 5.0 },
        .{ .pid = 2, .cpu_percent = 20.0 },
        .{ .pid = 3, .cpu_percent = 10.0 },
    };

    common.sortProcStats(&procs, .cpu);

    try std.testing.expectEqual(@as(u32, 2), procs[0].pid);
    try std.testing.expectEqual(@as(u32, 3), procs[1].pid);
    try std.testing.expectEqual(@as(u32, 1), procs[2].pid);
}

test "sortProcStats by mem" {
    var procs = [_]common.ProcStats{
        .{ .pid = 1, .mem_percent = 5.0 },
        .{ .pid = 2, .mem_percent = 20.0 },
        .{ .pid = 3, .mem_percent = 10.0 },
    };

    common.sortProcStats(&procs, .mem);

    try std.testing.expectEqual(@as(u32, 2), procs[0].pid);
    try std.testing.expectEqual(@as(u32, 3), procs[1].pid);
    try std.testing.expectEqual(@as(u32, 1), procs[2].pid);
}

test "sortProcStats by pid" {
    var procs = [_]common.ProcStats{
        .{ .pid = 3, .cpu_percent = 5.0 },
        .{ .pid = 1, .cpu_percent = 20.0 },
        .{ .pid = 2, .cpu_percent = 10.0 },
    };

    common.sortProcStats(&procs, .pid);

    try std.testing.expectEqual(@as(u32, 1), procs[0].pid);
    try std.testing.expectEqual(@as(u32, 2), procs[1].pid);
    try std.testing.expectEqual(@as(u32, 3), procs[2].pid);
}

test "sortProcStats by name" {
    var procs = [_]common.ProcStats{
        .{ .pid = 1, .name_buf = std.mem.zeroes([64]u8), .name_len = 1 },
        .{ .pid = 2, .name_buf = std.mem.zeroes([64]u8), .name_len = 1 },
        .{ .pid = 3, .name_buf = std.mem.zeroes([64]u8), .name_len = 1 },
    };
    procs[0].name_buf[0] = 'C';
    procs[1].name_buf[0] = 'A';
    procs[2].name_buf[0] = 'B';

    common.sortProcStats(&procs, .name);

    try std.testing.expectEqual(@as(u32, 2), procs[0].pid);
    try std.testing.expectEqual(@as(u32, 3), procs[1].pid);
    try std.testing.expectEqual(@as(u32, 1), procs[2].pid);
}
