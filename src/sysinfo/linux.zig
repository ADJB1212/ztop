const std = @import("std");
const common = @import("common.zig");

const CpuStats = common.CpuStats;
const CpuTopology = common.CpuTopology;
const CpuLogicalCore = common.CpuLogicalCore;
const MemStats = common.MemStats;
const DiskStats = common.DiskStats;
const NetStats = common.NetStats;
const ThermalStats = common.ThermalStats;
const BatteryStats = common.BatteryStats;
const BatteryStatus = common.BatteryStatus;
const CpuEfficiencyClass = common.CpuEfficiencyClass;
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

pub const ParsedProcStat = struct {
    name: []const u8,
    state: common.ProcState,
    ppid: u32,
    cpu_total: u64,
    num_threads: u32,
};

pub const CpuListInfo = struct {
    count: usize = 0,
    first: ?u16 = null,
    target_index: ?usize = null,
};

const MAX_THREADS = common.MAX_THREADS;

pub const SysInfo = struct {
    prev_cpu_tick: CpuTick = .{},
    prev_core_ticks: [MAX_CORES]CpuTick = std.mem.zeroes([MAX_CORES]CpuTick),
    core_usage: [MAX_CORES]f32 = [_]f32{0} ** MAX_CORES,
    ncpu: u32,
    topology_cores: [MAX_CORES]CpuLogicalCore = undefined,
    topology_count: usize = 0,
    topology_physical_cores: u16 = 0,
    topology_package_count: u16 = 1,
    topology_numa_count: u16 = 0,
    topology_has_numa: bool = false,
    topology_has_cache_groups: bool = false,
    total_mem: u64,
    page_size: usize,
    prev_procs: [MAX_PROCS]ProcCpuEntry = undefined,
    prev_proc_count: usize = 0,
    prev_proc_total_ticks: u64 = 0,
    prev_threads: [MAX_THREADS]common.ThreadCpuEntry = undefined,
    prev_thread_count: usize = 0,
    prev_thread_total_ticks: u64 = 0,
    thread_view_pid: u32 = 0,
    prev_disk_read: u64 = 0,
    prev_disk_write: u64 = 0,
    prev_net_rx: u64 = 0,
    prev_net_tx: u64 = 0,
    prev_time: i64 = 0,
    prev_disk_ms: i64 = 0,
    prev_net_ms: i64 = 0,

    pub fn init() SysInfo {
        const initial_cores = @min(std.Thread.getCpuCount() catch 1, MAX_CORES);
        const now = std.time.milliTimestamp();
        var self: SysInfo = .{
            .ncpu = @intCast(initial_cores),
            .total_mem = readMemInfoTotal() catch 0,
            .page_size = std.heap.pageSize(),
            .prev_time = now,
            .prev_disk_ms = now,
            .prev_net_ms = now,
        };
        self.loadTopology();
        return self;
    }

    fn loadTopology(self: *SysInfo) void {
        readCpuTopology(self) catch self.synthesizeTopology(@intCast(self.ncpu));
    }

    fn synthesizeTopology(self: *SysInfo, logical_count: usize) void {
        const bounded_logical = @min(logical_count, MAX_CORES);
        self.topology_count = bounded_logical;
        self.topology_physical_cores = @intCast(bounded_logical);
        self.topology_package_count = 1;
        self.topology_numa_count = 0;
        self.topology_has_numa = false;
        self.topology_has_cache_groups = false;

        for (0..bounded_logical) |logical_id| {
            self.topology_cores[logical_id] = .{
                .logical_id = @intCast(logical_id),
                .physical_id = @intCast(logical_id),
                .package_id = 0,
                .numa_node_id = -1,
                .thread_index = 0,
                .threads_per_core = 1,
                .shared_cache_group_id = -1,
                .shared_cache_level = 0,
                .shared_cache_logical_count = 0,
                .efficiency_class = .unknown,
            };
        }
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
        if (self.topology_count == 0 or self.topology_count != core_count) {
            self.loadTopology();
        }

        for (0..snapshot.core_count) |i| {
            self.core_usage[i] = usageFromTick(&self.prev_core_ticks[i], snapshot.cores[i]);
        }

        return .{
            .usage_percent = usage,
            .cores = self.ncpu,
            .per_core_usage = self.core_usage[0..snapshot.core_count],
        };
    }

    pub fn getCpuTopology(self: *const SysInfo) CpuTopology {
        return .{
            .logical_cores = self.topology_cores[0..self.topology_count],
            .physical_cores = self.topology_physical_cores,
            .package_count = self.topology_package_count,
            .numa_node_count = self.topology_numa_count,
            .has_numa = self.topology_has_numa,
            .has_smt = self.topology_physical_cores > 0 and self.topology_count > self.topology_physical_cores,
            .has_cache_groups = self.topology_has_cache_groups,
            .has_efficiency_classes = false,
        };
    }

    pub fn getMemStats(self: *SysInfo) MemStats {
        const mem_info = readMemInfo() catch {
            return .{ .total = self.total_mem, .used = 0, .free = self.total_mem, .cached = 0, .buffered = 0, .swap_total = 0, .swap_used = 0 };
        };

        self.total_mem = mem_info.total;

        return mem_info;
    }

    pub fn getDiskStats(self: *SysInfo) DiskStats {
        const stats = readDiskStats() catch .{ .read_bytes = 0, .write_bytes = 0 };
        const now = std.time.milliTimestamp();
        const elapsed = now - self.prev_disk_ms;

        var read_ps: u64 = 0;
        var write_ps: u64 = 0;

        if (elapsed > 0 and self.prev_disk_read > 0) {
            const d_read = stats.read_bytes -| self.prev_disk_read;
            const d_write = stats.write_bytes -| self.prev_disk_write;
            read_ps = (d_read *| 1000) / @as(u64, @intCast(elapsed));
            write_ps = (d_write *| 1000) / @as(u64, @intCast(elapsed));
        }

        self.prev_disk_read = stats.read_bytes;
        self.prev_disk_write = stats.write_bytes;
        self.prev_disk_ms = now;

        return .{ .read_bytes_ps = read_ps, .write_bytes_ps = write_ps };
    }

    pub fn getNetStats(self: *SysInfo) NetStats {
        const stats = readNetStats() catch .{ .rx_bytes = 0, .tx_bytes = 0 };
        const now = std.time.milliTimestamp();
        const elapsed = now - self.prev_net_ms;

        var rx_ps: u64 = 0;
        var tx_ps: u64 = 0;

        if (elapsed > 0 and self.prev_net_rx > 0) {
            const d_rx = stats.rx_bytes -| self.prev_net_rx;
            const d_tx = stats.tx_bytes -| self.prev_net_tx;
            rx_ps = (d_rx * 1000) / @as(u64, @intCast(elapsed));
            tx_ps = (d_tx * 1000) / @as(u64, @intCast(elapsed));
        }

        self.prev_net_rx = stats.rx_bytes;
        self.prev_net_tx = stats.tx_bytes;
        self.prev_net_ms = now;

        return .{
            .rx_bytes_ps = rx_ps,
            .tx_bytes_ps = tx_ps,
            .rx_bytes = stats.rx_bytes,
            .tx_bytes = stats.tx_bytes,
        };
    }

    pub fn getThermalStats(self: *SysInfo) ThermalStats {
        _ = self;
        var buf: [64]u8 = undefined;
        const contents = readAbsoluteFile("/sys/class/thermal/thermal_zone0/temp", &buf) catch return .{};
        const temp_str = std.mem.trim(u8, contents, " \n");
        const milli_c = std.fmt.parseInt(i32, temp_str, 10) catch return .{};
        return .{ .cpu_temp = @as(f32, @floatFromInt(milli_c)) / 1000.0, .gpu_temp = null };
    }

    pub fn getBatteryStats(self: *SysInfo) BatteryStats {
        _ = self;
        var buf_cap: [64]u8 = undefined;
        var buf_stat: [64]u8 = undefined;
        var buf_power: [64]u8 = undefined;

        var charge_percent: ?f32 = null;
        if (readAbsoluteFile("/sys/class/power_supply/BAT0/capacity", &buf_cap)) |cap| {
            const val = std.fmt.parseInt(u32, std.mem.trim(u8, cap, " \n"), 10) catch 0;
            charge_percent = @as(f32, @floatFromInt(val));
        } else |_| {}

        var status: BatteryStatus = .unknown;
        if (readAbsoluteFile("/sys/class/power_supply/BAT0/status", &buf_stat)) |stat| {
            const s = std.mem.trim(u8, stat, " \n");
            if (std.mem.eql(u8, s, "Charging")) {
                status = .charging;
            } else if (std.mem.eql(u8, s, "Discharging")) {
                status = .discharging;
            } else if (std.mem.eql(u8, s, "Full")) {
                status = .full;
            }
        } else |_| {}

        var power_draw_w: ?f32 = null;
        if (readAbsoluteFile("/sys/class/power_supply/BAT0/power_now", &buf_power)) |power| {
            const val = std.fmt.parseInt(u64, std.mem.trim(u8, power, " \n"), 10) catch 0;
            power_draw_w = @as(f32, @floatFromInt(val)) / 1000000.0;
        } else |_| {}

        return .{ .charge_percent = charge_percent, .power_draw_w = power_draw_w, .status = status };
    }

    fn findPrevProcEntry(self: *const SysInfo, pid: u32) ?ProcCpuEntry {
        for (self.prev_procs[0..self.prev_proc_count]) |entry| {
            if (entry.pid == pid) return entry;
        }
        return null;
    }

    pub fn getProcStats(self: *SysInfo, allocator: std.mem.Allocator, sort_by: common.SortBy) ![]ProcStats {
        const snapshot = readCpuSnapshot() catch CpuSnapshot{};
        const total_tick_delta = if (self.prev_proc_total_ticks > 0) snapshot.overall.total -| self.prev_proc_total_ticks else 0;

        const now = std.time.milliTimestamp();
        const elapsed_ms = now - self.prev_time;

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

            var io_buf: [1024]u8 = undefined;
            var disk_read: u64 = 0;
            var disk_write: u64 = 0;
            if (readDirFile(&pid_dir, "io", &io_buf)) |io_contents| {
                var lines = std.mem.splitScalar(u8, io_contents, '\n');
                while (lines.next()) |line| {
                    if (std.mem.startsWith(u8, line, "read_bytes:")) {
                        disk_read = std.fmt.parseInt(u64, std.mem.trim(u8, line[11..], " \t"), 10) catch 0;
                    } else if (std.mem.startsWith(u8, line, "write_bytes:")) {
                        disk_write = std.fmt.parseInt(u64, std.mem.trim(u8, line[12..], " \t"), 10) catch 0;
                    }
                }
            } else |_| {}

            if (new_proc_count < MAX_PROCS) {
                new_procs[new_proc_count] = .{ .pid = pid, .cpu_total = proc_info.cpu_total, .disk_read = disk_read, .disk_write = disk_write };
                new_proc_count += 1;
            }

            var cpu_percent: f32 = 0;
            var disk_read_ps: u64 = 0;
            var disk_write_ps: u64 = 0;

            const prev_entry = self.findPrevProcEntry(pid);

            if (prev_entry) |prev| {
                if (total_tick_delta > 0) {
                    if (proc_info.cpu_total >= prev.cpu_total) {
                        const delta_cpu = proc_info.cpu_total - prev.cpu_total;
                        cpu_percent = @as(f32, @floatFromInt(delta_cpu * self.ncpu)) / @as(f32, @floatFromInt(total_tick_delta)) * 100.0;
                    }
                }
                if (elapsed_ms > 0) {
                    const d_read = disk_read -| prev.disk_read;
                    const d_write = disk_write -| prev.disk_write;
                    disk_read_ps = (d_read *| 1000) / @as(u64, @intCast(elapsed_ms));
                    disk_write_ps = (d_write *| 1000) / @as(u64, @intCast(elapsed_ms));
                }
            }

            const mem_percent: f32 = if (self.total_mem > 0)
                @as(f32, @floatFromInt(resident_size)) / @as(f32, @floatFromInt(self.total_mem)) * 100.0
            else
                0;

            const name = if (proc_info.name.len > 63) proc_info.name[0..63] else proc_info.name;
            var proc_stat = ProcStats{
                .pid = pid,
                .ppid = proc_info.ppid,
                .cpu_percent = cpu_percent,
                .mem_percent = mem_percent,
                .threads = proc_info.num_threads,
                .disk_read_ps = disk_read_ps,
                .disk_write_ps = disk_write_ps,
                .name_len = @intCast(name.len),
                .state = proc_info.state,
            };
            @memcpy(proc_stat.name_buf[0..name.len], name);

            var cmdline_buf: [4096]u8 = undefined;
            if (readDirFile(&pid_dir, "cmdline", &cmdline_buf)) |cmdline_contents| {
                const launch_cmd = compactLinuxCmdline(cmdline_contents, &proc_stat.launch_cmd_buf);
                proc_stat.launch_cmd_len = @intCast(launch_cmd.len);
            } else |_| {}

            try result.append(allocator, proc_stat);
        }

        @memcpy(self.prev_procs[0..new_proc_count], new_procs[0..new_proc_count]);
        self.prev_proc_count = new_proc_count;
        self.prev_proc_total_ticks = snapshot.overall.total;
        self.prev_time = now;

        const slice = try result.toOwnedSlice(allocator);
        common.sortProcStats(slice, sort_by);
        return slice;
    }

    pub fn getThreadStats(self: *SysInfo, allocator: std.mem.Allocator, pid: u32) ![]common.ThreadStats {
        if (self.thread_view_pid != pid) {
            self.thread_view_pid = pid;
            self.prev_thread_count = 0;
        }

        const snapshot = readCpuSnapshot() catch CpuSnapshot{};
        const total_tick_delta = if (self.prev_thread_total_ticks > 0) snapshot.overall.total -| self.prev_thread_total_ticks else 0;

        var path_buf: [64]u8 = undefined;
        const task_path = std.fmt.bufPrint(&path_buf, "/proc/{d}/task", .{pid}) catch
            return allocator.alloc(common.ThreadStats, 0);

        var task_dir = std.fs.openDirAbsolute(task_path, .{ .iterate = true }) catch
            return allocator.alloc(common.ThreadStats, 0);
        defer task_dir.close();

        var iter = task_dir.iterate();
        var result: std.ArrayList(common.ThreadStats) = .empty;
        var new_threads: [MAX_THREADS]common.ThreadCpuEntry = undefined;
        var new_thread_count: usize = 0;

        while (try iter.next()) |entry| {
            if (entry.kind != .directory) continue;
            const tid = std.fmt.parseInt(u64, entry.name, 10) catch continue;

            var tid_dir = task_dir.openDir(entry.name, .{}) catch continue;
            defer tid_dir.close();

            var stat_buf: [4096]u8 = undefined;
            const stat_contents = readDirFile(&tid_dir, "stat", &stat_buf) catch continue;
            const parsed = parseProcStat(stat_contents) orelse continue;

            // Read comm for thread name
            var comm_buf: [128]u8 = undefined;
            var name_buf_local: [64]u8 = std.mem.zeroes([64]u8);
            var name_len: u8 = 0;
            if (readDirFile(&tid_dir, "comm", &comm_buf)) |comm| {
                const trimmed = std.mem.trimRight(u8, comm, "\n");
                name_len = @intCast(@min(trimmed.len, 63));
                @memcpy(name_buf_local[0..name_len], trimmed[0..name_len]);
            } else |_| {
                const n = if (parsed.name.len > 63) parsed.name[0..63] else parsed.name;
                name_len = @intCast(n.len);
                @memcpy(name_buf_local[0..name_len], n);
            }

            if (new_thread_count < MAX_THREADS) {
                new_threads[new_thread_count] = .{ .tid = tid, .cpu_total = parsed.cpu_total };
                new_thread_count += 1;
            }

            var cpu_percent: f32 = 0;
            for (self.prev_threads[0..self.prev_thread_count]) |prev| {
                if (prev.tid == tid) {
                    if (total_tick_delta > 0 and parsed.cpu_total >= prev.cpu_total) {
                        const delta_cpu = parsed.cpu_total - prev.cpu_total;
                        cpu_percent = @as(f32, @floatFromInt(delta_cpu * self.ncpu)) / @as(f32, @floatFromInt(total_tick_delta)) * 100.0;
                    }
                    break;
                }
            }

            var thread_stat = common.ThreadStats{
                .tid = tid,
                .cpu_percent = cpu_percent,
                .state = parsed.state,
                .name_len = name_len,
            };
            @memcpy(thread_stat.name_buf[0..name_len], name_buf_local[0..name_len]);

            try result.append(allocator, thread_stat);
        }

        @memcpy(self.prev_threads[0..new_thread_count], new_threads[0..new_thread_count]);
        self.prev_thread_count = new_thread_count;
        self.prev_thread_total_ticks = snapshot.overall.total;

        const thread_slice = try result.toOwnedSlice(allocator);
        common.sortThreadStats(thread_slice);
        return thread_slice;
    }
    pub fn getNetConnections(self: *SysInfo, allocator: std.mem.Allocator) ![]common.NetConnection {
        _ = self;
        var result: std.ArrayList(common.NetConnection) = .empty;
        defer result.deinit(allocator);
        return result.toOwnedSlice(allocator);
    }
};

