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

pub const ProcStats = struct {
    pid: u32,
    name_buf: [64]u8 = std.mem.zeroes([64]u8),
    name_len: u8 = 0,
    cpu_percent: f32 = 0,
    mem_percent: f32 = 0,
    threads: u32 = 0,
    disk_read_ps: u64 = 0,
    disk_write_ps: u64 = 0,

    pub fn name(self: *const ProcStats) []const u8 {
        return self.name_buf[0..self.name_len];
    }
};

pub const ProcCpuEntry = struct {
    pid: u32,
    cpu_total: u64,
    disk_read: u64 = 0,
    disk_write: u64 = 0,
};

pub const MAX_CORES = 256;
pub const MAX_PROCS = 2048;

pub const SortBy = enum {
    cpu,
    mem,
    pid,
    name,
};

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
