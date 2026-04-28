const std = @import("std");
const common = @import("common.zig");

const bindings = @import("darwin/bindings.zig");
const cf_util = @import("darwin/cf_util.zig");
const gpu_mod = @import("darwin/gpu.zig");
const net_mod = @import("darwin/net.zig");
const disk_mod = @import("darwin/disk.zig");
const process_mod = @import("darwin/process.zig");

// Re-export public API that tests depend on
pub const c = bindings.c;
pub const parseSocketFdInfo = net_mod.parseSocketFdInfo;
pub const mapTcpState = net_mod.mapTcpState;
pub const mapWifiGeneration = net_mod.mapWifiGeneration;

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

const DiskTotals = disk_mod.DiskTotals;
const DiskUsage = disk_mod.DiskUsage;
const NetTotals = net_mod.NetTotals;

const mach_port_t = bindings.mach_port_t;
const kern_return_t = bindings.kern_return_t;
const MachTimebaseInfo = bindings.MachTimebaseInfo;

const HOST_CPU_LOAD_INFO = bindings.HOST_CPU_LOAD_INFO;
const HOST_VM_INFO = bindings.HOST_VM_INFO;
const PROCESSOR_CPU_LOAD_INFO = bindings.PROCESSOR_CPU_LOAD_INFO;
const KERN_SUCCESS = bindings.KERN_SUCCESS;
const PROC_PIDTASKINFO = bindings.PROC_PIDTASKINFO;
const CPU_STATE_USER = bindings.CPU_STATE_USER;
const CPU_STATE_SYSTEM = bindings.CPU_STATE_SYSTEM;
const CPU_STATE_IDLE = bindings.CPU_STATE_IDLE;
const CPU_STATE_NICE = bindings.CPU_STATE_NICE;
const CPU_STATE_MAX = bindings.CPU_STATE_MAX;

const PROC_PIDTHREADINFO = bindings.PROC_PIDTHREADINFO;
const PROC_PIDRUSAGE = bindings.PROC_PIDRUSAGE;
const PROC_PIDLISTTHREADS = bindings.PROC_PIDLISTTHREADS;
const PROC_PIDT_SHORTBSDINFO = bindings.PROC_PIDT_SHORTBSDINFO;

const SIDL = bindings.SIDL;
const SRUN = bindings.SRUN;
const SSLEEP = bindings.SSLEEP;
const SSTOP = bindings.SSTOP;
const SZOMB = bindings.SZOMB;

const ProcBsdShortInfo = bindings.ProcBsdShortInfo;
const rusage_info_v2 = bindings.rusage_info_v2;
const HostCpuLoadInfo = bindings.HostCpuLoadInfo;
const VmStatistics = bindings.VmStatistics;
const xsw_usage = bindings.xsw_usage;
const ProcTaskInfo = bindings.ProcTaskInfo;
const ProcThreadInfo = bindings.ProcThreadInfo;

const TH_STATE_RUNNING = bindings.TH_STATE_RUNNING;
const TH_STATE_STOPPED = bindings.TH_STATE_STOPPED;
const TH_STATE_WAITING = bindings.TH_STATE_WAITING;
const TH_STATE_UNINTERRUPTIBLE = bindings.TH_STATE_UNINTERRUPTIBLE;
const TH_STATE_HALTED = bindings.TH_STATE_HALTED;

const MAX_THREADS = common.MAX_THREADS;

const kIOHIDEventTypeTemperature: i64 = 15;
const kIOHIDEventTypePower: i64 = 25;
fn IOHIDEventFieldBase(t: i64) u32 {
    return @intCast(t << 16);
}