const LinuxSharedCacheInfo = struct {
    level: u8 = 0,
    group_id: i16 = -1,
    shared_logical_count: u16 = 0,
};

const PhysicalCoreKey = struct {
    package_id: u16,
    core_id: i32,
};

const CacheGroupKey = struct {
    level: u8,
    group_id: i16,
};

fn readCpuTopology(self: *SysInfo) !void {
    var sys_cpu_dir = try std.fs.openDirAbsolute("/sys/devices/system/cpu", .{ .iterate = true });
    defer sys_cpu_dir.close();

    var logical_ids: [MAX_CORES]u16 = undefined;
    var logical_count: usize = 0;

    var iter = sys_cpu_dir.iterate();
    while (try iter.next()) |entry| {
        if (logical_count >= MAX_CORES) break;
        if (!std.mem.startsWith(u8, entry.name, "cpu")) continue;

        const suffix = entry.name[3..];
        if (suffix.len == 0 or !std.ascii.isDigit(suffix[0])) continue;

        logical_ids[logical_count] = std.fmt.parseInt(u16, suffix, 10) catch continue;
        logical_count += 1;
    }

    if (logical_count == 0) return error.UnexpectedCpuTopology;

    std.mem.sort(u16, logical_ids[0..logical_count], {}, struct {
        fn lessThan(_: void, a: u16, b: u16) bool {
            return a < b;
        }
    }.lessThan);

    var physical_keys: [MAX_CORES]PhysicalCoreKey = undefined;
    var physical_count: usize = 0;

    var package_ids: [MAX_CORES]u16 = undefined;
    var package_count: usize = 0;

    var numa_ids: [MAX_CORES]i16 = undefined;
    var numa_count: usize = 0;

    var cache_keys: [MAX_CORES]CacheGroupKey = undefined;
    var cache_count: usize = 0;

    var resolved_count: usize = 0;
    for (logical_ids[0..logical_count]) |logical_id| {
        var cpu_name_buf: [16]u8 = undefined;
        const cpu_name = std.fmt.bufPrint(&cpu_name_buf, "cpu{d}", .{logical_id}) catch continue;

        var cpu_dir = sys_cpu_dir.openDir(cpu_name, .{ .iterate = true }) catch continue;
        defer cpu_dir.close();

        var topo_dir = cpu_dir.openDir("topology", .{}) catch continue;
        defer topo_dir.close();

        const core_id = readIntFromDir(&topo_dir, i32, "core_id") catch @as(i32, @intCast(logical_id));
        const package_id = readIntFromDir(&topo_dir, u16, "physical_package_id") catch 0;

        var siblings_buf: [128]u8 = undefined;
        const siblings_info = if (readDirFile(&topo_dir, "thread_siblings_list", &siblings_buf)) |contents|
            parseCpuListInfo(std.mem.trim(u8, contents, " \t\r\n"), logical_id)
        else |_|
            CpuListInfo{ .count = 1, .first = logical_id, .target_index = 0 };

        const cache_info = readLinuxSharedCache(&cpu_dir) catch LinuxSharedCacheInfo{};
        const numa_node_id = readCpuNumaNode(&cpu_dir) catch -1;
        const physical_id = findOrAppendPhysicalId(&physical_keys, &physical_count, package_id, core_id);

        self.topology_cores[resolved_count] = .{
            .logical_id = logical_id,
            .physical_id = physical_id,
            .package_id = package_id,
            .numa_node_id = numa_node_id,
            .thread_index = @intCast(siblings_info.target_index orelse 0),
            .threads_per_core = @intCast(@max(siblings_info.count, 1)),
            .shared_cache_group_id = cache_info.group_id,
            .shared_cache_level = cache_info.level,
            .shared_cache_logical_count = cache_info.shared_logical_count,
            .efficiency_class = .unknown,
        };
        resolved_count += 1;

        appendUniqueU16(&package_ids, &package_count, package_id);
        if (numa_node_id >= 0) appendUniqueI16(&numa_ids, &numa_count, numa_node_id);
        if (cache_info.group_id >= 0 and cache_info.level > 0) {
            appendUniqueCacheGroup(&cache_keys, &cache_count, .{
                .level = cache_info.level,
                .group_id = cache_info.group_id,
            });
        }
    }

    if (resolved_count == 0) return error.UnexpectedCpuTopology;

    self.topology_count = resolved_count;
    self.topology_physical_cores = @intCast(@max(physical_count, 1));
    self.topology_package_count = @intCast(@max(package_count, 1));
    self.topology_numa_count = @intCast(numa_count);
    self.topology_has_numa = numa_count > 1;
    self.topology_has_cache_groups = cache_count > 1;
}

