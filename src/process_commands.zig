const common = @import("sysinfo/common.zig");

pub const ZombieParentEntry = struct {
    pid: u32,
    zombie_count: u32,
};

pub const ZombieParentSummary = struct {
    parent_count: usize = 0,
    zombie_count: usize = 0,
};

pub fn collectZombieParents(procs: []const common.ProcStats, out: []ZombieParentEntry) ZombieParentSummary {
    var summary: ZombieParentSummary = .{};

    for (procs) |proc| {
        if (proc.state != .zombie) continue;

        summary.zombie_count += 1;
        if (proc.ppid == 0 or !hasProcess(procs, proc.ppid)) continue;

        var found = false;
        for (out[0..summary.parent_count]) |*entry| {
            if (entry.pid != proc.ppid) continue;
            entry.zombie_count += 1;
            found = true;
            break;
        }

        if (found or summary.parent_count >= out.len) continue;

        out[summary.parent_count] = .{
            .pid = proc.ppid,
            .zombie_count = 1,
        };
        summary.parent_count += 1;
    }

    return summary;
}

pub fn containsParentPid(entries: []const ZombieParentEntry, pid: u32) bool {
    for (entries) |entry| {
        if (entry.pid == pid) return true;
    }
    return false;
}

fn hasProcess(procs: []const common.ProcStats, pid: u32) bool {
    for (procs) |proc| {
        if (proc.pid == pid) return true;
    }
    return false;
}