pub const SysInfo = struct {
    io: std.Io,
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
    disk_usage: DiskUsage = .{ .total_bytes = 0, .used_bytes = 0 },
    prev_net_rx: u64 = 0,
    prev_net_tx: u64 = 0,
    prev_ms: i64 = 0,
    prev_disk_ms: i64 = 0,
    prev_net_ms: i64 = 0,
    wifi_details: common.WifiDetails = .{},
    wifi_fetched: bool = false,
    hid_client: ?c.IOHIDEventSystemClientRef = null,

    pub fn init(io: std.Io) SysInfo {
        const host_port = bindings.mach_host_self();

        var ncpu: u32 = 0;
        var ncpu_size: usize = @sizeOf(u32);
        _ = bindings.sysctlbyname("hw.logicalcpu", @ptrCast(&ncpu), &ncpu_size, null, 0);

        var total_mem: u64 = 0;
        var mem_size: usize = @sizeOf(u64);
        _ = bindings.sysctlbyname("hw.memsize", @ptrCast(&total_mem), &mem_size, null, 0);

        var pg_size: usize = 0;
        _ = bindings.host_page_size(host_port, &pg_size);

        var timebase: MachTimebaseInfo = undefined;
        _ = bindings.mach_timebase_info(&timebase);

        const now = nowMs(io);

        var self: SysInfo = .{
            .io = io,
            .ncpu = if (ncpu > 0) @min(ncpu, @as(u32, MAX_CORES)) else 1,
            .total_mem = total_mem,
            .page_size = if (pg_size > 0) pg_size else 4096,
            .host_port = host_port,
            .timebase = timebase,
            .disk_usage = disk_mod.readDiskUsage() catch .{ .total_bytes = 0, .used_bytes = 0 },
            .prev_ms = now,
            .prev_disk_ms = now,
            .prev_net_ms = now,
            .hid_client = c.IOHIDEventSystemClientCreate(null),
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
        const ret = bindings.host_statistics(self.host_port, HOST_CPU_LOAD_INFO, @ptrCast(&cpu_load), &count);

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
        const proc_ret = bindings.host_processor_info(
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

        defer _ = bindings.vm_deallocate(
            bindings.mach_task_self(),
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
        const ret = bindings.host_statistics(self.host_port, HOST_VM_INFO, @ptrCast(&vm_stats), &count);

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
        _ = bindings.sysctlbyname("vm.swapusage", @ptrCast(&swap), &swap_size, null, 0);

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
        const stats = disk_mod.readDiskTotals() catch DiskTotals{ .read_bytes = 0, .write_bytes = 0 };
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

        return .{
            .read_bytes_ps = read_ps,
            .write_bytes_ps = write_ps,
            .capacity_used_bytes = self.disk_usage.used_bytes,
            .capacity_total_bytes = self.disk_usage.total_bytes,
        };
    }

    pub fn getNetStats(self: *SysInfo) NetStats {
        const stats = net_mod.readNetTotals() catch NetTotals{ .rx_bytes = 0, .tx_bytes = 0 };
        const now = nowMs(self.io);
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

        if (!self.wifi_fetched) {
            self.wifi_details = net_mod.readWifiDetails();
            self.wifi_fetched = true;
        }

        return .{
            .rx_bytes_ps = rx_ps,
            .tx_bytes_ps = tx_ps,
            .rx_bytes = stats.rx_bytes,
            .tx_bytes = stats.tx_bytes,
            .wifi = self.wifi_details,
        };
    }

    pub fn getThermalStats(self: *SysInfo) ThermalStats {
        var stats = ThermalStats{};
        const client = self.hid_client orelse return stats;

        const services = c.IOHIDEventSystemClientCopyServices(client) orelse return stats;
        defer c.CFRelease(services);

        const product_key = c.CFStringCreateWithCString(null, "Product", c.kCFStringEncodingUTF8) orelse return stats;
        defer c.CFRelease(product_key);

        var max_cpu_temp: f64 = 0;
        var max_gpu_temp: f64 = 0;

        const count = c.CFArrayGetCount(services);
        for (0..@intCast(count)) |i| {
            const service: c.IOHIDServiceClientRef = @ptrCast(@alignCast(@constCast(c.CFArrayGetValueAtIndex(services, @intCast(i)) orelse continue)));

            if (c.IOHIDServiceClientConformsTo(service, 0xff00, 5) == 0) continue;

            const event = c.IOHIDServiceClientCopyEvent(service, kIOHIDEventTypeTemperature, 0, 0) orelse continue;
            defer c.CFRelease(event);

            const val = c.IOHIDEventGetFloatValue(event, IOHIDEventFieldBase(kIOHIDEventTypeTemperature));
            if (val <= 0) continue;

            var name_buf: [64]u8 = undefined;
            var name: []const u8 = "";
            const prop = c.IOHIDServiceClientCopyProperty(service, product_key);
            if (prop) |p| {
                defer c.CFRelease(p);
                if (cf_util.copyCFStringLikeValue(p, &name_buf)) |len| {
                    name = name_buf[0..len];
                }
            }

            // Apple Silicon HID thermal sensor naming:
            //   "PMU tdie*"  = SoC die cluster temps (CPU E/P-core clusters)
            //   "PMU tdev*"  = thermal device sensors (GPU/ANE proximity)
            //   "PMU tcal"   = PMU calibration reference — NOT a component temp, excluded
            //   "PMU TP*"    = temperature probes (ambient/board)
            if (std.mem.indexOf(u8, name, "tdie") != null or
                std.mem.indexOf(u8, name, "Soc Die") != null or
                std.mem.indexOf(u8, name, "TD0P") != null)
            {
                if (val > max_cpu_temp) max_cpu_temp = val;
            } else if (std.mem.indexOf(u8, name, "tdev") != null or
                std.mem.indexOf(u8, name, "GPU Die") != null or
                std.mem.indexOf(u8, name, "TG0P") != null)
            {
                if (val > max_gpu_temp) max_gpu_temp = val;
            }
        }

        if (max_cpu_temp > 0) stats.cpu_temp = @floatCast(max_cpu_temp);
        if (max_gpu_temp > 0) stats.gpu_temp = @floatCast(max_gpu_temp);

        return stats;
    }

    pub fn getBatteryStats(self: *SysInfo) BatteryStats {
        _ = self;
        var stats = BatteryStats{};

        const blob = c.IOPSCopyPowerSourcesInfo() orelse return stats;
        defer c.CFRelease(blob);

        const list = c.IOPSCopyPowerSourcesList(blob) orelse return stats;
        defer c.CFRelease(list);

        if (c.CFArrayGetCount(list) == 0) return stats;

        const ps = c.CFArrayGetValueAtIndex(list, 0) orelse return stats;
        const desc = c.IOPSGetPowerSourceDescription(blob, ps) orelse return stats;
        const dict: c.CFDictionaryRef = @ptrCast(desc);

        if (cf_util.getCFDictionaryNumberFromCString(dict, c.kIOPSCurrentCapacityKey)) |cap| {
            if (cf_util.getCFDictionaryNumberFromCString(dict, c.kIOPSMaxCapacityKey)) |max| {
                if (max > 0) {
                    stats.charge_percent = @as(f32, @floatFromInt(cap)) / @as(f32, @floatFromInt(max)) * 100.0;
                }
            }
        }

        // Charge status
        if (cf_util.getCFDictionaryValueFromCString(dict, c.kIOPSPowerSourceStateKey)) |sr| {
            var buf: [32]u8 = undefined;
            if (cf_util.copyCFStringLikeValue(sr, &buf)) |len| {
                const state = buf[0..len];
                if (std.mem.eql(u8, state, "AC Power")) {
                    if (cf_util.getCFDictionaryValueFromCString(dict, c.kIOPSIsChargingKey)) |cr| {
                        if (c.CFGetTypeID(cr) == c.CFBooleanGetTypeID()) {
                            stats.status = if (c.CFBooleanGetValue(@ptrCast(@alignCast(cr))) != 0) .charging else .full;
                        }
                    }
                } else if (std.mem.eql(u8, state, "Battery Power")) {
                    stats.status = .discharging;
                }
            }
        }

        const amp_raw = cf_util.getCFDictionarySignedNumberFromCString(dict, "Amperage");
        const volt_raw = cf_util.getCFDictionaryNumberFromCString(dict, "Voltage");
        if (amp_raw) |amp_ma| {
            if (volt_raw) |volt_mv| {
                if (volt_mv > 0) {
                    const watts = @abs(@as(f64, @floatFromInt(amp_ma))) * @as(f64, @floatFromInt(volt_mv)) / 1_000_000.0;
                    if (watts > 0) stats.power_draw_w = @floatCast(watts);
                }
            }
        }

        return stats;
    }

    pub fn getGpuStats(self: *SysInfo, allocator: std.mem.Allocator) ![]GpuStats {
        _ = self;
        var result: std.ArrayList(GpuStats) = .empty;
        errdefer result.deinit(allocator);

        try gpu_mod.appendAppleGpuStats(allocator, &result);

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

    fn machToNs(self: *const SysInfo, mach_time: u64) u64 {
        return mach_time * self.timebase.numer / self.timebase.denom;
    }

    /// Fill `out_buf` with process stats, returning the used portion.
    /// Caller owns `out_buf` — no heap allocation per call.
    pub fn getProcStats(self: *SysInfo, out_buf: []ProcStats, sort_by: common.SortBy) ![]ProcStats {
        const current_time = bindings.mach_absolute_time();
        const wall_delta_ns: u64 = if (self.prev_time > 0) self.machToNs(current_time -| self.prev_time) else 0;
        const now_ms = nowMs(self.io);
        const elapsed_ms = now_ms - self.prev_ms;

        var pid_buf: [MAX_PROCS]c_int = undefined;
        const num_pids_raw = bindings.proc_listallpids(&pid_buf, @intCast(MAX_PROCS * @sizeOf(c_int)));
        const num_pids: usize = if (num_pids_raw > 0) @intCast(num_pids_raw) else 0;

        var proc_count: usize = 0;
        var new_procs: [MAX_PROCS]ProcCpuEntry = undefined;
        var new_proc_count: usize = 0;

        for (pid_buf[0..num_pids]) |raw_pid| {
            if (raw_pid <= 0) continue;
            const pid: u32 = @intCast(raw_pid);

            var task_info: ProcTaskInfo = undefined;
            const info_ret = bindings.proc_pidinfo(raw_pid, PROC_PIDTASKINFO, 0, @ptrCast(&task_info), @sizeOf(ProcTaskInfo));
            if (info_ret <= 0) continue;

            var bsd_info: ProcBsdShortInfo = undefined;
            const bsd_ret = bindings.proc_pidinfo(raw_pid, PROC_PIDT_SHORTBSDINFO, 0, @ptrCast(&bsd_info), @sizeOf(ProcBsdShortInfo));
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
            const name_ret = bindings.proc_name(raw_pid, &nbuf, 64);
            const name_len: u8 = if (name_ret > 0) @intCast(@min(@as(usize, @intCast(name_ret)), 63)) else 0;
            if (name_len == 0) continue;

            const cpu_total = task_info.pti_total_user +| task_info.pti_total_system;

            var rusage: rusage_info_v2 = undefined;
            const ru_ret = bindings.proc_pidinfo(raw_pid, PROC_PIDRUSAGE, 0, @ptrCast(&rusage), @sizeOf(rusage_info_v2));
            const disk_read = if (ru_ret > 0) rusage.ri_diskio_bytesread else 0;
            const disk_write = if (ru_ret > 0) rusage.ri_diskio_byteswritten else 0;
            const wakeups_total = if (ru_ret > 0) rusage.ri_pkg_idle_wkups +| rusage.ri_interrupt_wkups else 0;
            const context_switches_total = if (task_info.pti_csw > 0) @as(u64, @intCast(task_info.pti_csw)) else 0;

            var cpu_percent: f32 = 0;
            var disk_read_ps: u64 = 0;
            var disk_write_ps: u64 = 0;
            var wakeups_ps: u64 = 0;
            var context_switches_ps: u64 = 0;

            var launch_cmd_buf: [256]u8 = std.mem.zeroes([256]u8);
            var launch_cmd_len: u16 = 0;

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
                    const d_wakeups = wakeups_total -| prev.wakeups;
                    const d_csw = context_switches_total -| prev.context_switches;
                    wakeups_ps = (d_wakeups *| 1000) / @as(u64, @intCast(elapsed_ms));
                    context_switches_ps = (d_csw *| 1000) / @as(u64, @intCast(elapsed_ms));
                }
                @memcpy(launch_cmd_buf[0..prev.launch_cmd_len], prev.launch_cmd_buf[0..prev.launch_cmd_len]);
                launch_cmd_len = prev.launch_cmd_len;
            }

            if (launch_cmd_len == 0) {
                const launch_cmd = process_mod.readLaunchCommand(raw_pid, &launch_cmd_buf) catch &[_]u8{};
                launch_cmd_len = @intCast(launch_cmd.len);
            }

            if (new_proc_count < MAX_PROCS) {
                new_procs[new_proc_count] = .{
                    .pid = pid,
                    .cpu_total = cpu_total,
                    .disk_read = disk_read,
                    .disk_write = disk_write,
                    .wakeups = wakeups_total,
                    .context_switches = context_switches_total,
                    .launch_cmd_buf = launch_cmd_buf,
                    .launch_cmd_len = launch_cmd_len,
                };
                new_proc_count += 1;
            }

            const mem_percent: f32 = if (self.total_mem > 0)
                @as(f32, @floatFromInt(task_info.pti_resident_size)) / @as(f32, @floatFromInt(self.total_mem)) * 100.0
            else
                0;

            if (proc_count >= out_buf.len) continue;

            out_buf[proc_count] = ProcStats{
                .pid = pid,
                .ppid = bsd_info.pbsi_ppid,
                .cpu_percent = cpu_percent,
                .mem_percent = mem_percent,
                .threads = @intCast(task_info.pti_threadnum),
                .disk_read_ps = disk_read_ps,
                .disk_write_ps = disk_write_ps,
                .wakeups_ps = wakeups_ps,
                .context_switches_ps = context_switches_ps,
                .name_len = name_len,
                .state = state,
            };
            @memcpy(out_buf[proc_count].name_buf[0..name_len], nbuf[0..name_len]);
            @memcpy(out_buf[proc_count].launch_cmd_buf[0..launch_cmd_len], launch_cmd_buf[0..launch_cmd_len]);
            out_buf[proc_count].launch_cmd_len = launch_cmd_len;

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
        self.prev_time = current_time;
        self.prev_ms = now_ms;

        const result = out_buf[0..proc_count];
        common.sortProcStats(result, sort_by);
        return result;
    }

    pub fn getThreadStats(self: *SysInfo, allocator: std.mem.Allocator, pid: u32) ![]common.ThreadStats {
        _ = self;

        // Get list of thread unique IDs
        var tid_buf: [MAX_THREADS]u64 = undefined;
        const tid_ret = bindings.proc_pidinfo(
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
            const info_ret = bindings.proc_pidinfo(
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
        const num_pids_bytes = bindings.proc_listallpids(&pids, @intCast(pids.len * @sizeOf(c_int)));
        if (num_pids_bytes <= 0) return result.toOwnedSlice(allocator);
        const num_pids = @as(usize, @intCast(num_pids_bytes)) / @sizeOf(c_int);

        var fd_buf: [4096]c.struct_proc_fdinfo = undefined;

        for (pids[0..num_pids]) |pid| {
            if (pid <= 0) continue;

            const fds_bytes = bindings.proc_pidinfo(
                pid,
                c.PROC_PIDLISTFDS,
                0,
                &fd_buf,
                @intCast(fd_buf.len * @sizeOf(c.struct_proc_fdinfo)),
            );
            if (fds_bytes <= 0) continue;
            const num_fds = @as(usize, @intCast(fds_bytes)) / @sizeOf(c.struct_proc_fdinfo);

            var process_name: [64]u8 = std.mem.zeroes([64]u8);
            const name_len_c = bindings.proc_name(pid, &process_name, 64);
            const name_len: u8 = if (name_len_c > 0) @intCast(@min(name_len_c, 64)) else 0;

            for (fd_buf[0..num_fds]) |fdinfo| {
                if (fdinfo.proc_fdtype != c.PROX_FDTYPE_SOCKET) continue;

                var socket_info: c.struct_socket_fdinfo = std.mem.zeroes(c.struct_socket_fdinfo);
                const sret = bindings.proc_pidfdinfo(
                    pid,
                    fdinfo.proc_fd,
                    c.PROC_PIDFDSOCKETINFO,
                    &socket_info,
                    @sizeOf(c.struct_socket_fdinfo),
                );
                if (sret != @sizeOf(c.struct_socket_fdinfo)) continue;

                const conn = net_mod.parseSocketFdInfo(@intCast(pid), process_name, name_len, &socket_info) orelse continue;
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
    if (bindings.sysctlbyname(name.ptr, @ptrCast(&value), &size, null, 0) != 0) return null;
    if (size < @sizeOf(T)) return null;
    return value;
}

fn readSysctlString(name: [:0]const u8, buf: []u8) ?[]const u8 {
    var size = buf.len;
    if (bindings.sysctlbyname(name.ptr, @ptrCast(buf.ptr), &size, null, 0) != 0) return null;
    if (size == 0) return null;

    const used = if (size > 0 and buf[@min(size, buf.len) - 1] == 0) @min(size, buf.len) - 1 else @min(size, buf.len);
    return buf[0..used];
}