fn readLinuxSharedCache(cpu_dir: *std.fs.Dir) !LinuxSharedCacheInfo {
    var cache_dir = try cpu_dir.openDir("cache", .{ .iterate = true });
    defer cache_dir.close();

    var best = LinuxSharedCacheInfo{};
    var iter = cache_dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .directory) continue;
        if (!std.mem.startsWith(u8, entry.name, "index")) continue;

        var index_dir = cache_dir.openDir(entry.name, .{}) catch continue;
        defer index_dir.close();

        const level = readIntFromDir(&index_dir, u8, "level") catch continue;

        var type_buf: [32]u8 = undefined;
        const type_str = std.mem.trim(u8, readDirFile(&index_dir, "type", &type_buf) catch continue, " \t\r\n");
        if (!std.mem.eql(u8, type_str, "Unified") and !std.mem.eql(u8, type_str, "Data")) continue;

        var shared_buf: [128]u8 = undefined;
        const shared_list = std.mem.trim(u8, readDirFile(&index_dir, "shared_cpu_list", &shared_buf) catch continue, " \t\r\n");
        const shared_info = parseCpuListInfo(shared_list, null);
        if (shared_info.count == 0 or shared_info.first == null) continue;

        if (level > best.level or (level == best.level and shared_info.count >= best.shared_logical_count)) {
            best = .{
                .level = level,
                .group_id = @intCast(shared_info.first.?),
                .shared_logical_count = @intCast(shared_info.count),
            };
        }
    }

    if (best.level == 0) return error.SharedCacheUnavailable;
    return best;
}

