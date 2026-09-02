const std = @import("std");
const bindings = @import("bindings.zig");
const c = bindings.c;
const cf_util = @import("cf_util.zig");
const common = @import("../../sysinfo/common.zig");
const GpuStats = common.GpuStats;

const StaticGpuInfo = struct {
    name_buf: [64]u8 = std.mem.zeroes([64]u8),
    name_len: u8 = 0,
    core_count: ?u32 = null,
    valid: bool = false,
};

const MAX_CACHED_GPUS = 8;
var static_gpus: [MAX_CACHED_GPUS]StaticGpuInfo = [_]StaticGpuInfo{.{}} ** MAX_CACHED_GPUS;

var s_performance_key: ?c.CFStringRef = null;
var s_utilization_key: ?c.CFStringRef = null;
var s_in_use_key: ?c.CFStringRef = null;
var s_alloc_key: ?c.CFStringRef = null;
var s_model_key: ?c.CFStringRef = null;
var s_core_count_key: ?c.CFStringRef = null;

const GpuKeys = struct {
    perf: c.CFStringRef,
    util: c.CFStringRef,
    in_use: c.CFStringRef,
    alloc: c.CFStringRef,
    model: c.CFStringRef,
    core_count: c.CFStringRef,
};

fn getGpuKeys() ?GpuKeys {
    if (s_performance_key == null) {
        s_performance_key = c.CFStringCreateWithCString(null, "PerformanceStatistics", c.kCFStringEncodingUTF8) orelse return null;
        s_utilization_key = c.CFStringCreateWithCString(null, "Device Utilization %", c.kCFStringEncodingUTF8) orelse return null;
        s_in_use_key = c.CFStringCreateWithCString(null, "In use system memory", c.kCFStringEncodingUTF8) orelse return null;
        s_alloc_key = c.CFStringCreateWithCString(null, "Alloc system memory", c.kCFStringEncodingUTF8) orelse return null;
        s_model_key = c.CFStringCreateWithCString(null, "model", c.kCFStringEncodingUTF8) orelse return null;
        s_core_count_key = c.CFStringCreateWithCString(null, "gpu-core-count", c.kCFStringEncodingUTF8) orelse return null;
    }
    return .{
        .perf = s_performance_key.?,
        .util = s_utilization_key.?,
        .in_use = s_in_use_key.?,
        .alloc = s_alloc_key.?,
        .model = s_model_key.?,
        .core_count = s_core_count_key.?,
    };
}

pub fn appendAppleGpuStats(allocator: std.mem.Allocator, result: *std.ArrayList(GpuStats)) !void {
    const keys = getGpuKeys() orelse return;
    const matching = c.IOServiceMatching("IOAccelerator") orelse return;

    var iter: c.io_iterator_t = 0;
    if (c.IOServiceGetMatchingServices(c.kIOMainPortDefault, matching, &iter) != c.KERN_SUCCESS) {
        return;
    }
    defer _ = c.IOObjectRelease(iter);

    var device_index: u8 = 0;
    while (true) {
        const service = c.IOIteratorNext(iter);
        if (service == 0) break;
        defer _ = c.IOObjectRelease(service);

        const stats_ref = c.IORegistryEntryCreateCFProperty(service, keys.perf, null, 0) orelse continue;
        defer c.CFRelease(stats_ref);
        if (c.CFGetTypeID(stats_ref) != c.CFDictionaryGetTypeID()) continue;

        const stats_dict: c.CFDictionaryRef = @ptrCast(stats_ref);
        var gpu = GpuStats{
            .index = device_index,
            .vendor = .apple,
            .backend = .iokit,
        };

        const idx = device_index;
        device_index +%= 1;

        if (idx < MAX_CACHED_GPUS and static_gpus[idx].valid) {
            @memcpy(gpu.name_buf[0..static_gpus[idx].name_len], static_gpus[idx].name_buf[0..static_gpus[idx].name_len]);
            gpu.name_len = static_gpus[idx].name_len;
            gpu.core_count = static_gpus[idx].core_count;
        } else {
            if (copyServiceStringProperty(service, keys.model, gpu.name_buf[0..])) |name_len| {
                gpu.name_len = @intCast(name_len);
            } else {
                var fallback_buf: [24]u8 = undefined;
                setGpuName(&gpu, buildIndexedName(&fallback_buf, "Apple GPU", gpu.index));
            }

            if (cf_util.readServiceNumber(service, keys.core_count)) |core_count| {
                gpu.core_count = @intCast(core_count);
            }

            if (idx < MAX_CACHED_GPUS) {
                @memcpy(static_gpus[idx].name_buf[0..gpu.name_len], gpu.name_buf[0..gpu.name_len]);
                static_gpus[idx].name_len = gpu.name_len;
                static_gpus[idx].core_count = gpu.core_count;
                static_gpus[idx].valid = true;
            }
        }

        if (cf_util.getCFDictionaryNumber(stats_dict, keys.util)) |utilization| {
            gpu.utilization_percent = @floatFromInt(utilization);
        }
        if (cf_util.getCFDictionaryNumber(stats_dict, keys.in_use)) |used_bytes| {
            gpu.memory_used_bytes = used_bytes;
        }
        if (cf_util.getCFDictionaryNumber(stats_dict, keys.alloc)) |allocated_bytes| {
            gpu.memory_total_bytes = allocated_bytes;
        }

        try result.append(allocator, gpu);
    }
}

fn setGpuName(gpu: *GpuStats, name: []const u8) void {
    const bounded_len = @min(name.len, gpu.name_buf.len - 1);
    if (bounded_len == 0) return;
    @memcpy(gpu.name_buf[0..bounded_len], name[0..bounded_len]);
    gpu.name_len = @intCast(bounded_len);
}

fn buildIndexedName(buf: []u8, prefix: []const u8, index: u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s} {d}", .{ prefix, index }) catch prefix;
}

fn copyServiceStringProperty(service: c.io_registry_entry_t, key: c.CFStringRef, dest: []u8) ?usize {
    const value_ref = c.IORegistryEntryCreateCFProperty(service, key, null, 0) orelse return null;
    defer c.CFRelease(value_ref);
    return cf_util.copyCFStringLikeValue(value_ref, dest);
}
