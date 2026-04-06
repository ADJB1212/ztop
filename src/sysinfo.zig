const builtin = @import("builtin");
pub const common = @import("sysinfo/common.zig");

pub const CpuStats = common.CpuStats;
pub const MemStats = common.MemStats;
pub const DiskStats = common.DiskStats;
pub const NetStats = common.NetStats;
pub const ThermalStats = common.ThermalStats;
pub const BatteryStats = common.BatteryStats;
pub const BatteryStatus = common.BatteryStatus;
pub const ProcStats = common.ProcStats;
pub const SortBy = common.SortBy;
pub const sortProcStats = common.sortProcStats;

pub const SysInfo = switch (builtin.target.os.tag) {
    .macos => @import("sysinfo/darwin.zig").SysInfo,
    .linux => @import("sysinfo/linux.zig").SysInfo,
    else => @compileError("ztop sysinfo is only implemented for macOS and Linux"),
};
