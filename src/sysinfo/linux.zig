const std = @import("std");
const common = @import("common.zig");

const CpuStats = common.CpuStats;
const MemStats = common.MemStats;
const ProcStats = common.ProcStats;
const ProcCpuEntry = common.ProcCpuEntry;
const MAX_CORES = common.MAX_CORES;
const MAX_PROCS = common.MAX_PROCS;

const CpuTick = struct {
    total: u64 = 0,
    active: u64 = 0,
};

const CpuSnapshot = struct {
    overall: CpuTick = .{},
    cores: [MAX_CORES]CpuTick = undefined,
    core_count: usize = 0,
};

const ParsedProcStat = struct {
    name: []const u8,
    cpu_total: u64,
};

pub const SysInfo = struct {
    prev_cpu_tick: CpuTick = .{},
    prev_core_ticks: [MAX_CORES]CpuTick = std.mem.zeroes([MAX_CORES]CpuTick),
    core_usage: [MAX_CORES]f32 = [_]f32{0} ** MAX_CORES,
    ncpu: u32,
    total_mem: u64,
    page_size: usize,
    prev_procs: [MAX_PROCS]ProcCpuEntry = undefined,
    prev_proc_count: usize = 0,
    prev_proc_total_ticks: u64 = 0,

    pub fn init() SysInfo {
        const initial_cores = @min(std.Thread.getCpuCount() catch 1, MAX_CORES);
        return .{
            .ncpu = @intCast(initial_cores),
            .total_mem = readMemInfoTotal() catch 0,
            .page_size = std.heap.pageSize(),
        };
    }

    fn usageFromTick(prev_tick: *CpuTick, current_tick: CpuTick) f32 {
        const prev_total = prev_tick.total;
        const delta_total = current_tick.total -| prev_tick.total;
        const delta_active = current_tick.active -| prev_tick.active;

        prev_tick.* = current_tick;

        if (prev_total == 0 or delta_total == 0) return 0;

        return @as(f32, @floatFromInt(delta_active)) / @as(f32, @floatFromInt(delta_total)) * 100.0;
    }

    pub fn getCpuStats(self: *SysInfo) CpuStats {
        const snapshot = readCpuSnapshot() catch {
            return .{ .usage_percent = 0, .cores = self.ncpu };
        };

        const usage = usageFromTick(&self.prev_cpu_tick, snapshot.overall);
        const core_count = if (snapshot.core_count > 0) snapshot.core_count else @as(usize, self.ncpu);
        self.ncpu = @intCast(core_count);

        for (0..snapshot.core_count) |i| {
            self.core_usage[i] = usageFromTick(&self.prev_core_ticks[i], snapshot.cores[i]);
        }

        return .{
            .usage_percent = usage,
            .cores = self.ncpu,
            .per_core_usage = self.core_usage[0..snapshot.core_count],
        };
    }

    pub fn getMemStats(self: *SysInfo) MemStats {
        const mem_info = readMemInfo() catch {
            return .{ .total = self.total_mem, .used = 0, .free = self.total_mem };
        };

        self.total_mem = mem_info.total;

        return .{
            .total = mem_info.total,
            .used = mem_info.used,
            .free = mem_info.free,
        };
    }

    fn findPrevCpuTotal(self: *const SysInfo, pid: u32) ?u64 {
        for (self.prev_procs[0..self.prev_proc_count]) |entry| {
            if (entry.pid == pid) return entry.cpu_total;
        }
        return null;
    }

    pub fn getProcStats(self: *SysInfo, allocator: std.mem.Allocator) ![]ProcStats {
        const snapshot = readCpuSnapshot() catch CpuSnapshot{};
        const total_tick_delta = if (self.prev_proc_total_ticks > 0) snapshot.overall.total -| self.prev_proc_total_ticks else 0;

        var proc_dir = try std.fs.openDirAbsolute("/proc", .{ .iterate = true });
        defer proc_dir.close();

        var iter = proc_dir.iterate();
        var result: std.ArrayList(ProcStats) = .empty;
        var new_procs: [MAX_PROCS]ProcCpuEntry = undefined;
        var new_proc_count: usize = 0;

        while (try iter.next()) |entry| {
            if (entry.kind != .directory) continue;
            const pid = std.fmt.parseInt(u32, entry.name, 10) catch continue;

            var pid_dir = proc_dir.openDir(entry.name, .{}) catch continue;
            defer pid_dir.close();

            var stat_buf: [4096]u8 = undefined;
            const stat_contents = readDirFile(&pid_dir, "stat", &stat_buf) catch continue;
            const proc_info = parseProcStat(stat_contents) orelse continue;

            var statm_buf: [128]u8 = undefined;
            const statm_contents = readDirFile(&pid_dir, "statm", &statm_buf) catch continue;
            const resident_pages = parseResidentPages(statm_contents) orelse continue;
            const resident_size = resident_pages * self.page_size;

            if (new_proc_count < MAX_PROCS) {
                new_procs[new_proc_count] = .{ .pid = pid, .cpu_total = proc_info.cpu_total };
                new_proc_count += 1;
            }

            var cpu_percent: f32 = 0;
            if (total_tick_delta > 0) {
                if (self.findPrevCpuTotal(pid)) |prev_total| {
                    if (proc_info.cpu_total >= prev_total) {
                        const delta_cpu = proc_info.cpu_total - prev_total;
                        cpu_percent = @as(f32, @floatFromInt(delta_cpu * self.ncpu)) / @as(f32, @floatFromInt(total_tick_delta)) * 100.0;
                    }
                }
            }

            const mem_percent: f32 = if (self.total_mem > 0)
                @as(f32, @floatFromInt(resident_size)) / @as(f32, @floatFromInt(self.total_mem)) * 100.0
            else
                0;

            const name = if (proc_info.name.len > 63) proc_info.name[0..63] else proc_info.name;
            var proc_stat = ProcStats{
                .pid = pid,
                .cpu_percent = cpu_percent,
                .mem_percent = mem_percent,
                .name_len = @intCast(name.len),
            };
            @memcpy(proc_stat.name_buf[0..name.len], name);
            try result.append(allocator, proc_stat);
        }

        @memcpy(self.prev_procs[0..new_proc_count], new_procs[0..new_proc_count]);
        self.prev_proc_count = new_proc_count;
        self.prev_proc_total_ticks = snapshot.overall.total;

        const slice = try result.toOwnedSlice(allocator);
        common.sortProcStats(slice);
        return slice;
    }
};

