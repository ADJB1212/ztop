const std = @import("std");
const common = @import("common.zig");
pub const c = @cImport({
    @cInclude("sys/sysctl.h");
    @cInclude("sys/proc_info.h");
    @cInclude("sys/socket.h");
    @cInclude("net/if.h");
    @cInclude("net/route.h");
    @cInclude("IOKit/IOKitLib.h");
    @cInclude("IOKit/storage/IOBlockStorageDriver.h");
    @cInclude("CoreFoundation/CoreFoundation.h");
});

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

const DiskTotals = struct {
    read_bytes: u64,
    write_bytes: u64,
};

const NetTotals = struct {
    rx_bytes: u64,
    tx_bytes: u64,
};

const mach_port_t = u32;
const kern_return_t = c_int;

extern "c" fn mach_host_self() mach_port_t;
extern "c" fn host_statistics(host: mach_port_t, flavor: c_int, info: [*]c_int, count: *u32) kern_return_t;
extern "c" fn host_page_size(host: mach_port_t, page_size: *usize) kern_return_t;
extern "c" fn sysctlbyname(name: [*:0]const u8, oldp: ?*anyopaque, oldlenp: ?*usize, newp: ?*const anyopaque, newlen: usize) c_int;
extern "c" fn proc_listallpids(buffer: ?[*]c_int, bufsize: c_int) c_int;
extern "c" fn proc_pidinfo(pid: c_int, flavor: c_int, arg: u64, buffer: ?*anyopaque, bufsize: c_int) c_int;
extern "c" fn proc_pidfdinfo(pid: c_int, fd: c_int, flavor: c_int, buffer: ?*anyopaque, bufsize: c_int) c_int;
extern "c" fn proc_name(pid: c_int, buffer: [*]u8, bufsize: u32) c_int;
extern "c" fn proc_pidpath(pid: c_int, buffer: [*]u8, bufsize: u32) c_int;
extern "c" fn mach_absolute_time() u64;
extern "c" fn mach_timebase_info(info: *MachTimebaseInfo) kern_return_t;
extern "c" fn host_processor_info(host: mach_port_t, flavor: c_int, out_count: *u32, out_info: *[*]c_int, out_info_cnt: *u32) kern_return_t;
extern "c" fn vm_deallocate(task: mach_port_t, address: usize, size: usize) kern_return_t;
extern "c" fn mach_task_self() mach_port_t;

const MachTimebaseInfo = extern struct {
    numer: u32,
    denom: u32,
};

const HOST_CPU_LOAD_INFO: c_int = 3;
const HOST_VM_INFO: c_int = 2;
const PROCESSOR_CPU_LOAD_INFO: c_int = 2;
const KERN_SUCCESS: c_int = 0;
const PROC_PIDTASKINFO: c_int = 4;
const CPU_STATE_USER = 0;
const CPU_STATE_SYSTEM = 1;
const CPU_STATE_IDLE = 2;
const CPU_STATE_NICE = 3;
const CPU_STATE_MAX = 4;

const PROC_PIDTHREADINFO: c_int = 5;
const PROC_PIDRUSAGE = 5;
const PROC_PIDLISTTHREADS: c_int = 6;
const PROC_PIDT_SHORTBSDINFO: c_int = 13;

const SIDL = 1;
const SRUN = 2;
const SSLEEP = 3;
const SSTOP = 4;
const SZOMB = 5;

const ProcBsdShortInfo = extern struct {
    pbsi_pid: u32,
    pbsi_ppid: u32,
    pbsi_pgid: u32,
    pbsi_status: u32,
    pbsi_comm: [16]u8,
    pbsi_flags: u32,
    pbsi_uid: u32,
    pbsi_gid: u32,
    pbsi_ruid: u32,
    pbsi_rgid: u32,
    pbsi_svuid: u32,
    pbsi_svgid: u32,
    pbsi_rfu: u32,
};

const rusage_info_v2 = extern struct {
    ri_uuid: [16]u8,
    ri_user_time: u64,
    ri_system_time: u64,
    ri_pkg_idle_wkups: u64,
    ri_interrupt_wkups: u64,
    ri_pageins: u64,
    ri_wired_size: u64,
    ri_resident_size: u64,
    ri_phys_footprint: u64,
    ri_proc_start_abstime: u64,
    ri_proc_exit_abstime: u64,
    ri_child_user_time: u64,
    ri_child_system_time: u64,
    ri_child_pkg_idle_wkups: u64,
    ri_child_interrupt_wkups: u64,
    ri_child_pageins: u64,
    ri_child_elapsed_abstime: u64,
    ri_diskio_bytesread: u64,
    ri_diskio_byteswritten: u64,
};

const HostCpuLoadInfo = extern struct {
    ticks: [4]u32,
};

const VmStatistics = extern struct {
    free_count: u32,
    active_count: u32,
    inactive_count: u32,
    wire_count: u32,
    zero_fill_count: u32,
    reactivations: u32,
    pageins: u32,
    pageouts: u32,
    faults: u32,
    cow_faults: u32,
    lookups: u32,
    hits: u32,
    purgeable_count: u32,
    speculative_count: u32,
};

const xsw_usage = extern struct {
    xsu_total: u64,
    xsu_avail: u64,
    xsu_used: u64,
    xsu_pagesize: u32,
    xsu_encrypted: bool,
};

const ProcTaskInfo = extern struct {
    pti_virtual_size: u64,
    pti_resident_size: u64,
    pti_total_user: u64,
    pti_total_system: u64,
    pti_threads_user: u64,
    pti_threads_system: u64,
    pti_policy: i32,
    pti_faults: i32,
    pti_pageins: i32,
    pti_cow_faults: i32,
    pti_messages_sent: i32,
    pti_messages_received: i32,
    pti_syscalls_mach: i32,
    pti_syscalls_unix: i32,
    pti_csw: i32,
    pti_threadnum: i32,
    pti_numrunning: i32,
    pti_priority: i32,
};

