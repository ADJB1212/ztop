const builtin = @import("builtin");
pub const common = @import("sysinfo/common.zig");

pub const CpuStats = common.CpuStats;
pub const CpuTopology = common.CpuTopology;
pub const CpuLogicalCore = common.CpuLogicalCore;
pub const CpuEfficiencyClass = common.CpuEfficiencyClass;
pub const MemStats = common.MemStats;
pub const DiskStats = common.DiskStats;
pub const NetStats = common.NetStats;
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

pub const sys_linux = @import("sysinfo/linux.zig");
pub const sys_darwin = @import("sysinfo/darwin.zig");

pub const SysInfo = switch (builtin.target.os.tag) {
    .macos => @import("sysinfo/darwin.zig").SysInfo,
    .linux => @import("sysinfo/linux.zig").SysInfo,
    else => @compileError("ztop sysinfo is only implemented for macOS and Linux"),
};
