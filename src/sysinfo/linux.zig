const std = @import("std");
const common = @import("common.zig");

const io_util_mod = @import("linux/io_util.zig");
const cpu_snapshot_mod = @import("linux/cpu_snapshot.zig");
const memory_mod = @import("linux/memory.zig");
const disk_mod = @import("linux/disk.zig");
const net_mod = @import("linux/net.zig");
const process_mod = @import("linux/process.zig");
const cpu_topology_helpers = @import("linux/cpu_topology_helpers.zig");
const gpu_mod = @import("linux/gpu.zig");

// Re-export public API that tests depend on
pub const parseProcStat = process_mod.parseProcStat;
pub const parseCpuListInfo = process_mod.parseCpuListInfo;
pub const parseStatusContextSwitches = process_mod.parseStatusContextSwitches;
pub const parseSchedCounter = process_mod.parseSchedCounter;
pub const ParsedProcStat = process_mod.ParsedProcStat;
pub const CpuListInfo = process_mod.CpuListInfo;

const CpuStats = common.CpuStats;
const CpuTopology = common.CpuTopology;
const CpuLogicalCore = common.CpuLogicalCore;
const MemStats = common.MemStats;
const DiskStats = common.DiskStats;
const NetStats = common.NetStats;
const ThermalStats = common.ThermalStats;
const GpuStats = common.GpuStats;
const BatteryStats = common.BatteryStats;
const BatteryStatus = common.BatteryStatus;
const CpuEfficiencyClass = common.CpuEfficiencyClass;
const ProcStats = common.ProcStats;
const ProcCpuEntry = common.ProcCpuEntry;
const MAX_CORES = common.MAX_CORES;
const MAX_PROCS = common.MAX_PROCS;

const CpuTick = cpu_snapshot_mod.CpuTick;
const CpuSnapshot = cpu_snapshot_mod.CpuSnapshot;

const LinuxSharedCacheInfo = cpu_topology_helpers.LinuxSharedCacheInfo;
const PhysicalCoreKey = cpu_topology_helpers.PhysicalCoreKey;
const CacheGroupKey = cpu_topology_helpers.CacheGroupKey;

const MAX_THREADS = common.MAX_THREADS;