fn readCpuNumaNode(cpu_dir: *std.fs.Dir) !i16 {
    var iter = cpu_dir.iterate();
    while (try iter.next()) |entry| {
        if (!std.mem.startsWith(u8, entry.name, "node")) continue;
        const suffix = entry.name[4..];
        if (suffix.len == 0) continue;
        return std.fmt.parseInt(i16, suffix, 10);
    }
    return error.NumaNodeUnavailable;
}

fn readIntFromDir(dir: *std.fs.Dir, comptime T: type, sub_path: []const u8) !T {
    var buf: [64]u8 = undefined;
    const contents = try readDirFile(dir, sub_path, &buf);
    return std.fmt.parseInt(T, std.mem.trim(u8, contents, " \t\r\n"), 10);
}

fn appendUniqueU16(items: *[MAX_CORES]u16, count: *usize, value: u16) void {
    for (items[0..count.*]) |existing| {
        if (existing == value) return;
    }
    if (count.* < items.len) {
        items[count.*] = value;
        count.* += 1;
    }
}

fn appendUniqueI16(items: *[MAX_CORES]i16, count: *usize, value: i16) void {
    for (items[0..count.*]) |existing| {
        if (existing == value) return;
    }
    if (count.* < items.len) {
        items[count.*] = value;
        count.* += 1;
    }
}