const ProcThreadInfo = extern struct {
    pth_user_time: u64,
    pth_system_time: u64,
    pth_cpu_usage: i32,
    pth_policy: i32,
    pth_run_state: i32,
    pth_flags: i32,
    pth_sleep_time: i32,
    pth_curpri: i32,
    pth_priority: i32,
    pth_maxpri: i32,
    pth_name: [64]u8,
};

const TH_STATE_RUNNING: i32 = 1;
const TH_STATE_STOPPED: i32 = 2;
const TH_STATE_WAITING: i32 = 3;
const TH_STATE_UNINTERRUPTIBLE: i32 = 4;
const TH_STATE_HALTED: i32 = 5;

const MAX_THREADS = common.MAX_THREADS;

pub const SysInfo = struct {
    prev_ticks: [4]u64 = .{ 0, 0, 0, 0 },
    prev_core_ticks: [MAX_CORES][4]u64 = std.mem.zeroes([MAX_CORES][4]u64),
    core_usage: [MAX_CORES]f32 = [_]f32{0} ** MAX_CORES,
    ncpu: u32,
    topology_cores: [MAX_CORES]CpuLogicalCore = undefined,
    topology_count: usize = 0,
    topology_physical_cores: u16 = 0,
    topology_package_count: u16 = 1,
    topology_numa_count: u16 = 0,
    topology_has_cache_groups: bool = false,
    topology_has_efficiency_classes: bool = false,
    total_mem: u64,
    page_size: usize,
    host_port: mach_port_t,
    timebase: MachTimebaseInfo,
    prev_procs: [MAX_PROCS]ProcCpuEntry = undefined,
    prev_proc_count: usize = 0,
    prev_time: u64 = 0,
    prev_disk_read: u64 = 0,
    prev_disk_write: u64 = 0,
    prev_net_rx: u64 = 0,
    prev_net_tx: u64 = 0,
    prev_ms: i64 = 0,
    prev_disk_ms: i64 = 0,
    prev_net_ms: i64 = 0,

    pub fn init() SysInfo {
        const host_port = mach_host_self();

        var ncpu: u32 = 0;
        var ncpu_size: usize = @sizeOf(u32);
        _ = sysctlbyname("hw.logicalcpu", @ptrCast(&ncpu), &ncpu_size, null, 0);

        var total_mem: u64 = 0;
        var mem_size: usize = @sizeOf(u64);
        _ = sysctlbyname("hw.memsize", @ptrCast(&total_mem), &mem_size, null, 0);

        var pg_size: usize = 0;
        _ = host_page_size(host_port, &pg_size);

        var timebase: MachTimebaseInfo = undefined;
        _ = mach_timebase_info(&timebase);

        const now = std.time.milliTimestamp();

        var self: SysInfo = .{
            .ncpu = if (ncpu > 0) @min(ncpu, @as(u32, MAX_CORES)) else 1,
            .total_mem = total_mem,
            .page_size = if (pg_size > 0) pg_size else 4096,
            .host_port = host_port,
            .timebase = timebase,
            .prev_ms = now,
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
        const total_logical = @min(logical_count, MAX_CORES);
        const total_physical = @min(@as(usize, @intCast(readSysctlNumber(u32, "hw.physicalcpu") orelse @as(u32, @intCast(total_logical)))), total_logical);
        const package_count = @max(readSysctlNumber(u16, "hw.packages") orelse 1, 1);
        const threads_per_core: usize = if (total_physical > 0) @max(std.math.divCeil(usize, total_logical, total_physical) catch 1, 1) else 1;
        const physical_per_package: usize = if (package_count > 0) @max(std.math.divCeil(usize, total_physical, package_count) catch total_physical, 1) else total_physical;

        self.topology_count = total_logical;
        self.topology_physical_cores = @intCast(@max(total_physical, 1));
        self.topology_package_count = package_count;
        self.topology_numa_count = 0;
        self.topology_has_cache_groups = package_count > 1;
        self.topology_has_efficiency_classes = false;

        for (0..total_logical) |logical_id| {
            const physical_id: usize = if (total_physical > 0) logical_id % total_physical else logical_id;
            const package_id: u16 = if (total_physical > 0 and package_count > 1)
                @intCast(@min(physical_id / physical_per_package, package_count - 1))
            else
                0;
            const thread_index: usize = if (total_physical > 0) logical_id / total_physical else 0;

            self.topology_cores[logical_id] = .{
                .logical_id = @intCast(logical_id),
                .physical_id = @intCast(physical_id),
                .package_id = package_id,
                .numa_node_id = -1,
                .thread_index = @intCast(thread_index),
                .threads_per_core = @intCast(threads_per_core),
                .shared_cache_group_id = if (package_count > 1) @intCast(package_id) else -1,
                .shared_cache_level = if (package_count > 1) 3 else 0,
                .shared_cache_logical_count = if (package_count > 1 and total_logical > 0) @intCast(total_logical / package_count) else 0,
                .efficiency_class = .unknown,
            };
        }
    }

    fn usageFromTicks(prev_ticks: *[4]u64, user: u64, system: u64, idle: u64, nice: u64) f32 {
        const total = user + system + idle + nice;
        const active = user + system + nice;

        const prev_total = prev_ticks[CPU_STATE_USER] + prev_ticks[CPU_STATE_SYSTEM] + prev_ticks[CPU_STATE_IDLE] + prev_ticks[CPU_STATE_NICE];
        const prev_active = prev_ticks[CPU_STATE_USER] + prev_ticks[CPU_STATE_SYSTEM] + prev_ticks[CPU_STATE_NICE];

        const delta_total = total -| prev_total;
        const delta_active = active -| prev_active;

        prev_ticks.* = .{ user, system, idle, nice };

        if (prev_total == 0 or delta_total == 0) return 0;

        return @as(f32, @floatFromInt(delta_active)) / @as(f32, @floatFromInt(delta_total)) * 100.0;
    }

    pub fn getCpuStats(self: *SysInfo) CpuStats {
        var cpu_load: HostCpuLoadInfo = undefined;
        var count: u32 = @sizeOf(HostCpuLoadInfo) / @sizeOf(c_int);
        const ret = host_statistics(self.host_port, HOST_CPU_LOAD_INFO, @ptrCast(&cpu_load), &count);

        if (ret != KERN_SUCCESS) {
            return .{ .usage_percent = 0, .cores = self.ncpu };
        }

        const user: u64 = cpu_load.ticks[0];
        const system: u64 = cpu_load.ticks[1];
        const idle: u64 = cpu_load.ticks[2];
        const nice: u64 = cpu_load.ticks[3];

        const usage = usageFromTicks(&self.prev_ticks, user, system, idle, nice);
        if (self.topology_count == 0 or self.topology_count != self.ncpu) {
            self.loadTopology();
        }

        var processor_count: u32 = 0;
        var processor_info: [*]c_int = undefined;
        var processor_info_count: u32 = 0;
        const proc_ret = host_processor_info(
            self.host_port,
            PROCESSOR_CPU_LOAD_INFO,
            &processor_count,
            &processor_info,
            &processor_info_count,
        );

        if (proc_ret != KERN_SUCCESS) {
            return .{
                .usage_percent = usage,
                .cores = self.ncpu,
                .per_core_usage = self.core_usage[0..0],
            };
        }

        defer _ = vm_deallocate(
            mach_task_self(),
            @intFromPtr(processor_info),
            @as(usize, @intCast(processor_info_count)) * @sizeOf(c_int),
        );

        const info_core_count = @as(usize, @intCast(processor_info_count)) / CPU_STATE_MAX;
        const core_count = @min(@as(usize, @intCast(processor_count)), @min(@as(usize, @intCast(self.ncpu)), info_core_count));

        for (0..core_count) |i| {
            const base = i * CPU_STATE_MAX;
            const core_user: u64 = @intCast(@max(processor_info[base + CPU_STATE_USER], 0));
            const core_system: u64 = @intCast(@max(processor_info[base + CPU_STATE_SYSTEM], 0));
            const core_idle: u64 = @intCast(@max(processor_info[base + CPU_STATE_IDLE], 0));
            const core_nice: u64 = @intCast(@max(processor_info[base + CPU_STATE_NICE], 0));

            self.core_usage[i] = usageFromTicks(&self.prev_core_ticks[i], core_user, core_system, core_idle, core_nice);
        }

        return .{
            .usage_percent = usage,
            .cores = @intCast(core_count),
            .per_core_usage = self.core_usage[0..core_count],
        };
    }

    pub fn getCpuTopology(self: *const SysInfo) CpuTopology {
        return .{
            .logical_cores = self.topology_cores[0..self.topology_count],
            .physical_cores = self.topology_physical_cores,
            .package_count = self.topology_package_count,
            .numa_node_count = self.topology_numa_count,
            .has_numa = false,
            .has_smt = self.topology_physical_cores > 0 and self.topology_count > self.topology_physical_cores,
            .has_cache_groups = self.topology_has_cache_groups,
            .has_efficiency_classes = self.topology_has_efficiency_classes,
        };
    }

    pub fn getMemStats(self: *SysInfo) MemStats {
        var vm_stats: VmStatistics = undefined;
        var count: u32 = @sizeOf(VmStatistics) / @sizeOf(c_int);
        const ret = host_statistics(self.host_port, HOST_VM_INFO, @ptrCast(&vm_stats), &count);

        if (ret != KERN_SUCCESS) {
            return .{ .total = self.total_mem, .used = 0, .free = self.total_mem, .cached = 0, .buffered = 0, .swap_total = 0, .swap_used = 0 };
        }

        const pg = self.page_size;
        const active: u64 = @as(u64, vm_stats.active_count) * pg;
        const wired: u64 = @as(u64, vm_stats.wire_count) * pg;
        const inactive: u64 = @as(u64, vm_stats.inactive_count) * pg;
        const purgeable: u64 = @as(u64, vm_stats.purgeable_count) * pg;
        const speculative: u64 = @as(u64, vm_stats.speculative_count) * pg;

        const used = active + wired;
        const free = if (self.total_mem > used) self.total_mem - used else 0;
        const cached = purgeable + inactive + speculative;

        var swap: xsw_usage = std.mem.zeroes(xsw_usage);
        var swap_size: usize = @sizeOf(xsw_usage);
        _ = sysctlbyname("vm.swapusage", @ptrCast(&swap), &swap_size, null, 0);

        return .{
            .total = self.total_mem,
            .used = used,
            .free = free,
            .cached = cached,
            .buffered = 0,
            .swap_total = swap.xsu_total,
            .swap_used = swap.xsu_used,
        };
    }

    pub fn getDiskStats(self: *SysInfo) DiskStats {
        const stats = readDiskTotals() catch DiskTotals{ .read_bytes = 0, .write_bytes = 0 };
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
        const stats = readNetTotals() catch NetTotals{ .rx_bytes = 0, .tx_bytes = 0 };
        const now = std.time.milliTimestamp();
        const elapsed = now - self.prev_net_ms;

        var rx_ps: u64 = 0;
        var tx_ps: u64 = 0;

        if (elapsed > 0 and self.prev_net_rx > 0) {
            const d_rx = stats.rx_bytes -| self.prev_net_rx;
            const d_tx = stats.tx_bytes -| self.prev_net_tx;
            rx_ps = (d_rx *| 1000) / @as(u64, @intCast(elapsed));
            tx_ps = (d_tx *| 1000) / @as(u64, @intCast(elapsed));
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
        return .{};
    }

    pub fn getBatteryStats(self: *SysInfo) BatteryStats {
        _ = self;
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        var child = std.process.Child.init(&.{ "pmset", "-g", "batt" }, allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Ignore;

        child.spawn() catch return .{};

        const out_str = child.stdout.?.readToEndAlloc(allocator, 4096) catch return .{};

        _ = child.wait() catch return .{};

        var charge: ?f32 = null;
        var status: BatteryStatus = .unknown;

        // Output looks like: " -InternalBattery-0 (id=...) 100%; charged; 0:00 remaining present: true"
        if (std.mem.indexOf(u8, out_str, "%")) |pct_idx| {
            var start = pct_idx;
            while (start > 0 and out_str[start - 1] >= '0' and out_str[start - 1] <= '9') {
                start -= 1;
            }
            if (start < pct_idx) {
                const val = std.fmt.parseInt(u32, out_str[start..pct_idx], 10) catch 0;
                charge = @as(f32, @floatFromInt(val));
            }

            if (std.mem.indexOf(u8, out_str, "charging")) |_| {
                status = .charging;
            } else if (std.mem.indexOf(u8, out_str, "discharging")) |_| {
                status = .discharging;
            } else if (std.mem.indexOf(u8, out_str, "charged")) |_| {
                status = .full;
            }
        }

        return .{ .charge_percent = charge, .power_draw_w = null, .status = status };
    }

    fn findPrevProcEntry(self: *const SysInfo, pid: u32) ?ProcCpuEntry {
        for (self.prev_procs[0..self.prev_proc_count]) |entry| {
            if (entry.pid == pid) return entry;
        }
        return null;
    }

    fn machToNs(self: *const SysInfo, mach_time: u64) u64 {
        return mach_time * self.timebase.numer / self.timebase.denom;
    }

    pub fn getProcStats(self: *SysInfo, allocator: std.mem.Allocator, sort_by: common.SortBy) ![]ProcStats {
        const current_time = mach_absolute_time();
        const wall_delta_ns: u64 = if (self.prev_time > 0) self.machToNs(current_time -| self.prev_time) else 0;
        const now_ms = std.time.milliTimestamp();
        const elapsed_ms = now_ms - self.prev_ms;

        var pid_buf: [MAX_PROCS]c_int = undefined;
        const num_pids_raw = proc_listallpids(&pid_buf, @intCast(MAX_PROCS * @sizeOf(c_int)));
        const num_pids: usize = if (num_pids_raw > 0) @intCast(num_pids_raw) else 0;

        var result: std.ArrayList(ProcStats) = .empty;
        var new_procs: [MAX_PROCS]ProcCpuEntry = undefined;
        var new_proc_count: usize = 0;

        for (pid_buf[0..num_pids]) |raw_pid| {
            if (raw_pid <= 0) continue;
            const pid: u32 = @intCast(raw_pid);

            var task_info: ProcTaskInfo = undefined;
            const info_ret = proc_pidinfo(raw_pid, PROC_PIDTASKINFO, 0, @ptrCast(&task_info), @sizeOf(ProcTaskInfo));
            if (info_ret <= 0) continue;

            var bsd_info: ProcBsdShortInfo = undefined;
            const bsd_ret = proc_pidinfo(raw_pid, PROC_PIDT_SHORTBSDINFO, 0, @ptrCast(&bsd_info), @sizeOf(ProcBsdShortInfo));
            var state: common.ProcState = .unknown;
            if (bsd_ret > 0) {
                state = switch (bsd_info.pbsi_status) {
                    SIDL => .idle,
                    SRUN => .running,
                    SSLEEP => .sleeping,
                    SSTOP => .stopped,
                    SZOMB => .zombie,
                    else => .unknown,
                };
            }

            var nbuf: [64]u8 = std.mem.zeroes([64]u8);
            const name_ret = proc_name(raw_pid, &nbuf, 64);
            const name_len: u8 = if (name_ret > 0) @intCast(@min(@as(usize, @intCast(name_ret)), 63)) else 0;
            if (name_len == 0) continue;

            const cpu_total = task_info.pti_total_user +| task_info.pti_total_system;

            var rusage: rusage_info_v2 = undefined;
            const ru_ret = proc_pidinfo(raw_pid, PROC_PIDRUSAGE, 0, @ptrCast(&rusage), @sizeOf(rusage_info_v2));
            const disk_read = if (ru_ret > 0) rusage.ri_diskio_bytesread else 0;
            const disk_write = if (ru_ret > 0) rusage.ri_diskio_byteswritten else 0;

            if (new_proc_count < MAX_PROCS) {
                new_procs[new_proc_count] = .{ .pid = pid, .cpu_total = cpu_total, .disk_read = disk_read, .disk_write = disk_write };
                new_proc_count += 1;
            }

            var cpu_percent: f32 = 0;
            var disk_read_ps: u64 = 0;
            var disk_write_ps: u64 = 0;

            const prev_entry = self.findPrevProcEntry(pid);

            if (prev_entry) |prev| {
                if (wall_delta_ns > 0) {
                    if (cpu_total >= prev.cpu_total) {
                        const delta_cpu = cpu_total - prev.cpu_total;
                        cpu_percent = @as(f32, @floatFromInt(delta_cpu)) / @as(f32, @floatFromInt(wall_delta_ns)) * 100.0;
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
                @as(f32, @floatFromInt(task_info.pti_resident_size)) / @as(f32, @floatFromInt(self.total_mem)) * 100.0
            else
                0;

            var proc_stat = ProcStats{
                .pid = pid,
                .ppid = bsd_info.pbsi_ppid,
                .cpu_percent = cpu_percent,
                .mem_percent = mem_percent,
                .threads = @intCast(task_info.pti_threadnum),
                .disk_read_ps = disk_read_ps,
                .disk_write_ps = disk_write_ps,
                .name_len = name_len,
                .state = state,
            };
            @memcpy(proc_stat.name_buf[0..name_len], nbuf[0..name_len]);
            const launch_cmd = try readLaunchCommand(raw_pid, &proc_stat.launch_cmd_buf);
            proc_stat.launch_cmd_len = @intCast(launch_cmd.len);

            try result.append(allocator, proc_stat);
        }

        @memcpy(self.prev_procs[0..new_proc_count], new_procs[0..new_proc_count]);
        self.prev_proc_count = new_proc_count;
        self.prev_time = current_time;
        self.prev_ms = now_ms;

        const slice = try result.toOwnedSlice(allocator);
        common.sortProcStats(slice, sort_by);
        return slice;
    }

    pub fn getThreadStats(self: *SysInfo, allocator: std.mem.Allocator, pid: u32) ![]common.ThreadStats {
        _ = self;

        // Get list of thread unique IDs
        var tid_buf: [MAX_THREADS]u64 = undefined;
        const tid_ret = proc_pidinfo(
            @intCast(pid),
            PROC_PIDLISTTHREADS,
            0,
            @ptrCast(&tid_buf),
            @intCast(MAX_THREADS * @sizeOf(u64)),
        );

        if (tid_ret <= 0) return allocator.alloc(common.ThreadStats, 0);

        const num_threads = @as(usize, @intCast(tid_ret)) / @sizeOf(u64);

        var result: std.ArrayList(common.ThreadStats) = .empty;

        for (tid_buf[0..num_threads]) |tid| {
            var thread_info: ProcThreadInfo = undefined;
            const info_ret = proc_pidinfo(
                @intCast(pid),
                PROC_PIDTHREADINFO,
                tid,
                @ptrCast(&thread_info),
                @sizeOf(ProcThreadInfo),
            );
            if (info_ret <= 0) continue;

            const state: common.ProcState = switch (thread_info.pth_run_state) {
                TH_STATE_RUNNING => .running,
                TH_STATE_STOPPED => .stopped,
                TH_STATE_WAITING => .sleeping,
                TH_STATE_UNINTERRUPTIBLE => .disk_sleep,
                TH_STATE_HALTED => .dead,
                else => .unknown,
            };

            // pth_cpu_usage is scaled: TH_USAGE_SCALE (1000) = 100%
            const cpu_percent: f32 = if (thread_info.pth_cpu_usage > 0)
                @as(f32, @floatFromInt(thread_info.pth_cpu_usage)) / 10.0
            else
                0;

            const name_end = std.mem.indexOfScalar(u8, &thread_info.pth_name, 0) orelse 64;
            const name_len: u8 = @intCast(@min(name_end, 63));

            var thread_stat = common.ThreadStats{
                .tid = tid,
                .cpu_percent = cpu_percent,
                .state = state,
                .name_len = name_len,
            };
            if (name_len > 0) {
                @memcpy(thread_stat.name_buf[0..name_len], thread_info.pth_name[0..name_len]);
            }

            try result.append(allocator, thread_stat);
        }

        const thread_slice = try result.toOwnedSlice(allocator);
        common.sortThreadStats(thread_slice);
        return thread_slice;
    }
    pub fn getNetConnections(self: *SysInfo, allocator: std.mem.Allocator) ![]common.NetConnection {
        _ = self;
        var result: std.ArrayList(common.NetConnection) = .empty;
        defer result.deinit(allocator);

        var pids: [MAX_PROCS]c_int = undefined;
        const num_pids_bytes = proc_listallpids(&pids, @intCast(pids.len * @sizeOf(c_int)));
        if (num_pids_bytes <= 0) return result.toOwnedSlice(allocator);
        const num_pids = @as(usize, @intCast(num_pids_bytes)) / @sizeOf(c_int);

        var fd_buf: [4096]c.struct_proc_fdinfo = undefined;

        for (pids[0..num_pids]) |pid| {
            if (pid <= 0) continue;

            const fds_bytes = proc_pidinfo(
                pid,
                c.PROC_PIDLISTFDS,
                0,
                &fd_buf,
                @intCast(fd_buf.len * @sizeOf(c.struct_proc_fdinfo)),
            );
            if (fds_bytes <= 0) continue;
            const num_fds = @as(usize, @intCast(fds_bytes)) / @sizeOf(c.struct_proc_fdinfo);

            var process_name: [64]u8 = std.mem.zeroes([64]u8);
            const name_len_c = proc_name(pid, &process_name, 64);
            const name_len: u8 = if (name_len_c > 0) @intCast(@min(name_len_c, 64)) else 0;

            for (fd_buf[0..num_fds]) |fdinfo| {
                if (fdinfo.proc_fdtype != c.PROX_FDTYPE_SOCKET) continue;

                var socket_info: c.struct_socket_fdinfo = std.mem.zeroes(c.struct_socket_fdinfo);
                const sret = proc_pidfdinfo(
                    pid,
                    fdinfo.proc_fd,
                    c.PROC_PIDFDSOCKETINFO,
                    &socket_info,
                    @sizeOf(c.struct_socket_fdinfo),
                );
                if (sret != @sizeOf(c.struct_socket_fdinfo)) continue;

                const conn = parseSocketFdInfo(@intCast(pid), process_name, name_len, &socket_info) orelse continue;
                try result.append(allocator, conn);
            }
        }
        return result.toOwnedSlice(allocator);
    }
};

fn readCpuTopology(self: *SysInfo) !void {
    const total_logical = @min(@as(usize, @intCast(readSysctlNumber(u32, "hw.logicalcpu") orelse return error.UnexpectedCpuTopology)), MAX_CORES);
    const total_physical = @min(@as(usize, @intCast(readSysctlNumber(u32, "hw.physicalcpu") orelse return error.UnexpectedCpuTopology)), total_logical);
    const perflevel_count = readSysctlNumber(u32, "hw.nperflevels") orelse 0;
    if (perflevel_count == 0 or total_logical == 0 or total_physical == 0) {
        return error.UnexpectedCpuTopology;
    }

    const package_count = @max(readSysctlNumber(u16, "hw.packages") orelse 1, 1);

    var logical_offset: usize = 0;
    var physical_offset: usize = 0;
    var saw_perf = false;
    var saw_eff = false;
    var saw_balanced = false;
    var saw_unknown = false;

    for (0..perflevel_count) |perflevel| {
        var name_buf: [64]u8 = undefined;
        const perf_logical = @as(usize, @intCast(readPerfLevelNumber(u32, perflevel, "logicalcpu") orelse 0));
        const perf_physical = @as(usize, @intCast(readPerfLevelNumber(u32, perflevel, "physicalcpu") orelse 0));
        if (perf_logical == 0 or perf_physical == 0) continue;

        if (logical_offset + perf_logical > total_logical or physical_offset + perf_physical > total_physical) {
            return error.UnexpectedCpuTopology;
        }

        const perf_class = efficiencyClassFromName(readPerfLevelString(perflevel, "name", &name_buf) orelse "");
        markEfficiencyClass(perf_class, &saw_perf, &saw_eff, &saw_balanced, &saw_unknown);

        const threads_per_core = @max(std.math.divCeil(usize, perf_logical, perf_physical) catch 1, 1);
        const cpus_per_l2 = @as(usize, @intCast(readPerfLevelNumber(u32, perflevel, "cpusperl2") orelse @as(u32, @intCast(perf_physical))));
        const cores_per_cache = @max(@min(cpus_per_l2, perf_physical), 1);

        for (0..perf_physical) |physical_local| {
            const cluster_core_start = (physical_local / cores_per_cache) * cores_per_cache;
            const cluster_core_count = @min(cores_per_cache, perf_physical - cluster_core_start);
            const cluster_first_logical = logical_offset + cluster_core_start * threads_per_core;
            const shared_count = cluster_core_count * threads_per_core;

            for (0..threads_per_core) |thread_index| {
                const logical_local = physical_local + thread_index * perf_physical;
                if (logical_local >= perf_logical) break;

                const global_logical = logical_offset + logical_local;
                self.topology_cores[global_logical] = .{
                    .logical_id = @intCast(global_logical),
                    .physical_id = @intCast(physical_offset + physical_local),
                    .package_id = 0,
                    .numa_node_id = -1,
                    .thread_index = @intCast(thread_index),
                    .threads_per_core = @intCast(threads_per_core),
                    .shared_cache_group_id = @intCast(cluster_first_logical),
                    .shared_cache_level = 2,
                    .shared_cache_logical_count = @intCast(shared_count),
                    .efficiency_class = perf_class,
                };
            }
        }

        logical_offset += perf_logical;
        physical_offset += perf_physical;
    }

    if (logical_offset != total_logical or physical_offset != total_physical) {
        return error.UnexpectedCpuTopology;
    }

    assignPackagesEvenly(self.topology_cores[0..logical_offset], total_physical, package_count);

    self.topology_count = logical_offset;
    self.topology_physical_cores = @intCast(total_physical);
    self.topology_package_count = package_count;
    self.topology_numa_count = 0;
    self.topology_has_cache_groups = countUniqueCacheGroups(self.topology_cores[0..logical_offset]) > 1;
    self.topology_has_efficiency_classes = countSeenClasses(saw_perf, saw_eff, saw_balanced, saw_unknown) > 1;
}

fn assignPackagesEvenly(logical_cores: []CpuLogicalCore, total_physical: usize, package_count: u16) void {
    if (package_count <= 1 or total_physical == 0) return;

    const physical_per_package = @max(std.math.divCeil(usize, total_physical, package_count) catch total_physical, 1);
    for (logical_cores) |*logical_core| {
        logical_core.package_id = @intCast(@min(@as(usize, logical_core.physical_id) / physical_per_package, package_count - 1));
    }
}

fn countUniqueCacheGroups(logical_cores: []const CpuLogicalCore) usize {
    var groups: [MAX_CORES]struct { level: u8, group_id: i16 } = undefined;
    var group_count: usize = 0;

    for (logical_cores) |logical_core| {
        if (logical_core.shared_cache_group_id < 0 or logical_core.shared_cache_level == 0) continue;

        var found = false;
        for (groups[0..group_count]) |group| {
            if (group.level == logical_core.shared_cache_level and group.group_id == logical_core.shared_cache_group_id) {
                found = true;
                break;
            }
        }
        if (!found and group_count < groups.len) {
            groups[group_count] = .{
                .level = logical_core.shared_cache_level,
                .group_id = logical_core.shared_cache_group_id,
            };
            group_count += 1;
        }
    }

    return group_count;
}

fn countSeenClasses(saw_perf: bool, saw_eff: bool, saw_balanced: bool, saw_unknown: bool) usize {
    var count: usize = 0;
    if (saw_perf) count += 1;
    if (saw_eff) count += 1;
    if (saw_balanced) count += 1;
    if (saw_unknown) count += 1;
    return count;
}

fn markEfficiencyClass(class: CpuEfficiencyClass, saw_perf: *bool, saw_eff: *bool, saw_balanced: *bool, saw_unknown: *bool) void {
    switch (class) {
        .performance => saw_perf.* = true,
        .efficiency => saw_eff.* = true,
        .balanced => saw_balanced.* = true,
        .unknown => saw_unknown.* = true,
    }
}

fn efficiencyClassFromName(name: []const u8) CpuEfficiencyClass {
    var lowered_buf: [64]u8 = undefined;
    const lower_len = @min(name.len, lowered_buf.len);
    for (name[0..lower_len], 0..) |ch, idx| {
        lowered_buf[idx] = std.ascii.toLower(ch);
    }
    const lowered = lowered_buf[0..lower_len];

    if (std.mem.indexOf(u8, lowered, "performance") != null) return .performance;
    if (std.mem.indexOf(u8, lowered, "efficiency") != null) return .efficiency;
    if (std.mem.indexOf(u8, lowered, "balanced") != null) return .balanced;
    return .unknown;
}

fn readPerfLevelNumber(comptime T: type, perflevel: usize, field: []const u8) ?T {
    var name_buf: [64]u8 = undefined;
    const sysctl_name = std.fmt.bufPrintZ(&name_buf, "hw.perflevel{d}.{s}", .{ perflevel, field }) catch return null;
    return readSysctlNumber(T, sysctl_name);
}

fn readPerfLevelString(perflevel: usize, field: []const u8, buf: []u8) ?[]const u8 {
    var name_buf: [64]u8 = undefined;
    const sysctl_name = std.fmt.bufPrintZ(&name_buf, "hw.perflevel{d}.{s}", .{ perflevel, field }) catch return null;
    return readSysctlString(sysctl_name, buf);
}

fn readSysctlNumber(comptime T: type, name: [:0]const u8) ?T {
    var value: T = 0;
    var size: usize = @sizeOf(T);
    if (sysctlbyname(name.ptr, @ptrCast(&value), &size, null, 0) != 0) return null;
    if (size < @sizeOf(T)) return null;
    return value;
}

fn readSysctlString(name: [:0]const u8, buf: []u8) ?[]const u8 {
    var size = buf.len;
    if (sysctlbyname(name.ptr, @ptrCast(buf.ptr), &size, null, 0) != 0) return null;
    if (size == 0) return null;

    const used = if (size > 0 and buf[@min(size, buf.len) - 1] == 0) @min(size, buf.len) - 1 else @min(size, buf.len);
    return buf[0..used];
}

pub fn parseSocketFdInfo(pid: u32, process_name: [64]u8, name_len: u8, socket_info: *const c.struct_socket_fdinfo) ?common.NetConnection {
    const kind = socket_info.psi.soi_kind;
    const in_info: c.struct_in_sockinfo = switch (kind) {
        c.SOCKINFO_IN => socket_info.psi.soi_proto.pri_in,
        c.SOCKINFO_TCP => socket_info.psi.soi_proto.pri_tcp.tcpsi_ini,
        else => return null,
    };

    var conn = common.NetConnection{
        .protocol = protocolForSocketKind(kind, in_info.insi_vflag),
        .pid = pid,
        .process_name = process_name,
        .process_name_len = name_len,
    };
    conn.local_port = decodeSocketPort(in_info.insi_lport);
    conn.remote_port = decodeSocketPort(in_info.insi_fport);
    formatSocketAddress(&conn.local_addr, in_info, true);
    formatSocketAddress(&conn.remote_addr, in_info, false);

    if (kind == c.SOCKINFO_TCP) {
        conn.state = mapTcpState(socket_info.psi.soi_proto.pri_tcp.tcpsi_state);
    }

    return conn;
}

fn protocolForSocketKind(kind: c_int, vflag: u8) common.NetProtocol {
    const is_ipv6 = (vflag & c.INI_IPV6) != 0;
    return switch (kind) {
        c.SOCKINFO_TCP => if (is_ipv6) .tcp6 else .tcp,
        c.SOCKINFO_IN => if (is_ipv6) .udp6 else .udp,
        else => .unknown,
    };
}

fn decodeSocketPort(port: c_int) u16 {
    if (port <= 0) return 0;
    return std.mem.nativeToBig(u16, @intCast(port));
}

fn formatSocketAddress(dest: *[46]u8, in_info: c.struct_in_sockinfo, is_local: bool) void {
    dest.* = std.mem.zeroes([46]u8);

    if ((in_info.insi_vflag & c.INI_IPV4) != 0) {
        const addr = if (is_local) in_info.insi_laddr.ina_46.i46a_addr4 else in_info.insi_faddr.ina_46.i46a_addr4;
        const octets: [4]u8 = @bitCast(addr.s_addr);
        _ = std.fmt.bufPrint(dest, "{}.{}.{}.{}", .{ octets[0], octets[1], octets[2], octets[3] }) catch {};
        return;
    }

    if ((in_info.insi_vflag & c.INI_IPV6) != 0) {
        const addr = if (is_local) in_info.insi_laddr.ina_6 else in_info.insi_faddr.ina_6;
        const octets = std.mem.asBytes(&addr);
        _ = std.fmt.bufPrint(
            dest,
            "{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}",
            .{
                octets[0],  octets[1],  octets[2],  octets[3],
                octets[4],  octets[5],  octets[6],  octets[7],
                octets[8],  octets[9],  octets[10], octets[11],
                octets[12], octets[13], octets[14], octets[15],
            },
        ) catch {};
    }
}

pub fn mapTcpState(state: c_int) common.NetConnState {
    return switch (state) {
        c.TSI_S_CLOSED => .closed,
        c.TSI_S_LISTEN => .listen,
        c.TSI_S_SYN_SENT => .syn_sent,
        c.TSI_S_SYN_RECEIVED => .syn_recv,
        c.TSI_S_ESTABLISHED => .established,
        c.TSI_S__CLOSE_WAIT => .close_wait,
        c.TSI_S_FIN_WAIT_1 => .fin_wait1,
        c.TSI_S_CLOSING => .closing,
        c.TSI_S_LAST_ACK => .last_ack,
        c.TSI_S_FIN_WAIT_2 => .fin_wait2,
        c.TSI_S_TIME_WAIT => .time_wait,
        else => .unknown,
    };
}

fn readNetTotals() !NetTotals {
    var mib = [_]c_int{ c.CTL_NET, c.PF_ROUTE, 0, 0, c.NET_RT_IFLIST2, 0 };
    var len: usize = 0;
    if (c.sysctl(&mib, mib.len, null, &len, null, 0) != 0) return error.SysctlFailed;

    const buf = try std.heap.page_allocator.alloc(u8, len);
    defer std.heap.page_allocator.free(buf);

    if (c.sysctl(&mib, mib.len, buf.ptr, &len, null, 0) != 0) return error.SysctlFailed;

    var rx: u64 = 0;
    var tx: u64 = 0;
    var offset: usize = 0;

    while (offset + @sizeOf(c.struct_if_msghdr2) <= len) {
        const hdr: *align(1) const c.struct_if_msghdr2 = @ptrCast(buf.ptr + offset);
        const msg_len: usize = hdr.ifm_msglen;
        if (msg_len == 0) break;

        if (msg_len >= @sizeOf(c.struct_if_msghdr2) and hdr.ifm_type == c.RTM_IFINFO2 and (hdr.ifm_flags & c.IFF_LOOPBACK) == 0) {
            rx +|= hdr.ifm_data.ifi_ibytes;
            tx +|= hdr.ifm_data.ifi_obytes;
        }

        offset += msg_len;
    }

    return .{ .rx_bytes = rx, .tx_bytes = tx };
}

fn readLaunchCommand(pid: c_int, dest: []u8) ![]const u8 {
    var argmax: usize = 0;
    var argmax_len: usize = @sizeOf(usize);
    if (sysctlbyname("kern.argmax", &argmax, &argmax_len, null, 0) == 0 and argmax > @sizeOf(c_int) and argmax <= 64 * 1024) {
        const buf = try std.heap.page_allocator.alloc(u8, argmax);
        defer std.heap.page_allocator.free(buf);

        var mib = [_]c_int{ c.CTL_KERN, c.KERN_PROCARGS2, pid };
        var len = buf.len;
        if (c.sysctl(&mib, mib.len, buf.ptr, &len, null, 0) == 0) {
            if (parseKernProcArgs(buf[0..len], dest)) |cmd| return cmd;
        }
    }

    var path_buf: [std.fs.max_path_bytes]u8 = std.mem.zeroes([std.fs.max_path_bytes]u8);
    const path_len = proc_pidpath(pid, &path_buf, @intCast(path_buf.len));
    if (path_len > 0) {
        const bounded_len: usize = @intCast(@min(path_len, dest.len));
        @memcpy(dest[0..bounded_len], path_buf[0..bounded_len]);
        return dest[0..bounded_len];
    }

    return dest[0..0];
}

fn parseKernProcArgs(raw: []const u8, dest: []u8) ?[]const u8 {
    if (raw.len <= @sizeOf(c_int)) return null;

    const argc = std.mem.readInt(c_int, raw[0..@sizeOf(c_int)], @import("builtin").cpu.arch.endian());
    if (argc <= 0) return null;

    var offset: usize = @sizeOf(c_int);
    while (offset < raw.len and raw[offset] != 0) : (offset += 1) {}
    while (offset < raw.len and raw[offset] == 0) : (offset += 1) {}

    var write_idx: usize = 0;
    var args_seen: c_int = 0;
    while (offset < raw.len and args_seen < argc) : (args_seen += 1) {
        const arg_start = offset;
        while (offset < raw.len and raw[offset] != 0) : (offset += 1) {}
        const arg = raw[arg_start..offset];
        if (arg.len > 0) {
            if (write_idx > 0 and write_idx < dest.len) {
                dest[write_idx] = ' ';
                write_idx += 1;
            }

            const available = dest.len -| write_idx;
            if (available == 0) break;

            const copy_len = @min(arg.len, available);
            @memcpy(dest[write_idx .. write_idx + copy_len], arg[0..copy_len]);
            write_idx += copy_len;
            if (copy_len < arg.len) break;
        }

        while (offset < raw.len and raw[offset] == 0) : (offset += 1) {}
    }

    if (write_idx == 0) return null;
    return dest[0..write_idx];
}

fn readDiskTotals() !DiskTotals {
    const matching = c.IOServiceMatching(c.kIOBlockStorageDriverClass) orelse return error.IOKitMatchingFailed;

    var iter: c.io_iterator_t = 0;
    if (c.IOServiceGetMatchingServices(c.kIOMainPortDefault, matching, &iter) != c.KERN_SUCCESS) {
        return error.IOKitQueryFailed;
    }
    defer _ = c.IOObjectRelease(iter);

    const stats_key = c.CFStringCreateWithCString(null, c.kIOBlockStorageDriverStatisticsKey, c.kCFStringEncodingUTF8) orelse {
        return error.OutOfMemory;
    };
    defer c.CFRelease(stats_key);

    const read_key = c.CFStringCreateWithCString(null, c.kIOBlockStorageDriverStatisticsBytesReadKey, c.kCFStringEncodingUTF8) orelse {
        return error.OutOfMemory;
    };
    defer c.CFRelease(read_key);

    const write_key = c.CFStringCreateWithCString(null, c.kIOBlockStorageDriverStatisticsBytesWrittenKey, c.kCFStringEncodingUTF8) orelse {
        return error.OutOfMemory;
    };
    defer c.CFRelease(write_key);

    var read_bytes: u64 = 0;
    var write_bytes: u64 = 0;

    while (true) {
        const service = c.IOIteratorNext(iter);
        if (service == 0) break;
        defer _ = c.IOObjectRelease(service);

        const stats_ref = c.IORegistryEntryCreateCFProperty(service, stats_key, null, 0) orelse continue;
        defer c.CFRelease(stats_ref);

        if (c.CFGetTypeID(stats_ref) != c.CFDictionaryGetTypeID()) continue;

        const stats_dict: c.CFDictionaryRef = @ptrCast(stats_ref);
        read_bytes +|= getCFDictionaryU64(stats_dict, read_key);
        write_bytes +|= getCFDictionaryU64(stats_dict, write_key);
    }

    return .{ .read_bytes = read_bytes, .write_bytes = write_bytes };
}

fn getCFDictionaryU64(dict: c.CFDictionaryRef, key: c.CFStringRef) u64 {
    const value = c.CFDictionaryGetValue(dict, key) orelse return 0;
    if (c.CFGetTypeID(value) != c.CFNumberGetTypeID()) return 0;

    var raw: i64 = 0;
    if (c.CFNumberGetValue(@ptrCast(value), c.kCFNumberSInt64Type, &raw) == 0 or raw < 0) return 0;

    return @intCast(raw);
}
