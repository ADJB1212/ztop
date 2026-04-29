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

pub const BuildStage = enum {
    compile,
    link,
    test_run,
    package,
    other,

    pub fn label(self: @This()) []const u8 {
        return switch (self) {
            .compile => "compile",
            .link => "link",
            .test_run => "test",
            .package => "package",
            .other => "build",
        };
    }
};

pub const MAX_PIPELINE_GROUPS = 16;
pub const MAX_PIPELINE_CHILDREN = 32;

pub const PipelineGroup = struct {
    root_pid: u32,
    root_name_buf: [64]u8,
    root_name_len: u8,
    total_cpu: f32,
    total_mem: f32,
    total_disk_read_ps: u64,
    total_disk_write_ps: u64,
    child_pids: [MAX_PIPELINE_CHILDREN]u32,
    child_stages: [MAX_PIPELINE_CHILDREN]BuildStage,
    child_count: u8,

    pub fn rootName(self: *const @This()) []const u8 {
        return self.root_name_buf[0..self.root_name_len];
    }
};

fn isBuildRoot(name: []const u8) bool {
    const roots = [_][]const u8{
        "make",       "gmake",  "cmake", "ninja", "cargo", "go",
        "zig",        "gradle", "mvn",   "ant",   "bazel", "buck",
        "sbt",        "mix",    "npm",   "yarn",  "pnpm",  "pytest",
        "jest",       "mocha",  "meson", "rake",  "tup",   "rebar3",
        "xcodebuild", "swift",
    };
    for (roots) |root| {
        if (std.mem.eql(u8, name, root)) return true;
    }
    return false;
}

pub fn detectBuildStage(name: []const u8) BuildStage {
    const compilers = [_][]const u8{
        "cc",    "gcc",     "clang",  "clang++", "g++", "c++", "rustc",
        "javac", "kotlinc", "scalac", "swiftc",  "tsc", "cc1", "cc1plus",
    };
    for (compilers) |c| {
        if (std.mem.eql(u8, name, c)) return .compile;
    }

    const linkers = [_][]const u8{ "ld", "lld", "gold", "ld.lld", "ld64", "link", "mold" };
    for (linkers) |l| {
        if (std.mem.eql(u8, name, l)) return .link;
    }

    const testers = [_][]const u8{ "pytest", "jest", "mocha", "jasmine", "karma", "phpunit", "rspec" };
    for (testers) |t| {
        if (std.mem.eql(u8, name, t)) return .test_run;
    }

    const packagers = [_][]const u8{ "ar", "strip", "zip", "tar", "objcopy", "ranlib", "libtool" };
    for (packagers) |p| {
        if (std.mem.eql(u8, name, p)) return .package;
    }

    return .other;
}

pub fn buildPipelineGroups(
    allocator: std.mem.Allocator,
    procs: []const common.ProcStats,
    groups: []PipelineGroup,
) usize {
    var group_count: usize = 0;
    if (procs.len == 0) return 0;

    var pid_to_idx = std.AutoHashMap(u32, usize).init(allocator);
    defer pid_to_idx.deinit();
    for (procs, 0..) |proc, i| {
        pid_to_idx.put(proc.pid, i) catch {};
    }

    // Pass 1: create groups for root build processes
    for (procs) |proc| {
        if (!isBuildRoot(proc.name())) continue;
        if (group_count >= groups.len) break;
        const g = &groups[group_count];
        g.root_pid = proc.pid;
        g.root_name_buf = std.mem.zeroes([64]u8);
        g.root_name_len = proc.name_len;
        g.total_cpu = proc.cpu_percent;
        g.total_mem = proc.mem_percent;
        g.total_disk_read_ps = proc.disk_read_ps;
        g.total_disk_write_ps = proc.disk_write_ps;
        g.child_pids = std.mem.zeroes([MAX_PIPELINE_CHILDREN]u32);
        g.child_count = 0;
        @memcpy(g.root_name_buf[0..proc.name_len], proc.name());
        group_count += 1;
    }

    if (group_count == 0) return 0;

    var root_to_group = std.AutoHashMap(u32, usize).init(allocator);
    defer root_to_group.deinit();
    for (0..group_count) |gi| {
        root_to_group.put(groups[gi].root_pid, gi) catch {};
    }

    // Pass 2: assign children by walking PPID chain
    for (procs) |proc| {
        if (root_to_group.contains(proc.pid)) continue;

        var ppid = proc.ppid;
        var depth: u8 = 0;
        while (depth < 8 and ppid != 0 and ppid != proc.pid) : (depth += 1) {
            if (root_to_group.get(ppid)) |gi| {
                const g = &groups[gi];
                if (g.child_count < MAX_PIPELINE_CHILDREN) {
                    const ci = g.child_count;
                    g.child_pids[ci] = proc.pid;
                    g.child_stages[ci] = detectBuildStage(proc.name());
                    g.child_count += 1;
                    g.total_cpu += proc.cpu_percent;
                    g.total_mem += proc.mem_percent;
                    g.total_disk_read_ps += proc.disk_read_ps;
                    g.total_disk_write_ps += proc.disk_write_ps;
                }
                break;
            }
            if (pid_to_idx.get(ppid)) |parent_idx| {
                const parent = procs[parent_idx];
                if (parent.ppid == ppid) break;
                ppid = parent.ppid;
            } else break;
        }
    }

    return group_count;
}