fn appendUniqueCacheGroup(items: *[MAX_CORES]CacheGroupKey, count: *usize, value: CacheGroupKey) void {
    for (items[0..count.*]) |existing| {
        if (existing.level == value.level and existing.group_id == value.group_id) return;
    }
    if (count.* < items.len) {
        items[count.*] = value;
        count.* += 1;
    }
}

fn findOrAppendPhysicalId(keys: *[MAX_CORES]PhysicalCoreKey, count: *usize, package_id: u16, core_id: i32) u16 {
    for (keys[0..count.*], 0..) |existing, idx| {
        if (existing.package_id == package_id and existing.core_id == core_id) {
            return @intCast(idx);
        }
    }

    if (count.* < keys.len) {
        keys[count.*] = .{ .package_id = package_id, .core_id = core_id };
        count.* += 1;
        return @intCast(count.* - 1);
    }

    return 0;
}

pub fn parseCpuListInfo(list: []const u8, target: ?u16) CpuListInfo {
    var info = CpuListInfo{};
    var parts = std.mem.splitScalar(u8, std.mem.trim(u8, list, " \t\r\n"), ',');

    while (parts.next()) |part_raw| {
        const part = std.mem.trim(u8, part_raw, " \t\r\n");
        if (part.len == 0) continue;

        if (std.mem.indexOfScalar(u8, part, '-')) |dash| {
            const start = std.fmt.parseInt(u16, std.mem.trim(u8, part[0..dash], " \t"), 10) catch continue;
            const end = std.fmt.parseInt(u16, std.mem.trim(u8, part[dash + 1 ..], " \t"), 10) catch continue;
            if (end < start) continue;

            var value = start;
            while (true) {
                recordCpuListValue(&info, value, target);
                if (value == end) break;
                value += 1;
            }
        } else {
            const value = std.fmt.parseInt(u16, part, 10) catch continue;
            recordCpuListValue(&info, value, target);
        }
    }

    return info;
}

