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
const MAX_GPU_SERVICES = 16;
const SERVICE_RESCAN_INTERVAL = 20;

pub const GpuCollector = struct {
    services: [MAX_GPU_SERVICES]c.io_registry_entry_t = [_]c.io_registry_entry_t{0} ** MAX_GPU_SERVICES,
    service_count: usize = 0,
    static_gpus: [MAX_CACHED_GPUS]StaticGpuInfo = [_]StaticGpuInfo{.{}} ** MAX_CACHED_GPUS,
    polls_until_rescan: u8 = 0,
    initialized: bool = false,

    pub fn deinit(self: *GpuCollector) void {
        self.releaseServices();
        self.initialized = false;
    }

    fn releaseServices(self: *GpuCollector) void {
        for (self.services[0..self.service_count]) |service| {
            _ = c.IOObjectRelease(service);
        }
        self.service_count = 0;
    }

    fn reloadServices(self: *GpuCollector) !void {
        const matching = c.IOServiceMatching("IOAccelerator") orelse return error.IOKitMatchingFailed;
        var iter: c.io_iterator_t = 0;
        if (c.IOServiceGetMatchingServices(c.kIOMainPortDefault, matching, &iter) != c.KERN_SUCCESS) {
            return error.IOKitQueryFailed;
        }
        defer _ = c.IOObjectRelease(iter);

        var new_services: [MAX_GPU_SERVICES]c.io_registry_entry_t = [_]c.io_registry_entry_t{0} ** MAX_GPU_SERVICES;
        var new_count: usize = 0;
        while (true) {
            const service = c.IOIteratorNext(iter);
            if (service == 0) break;
            if (new_count == new_services.len) {
                _ = c.IOObjectRelease(service);
                continue;
            }
            new_services[new_count] = service;
            new_count += 1;
        }

        self.releaseServices();
        @memcpy(self.services[0..new_count], new_services[0..new_count]);
        self.service_count = new_count;
        self.static_gpus = [_]StaticGpuInfo{.{}} ** MAX_CACHED_GPUS;
        self.polls_until_rescan = SERVICE_RESCAN_INTERVAL;
        self.initialized = true;
    }

    fn prepare(self: *GpuCollector) !void {
        if (!self.initialized or self.polls_until_rescan == 0) {
            try self.reloadServices();
        } else {
            self.polls_until_rescan -= 1;
        }
    }
};

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

pub fn appendAppleGpuStats(collector: *GpuCollector, allocator: std.mem.Allocator, result: *std.ArrayList(GpuStats)) !void {
    const keys = getGpuKeys() orelse return;
    collector.prepare() catch return;

    var stale_service = false;
    for (collector.services[0..collector.service_count], 0..) |service, service_index| {
        const stats_ref = c.IORegistryEntryCreateCFProperty(service, keys.perf, null, 0) orelse {
            stale_service = true;
            continue;
        };
        defer c.CFRelease(stats_ref);
        if (c.CFGetTypeID(stats_ref) != c.CFDictionaryGetTypeID()) continue;

        const stats_dict: c.CFDictionaryRef = @ptrCast(stats_ref);
        var gpu = GpuStats{
            .index = @intCast(service_index),
            .vendor = .apple,
            .backend = .iokit,
        };

        const idx = service_index;

        if (idx < MAX_CACHED_GPUS and collector.static_gpus[idx].valid) {
            @memcpy(gpu.name_buf[0..collector.static_gpus[idx].name_len], collector.static_gpus[idx].name_buf[0..collector.static_gpus[idx].name_len]);
            gpu.name_len = collector.static_gpus[idx].name_len;
            gpu.core_count = collector.static_gpus[idx].core_count;
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
                @memcpy(collector.static_gpus[idx].name_buf[0..gpu.name_len], gpu.name_buf[0..gpu.name_len]);
                collector.static_gpus[idx].name_len = gpu.name_len;
                collector.static_gpus[idx].core_count = gpu.core_count;
                collector.static_gpus[idx].valid = true;
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
    if (stale_service) collector.polls_until_rescan = 0;
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
