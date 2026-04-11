const std = @import("std");
const common = @import("sysinfo/common.zig");

pub const TreeBuilder = struct {
    first_child: []const usize,
    next_sibling: []const usize,
    indices: []usize,
    depths: []u8,
    is_lasts: []u16,
    count: *usize,

    pub fn walk(self: *@This(), idx: usize, depth: u8, is_last_mask: u16) void {
        if (self.count.* >= self.indices.len) return;

        self.indices[self.count.*] = idx;
        self.depths[self.count.*] = depth;
        self.is_lasts[self.count.*] = is_last_mask;
        self.count.* += 1;

        var child = self.first_child[idx];
        while (child != std.math.maxInt(usize)) {
            const next = self.next_sibling[child];
            const is_last_child = (next == std.math.maxInt(usize));
            const new_mask = if (is_last_child) (is_last_mask | (@as(u16, 1) << @as(u4, @intCast(depth)))) else is_last_mask;
            self.walk(child, depth + 1, new_mask);
            child = next;
        }
    }
};

pub fn buildTreeView(
    allocator: std.mem.Allocator,
    procs: []const common.ProcStats,
    indices: []usize,
    depths: []u8,
    is_lasts: []u16,
) usize {
    var count: usize = 0;
    if (procs.len == 0) return 0;

    var first_child_buf: [common.MAX_PROCS]usize = undefined;
    var next_sibling_buf: [common.MAX_PROCS]usize = undefined;
    var is_root: [common.MAX_PROCS]bool = undefined;

    for (0..procs.len) |i| {
        first_child_buf[i] = std.math.maxInt(usize);
        next_sibling_buf[i] = std.math.maxInt(usize);
        is_root[i] = true;
    }

    var pid_to_idx = std.AutoHashMap(u32, usize).init(allocator);
    defer pid_to_idx.deinit();

    for (procs, 0..) |proc, i| {
        pid_to_idx.put(proc.pid, i) catch {};
    }

    var idx: usize = procs.len;
    while (idx > 0) {
        idx -= 1;
        const proc = procs[idx];
        if (proc.ppid != 0 and proc.ppid != proc.pid) {
            if (pid_to_idx.get(proc.ppid)) |parent_idx| {
                next_sibling_buf[idx] = first_child_buf[parent_idx];
                first_child_buf[parent_idx] = idx;
                is_root[idx] = false;
            }
        }
    }

    var builder = TreeBuilder{
        .first_child = first_child_buf[0..procs.len],
        .next_sibling = next_sibling_buf[0..procs.len],
        .indices = indices,
        .depths = depths,
        .is_lasts = is_lasts,
        .count = &count,
    };

    for (procs, 0..) |_, i| {
        if (is_root[i]) {
            builder.walk(i, 0, 0);
        }
    }

    return count;
}

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
