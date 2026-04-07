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
