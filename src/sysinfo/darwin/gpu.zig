const std = @import("std");
const bindings = @import("bindings.zig");
const c = bindings.c;
const cf_util = @import("cf_util.zig");
const common = @import("../../sysinfo/common.zig");
const GpuStats = common.GpuStats;

pub fn appendAppleGpuStats(allocator: std.mem.Allocator, result: *std.ArrayList(GpuStats)) !void {
    const matching = c.IOServiceMatching("IOAccelerator") orelse return;

    var iter: c.io_iterator_t = 0;
    if (c.IOServiceGetMatchingServices(c.kIOMainPortDefault, matching, &iter) != c.KERN_SUCCESS) {
        return;
    }
    defer _ = c.IOObjectRelease(iter);

    const performance_key = c.CFStringCreateWithCString(null, "PerformanceStatistics", c.kCFStringEncodingUTF8) orelse return;
    defer c.CFRelease(performance_key);

    const utilization_key = c.CFStringCreateWithCString(null, "Device Utilization %", c.kCFStringEncodingUTF8) orelse return;
    defer c.CFRelease(utilization_key);

    const in_use_key = c.CFStringCreateWithCString(null, "In use system memory", c.kCFStringEncodingUTF8) orelse return;
    defer c.CFRelease(in_use_key);

    const alloc_key = c.CFStringCreateWithCString(null, "Alloc system memory", c.kCFStringEncodingUTF8) orelse return;
    defer c.CFRelease(alloc_key);

    const model_key = c.CFStringCreateWithCString(null, "model", c.kCFStringEncodingUTF8) orelse return;
    defer c.CFRelease(model_key);

    const core_count_key = c.CFStringCreateWithCString(null, "gpu-core-count", c.kCFStringEncodingUTF8) orelse return;
    defer c.CFRelease(core_count_key);

    var device_index: u8 = 0;
    while (true) {
        const service = c.IOIteratorNext(iter);
        if (service == 0) break;
        defer _ = c.IOObjectRelease(service);

        const stats_ref = c.IORegistryEntryCreateCFProperty(service, performance_key, null, 0) orelse continue;
        defer c.CFRelease(stats_ref);
        if (c.CFGetTypeID(stats_ref) != c.CFDictionaryGetTypeID()) continue;

        const stats_dict: c.CFDictionaryRef = @ptrCast(stats_ref);
        var gpu = GpuStats{
            .index = device_index,
            .vendor = .apple,
            .backend = .iokit,
        };
        device_index +%= 1;

        if (copyServiceStringProperty(service, model_key, gpu.name_buf[0..])) |name_len| {
            gpu.name_len = @intCast(name_len);
        } else {
            var fallback_buf: [24]u8 = undefined;
            setGpuName(&gpu, buildIndexedName(&fallback_buf, "Apple GPU", gpu.index));
        }

        if (cf_util.getCFDictionaryNumber(stats_dict, utilization_key)) |utilization| {
            gpu.utilization_percent = @floatFromInt(utilization);
        }
        if (cf_util.getCFDictionaryNumber(stats_dict, in_use_key)) |used_bytes| {
            gpu.memory_used_bytes = used_bytes;
        }
        if (cf_util.getCFDictionaryNumber(stats_dict, alloc_key)) |allocated_bytes| {
            gpu.memory_total_bytes = allocated_bytes;
        }
        if (cf_util.readServiceNumber(service, core_count_key)) |core_count| {
            gpu.core_count = @intCast(core_count);
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