pub const SysInfo = struct {
    io: std.Io,
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

    pub fn init(io: std.Io) SysInfo {
        const initial_cores = @min(std.Thread.getCpuCount() catch 1, MAX_CORES);
        const now = nowMs(io);
        var self: SysInfo = .{
            .io = io,
            .ncpu = @intCast(initial_cores),
            .total_mem = memory_mod.readMemInfoTotal(io) catch 0,
            .page_size = std.heap.pageSize(),
            .prev_time = now,
            .prev_disk_ms = now,
            .prev_net_ms = now,
        };
        self.loadTopology();
        return self;
    }

    fn nowMs(io: std.Io) i64 {
        return std.Io.Clock.now(.real, io).toMilliseconds();
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
        const snapshot = cpu_snapshot_mod.readCpuSnapshot(self.io) catch {
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
        const mem_info = memory_mod.readMemInfo(self.io) catch {
            return .{ .total = self.total_mem, .used = 0, .free = self.total_mem, .cached = 0, .buffered = 0, .swap_total = 0, .swap_used = 0 };
        };

        self.total_mem = mem_info.total;

        return mem_info;
    }

    pub fn getDiskStats(self: *SysInfo) DiskStats {
        const stats = disk_mod.readDiskStats(self.io) catch .{ .read_bytes = 0, .write_bytes = 0 };
        const now = nowMs(self.io);
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
        const stats = net_mod.readNetStats(self.io) catch .{ .rx_bytes = 0, .tx_bytes = 0 };
        const now = nowMs(self.io);
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
        var buf: [64]u8 = undefined;
        const contents = io_util_mod.readAbsoluteFile(self.io, "/sys/class/thermal/thermal_zone0/temp", &buf) catch return .{};
        const temp_str = std.mem.trim(u8, contents, " \n");
        const milli_c = std.fmt.parseInt(i32, temp_str, 10) catch return .{};
        return .{ .cpu_temp = @as(f32, @floatFromInt(milli_c)) / 1000.0, .gpu_temp = null };
    }

    pub fn getBatteryStats(self: *SysInfo) BatteryStats {
        var buf_cap: [64]u8 = undefined;
        var buf_stat: [64]u8 = undefined;
        var buf_power: [64]u8 = undefined;

        var charge_percent: ?f32 = null;
        if (io_util_mod.readAbsoluteFile(self.io, "/sys/class/power_supply/BAT0/capacity", &buf_cap)) |cap| {
            const val = std.fmt.parseInt(u32, std.mem.trim(u8, cap, " \n"), 10) catch 0;
            charge_percent = @as(f32, @floatFromInt(val));
        } else |_| {}

        var status: BatteryStatus = .unknown;
        if (io_util_mod.readAbsoluteFile(self.io, "/sys/class/power_supply/BAT0/status", &buf_stat)) |stat| {
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
        if (io_util_mod.readAbsoluteFile(self.io, "/sys/class/power_supply/BAT0/power_now", &buf_power)) |power| {
            const val = std.fmt.parseInt(u64, std.mem.trim(u8, power, " \n"), 10) catch 0;
            power_draw_w = @as(f32, @floatFromInt(val)) / 1000000.0;
        } else |_| {}

        return .{ .charge_percent = charge_percent, .power_draw_w = power_draw_w, .status = status };
    }

    pub fn getGpuStats(self: *SysInfo, allocator: std.mem.Allocator) ![]GpuStats {
        var result: std.ArrayList(GpuStats) = .empty;
        errdefer result.deinit(allocator);

        try gpu_mod.appendNvidiaGpuStats(allocator, &result);
        try gpu_mod.appendAmdGpuStats(self.io, allocator, &result);

        return result.toOwnedSlice(allocator);
    }

    fn findPrevProcEntry(self: *const SysInfo, pid: u32) ?ProcCpuEntry {
        // Binary search — prev_procs is kept sorted by PID
        const slice = self.prev_procs[0..self.prev_proc_count];
        var lo: usize = 0;
        var hi: usize = slice.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (slice[mid].pid == pid) return slice[mid];
            if (slice[mid].pid < pid) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        return null;
    }

    /// Fill `out_buf` with process stats, returning the used portion.
    /// Caller owns `out_buf` — no heap allocation per call.
    pub fn getProcStats(self: *SysInfo, out_buf: []ProcStats, sort_by: common.SortBy) ![]ProcStats {
        const snapshot = cpu_snapshot_mod.readCpuSnapshot(self.io) catch CpuSnapshot{};
        const total_tick_delta = if (self.prev_proc_total_ticks > 0) snapshot.overall.total -| self.prev_proc_total_ticks else 0;

        const now = nowMs(self.io);
        const elapsed_ms = now - self.prev_time;

        var proc_dir = try std.Io.Dir.openDirAbsolute(self.io, "/proc", .{ .iterate = true });
        defer proc_dir.close(self.io);

        var iter = proc_dir.iterate();
        var proc_count: usize = 0;
        var new_procs: [MAX_PROCS]ProcCpuEntry = undefined;
        var new_proc_count: usize = 0;

        while (try iter.next(self.io)) |entry| {
            if (entry.kind != .directory) continue;
            const pid = std.fmt.parseInt(u32, entry.name, 10) catch continue;

            var pid_dir = proc_dir.openDir(self.io, entry.name, .{}) catch continue;
            defer pid_dir.close(self.io);

            var stat_buf: [4096]u8 = undefined;
            const stat_contents = io_util_mod.readDirFile(self.io, &pid_dir, "stat", &stat_buf) catch continue;
            const proc_info = process_mod.parseProcStat(stat_contents) orelse continue;

            var statm_buf: [128]u8 = undefined;
            const statm_contents = io_util_mod.readDirFile(self.io, &pid_dir, "statm", &statm_buf) catch continue;
            const resident_pages = process_mod.parseResidentPages(statm_contents) orelse continue;
            const resident_size = resident_pages * self.page_size;

            var io_buf: [1024]u8 = undefined;
            var disk_read: u64 = 0;
            var disk_write: u64 = 0;
            if (io_util_mod.readDirFile(self.io, &pid_dir, "io", &io_buf)) |io_contents| {
                var lines = std.mem.splitScalar(u8, io_contents, '\n');
                while (lines.next()) |line| {
                    if (std.mem.startsWith(u8, line, "read_bytes:")) {
                        disk_read = std.fmt.parseInt(u64, std.mem.trim(u8, line[11..], " \t"), 10) catch 0;
                    } else if (std.mem.startsWith(u8, line, "write_bytes:")) {
                        disk_write = std.fmt.parseInt(u64, std.mem.trim(u8, line[12..], " \t"), 10) catch 0;
                    }
                }
            } else |_| {}

            var status_buf: [1024]u8 = undefined;
            var context_switches_total: u64 = 0;
            if (io_util_mod.readDirFile(self.io, &pid_dir, "status", &status_buf)) |status_contents| {
                context_switches_total = process_mod.parseStatusContextSwitches(status_contents) orelse 0;
            } else |_| {}

            var sched_buf: [2048]u8 = undefined;
            var wakeups_total: u64 = 0;
            if (io_util_mod.readDirFile(self.io, &pid_dir, "sched", &sched_buf)) |sched_contents| {
                wakeups_total = process_mod.parseSchedCounter(sched_contents, "nr_wakeups") orelse 0;
            } else |_| {}

            if (new_proc_count < MAX_PROCS) {
                new_procs[new_proc_count] = .{
                    .pid = pid,
                    .cpu_total = proc_info.cpu_total,
                    .disk_read = disk_read,
                    .disk_write = disk_write,
                    .wakeups = wakeups_total,
                    .context_switches = context_switches_total,
                };
                new_proc_count += 1;
            }

            var cpu_percent: f32 = 0;
            var disk_read_ps: u64 = 0;
            var disk_write_ps: u64 = 0;
            var wakeups_ps: u64 = 0;
            var context_switches_ps: u64 = 0;

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
                    const d_wakeups = wakeups_total -| prev.wakeups;
                    const d_csw = context_switches_total -| prev.context_switches;
                    wakeups_ps = (d_wakeups *| 1000) / @as(u64, @intCast(elapsed_ms));
                    context_switches_ps = (d_csw *| 1000) / @as(u64, @intCast(elapsed_ms));
                }
            }

            const mem_percent: f32 = if (self.total_mem > 0)
                @as(f32, @floatFromInt(resident_size)) / @as(f32, @floatFromInt(self.total_mem)) * 100.0
            else
                0;

            if (proc_count >= out_buf.len) continue;

            const name = if (proc_info.name.len > 63) proc_info.name[0..63] else proc_info.name;
            out_buf[proc_count] = ProcStats{
                .pid = pid,
                .ppid = proc_info.ppid,
                .cpu_percent = cpu_percent,
                .mem_percent = mem_percent,
                .threads = proc_info.num_threads,
                .disk_read_ps = disk_read_ps,
                .disk_write_ps = disk_write_ps,
                .wakeups_ps = wakeups_ps,
                .context_switches_ps = context_switches_ps,
                .name_len = @intCast(name.len),
                .state = proc_info.state,
            };
            @memcpy(out_buf[proc_count].name_buf[0..name.len], name);

            var cmdline_buf: [4096]u8 = undefined;
            if (io_util_mod.readDirFile(self.io, &pid_dir, "cmdline", &cmdline_buf)) |cmdline_contents| {
                const launch_cmd = process_mod.compactLinuxCmdline(cmdline_contents, &out_buf[proc_count].launch_cmd_buf);
                out_buf[proc_count].launch_cmd_len = @intCast(launch_cmd.len);
            } else |_| {}

            proc_count += 1;
        }

        @memcpy(self.prev_procs[0..new_proc_count], new_procs[0..new_proc_count]);
        self.prev_proc_count = new_proc_count;
        // Sort by PID for binary search in findPrevProcEntry
        std.mem.sort(ProcCpuEntry, self.prev_procs[0..new_proc_count], {}, struct {
            fn lessThan(_: void, a: ProcCpuEntry, b: ProcCpuEntry) bool {
                return a.pid < b.pid;
            }
        }.lessThan);
        self.prev_proc_total_ticks = snapshot.overall.total;
        self.prev_time = now;

        const result = out_buf[0..proc_count];
        common.sortProcStats(result, sort_by);
        return result;
    }

    pub fn getThreadStats(self: *SysInfo, allocator: std.mem.Allocator, pid: u32) ![]common.ThreadStats {
        if (self.thread_view_pid != pid) {
            self.thread_view_pid = pid;
            self.prev_thread_count = 0;
        }

        const snapshot = cpu_snapshot_mod.readCpuSnapshot(self.io) catch CpuSnapshot{};
        const total_tick_delta = if (self.prev_thread_total_ticks > 0) snapshot.overall.total -| self.prev_thread_total_ticks else 0;

        var path_buf: [64]u8 = undefined;
        const task_path = std.fmt.bufPrint(&path_buf, "/proc/{d}/task", .{pid}) catch
            return allocator.alloc(common.ThreadStats, 0);

        var task_dir = std.Io.Dir.openDirAbsolute(self.io, task_path, .{ .iterate = true }) catch
            return allocator.alloc(common.ThreadStats, 0);
        defer task_dir.close(self.io);

        var iter = task_dir.iterate();
        var result: std.ArrayList(common.ThreadStats) = .empty;
        var new_threads: [MAX_THREADS]common.ThreadCpuEntry = undefined;
        var new_thread_count: usize = 0;

        while (try iter.next(self.io)) |entry| {
            if (entry.kind != .directory) continue;
            const tid = std.fmt.parseInt(u64, entry.name, 10) catch continue;

            var tid_dir = task_dir.openDir(self.io, entry.name, .{}) catch continue;
            defer tid_dir.close(self.io);

            var stat_buf: [4096]u8 = undefined;
            const stat_contents = io_util_mod.readDirFile(self.io, &tid_dir, "stat", &stat_buf) catch continue;
            const parsed = process_mod.parseProcStat(stat_contents) orelse continue;

            // Read comm for thread name
            var comm_buf: [128]u8 = undefined;
            var name_buf_local: [64]u8 = std.mem.zeroes([64]u8);
            var name_len: u8 = 0;
            if (io_util_mod.readDirFile(self.io, &tid_dir, "comm", &comm_buf)) |comm| {
                const trimmed = std.mem.trimEnd(u8, comm, "\n");
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

fn readCpuTopology(self: *SysInfo) !void {
    var sys_cpu_dir = try std.Io.Dir.openDirAbsolute(self.io, "/sys/devices/system/cpu", .{ .iterate = true });
    defer sys_cpu_dir.close(self.io);

    var logical_ids: [MAX_CORES]u16 = undefined;
    var logical_count: usize = 0;

    var iter = sys_cpu_dir.iterate();
    while (try iter.next(self.io)) |entry| {
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

        var cpu_dir = sys_cpu_dir.openDir(self.io, cpu_name, .{ .iterate = true }) catch continue;
        defer cpu_dir.close(self.io);

        var topo_dir = cpu_dir.openDir(self.io, "topology", .{}) catch continue;
        defer topo_dir.close(self.io);

        const core_id = io_util_mod.readIntFromDir(self.io, &topo_dir, i32, "core_id") catch @as(i32, @intCast(logical_id));
        const package_id = io_util_mod.readIntFromDir(self.io, &topo_dir, u16, "physical_package_id") catch 0;

        var siblings_buf: [128]u8 = undefined;
        const siblings_info = if (io_util_mod.readDirFile(self.io, &topo_dir, "thread_siblings_list", &siblings_buf)) |contents|
            process_mod.parseCpuListInfo(std.mem.trim(u8, contents, " \t\r\n"), logical_id)
        else |_|
            CpuListInfo{ .count = 1, .first = logical_id, .target_index = 0 };

        const cache_info = cpu_topology_helpers.readLinuxSharedCache(self.io, &cpu_dir) catch LinuxSharedCacheInfo{};
        const numa_node_id = cpu_topology_helpers.readCpuNumaNode(self.io, &cpu_dir) catch -1;
        const physical_id = cpu_topology_helpers.findOrAppendPhysicalId(&physical_keys, &physical_count, package_id, core_id);

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

        cpu_topology_helpers.appendUniqueU16(&package_ids, &package_count, package_id);
        if (numa_node_id >= 0) cpu_topology_helpers.appendUniqueI16(&numa_ids, &numa_count, numa_node_id);
        if (cache_info.group_id >= 0 and cache_info.level > 0) {
            cpu_topology_helpers.appendUniqueCacheGroup(&cache_keys, &cache_count, .{
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
