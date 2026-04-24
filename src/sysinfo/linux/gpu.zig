const std = @import("std");
const common = @import("../../sysinfo/common.zig");
const io_util = @import("io_util.zig");

const GpuStats = common.GpuStats;

const NvmlReturn = c_uint;
const NvmlDevice = ?*anyopaque;

const NvmlUtilization = extern struct {
    gpu: c_uint,
    memory: c_uint,
};

const NvmlMemoryInfo = extern struct {
    total: u64,
    free: u64,
    used: u64,
};

const NvmlSymbols = struct {
    init: *const fn () callconv(.c) NvmlReturn,
    shutdown: *const fn () callconv(.c) NvmlReturn,
    device_get_count: *const fn (*c_uint) callconv(.c) NvmlReturn,
    device_get_handle_by_index: *const fn (c_uint, *NvmlDevice) callconv(.c) NvmlReturn,
    device_get_name: *const fn (NvmlDevice, [*]u8, c_uint) callconv(.c) NvmlReturn,
    device_get_utilization: ?*const fn (NvmlDevice, *NvmlUtilization) callconv(.c) NvmlReturn,
    device_get_memory_info: ?*const fn (NvmlDevice, *NvmlMemoryInfo) callconv(.c) NvmlReturn,
    device_get_temperature: ?*const fn (NvmlDevice, c_uint, *c_uint) callconv(.c) NvmlReturn,
    device_get_power_usage: ?*const fn (NvmlDevice, *c_uint) callconv(.c) NvmlReturn,
};

const NVML_SUCCESS: NvmlReturn = 0;
const NVML_TEMPERATURE_GPU: c_uint = 0;

pub fn appendNvidiaGpuStats(allocator: std.mem.Allocator, result: *std.ArrayList(GpuStats)) !void {
    var lib = openOptionalDynLib(&.{ "libnvidia-ml.so.1", "libnvidia-ml.so" }) orelse return;
    defer lib.close();

    const symbols = loadNvmlSymbols(&lib) orelse return;
    if (symbols.init() != NVML_SUCCESS) return;
    defer _ = symbols.shutdown();

    var device_count: c_uint = 0;
    if (symbols.device_get_count(&device_count) != NVML_SUCCESS or device_count == 0) return;

    var device_index: c_uint = 0;
    while (device_index < device_count) : (device_index += 1) {
        var device: NvmlDevice = null;
        if (symbols.device_get_handle_by_index(device_index, &device) != NVML_SUCCESS) continue;

        var gpu = GpuStats{
            .index = @intCast(device_index),
            .vendor = .nvidia,
            .backend = .nvml,
        };

        var name_buf: [96]u8 = std.mem.zeroes([96]u8);
        if (symbols.device_get_name(device, name_buf[0..].ptr, @intCast(name_buf.len)) == NVML_SUCCESS) {
            const name_len = std.mem.indexOfScalar(u8, name_buf[0..], 0) orelse name_buf.len;
            setGpuName(&gpu, name_buf[0..name_len]);
        } else {
            var fallback_buf: [32]u8 = undefined;
            setGpuName(&gpu, buildIndexedName(&fallback_buf, "NVIDIA GPU", device_index));
        }

        if (symbols.device_get_utilization) |device_get_utilization| {
            var utilization: NvmlUtilization = undefined;
            if (device_get_utilization(device, &utilization) == NVML_SUCCESS) {
                gpu.utilization_percent = @floatFromInt(utilization.gpu);
            }
        }

        if (symbols.device_get_memory_info) |device_get_memory_info| {
            var memory_info: NvmlMemoryInfo = undefined;
            if (device_get_memory_info(device, &memory_info) == NVML_SUCCESS) {
                gpu.memory_used_bytes = memory_info.used;
                gpu.memory_total_bytes = memory_info.total;
            }
        }

        if (symbols.device_get_temperature) |device_get_temperature| {
            var temp_c: c_uint = 0;
            if (device_get_temperature(device, NVML_TEMPERATURE_GPU, &temp_c) == NVML_SUCCESS) {
                gpu.temperature_c = @floatFromInt(temp_c);
            }
        }

        if (symbols.device_get_power_usage) |device_get_power_usage| {
            var milliwatts: c_uint = 0;
            if (device_get_power_usage(device, &milliwatts) == NVML_SUCCESS) {
                gpu.power_draw_w = @as(f32, @floatFromInt(milliwatts)) / 1000.0;
            }
        }

        try result.append(allocator, gpu);
    }
}

