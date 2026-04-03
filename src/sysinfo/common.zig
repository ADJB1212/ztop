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
};

pub const ProcStats = struct {
    pid: u32,
    name_buf: [64]u8 = std.mem.zeroes([64]u8),
    name_len: u8 = 0,
    cpu_percent: f32 = 0,
    mem_percent: f32 = 0,

    pub fn name(self: *const ProcStats) []const u8 {
        return self.name_buf[0..self.name_len];
    }
};

pub const ProcCpuEntry = struct {
    pid: u32,
    cpu_total: u64,
};

pub const MAX_CORES = 256;
pub const MAX_PROCS = 2048;

pub fn sortProcStats(slice: []ProcStats) void {
    std.mem.sort(ProcStats, slice, {}, struct {
        pub fn lessThan(_: void, a: ProcStats, b: ProcStats) bool {
            return a.cpu_percent > b.cpu_percent;
        }
    }.lessThan);
}
