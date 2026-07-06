const builtin = @import("builtin");
pub const common = @import("sysinfo/common.zig");

pub const CpuStats = common.CpuStats;
pub const CpuTopology = common.CpuTopology;
pub const CpuLogicalCore = common.CpuLogicalCore;
pub const CpuEfficiencyClass = common.CpuEfficiencyClass;
pub const MemStats = common.MemStats;
pub const DiskStats = common.DiskStats;
pub const NetStats = common.NetStats;
pub const WifiDetails = common.WifiDetails;
pub const WifiGeneration = common.WifiGeneration;
pub const ThermalStats = common.ThermalStats;
pub const GpuStats = common.GpuStats;
pub const GpuVendor = common.GpuVendor;
pub const GpuBackend = common.GpuBackend;
pub const BatteryStats = common.BatteryStats;
pub const BatteryStatus = common.BatteryStatus;
pub const ProcState = common.ProcState;
pub const ProcStats = common.ProcStats;
pub const ThreadStats = common.ThreadStats;
pub const SortBy = common.SortBy;
pub const sortProcStats = common.sortProcStats;
pub const sortThreadStats = common.sortThreadStats;

pub const sys_darwin = @import("sysinfo/darwin.zig");

pub const SysInfo = switch (builtin.target.os.tag) {
    .macos => switch (builtin.target.cpu.arch) {
        .aarch64 => @import("sysinfo/darwin.zig").SysInfo,
        else => @compileError("ztop is only supported on ARM (Apple Silicon) Macs"),
    },
    else => @compileError("ztop is only supported on macOS"),
};
