const std = @import("std");
const common = @import("../../sysinfo/common.zig");
const io_util = @import("io_util.zig");
const process_mod = @import("process.zig");

const MAX_CORES = common.MAX_CORES;
const CpuLogicalCore = common.CpuLogicalCore;

pub const LinuxSharedCacheInfo = struct {
    level: u8 = 0,
    group_id: i16 = -1,
    shared_logical_count: u16 = 0,
};

pub const PhysicalCoreKey = struct {
    package_id: u16,
    core_id: i32,
};

pub const CacheGroupKey = struct {
    level: u8,
    group_id: i16,
};

pub fn readLinuxSharedCache(io: std.Io, cpu_dir: *std.Io.Dir) !LinuxSharedCacheInfo {
    var cache_dir = try cpu_dir.openDir(io, "cache", .{ .iterate = true });
    defer cache_dir.close(io);

    var best = LinuxSharedCacheInfo{};
    var iter = cache_dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        if (!std.mem.startsWith(u8, entry.name, "index")) continue;

        var index_dir = cache_dir.openDir(io, entry.name, .{}) catch continue;
        defer index_dir.close(io);

        const level = io_util.readIntFromDir(io, &index_dir, u8, "level") catch continue;

        var type_buf: [32]u8 = undefined;
        const type_str = std.mem.trim(u8, io_util.readDirFile(io, &index_dir, "type", &type_buf) catch continue, " \t\r\n");
        if (!std.mem.eql(u8, type_str, "Unified") and !std.mem.eql(u8, type_str, "Data")) continue;

        var shared_buf: [128]u8 = undefined;
        const shared_list = std.mem.trim(u8, io_util.readDirFile(io, &index_dir, "shared_cpu_list", &shared_buf) catch continue, " \t\r\n");
        const shared_info = process_mod.parseCpuListInfo(shared_list, null);
        if (shared_info.count == 0 or shared_info.first == null) continue;

        if (level > best.level or (level == best.level and shared_info.count >= best.shared_logical_count)) {
            best = .{
                .level = level,
                .group_id = @intCast(shared_info.first.?),
                .shared_logical_count = @intCast(shared_info.count),
            };
        }
    }

    if (best.level == 0) return error.SharedCacheUnavailable;
    return best;
}

pub fn readCpuNumaNode(io: std.Io, cpu_dir: *std.Io.Dir) !i16 {
    var iter = cpu_dir.iterate();
    while (try iter.next(io)) |entry| {
        if (!std.mem.startsWith(u8, entry.name, "node")) continue;
        const suffix = entry.name[4..];
        if (suffix.len == 0) continue;
        return std.fmt.parseInt(i16, suffix, 10);
    }
    return error.NumaNodeUnavailable;
}

pub fn appendUniqueU16(items: *[MAX_CORES]u16, count: *usize, value: u16) void {
    for (items[0..count.*]) |existing| {
        if (existing == value) return;
    }
    if (count.* < items.len) {
        items[count.*] = value;
        count.* += 1;
    }
}

pub fn appendUniqueI16(items: *[MAX_CORES]i16, count: *usize, value: i16) void {
    for (items[0..count.*]) |existing| {
        if (existing == value) return;
    }
    if (count.* < items.len) {
        items[count.*] = value;
        count.* += 1;
    }
}

pub fn appendUniqueCacheGroup(items: *[MAX_CORES]CacheGroupKey, count: *usize, value: CacheGroupKey) void {
    for (items[0..count.*]) |existing| {
        if (existing.level == value.level and existing.group_id == value.group_id) return;
    }
    if (count.* < items.len) {
        items[count.*] = value;
        count.* += 1;
    }
}

pub fn findOrAppendPhysicalId(keys: *[MAX_CORES]PhysicalCoreKey, count: *usize, package_id: u16, core_id: i32) u16 {
    for (keys[0..count.*], 0..) |existing, idx| {
        if (existing.package_id == package_id and existing.core_id == core_id) {
            return @intCast(idx);
        }
    }

    if (count.* < keys.len) {
        keys[count.*] = .{ .package_id = package_id, .core_id = core_id };
        count.* += 1;
        return @intCast(count.* - 1);
    }

    return 0;
}