fn recordCpuListValue(info: *CpuListInfo, value: u16, target: ?u16) void {
    if (info.first == null) info.first = value;
    if (target) |target_value| {
        if (info.target_index == null and value == target_value) {
            info.target_index = info.count;
        }
    }
    info.count += 1;
}

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

fn compactLinuxCmdline(raw: []const u8, dest: []u8) []const u8 {
    var write_idx: usize = 0;
    var needs_space = false;

    for (raw) |byte| {
        if (byte == 0) {
            if (write_idx > 0) needs_space = true;
            continue;
        }

        if (needs_space and write_idx < dest.len) {
            dest[write_idx] = ' ';
            write_idx += 1;
            needs_space = false;
        }
        if (write_idx >= dest.len) break;

        dest[write_idx] = byte;
        write_idx += 1;
    }

    return std.mem.trimRight(u8, dest[0..write_idx], " ");
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

pub fn parseProcStat(contents: []const u8) ?ParsedProcStat {
    const line = std.mem.trimRight(u8, contents, "\n");
    const open_paren = std.mem.indexOfScalar(u8, line, '(') orelse return null;
    const close_paren = std.mem.lastIndexOfScalar(u8, line, ')') orelse return null;
    if (close_paren <= open_paren) return null;

    const name = line[open_paren + 1 .. close_paren];
    const rest = std.mem.trimLeft(u8, line[close_paren + 1 ..], " ");
    var fields = std.mem.tokenizeAny(u8, rest, " ");
    var field_number: usize = 3;
    var state: common.ProcState = .unknown;
    var ppid: ?u32 = null;
    var utime: ?u64 = null;
    var stime: ?u64 = null;
    var num_threads: ?u32 = null;

    while (fields.next()) |field| : (field_number += 1) {
        if (field_number == 3) {
            state = switch (field[0]) {
                'R' => .running,
                'S' => .sleeping,
                'D' => .disk_sleep,
                'T' => .stopped,
                't' => .tracing_stop,
                'Z' => .zombie,
                'X' => .dead,
                'I' => .idle,
                else => .unknown,
            };
        } else if (field_number == 4) {
            ppid = std.fmt.parseInt(u32, field, 10) catch return null;
        } else if (field_number == 14) {
            utime = std.fmt.parseInt(u64, field, 10) catch return null;
        } else if (field_number == 15) {
            stime = std.fmt.parseInt(u64, field, 10) catch return null;
        } else if (field_number == 20) {
            num_threads = std.fmt.parseInt(u32, field, 10) catch return null;
            break;
        }
    }

    return .{
        .name = name,
        .state = state,
        .ppid = ppid orelse return null,
        .cpu_total = (utime orelse return null) + (stime orelse return null),
        .num_threads = num_threads orelse return null,
    };
}

fn parseResidentPages(contents: []const u8) ?u64 {
    var fields = std.mem.tokenizeAny(u8, contents, " \t\n");
    _ = fields.next() orelse return null;
    const resident = fields.next() orelse return null;
    return std.fmt.parseInt(u64, resident, 10) catch null;
}

fn readDiskStats() !struct { read_bytes: u64, write_bytes: u64 } {
    var buf: [4096]u8 = undefined;
    const contents = readAbsoluteFile("/proc/diskstats", &buf) catch return .{ .read_bytes = 0, .write_bytes = 0 };
    var lines = std.mem.splitScalar(u8, contents, '\n');
    var read_sectors: u64 = 0;
    var write_sectors: u64 = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        _ = fields.next();
        _ = fields.next();
        const dev = fields.next() orelse continue;
        if (std.mem.startsWith(u8, dev, "loop") or std.mem.startsWith(u8, dev, "ram")) continue;

        _ = fields.next();
        _ = fields.next();
        const rs = fields.next() orelse continue;
        _ = fields.next();
        _ = fields.next();
        _ = fields.next();
        const ws = fields.next() orelse continue;

        read_sectors += std.fmt.parseInt(u64, rs, 10) catch 0;
        write_sectors += std.fmt.parseInt(u64, ws, 10) catch 0;
    }
    return .{ .read_bytes = read_sectors * 512, .write_bytes = write_sectors * 512 };
}

