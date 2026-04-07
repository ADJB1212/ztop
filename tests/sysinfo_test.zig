const std = @import("std");
const SysInfo = @import("ztop").sysinfo.SysInfo;

test "SysInfo initializes and fetches CPU stats" {
    var sys_info = SysInfo.init();
    const cpu = sys_info.getCpuStats();
    try std.testing.expect(cpu.cores > 0);
    try std.testing.expect(cpu.usage_percent >= 0.0);
}

test "SysInfo fetches Mem stats" {
    var sys_info = SysInfo.init();
    const mem = sys_info.getMemStats();
    try std.testing.expect(mem.total > 0);
    try std.testing.expect(mem.free <= mem.total);
}

test "SysInfo fetches Proc stats" {
    var sys_info = SysInfo.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const procs = try sys_info.getProcStats(allocator, .cpu);
    try std.testing.expect(procs.len > 0);

    // Check that at least one process has a valid state and name
    var valid_found = false;
    for (procs) |p| {
        if (p.name_len > 0) {
            valid_found = true;
            break;
        }
    }
    try std.testing.expect(valid_found);
}
