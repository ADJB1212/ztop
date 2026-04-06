const std = @import("std");
const common = @import("common.zig");
const c = @cImport({
    @cInclude("sys/sysctl.h");
    @cInclude("sys/socket.h");
    @cInclude("net/if.h");
    @cInclude("net/route.h");
    @cInclude("IOKit/IOKitLib.h");
    @cInclude("IOKit/storage/IOBlockStorageDriver.h");
    @cInclude("CoreFoundation/CoreFoundation.h");
});

const CpuStats = common.CpuStats;
const MemStats = common.MemStats;
const DiskStats = common.DiskStats;
const NetStats = common.NetStats;
const ThermalStats = common.ThermalStats;
const BatteryStats = common.BatteryStats;
const BatteryStatus = common.BatteryStatus;
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
extern "c" fn proc_name(pid: c_int, buffer: [*]u8, bufsize: u32) c_int;
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

const PROC_PIDRUSAGE = 5;

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

pub const SysInfo = struct {
    prev_ticks: [4]u64 = .{ 0, 0, 0, 0 },
    prev_core_ticks: [MAX_CORES][4]u64 = std.mem.zeroes([MAX_CORES][4]u64),
    core_usage: [MAX_CORES]f32 = [_]f32{0} ** MAX_CORES,
    ncpu: u32,
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

        return .{
            .ncpu = if (ncpu > 0) @min(ncpu, @as(u32, MAX_CORES)) else 1,
            .total_mem = total_mem,
            .page_size = if (pg_size > 0) pg_size else 4096,
            .host_port = host_port,
            .timebase = timebase,
            .prev_ms = now,
            .prev_disk_ms = now,
            .prev_net_ms = now,
        };
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

        return .{ .rx_bytes_ps = rx_ps, .tx_bytes_ps = tx_ps };
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
                .cpu_percent = cpu_percent,
                .mem_percent = mem_percent,
                .threads = @intCast(task_info.pti_threadnum),
                .disk_read_ps = disk_read_ps,
                .disk_write_ps = disk_write_ps,
                .name_len = name_len,
            };
            @memcpy(proc_stat.name_buf[0..name_len], nbuf[0..name_len]);

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
};

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