pub fn appendAmdGpuStats(io: std.Io, allocator: std.mem.Allocator, result: *std.ArrayList(GpuStats)) !void {
    var drm_dir = std.Io.Dir.openDirAbsolute(io, "/sys/class/drm", .{ .iterate = true }) catch return;
    defer drm_dir.close(io);

    var iter = drm_dir.iterate();
    while (try iter.next(io)) |entry| {
        const card_index = parseDrmCardIndex(entry.name) orelse continue;

        var card_dir = drm_dir.openDir(io, entry.name, .{}) catch continue;
        defer card_dir.close(io);

        var device_dir = card_dir.openDir(io, "device", .{}) catch continue;
        defer device_dir.close(io);

        const vendor_id = io_util.readHexIntFromDir(io, &device_dir, u32, "vendor") catch continue;
        if (vendor_id != 0x1002) continue;

        var gpu = GpuStats{
            .index = card_index,
            .vendor = .amd,
            .backend = .sysfs,
        };

        var name_buf: [48]u8 = undefined;
        setGpuName(&gpu, buildAmdGpuName(&name_buf, entry.name));

        if (io_util.readIntFromDir(io, &device_dir, u32, "gpu_busy_percent")) |busy_percent| {
            gpu.utilization_percent = @floatFromInt(busy_percent);
        } else |_| {}

        if (io_util.readIntFromDir(io, &device_dir, u64, "mem_info_vram_used")) |used_bytes| {
            gpu.memory_used_bytes = used_bytes;
        } else |_| {}

        if (io_util.readIntFromDir(io, &device_dir, u64, "mem_info_vram_total")) |total_bytes| {
            gpu.memory_total_bytes = total_bytes;
        } else |_| {}

        if (readHwmonMetric(io, &device_dir, "temp1_input")) |milli_c| {
            gpu.temperature_c = @as(f32, @floatFromInt(milli_c)) / 1000.0;
        } else |_| {}

        if (readHwmonMetric(io, &device_dir, "power1_average")) |microwatts| {
            gpu.power_draw_w = @as(f32, @floatFromInt(microwatts)) / 1000000.0;
        } else |_| {}

        try result.append(allocator, gpu);
    }
}

fn openOptionalDynLib(candidates: []const []const u8) ?std.DynLib {
    for (candidates) |candidate| {
        if (std.DynLib.open(candidate)) |lib| {
            return lib;
        } else |_| {}
    }
    return null;
}

fn loadNvmlSymbols(lib: *std.DynLib) ?NvmlSymbols {
    return .{
        .init = lib.lookup(*const fn () callconv(.c) NvmlReturn, "nvmlInit_v2") orelse return null,
        .shutdown = lib.lookup(*const fn () callconv(.c) NvmlReturn, "nvmlShutdown") orelse return null,
        .device_get_count = lib.lookup(*const fn (*c_uint) callconv(.c) NvmlReturn, "nvmlDeviceGetCount_v2") orelse return null,
        .device_get_handle_by_index = lib.lookup(*const fn (c_uint, *NvmlDevice) callconv(.c) NvmlReturn, "nvmlDeviceGetHandleByIndex_v2") orelse return null,
        .device_get_name = lib.lookup(*const fn (NvmlDevice, [*]u8, c_uint) callconv(.c) NvmlReturn, "nvmlDeviceGetName") orelse return null,
        .device_get_utilization = lib.lookup(*const fn (NvmlDevice, *NvmlUtilization) callconv(.c) NvmlReturn, "nvmlDeviceGetUtilizationRates"),
        .device_get_memory_info = lib.lookup(*const fn (NvmlDevice, *NvmlMemoryInfo) callconv(.c) NvmlReturn, "nvmlDeviceGetMemoryInfo"),
        .device_get_temperature = lib.lookup(*const fn (NvmlDevice, c_uint, *c_uint) callconv(.c) NvmlReturn, "nvmlDeviceGetTemperature"),
        .device_get_power_usage = lib.lookup(*const fn (NvmlDevice, *c_uint) callconv(.c) NvmlReturn, "nvmlDeviceGetPowerUsage"),
    };
}

fn setGpuName(gpu: *GpuStats, name: []const u8) void {
    const bounded_len = @min(name.len, gpu.name_buf.len - 1);
    if (bounded_len == 0) return;
    @memcpy(gpu.name_buf[0..bounded_len], name[0..bounded_len]);
    gpu.name_len = @intCast(bounded_len);
}

fn buildIndexedName(buf: []u8, prefix: []const u8, index: c_uint) []const u8 {
    return std.fmt.bufPrint(buf, "{s} {d}", .{ prefix, index }) catch prefix;
}

fn buildAmdGpuName(buf: []u8, card_name: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "AMD GPU {s}", .{card_name}) catch "AMD GPU";
}

fn parseDrmCardIndex(name: []const u8) ?u8 {
    if (!std.mem.startsWith(u8, name, "card")) return null;
    const suffix = name[4..];
    if (suffix.len == 0) return null;
    for (suffix) |ch| {
        if (!std.ascii.isDigit(ch)) return null;
    }
    return std.fmt.parseInt(u8, suffix, 10) catch null;
}

fn readHwmonMetric(io: std.Io, device_dir: *std.Io.Dir, file_name: []const u8) !u64 {
    var hwmon_dir = try device_dir.openDir(io, "hwmon", .{ .iterate = true });
    defer hwmon_dir.close(io);

    var iter = hwmon_dir.iterate();
    while (try iter.next(io)) |entry| {
        var sensor_dir = hwmon_dir.openDir(io, entry.name, .{}) catch continue;
        defer sensor_dir.close(io);

        return io_util.readIntFromDir(io, &sensor_dir, u64, file_name) catch continue;
    }

    return error.HwmonMetricUnavailable;
}
