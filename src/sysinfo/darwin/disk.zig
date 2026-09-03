const std = @import("std");
const bindings = @import("bindings.zig");
const c = bindings.c;
const cf_util = @import("cf_util.zig");

pub const DiskTotals = struct {
    read_bytes: u64,
    write_bytes: u64,
};

pub const DiskUsage = struct {
    total_bytes: u64,
    used_bytes: u64,
};

var s_stats_key: ?c.CFStringRef = null;
var s_read_key: ?c.CFStringRef = null;
var s_write_key: ?c.CFStringRef = null;

const DiskKeys = struct {
    stats: c.CFStringRef,
    read: c.CFStringRef,
    write: c.CFStringRef,
};

const MAX_DISK_SERVICES = 64;
const SERVICE_RESCAN_INTERVAL = 20;

pub const DiskCollector = struct {
    services: [MAX_DISK_SERVICES]c.io_registry_entry_t = [_]c.io_registry_entry_t{0} ** MAX_DISK_SERVICES,
    service_count: usize = 0,
    polls_until_rescan: u8 = 0,
    initialized: bool = false,

    pub fn deinit(self: *DiskCollector) void {
        self.releaseServices();
        self.initialized = false;
    }

    fn releaseServices(self: *DiskCollector) void {
        for (self.services[0..self.service_count]) |service| {
            _ = c.IOObjectRelease(service);
        }
        self.service_count = 0;
    }

    fn reloadServices(self: *DiskCollector) !void {
        const matching = c.IOServiceMatching(c.kIOBlockStorageDriverClass) orelse return error.IOKitMatchingFailed;
        var iter: c.io_iterator_t = 0;
        if (c.IOServiceGetMatchingServices(c.kIOMainPortDefault, matching, &iter) != c.KERN_SUCCESS) {
            return error.IOKitQueryFailed;
        }
        defer _ = c.IOObjectRelease(iter);

        var new_services: [MAX_DISK_SERVICES]c.io_registry_entry_t = [_]c.io_registry_entry_t{0} ** MAX_DISK_SERVICES;
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
        self.polls_until_rescan = SERVICE_RESCAN_INTERVAL;
        self.initialized = true;
    }

    pub fn readTotals(self: *DiskCollector) !DiskTotals {
        if (!self.initialized or self.polls_until_rescan == 0) {
            try self.reloadServices();
        } else {
            self.polls_until_rescan -= 1;
        }

        const keys = try getDiskKeys();
        var read_bytes: u64 = 0;
        var write_bytes: u64 = 0;
        var stale_service = false;

        for (self.services[0..self.service_count]) |service| {
            const stats_ref = c.IORegistryEntryCreateCFProperty(service, keys.stats, null, 0) orelse {
                stale_service = true;
                continue;
            };
            defer c.CFRelease(stats_ref);
            if (c.CFGetTypeID(stats_ref) != c.CFDictionaryGetTypeID()) continue;

            const stats_dict: c.CFDictionaryRef = @ptrCast(stats_ref);
            read_bytes +|= cf_util.getCFDictionaryU64(stats_dict, keys.read);
            write_bytes +|= cf_util.getCFDictionaryU64(stats_dict, keys.write);
        }

        if (stale_service) self.polls_until_rescan = 0;
        return .{ .read_bytes = read_bytes, .write_bytes = write_bytes };
    }
};

fn getDiskKeys() !DiskKeys {
    if (s_stats_key == null) {
        s_stats_key = c.CFStringCreateWithCString(null, c.kIOBlockStorageDriverStatisticsKey, c.kCFStringEncodingUTF8) orelse return error.OutOfMemory;
        s_read_key = c.CFStringCreateWithCString(null, c.kIOBlockStorageDriverStatisticsBytesReadKey, c.kCFStringEncodingUTF8) orelse return error.OutOfMemory;
        s_write_key = c.CFStringCreateWithCString(null, c.kIOBlockStorageDriverStatisticsBytesWrittenKey, c.kCFStringEncodingUTF8) orelse return error.OutOfMemory;
    }
    return .{
        .stats = s_stats_key.?,
        .read = s_read_key.?,
        .write = s_write_key.?,
    };
}

pub fn readDiskUsage() !DiskUsage {
    var stats: c.struct_statvfs = std.mem.zeroes(c.struct_statvfs);
    if (c.statvfs("/", &stats) != 0) return error.StatVfsFailed;

    const block_size = if (stats.f_frsize > 0) stats.f_frsize else stats.f_bsize;
    if (block_size == 0) return error.InvalidStatVfs;

    const total = stats.f_blocks *| block_size;
    const used_blocks = stats.f_blocks -| stats.f_bfree;
    return .{
        .total_bytes = total,
        .used_bytes = used_blocks *| block_size,
    };
}
