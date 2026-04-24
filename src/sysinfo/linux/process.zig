const std = @import("std");
const common = @import("../../sysinfo/common.zig");

pub const ParsedProcStat = struct {
    name: []const u8,
    state: common.ProcState,
    ppid: u32,
    cpu_total: u64,
    num_threads: u32,
};

pub const CpuListInfo = struct {
    count: usize = 0,
    first: ?u16 = null,
    target_index: ?usize = null,
};

pub fn parseProcStat(contents: []const u8) ?ParsedProcStat {
    const line = std.mem.trimEnd(u8, contents, "\n");
    const open_paren = std.mem.indexOfScalar(u8, line, '(') orelse return null;
    const close_paren = std.mem.lastIndexOfScalar(u8, line, ')') orelse return null;
    if (close_paren <= open_paren) return null;

    const name = line[open_paren + 1 .. close_paren];
    const rest = std.mem.trimStart(u8, line[close_paren + 1 ..], " ");
    var fields = std.mem.tokenizeAny(u8, rest, " ");
    var field_number: usize = 3;
    var state: common.ProcState = .unknown;
    var ppid: ?u32 = null;
    var utime: ?u64 = null;
    var stime: ?u64 = null;
    var num_threads: ?u32 = null;

    while (fields.next()) |field| : (field_number += 1) {
        if (field_number == 3) {
            state = switch (field[0]) {
                'R' => .running,
                'S' => .sleeping,
                'D' => .disk_sleep,
                'T' => .stopped,
                't' => .tracing_stop,
                'Z' => .zombie,
                'X' => .dead,
                'I' => .idle,
                else => .unknown,
            };
        } else if (field_number == 4) {
            ppid = std.fmt.parseInt(u32, field, 10) catch return null;
        } else if (field_number == 14) {
            utime = std.fmt.parseInt(u64, field, 10) catch return null;
        } else if (field_number == 15) {
            stime = std.fmt.parseInt(u64, field, 10) catch return null;
        } else if (field_number == 20) {
            num_threads = std.fmt.parseInt(u32, field, 10) catch return null;
            break;
        }
    }

    return .{
        .name = name,
        .state = state,
        .ppid = ppid orelse return null,
        .cpu_total = (utime orelse return null) + (stime orelse return null),
        .num_threads = num_threads orelse return null,
    };
}

pub fn parseCpuListInfo(list: []const u8, target: ?u16) CpuListInfo {
    var info = CpuListInfo{};
    var parts = std.mem.splitScalar(u8, std.mem.trim(u8, list, " \t\r\n"), ',');

    while (parts.next()) |part_raw| {
        const part = std.mem.trim(u8, part_raw, " \t\r\n");
        if (part.len == 0) continue;

        if (std.mem.indexOfScalar(u8, part, '-')) |dash| {
            const start = std.fmt.parseInt(u16, std.mem.trim(u8, part[0..dash], " \t"), 10) catch continue;
            const end = std.fmt.parseInt(u16, std.mem.trim(u8, part[dash + 1 ..], " \t"), 10) catch continue;
            if (end < start) continue;

            var value = start;
            while (true) {
                recordCpuListValue(&info, value, target);
                if (value == end) break;
                value += 1;
            }
        } else {
            const value = std.fmt.parseInt(u16, part, 10) catch continue;
            recordCpuListValue(&info, value, target);
        }
    }

    return info;
}

fn recordCpuListValue(info: *CpuListInfo, value: u16, target: ?u16) void {
    if (info.first == null) info.first = value;
    if (target) |target_value| {
        if (info.target_index == null and value == target_value) {
            info.target_index = info.count;
        }
    }
    info.count += 1;
}

pub fn parseResidentPages(contents: []const u8) ?u64 {
    var fields = std.mem.tokenizeAny(u8, contents, " \t\n");
    _ = fields.next() orelse return null;
    const resident = fields.next() orelse return null;
    return std.fmt.parseInt(u64, resident, 10) catch null;
}

pub fn compactLinuxCmdline(raw: []const u8, dest: []u8) []const u8 {
    var write_idx: usize = 0;
    var needs_space = false;

    for (raw) |byte| {
        if (byte == 0) {
            if (write_idx > 0) needs_space = true;
            continue;
        }

        if (needs_space and write_idx < dest.len) {
            dest[write_idx] = ' ';
            write_idx += 1;
            needs_space = false;
        }
        if (write_idx >= dest.len) break;

        dest[write_idx] = byte;
        write_idx += 1;
    }

    return std.mem.trimEnd(u8, dest[0..write_idx], " ");
}