fn readDirFile(dir: *std.fs.Dir, sub_path: []const u8, buf: []u8) ![]const u8 {
    var file = try dir.openFile(sub_path, .{});
    defer file.close();
    const len = try file.readAll(buf);
    return buf[0..len];
}

fn readAbsoluteFile(path: []const u8, buf: []u8) ![]const u8 {
    var file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    const len = try file.readAll(buf);
    return buf[0..len];
}

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

fn readCpuSnapshot() !CpuSnapshot {
    var buf: [16384]u8 = undefined;
    const contents = try readAbsoluteFile("/proc/stat", &buf);

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

fn parseProcStat(contents: []const u8) ?ParsedProcStat {
    const line = std.mem.trimRight(u8, contents, "\n");
    const open_paren = std.mem.indexOfScalar(u8, line, '(') orelse return null;
    const close_paren = std.mem.lastIndexOfScalar(u8, line, ')') orelse return null;
    if (close_paren <= open_paren) return null;

    const name = line[open_paren + 1 .. close_paren];
    const rest = std.mem.trimLeft(u8, line[close_paren + 1 ..], " ");
    var fields = std.mem.tokenizeAny(u8, rest, " ");
    var field_number: usize = 3;
    var utime: ?u64 = null;
    var stime: ?u64 = null;

    while (fields.next()) |field| : (field_number += 1) {
        if (field_number == 14) {
            utime = std.fmt.parseInt(u64, field, 10) catch return null;
        } else if (field_number == 15) {
            stime = std.fmt.parseInt(u64, field, 10) catch return null;
            break;
        }
    }

    return .{
        .name = name,
        .cpu_total = (utime orelse return null) + (stime orelse return null),
    };
}

fn parseResidentPages(contents: []const u8) ?u64 {
    var fields = std.mem.tokenizeAny(u8, contents, " \t\n");
    _ = fields.next() orelse return null;
    const resident = fields.next() orelse return null;
    return std.fmt.parseInt(u64, resident, 10) catch null;
}

fn readMemInfoTotal() !u64 {
    const mem_info = try readMemInfo();
    return mem_info.total;
}

fn readMemInfo() !struct { total: u64, used: u64, free: u64 } {
    var buf: [4096]u8 = undefined;
    const contents = try readAbsoluteFile("/proc/meminfo", &buf);

    var total_kb: ?u64 = null;
    var available_kb: ?u64 = null;

    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "MemTotal:")) {
            total_kb = parseMemInfoValue(line);
        } else if (std.mem.startsWith(u8, line, "MemAvailable:")) {
            available_kb = parseMemInfoValue(line);
        }
    }

    const total = (total_kb orelse return error.UnexpectedProcMemInfo) * 1024;
    const free = (available_kb orelse return error.UnexpectedProcMemInfo) * 1024;
    const used = total -| free;
    return .{ .total = total, .used = used, .free = free };
}

fn parseMemInfoValue(line: []const u8) ?u64 {
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return null;
    var fields = std.mem.tokenizeAny(u8, line[colon + 1 ..], " \t");
    const value = fields.next() orelse return null;
    return std.fmt.parseInt(u64, value, 10) catch null;
}
