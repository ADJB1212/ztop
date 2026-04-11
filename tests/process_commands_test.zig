const std = @import("std");
const common = @import("ztop").sysinfo.common;
const process_commands = @import("ztop").process_commands;

fn proc(pid: u32, ppid: u32, state: common.ProcState) common.ProcStats {
    return .{
        .pid = pid,
        .ppid = ppid,
        .state = state,
    };
}

test "collectZombieParents groups zombies by visible parent process" {
    const procs = [_]common.ProcStats{
        proc(100, 1, .running),
        proc(101, 1, .sleeping),
        proc(200, 100, .zombie),
        proc(201, 100, .zombie),
        proc(202, 101, .zombie),
        proc(300, 999, .zombie),
        proc(301, 0, .zombie),
    };

    var out: [8]process_commands.ZombieParentEntry = undefined;
    const summary = process_commands.collectZombieParents(&procs, &out);

    try std.testing.expectEqual(@as(usize, 2), summary.parent_count);
    try std.testing.expectEqual(@as(usize, 5), summary.zombie_count);
    try std.testing.expectEqual(@as(u32, 100), out[0].pid);
    try std.testing.expectEqual(@as(u32, 2), out[0].zombie_count);
    try std.testing.expectEqual(@as(u32, 101), out[1].pid);
    try std.testing.expectEqual(@as(u32, 1), out[1].zombie_count);
}

test "containsParentPid matches collected parent processes" {
    const entries = [_]process_commands.ZombieParentEntry{
        .{ .pid = 42, .zombie_count = 1 },
        .{ .pid = 77, .zombie_count = 3 },
    };

    try std.testing.expect(process_commands.containsParentPid(&entries, 42));
    try std.testing.expect(process_commands.containsParentPid(&entries, 77));
    try std.testing.expect(!process_commands.containsParentPid(&entries, 99));
}

test "buildTreeView correctly orders hierarchy" {
    const procs = [_]common.ProcStats{
        proc(1, 0, .running), // Root
        proc(10, 1, .sleeping), // Child of 1
        proc(11, 1, .sleeping), // Child of 1
        proc(100, 10, .running), // Child of 10
        proc(2, 0, .running), // Another Root
    };

    var indices: [5]usize = undefined;
    var depths: [5]u8 = undefined;
    var is_lasts: [5]u16 = undefined;

    const count = process_commands.buildTreeView(
        std.testing.allocator,
        &procs,
        &indices,
        &depths,
        &is_lasts,
    );

    try std.testing.expectEqual(@as(usize, 5), count);

    // Expected order: 1, 10, 100, 11, 2
    try std.testing.expectEqual(@as(usize, 0), indices[0]); // pid 1
    try std.testing.expectEqual(@as(u8, 0), depths[0]);

    try std.testing.expectEqual(@as(usize, 1), indices[1]); // pid 10
    try std.testing.expectEqual(@as(u8, 1), depths[1]);
    // 10 is NOT last child of 1 (11 is)
    try std.testing.expectEqual(@as(u16, 0), is_lasts[1] & 1);

    try std.testing.expectEqual(@as(usize, 3), indices[2]); // pid 100
    try std.testing.expectEqual(@as(u8, 2), depths[2]);
    // 100 is last child of 10
    try std.testing.expectEqual(@as(u16, 2), is_lasts[2] & 2);

    try std.testing.expectEqual(@as(usize, 2), indices[3]); // pid 11
    try std.testing.expectEqual(@as(u8, 1), depths[3]);
    // 11 is last child of 1
    try std.testing.expectEqual(@as(u16, 1), is_lasts[3] & 1);

    try std.testing.expectEqual(@as(usize, 4), indices[4]); // pid 2
    try std.testing.expectEqual(@as(u8, 0), depths[4]);
}
