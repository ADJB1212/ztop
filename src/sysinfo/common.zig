const std = @import("std");

pub const CpuStats = struct {
    usage_percent: f32,
    cores: u32,
    per_core_usage: []const f32 = &.{},
};

pub const MemStats = struct {
    total: u64,
    used: u64,
    free: u64,
    cached: u64 = 0,
    buffered: u64 = 0,
    swap_total: u64 = 0,
    swap_used: u64 = 0,
};

pub const DiskStats = struct {
    read_bytes_ps: u64 = 0,
    write_bytes_ps: u64 = 0,
};

pub const NetStats = struct {
    rx_bytes_ps: u64 = 0,
    tx_bytes_ps: u64 = 0,
    rx_bytes: u64 = 0,
    tx_bytes: u64 = 0,
};

pub const ThermalStats = struct {
    cpu_temp: ?f32 = null,
    gpu_temp: ?f32 = null,
};

pub const BatteryStatus = enum {
    unknown,
    charging,
    discharging,
    full,
};

pub const BatteryStats = struct {
    charge_percent: ?f32 = null,
    power_draw_w: ?f32 = null,
    status: BatteryStatus = .unknown,
};

pub const ProcState = enum {
    running,
    sleeping,
    disk_sleep,
    stopped,
    tracing_stop,
    zombie,
    dead,
    idle,
    unknown,
};

pub const ProcStats = struct {
    pid: u32,
    ppid: u32 = 0,
    name_buf: [64]u8 = std.mem.zeroes([64]u8),
    name_len: u8 = 0,
    state: ProcState = .unknown,
    cpu_percent: f32 = 0,
    mem_percent: f32 = 0,
    threads: u32 = 0,
    disk_read_ps: u64 = 0,
    disk_write_ps: u64 = 0,

    pub fn name(self: *const ProcStats) []const u8 {
        return self.name_buf[0..self.name_len];
    }
};

pub const NetConnState = enum {
    established,
    syn_sent,
    syn_recv,
    fin_wait1,
    fin_wait2,
    time_wait,
    closed,
    close_wait,
    last_ack,
    listen,
    closing,
    unknown,
};

pub const NetProtocol = enum {
    tcp,
    udp,
    tcp6,
    udp6,
    unknown,
};

pub const NetConnection = struct {
    protocol: NetProtocol,
    local_addr: [46]u8 = std.mem.zeroes([46]u8),
    local_port: u16 = 0,
    remote_addr: [46]u8 = std.mem.zeroes([46]u8),
    remote_port: u16 = 0,
    state: NetConnState = .unknown,
    pid: u32 = 0,
    process_name: [64]u8 = std.mem.zeroes([64]u8),
    process_name_len: u8 = 0,

    pub fn name(self: *const NetConnection) []const u8 {
        return self.process_name[0..self.process_name_len];
    }
};

pub const ThreadStats = struct {
    tid: u64,
    name_buf: [64]u8 = std.mem.zeroes([64]u8),
    name_len: u8 = 0,
    cpu_percent: f32 = 0,
    state: ProcState = .unknown,

    pub fn name(self: *const ThreadStats) []const u8 {
        return self.name_buf[0..self.name_len];
    }
};

pub const ProcCpuEntry = struct {
    pid: u32,
    cpu_total: u64,
    disk_read: u64 = 0,
    disk_write: u64 = 0,
};

pub const ThreadCpuEntry = struct {
    tid: u64,
    cpu_total: u64,
};

pub const MAX_CORES = 256;
pub const MAX_PROCS = 2048;
pub const MAX_THREADS = 1024;

pub const SortBy = enum {
    cpu,
    mem,
    pid,
    name,
};

pub inline fn kbToBytes(x: usize) usize {
    return x << 10;
}

pub fn sortProcStats(slice: []ProcStats, sort_by: SortBy) void {
    const Context = struct {
        sort_by: SortBy,
        pub fn lessThan(self: @This(), a: ProcStats, b: ProcStats) bool {
            switch (self.sort_by) {
                .cpu => return a.cpu_percent > b.cpu_percent,
                .mem => return a.mem_percent > b.mem_percent,
                .pid => return a.pid < b.pid,
                .name => return std.mem.order(u8, a.name(), b.name()) == .lt,
            }
        }
    };
    std.mem.sort(ProcStats, slice, Context{ .sort_by = sort_by }, Context.lessThan);
}

pub fn sortThreadStats(slice: []ThreadStats) void {
    const Context = struct {
        pub fn lessThan(_: @This(), a: ThreadStats, b: ThreadStats) bool {
            return a.cpu_percent > b.cpu_percent;
        }
    };
    std.mem.sort(ThreadStats, slice, Context{}, Context.lessThan);
}
