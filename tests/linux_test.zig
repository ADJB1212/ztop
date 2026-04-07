const std = @import("std");
const linux = @import("ztop").sysinfo.sys_linux;
const common = @import("ztop").sysinfo.common;

test "parseProcStat parses running process" {
    const stat_contents = "1234 (bash) R 1000 1234 1234 0 -1 4194560 123 0 0 0 100 200 0 0 20 0 1 0 1234567 4096 123";
    const parsed = linux.parseProcStat(stat_contents);
    try std.testing.expect(parsed != null);
    if (parsed) |p| {
        try std.testing.expectEqualStrings("bash", p.name);
        try std.testing.expectEqual(common.ProcState.running, p.state);
        try std.testing.expectEqual(@as(u32, 1000), p.ppid);
        try std.testing.expectEqual(@as(u64, 300), p.cpu_total);
        try std.testing.expectEqual(@as(u32, 1), p.num_threads);
    }
}

test "parseProcStat parses zombie process" {
    const stat_contents = "9999 (defunct_proc) Z 1 9999 9999 0 -1 4194560 0 0 0 0 0 0 0 0 20 0 1 0 1234567 0 0";
    const parsed = linux.parseProcStat(stat_contents);
    try std.testing.expect(parsed != null);
    if (parsed) |p| {
        try std.testing.expectEqualStrings("defunct_proc", p.name);
        try std.testing.expectEqual(common.ProcState.zombie, p.state);
        try std.testing.expectEqual(@as(u32, 1), p.ppid);
        try std.testing.expectEqual(@as(u64, 0), p.cpu_total);
        try std.testing.expectEqual(@as(u32, 1), p.num_threads);
    }
}

test "parseProcStat parses process with spaces in name" {
    const stat_contents = "5678 (a b c d) S 2000 5678 5678 0 -1 4194560 0 0 0 0 50 10 0 0 20 0 4 0 1234567 0 0";
    const parsed = linux.parseProcStat(stat_contents);
    try std.testing.expect(parsed != null);
    if (parsed) |p| {
        try std.testing.expectEqualStrings("a b c d", p.name);
        try std.testing.expectEqual(common.ProcState.sleeping, p.state);
        try std.testing.expectEqual(@as(u32, 2000), p.ppid);
        try std.testing.expectEqual(@as(u64, 60), p.cpu_total);
        try std.testing.expectEqual(@as(u32, 4), p.num_threads);
    }
}

test "parseProcStat returns null on invalid input" {
    const invalid_contents = "invalid stat string without parens";
    try std.testing.expectEqual(null, linux.parseProcStat(invalid_contents));
}
