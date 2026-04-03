const builtin = @import("builtin");
const common = @import("sysinfo/common.zig");

pub const CpuStats = common.CpuStats;
pub const MemStats = common.MemStats;
pub const ProcStats = common.ProcStats;

pub const SysInfo = switch (builtin.target.os.tag) {
    .macos => @import("sysinfo/darwin.zig").SysInfo,
    .linux => @import("sysinfo/linux.zig").SysInfo,
    else => @compileError("ztop sysinfo is only implemented for macOS and Linux"),
};