fn readNetStats() !struct { rx_bytes: u64, tx_bytes: u64 } {
    var buf: [4096]u8 = undefined;
    const contents = readAbsoluteFile("/proc/net/dev", &buf) catch return .{ .rx_bytes = 0, .tx_bytes = 0 };
    var lines = std.mem.splitScalar(u8, contents, '\n');
    _ = lines.next();
    _ = lines.next();

    var rx: u64 = 0;
    var tx: u64 = 0;

    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const dev = std.mem.trim(u8, line[0..colon], " \t");
        if (std.mem.eql(u8, dev, "lo")) continue;

        var fields = std.mem.tokenizeAny(u8, line[colon + 1 ..], " \t");
        const r_bytes = fields.next() orelse continue;
        rx += std.fmt.parseInt(u64, r_bytes, 10) catch 0;

        for (0..7) |_| {
            _ = fields.next();
        }
        const t_bytes = fields.next() orelse continue;
        tx += std.fmt.parseInt(u64, t_bytes, 10) catch 0;
    }
    return .{ .rx_bytes = rx, .tx_bytes = tx };
}

fn readMemInfoTotal() !u64 {
    const mem_info = try readMemInfo();
    return mem_info.total;
}

fn readMemInfo() !MemStats {
    var buf: [4096]u8 = undefined;
    const contents = try readAbsoluteFile("/proc/meminfo", &buf);

    var total_kb: ?u64 = null;
    var available_kb: ?u64 = null;
    var cached_kb: ?u64 = null;
    var buffered_kb: ?u64 = null;
    var swap_total_kb: ?u64 = null;
    var swap_free_kb: ?u64 = null;

    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "MemTotal:")) {
            total_kb = parseMemInfoValue(line);
        } else if (std.mem.startsWith(u8, line, "MemAvailable:")) {
            available_kb = parseMemInfoValue(line);
        } else if (std.mem.startsWith(u8, line, "Cached:")) {
            cached_kb = parseMemInfoValue(line);
        } else if (std.mem.startsWith(u8, line, "Buffers:")) {
            buffered_kb = parseMemInfoValue(line);
        } else if (std.mem.startsWith(u8, line, "SwapTotal:")) {
            swap_total_kb = parseMemInfoValue(line);
        } else if (std.mem.startsWith(u8, line, "SwapFree:")) {
            swap_free_kb = parseMemInfoValue(line);
        }
    }

    const total = common.kbToBytes(total_kb orelse return error.UnexpectedProcMemInfo);
    const free = common.kbToBytes(available_kb orelse return error.UnexpectedProcMemInfo);
    const used = total -| free;
    const cached = common.kbToBytes(cached_kb orelse 0);
    const buffered = common.kbToBytes(buffered_kb orelse 0);
    const swap_total = common.kbToBytes(swap_total_kb orelse 0);
    const swap_free = common.kbToBytes(swap_free_kb orelse 0);
    const swap_used = swap_total -| swap_free;

    return .{
        .total = total,
        .used = used,
        .free = free,
        .cached = cached,
        .buffered = buffered,
        .swap_total = swap_total,
        .swap_used = swap_used,
    };
}

fn parseMemInfoValue(line: []const u8) ?u64 {
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return null;
    var fields = std.mem.tokenizeAny(u8, line[colon + 1 ..], " \t");
    const value = fields.next() orelse return null;
    return std.fmt.parseInt(u64, value, 10) catch null;
}
