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

pub fn readDiskTotals() !DiskTotals {
    const matching = c.IOServiceMatching(c.kIOBlockStorageDriverClass) orelse return error.IOKitMatchingFailed;

    var iter: c.io_iterator_t = 0;
    if (c.IOServiceGetMatchingServices(c.kIOMainPortDefault, matching, &iter) != c.KERN_SUCCESS) {
        return error.IOKitQueryFailed;
    }
    defer _ = c.IOObjectRelease(iter);

    const stats_key = c.CFStringCreateWithCString(null, c.kIOBlockStorageDriverStatisticsKey, c.kCFStringEncodingUTF8) orelse {
        return error.OutOfMemory;
    };
    defer c.CFRelease(stats_key);

    const read_key = c.CFStringCreateWithCString(null, c.kIOBlockStorageDriverStatisticsBytesReadKey, c.kCFStringEncodingUTF8) orelse {
        return error.OutOfMemory;
    };
    defer c.CFRelease(read_key);

    const write_key = c.CFStringCreateWithCString(null, c.kIOBlockStorageDriverStatisticsBytesWrittenKey, c.kCFStringEncodingUTF8) orelse {
        return error.OutOfMemory;
    };
    defer c.CFRelease(write_key);

    var read_bytes: u64 = 0;
    var write_bytes: u64 = 0;

    while (true) {
        const service = c.IOIteratorNext(iter);
        if (service == 0) break;
        defer _ = c.IOObjectRelease(service);

        const stats_ref = c.IORegistryEntryCreateCFProperty(service, stats_key, null, 0) orelse continue;
        defer c.CFRelease(stats_ref);

        if (c.CFGetTypeID(stats_ref) != c.CFDictionaryGetTypeID()) continue;

        const stats_dict: c.CFDictionaryRef = @ptrCast(stats_ref);
        read_bytes +|= cf_util.getCFDictionaryU64(stats_dict, read_key);
        write_bytes +|= cf_util.getCFDictionaryU64(stats_dict, write_key);
    }

    return .{ .read_bytes = read_bytes, .write_bytes = write_bytes };
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
