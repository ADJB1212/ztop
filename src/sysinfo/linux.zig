const std = @import("std");
const common = @import("common.zig");

const CpuStats = common.CpuStats;
const MemStats = common.MemStats;
const DiskStats = common.DiskStats;
const NetStats = common.NetStats;
const ThermalStats = common.ThermalStats;
const BatteryStats = common.BatteryStats;
const BatteryStatus = common.BatteryStatus;
const ProcStats = common.ProcStats;
const ProcCpuEntry = common.ProcCpuEntry;
const MAX_CORES = common.MAX_CORES;
const MAX_PROCS = common.MAX_PROCS;

const CpuTick = struct {
    total: u64 = 0,
    active: u64 = 0,
};

const CpuSnapshot = struct {
    overall: CpuTick = .{},
    cores: [MAX_CORES]CpuTick = undefined,
    core_count: usize = 0,
};

pub const ParsedProcStat = struct {
    name: []const u8,
    state: common.ProcState,
    ppid: u32,
    cpu_total: u64,
    num_threads: u32,
};

const MAX_THREADS = common.MAX_THREADS;

pub const SysInfo = struct {
    prev_cpu_tick: CpuTick = .{},
    prev_core_ticks: [MAX_CORES]CpuTick = std.mem.zeroes([MAX_CORES]CpuTick),
    core_usage: [MAX_CORES]f32 = [_]f32{0} ** MAX_CORES,
    ncpu: u32,
    total_mem: u64,
    page_size: usize,
    prev_procs: [MAX_PROCS]ProcCpuEntry = undefined,
    prev_proc_count: usize = 0,
    prev_proc_total_ticks: u64 = 0,
    prev_threads: [MAX_THREADS]common.ThreadCpuEntry = undefined,
    prev_thread_count: usize = 0,
    prev_thread_total_ticks: u64 = 0,
    thread_view_pid: u32 = 0,
    prev_disk_read: u64 = 0,
    prev_disk_write: u64 = 0,
    prev_net_rx: u64 = 0,
    prev_net_tx: u64 = 0,
    prev_time: i64 = 0,
    prev_disk_ms: i64 = 0,
    prev_net_ms: i64 = 0,

    pub fn init() SysInfo {
        const initial_cores = @min(std.Thread.getCpuCount() catch 1, MAX_CORES);
        const now = std.time.milliTimestamp();
        return .{
            .ncpu = @intCast(initial_cores),
            .total_mem = readMemInfoTotal() catch 0,
            .page_size = std.heap.pageSize(),
            .prev_time = now,
            .prev_disk_ms = now,
            .prev_net_ms = now,
        };
    }

    fn usageFromTick(prev_tick: *CpuTick, current_tick: CpuTick) f32 {
        const prev_total = prev_tick.total;
        const delta_total = current_tick.total -| prev_tick.total;
        const delta_active = current_tick.active -| prev_tick.active;

        prev_tick.* = current_tick;

        if (prev_total == 0 or delta_total == 0) return 0;

        return @as(f32, @floatFromInt(delta_active)) / @as(f32, @floatFromInt(delta_total)) * 100.0;
    }

    pub fn getCpuStats(self: *SysInfo) CpuStats {
        const snapshot = readCpuSnapshot() catch {
            return .{ .usage_percent = 0, .cores = self.ncpu };
        };

        const usage = usageFromTick(&self.prev_cpu_tick, snapshot.overall);
        const core_count = if (snapshot.core_count > 0) snapshot.core_count else @as(usize, self.ncpu);
        self.ncpu = @intCast(core_count);

        for (0..snapshot.core_count) |i| {
            self.core_usage[i] = usageFromTick(&self.prev_core_ticks[i], snapshot.cores[i]);
        }

        return .{
            .usage_percent = usage,
            .cores = self.ncpu,
            .per_core_usage = self.core_usage[0..snapshot.core_count],
        };
    }

    pub fn getMemStats(self: *SysInfo) MemStats {
        const mem_info = readMemInfo() catch {
            return .{ .total = self.total_mem, .used = 0, .free = self.total_mem, .cached = 0, .buffered = 0, .swap_total = 0, .swap_used = 0 };
        };

        self.total_mem = mem_info.total;

        return mem_info;
    }

    pub fn getDiskStats(self: *SysInfo) DiskStats {
        const stats = readDiskStats() catch .{ .read_bytes = 0, .write_bytes = 0 };
        const now = std.time.milliTimestamp();
        const elapsed = now - self.prev_disk_ms;

        var read_ps: u64 = 0;
        var write_ps: u64 = 0;

        if (elapsed > 0 and self.prev_disk_read > 0) {
            const d_read = stats.read_bytes -| self.prev_disk_read;
            const d_write = stats.write_bytes -| self.prev_disk_write;
            read_ps = (d_read *| 1000) / @as(u64, @intCast(elapsed));
            write_ps = (d_write *| 1000) / @as(u64, @intCast(elapsed));
        }

        self.prev_disk_read = stats.read_bytes;
        self.prev_disk_write = stats.write_bytes;
        self.prev_disk_ms = now;

        return .{ .read_bytes_ps = read_ps, .write_bytes_ps = write_ps };
    }

    pub fn getNetStats(self: *SysInfo) NetStats {
        const stats = readNetStats() catch .{ .rx_bytes = 0, .tx_bytes = 0 };
        const now = std.time.milliTimestamp();
        const elapsed = now - self.prev_net_ms;

        var rx_ps: u64 = 0;
        var tx_ps: u64 = 0;

        if (elapsed > 0 and self.prev_net_rx > 0) {
            const d_rx = stats.rx_bytes -| self.prev_net_rx;
            const d_tx = stats.tx_bytes -| self.prev_net_tx;
            rx_ps = (d_rx * 1000) / @as(u64, @intCast(elapsed));
            tx_ps = (d_tx * 1000) / @as(u64, @intCast(elapsed));
        }

        self.prev_net_rx = stats.rx_bytes;
        self.prev_net_tx = stats.tx_bytes;
        self.prev_net_ms = now;

        return .{
            .rx_bytes_ps = rx_ps,
            .tx_bytes_ps = tx_ps,
            .rx_bytes = stats.rx_bytes,
            .tx_bytes = stats.tx_bytes,
        };
    }

    pub fn getThermalStats(self: *SysInfo) ThermalStats {
        _ = self;
        var buf: [64]u8 = undefined;
        const contents = readAbsoluteFile("/sys/class/thermal/thermal_zone0/temp", &buf) catch return .{};
        const temp_str = std.mem.trim(u8, contents, " \n");
        const milli_c = std.fmt.parseInt(i32, temp_str, 10) catch return .{};
        return .{ .cpu_temp = @as(f32, @floatFromInt(milli_c)) / 1000.0, .gpu_temp = null };
    }

    pub fn getBatteryStats(self: *SysInfo) BatteryStats {
        _ = self;
        var buf_cap: [64]u8 = undefined;
        var buf_stat: [64]u8 = undefined;
        var buf_power: [64]u8 = undefined;

        var charge_percent: ?f32 = null;
        if (readAbsoluteFile("/sys/class/power_supply/BAT0/capacity", &buf_cap)) |cap| {
            const val = std.fmt.parseInt(u32, std.mem.trim(u8, cap, " \n"), 10) catch 0;
            charge_percent = @as(f32, @floatFromInt(val));
        } else |_| {}

        var status: BatteryStatus = .unknown;
        if (readAbsoluteFile("/sys/class/power_supply/BAT0/status", &buf_stat)) |stat| {
            const s = std.mem.trim(u8, stat, " \n");
            if (std.mem.eql(u8, s, "Charging")) {
                status = .charging;
            } else if (std.mem.eql(u8, s, "Discharging")) {
                status = .discharging;
            } else if (std.mem.eql(u8, s, "Full")) {
                status = .full;
            }
        } else |_| {}

        var power_draw_w: ?f32 = null;
        if (readAbsoluteFile("/sys/class/power_supply/BAT0/power_now", &buf_power)) |power| {
            const val = std.fmt.parseInt(u64, std.mem.trim(u8, power, " \n"), 10) catch 0;
            power_draw_w = @as(f32, @floatFromInt(val)) / 1000000.0;
        } else |_| {}

        return .{ .charge_percent = charge_percent, .power_draw_w = power_draw_w, .status = status };
    }

    fn findPrevProcEntry(self: *const SysInfo, pid: u32) ?ProcCpuEntry {
        for (self.prev_procs[0..self.prev_proc_count]) |entry| {
            if (entry.pid == pid) return entry;
        }
        return null;
    }

    pub fn getProcStats(self: *SysInfo, allocator: std.mem.Allocator, sort_by: common.SortBy) ![]ProcStats {
        const snapshot = readCpuSnapshot() catch CpuSnapshot{};
        const total_tick_delta = if (self.prev_proc_total_ticks > 0) snapshot.overall.total -| self.prev_proc_total_ticks else 0;

        const now = std.time.milliTimestamp();
        const elapsed_ms = now - self.prev_time;

        var proc_dir = try std.fs.openDirAbsolute("/proc", .{ .iterate = true });
        defer proc_dir.close();

        var iter = proc_dir.iterate();
        var result: std.ArrayList(ProcStats) = .empty;
        var new_procs: [MAX_PROCS]ProcCpuEntry = undefined;
        var new_proc_count: usize = 0;

        while (try iter.next()) |entry| {
            if (entry.kind != .directory) continue;
            const pid = std.fmt.parseInt(u32, entry.name, 10) catch continue;

            var pid_dir = proc_dir.openDir(entry.name, .{}) catch continue;
            defer pid_dir.close();

            var stat_buf: [4096]u8 = undefined;
            const stat_contents = readDirFile(&pid_dir, "stat", &stat_buf) catch continue;
            const proc_info = parseProcStat(stat_contents) orelse continue;

            var statm_buf: [128]u8 = undefined;
            const statm_contents = readDirFile(&pid_dir, "statm", &statm_buf) catch continue;
            const resident_pages = parseResidentPages(statm_contents) orelse continue;
            const resident_size = resident_pages * self.page_size;

            var io_buf: [1024]u8 = undefined;
            var disk_read: u64 = 0;
            var disk_write: u64 = 0;
            if (readDirFile(&pid_dir, "io", &io_buf)) |io_contents| {
                var lines = std.mem.splitScalar(u8, io_contents, '\n');
                while (lines.next()) |line| {
                    if (std.mem.startsWith(u8, line, "read_bytes:")) {
                        disk_read = std.fmt.parseInt(u64, std.mem.trim(u8, line[11..], " \t"), 10) catch 0;
                    } else if (std.mem.startsWith(u8, line, "write_bytes:")) {
                        disk_write = std.fmt.parseInt(u64, std.mem.trim(u8, line[12..], " \t"), 10) catch 0;
                    }
                }
            } else |_| {}

            if (new_proc_count < MAX_PROCS) {
                new_procs[new_proc_count] = .{ .pid = pid, .cpu_total = proc_info.cpu_total, .disk_read = disk_read, .disk_write = disk_write };
                new_proc_count += 1;
            }

            var cpu_percent: f32 = 0;
            var disk_read_ps: u64 = 0;
            var disk_write_ps: u64 = 0;

            const prev_entry = self.findPrevProcEntry(pid);

            if (prev_entry) |prev| {
                if (total_tick_delta > 0) {
                    if (proc_info.cpu_total >= prev.cpu_total) {
                        const delta_cpu = proc_info.cpu_total - prev.cpu_total;
                        cpu_percent = @as(f32, @floatFromInt(delta_cpu * self.ncpu)) / @as(f32, @floatFromInt(total_tick_delta)) * 100.0;
                    }
                }
                if (elapsed_ms > 0) {
                    const d_read = disk_read -| prev.disk_read;
                    const d_write = disk_write -| prev.disk_write;
                    disk_read_ps = (d_read *| 1000) / @as(u64, @intCast(elapsed_ms));
                    disk_write_ps = (d_write *| 1000) / @as(u64, @intCast(elapsed_ms));
                }
            }

            const mem_percent: f32 = if (self.total_mem > 0)
                @as(f32, @floatFromInt(resident_size)) / @as(f32, @floatFromInt(self.total_mem)) * 100.0
            else
                0;

            const name = if (proc_info.name.len > 63) proc_info.name[0..63] else proc_info.name;
            var proc_stat = ProcStats{
                .pid = pid,
                .ppid = proc_info.ppid,
                .cpu_percent = cpu_percent,
                .mem_percent = mem_percent,
                .threads = proc_info.num_threads,
                .disk_read_ps = disk_read_ps,
                .disk_write_ps = disk_write_ps,
                .name_len = @intCast(name.len),
                .state = proc_info.state,
            };
            @memcpy(proc_stat.name_buf[0..name.len], name);
            try result.append(allocator, proc_stat);
        }

        @memcpy(self.prev_procs[0..new_proc_count], new_procs[0..new_proc_count]);
        self.prev_proc_count = new_proc_count;
        self.prev_proc_total_ticks = snapshot.overall.total;
        self.prev_time = now;

        const slice = try result.toOwnedSlice(allocator);
        common.sortProcStats(slice, sort_by);
        return slice;
    }

    pub fn getThreadStats(self: *SysInfo, allocator: std.mem.Allocator, pid: u32) ![]common.ThreadStats {
        if (self.thread_view_pid != pid) {
            self.thread_view_pid = pid;
            self.prev_thread_count = 0;
        }

        const snapshot = readCpuSnapshot() catch CpuSnapshot{};
        const total_tick_delta = if (self.prev_thread_total_ticks > 0) snapshot.overall.total -| self.prev_thread_total_ticks else 0;

        var path_buf: [64]u8 = undefined;
        const task_path = std.fmt.bufPrint(&path_buf, "/proc/{d}/task", .{pid}) catch
            return allocator.alloc(common.ThreadStats, 0);

        var task_dir = std.fs.openDirAbsolute(task_path, .{ .iterate = true }) catch
            return allocator.alloc(common.ThreadStats, 0);
        defer task_dir.close();

        var iter = task_dir.iterate();
        var result: std.ArrayList(common.ThreadStats) = .empty;
        var new_threads: [MAX_THREADS]common.ThreadCpuEntry = undefined;
        var new_thread_count: usize = 0;

        while (try iter.next()) |entry| {
            if (entry.kind != .directory) continue;
            const tid = std.fmt.parseInt(u64, entry.name, 10) catch continue;

            var tid_dir = task_dir.openDir(entry.name, .{}) catch continue;
            defer tid_dir.close();

            var stat_buf: [4096]u8 = undefined;
            const stat_contents = readDirFile(&tid_dir, "stat", &stat_buf) catch continue;
            const parsed = parseProcStat(stat_contents) orelse continue;

            // Read comm for thread name
            var comm_buf: [128]u8 = undefined;
            var name_buf_local: [64]u8 = std.mem.zeroes([64]u8);
            var name_len: u8 = 0;
            if (readDirFile(&tid_dir, "comm", &comm_buf)) |comm| {
                const trimmed = std.mem.trimRight(u8, comm, "\n");
                name_len = @intCast(@min(trimmed.len, 63));
                @memcpy(name_buf_local[0..name_len], trimmed[0..name_len]);
            } else |_| {
                const n = if (parsed.name.len > 63) parsed.name[0..63] else parsed.name;
                name_len = @intCast(n.len);
                @memcpy(name_buf_local[0..name_len], n);
            }

            if (new_thread_count < MAX_THREADS) {
                new_threads[new_thread_count] = .{ .tid = tid, .cpu_total = parsed.cpu_total };
                new_thread_count += 1;
            }

            var cpu_percent: f32 = 0;
            for (self.prev_threads[0..self.prev_thread_count]) |prev| {
                if (prev.tid == tid) {
                    if (total_tick_delta > 0 and parsed.cpu_total >= prev.cpu_total) {
                        const delta_cpu = parsed.cpu_total - prev.cpu_total;
                        cpu_percent = @as(f32, @floatFromInt(delta_cpu * self.ncpu)) / @as(f32, @floatFromInt(total_tick_delta)) * 100.0;
                    }
                    break;
                }
            }

            var thread_stat = common.ThreadStats{
                .tid = tid,
                .cpu_percent = cpu_percent,
                .state = parsed.state,
                .name_len = name_len,
            };
            @memcpy(thread_stat.name_buf[0..name_len], name_buf_local[0..name_len]);

            try result.append(allocator, thread_stat);
        }

        @memcpy(self.prev_threads[0..new_thread_count], new_threads[0..new_thread_count]);
        self.prev_thread_count = new_thread_count;
        self.prev_thread_total_ticks = snapshot.overall.total;

        const thread_slice = try result.toOwnedSlice(allocator);
        common.sortThreadStats(thread_slice);
        return thread_slice;
    }
};

fn readDirFile(dir: *std.fs.Dir, sub_path: []const u8, buf: []u8) ![]const u8 {
    var file = try dir.openFile(sub_path, .{});
    defer file.close();
    const len = try file.readAll(buf);
    return buf[0..len];
}

fn readAbsoluteFile(path: []const u8, buf: []u8) ![]const u8 {
    var file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    const len = try file.readAll(buf);
    return buf[0..len];
}

fn parseCpuStatLine(line: []const u8) ?struct { label: []const u8, tick: CpuTick } {
    var fields = std.mem.tokenizeAny(u8, line, " \t");
    const label = fields.next() orelse return null;
    if (!std.mem.startsWith(u8, label, "cpu")) return null;

    var total: u64 = 0;
    var idle: u64 = 0;
    var iowait: u64 = 0;
    var value_index: usize = 0;

    while (fields.next()) |field| : (value_index += 1) {
        const value = std.fmt.parseInt(u64, field, 10) catch return null;
        total += value;
        if (value_index == 3) idle = value;
        if (value_index == 4) iowait = value;
    }

    if (value_index < 4) return null;

    return .{
        .label = label,
        .tick = .{
            .total = total,
            .active = total -| (idle + iowait),
        },
    };
}

fn readCpuSnapshot() !CpuSnapshot {
    var buf: [16384]u8 = undefined;
    const contents = try readAbsoluteFile("/proc/stat", &buf);

    var snapshot = CpuSnapshot{};
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        const parsed = parseCpuStatLine(line) orelse continue;
        if (std.mem.eql(u8, parsed.label, "cpu")) {
            snapshot.overall = parsed.tick;
            continue;
        }

        if (snapshot.core_count >= MAX_CORES) continue;
        if (parsed.label.len > 3 and std.ascii.isDigit(parsed.label[3])) {
            snapshot.cores[snapshot.core_count] = parsed.tick;
            snapshot.core_count += 1;
        }
    }

    return snapshot;
}

pub fn parseProcStat(contents: []const u8) ?ParsedProcStat {
    const line = std.mem.trimRight(u8, contents, "\n");
    const open_paren = std.mem.indexOfScalar(u8, line, '(') orelse return null;
    const close_paren = std.mem.lastIndexOfScalar(u8, line, ')') orelse return null;
    if (close_paren <= open_paren) return null;

    const name = line[open_paren + 1 .. close_paren];
    const rest = std.mem.trimLeft(u8, line[close_paren + 1 ..], " ");
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

fn parseResidentPages(contents: []const u8) ?u64 {
    var fields = std.mem.tokenizeAny(u8, contents, " \t\n");
    _ = fields.next() orelse return null;
    const resident = fields.next() orelse return null;
    return std.fmt.parseInt(u64, resident, 10) catch null;
}

fn readDiskStats() !struct { read_bytes: u64, write_bytes: u64 } {
    var buf: [4096]u8 = undefined;
    const contents = readAbsoluteFile("/proc/diskstats", &buf) catch return .{ .read_bytes = 0, .write_bytes = 0 };
    var lines = std.mem.splitScalar(u8, contents, '\n');
    var read_sectors: u64 = 0;
    var write_sectors: u64 = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        _ = fields.next();
        _ = fields.next();
        const dev = fields.next() orelse continue;
        if (std.mem.startsWith(u8, dev, "loop") or std.mem.startsWith(u8, dev, "ram")) continue;

        _ = fields.next();
        _ = fields.next();
        const rs = fields.next() orelse continue;
        _ = fields.next();
        _ = fields.next();
        _ = fields.next();
        const ws = fields.next() orelse continue;

        read_sectors += std.fmt.parseInt(u64, rs, 10) catch 0;
        write_sectors += std.fmt.parseInt(u64, ws, 10) catch 0;
    }
    return .{ .read_bytes = read_sectors * 512, .write_bytes = write_sectors * 512 };
}

fn readNetStats() !struct { rx_bytes: u64, tx_bytes: u64 } {
    var buf: [4096]u8 = undefined;
    const contents = readAbsoluteFile("/proc/net/dev", &buf) catch return .{ .rx_bytes = 0, .tx_bytes = 0 };
    var lines = std.mem.splitScalar(u8, contents, '\n');
    _ = lines.next();
    _ = lines.next();

    var rx: u64 = 0;
    var tx: u64 = 0;

    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const dev = std.mem.trim(u8, line[0..colon], " \t");
        if (std.mem.eql(u8, dev, "lo")) continue;

        var fields = std.mem.tokenizeAny(u8, line[colon + 1 ..], " \t");
        const r_bytes = fields.next() orelse continue;
        rx += std.fmt.parseInt(u64, r_bytes, 10) catch 0;

        for (0..7) |_| {
            _ = fields.next();
        }
        const t_bytes = fields.next() orelse continue;
        tx += std.fmt.parseInt(u64, t_bytes, 10) catch 0;
    }
    return .{ .rx_bytes = rx, .tx_bytes = tx };
}

fn readMemInfoTotal() !u64 {
    const mem_info = try readMemInfo();
    return mem_info.total;
}

fn readMemInfo() !MemStats {
    var buf: [4096]u8 = undefined;
    const contents = try readAbsoluteFile("/proc/meminfo", &buf);

    var total_kb: ?u64 = null;
    var available_kb: ?u64 = null;
    var cached_kb: ?u64 = null;
    var buffered_kb: ?u64 = null;
    var swap_total_kb: ?u64 = null;
    var swap_free_kb: ?u64 = null;

    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "MemTotal:")) {
            total_kb = parseMemInfoValue(line);
        } else if (std.mem.startsWith(u8, line, "MemAvailable:")) {
            available_kb = parseMemInfoValue(line);
        } else if (std.mem.startsWith(u8, line, "Cached:")) {
            cached_kb = parseMemInfoValue(line);
        } else if (std.mem.startsWith(u8, line, "Buffers:")) {
            buffered_kb = parseMemInfoValue(line);
        } else if (std.mem.startsWith(u8, line, "SwapTotal:")) {
            swap_total_kb = parseMemInfoValue(line);
        } else if (std.mem.startsWith(u8, line, "SwapFree:")) {
            swap_free_kb = parseMemInfoValue(line);
        }
    }

    const total = common.kbToBytes(total_kb orelse return error.UnexpectedProcMemInfo);
    const free = common.kbToBytes(available_kb orelse return error.UnexpectedProcMemInfo);
    const used = total -| free;
    const cached = common.kbToBytes(cached_kb orelse 0);
    const buffered = common.kbToBytes(buffered_kb orelse 0);
    const swap_total = common.kbToBytes(swap_total_kb orelse 0);
    const swap_free = common.kbToBytes(swap_free_kb orelse 0);
    const swap_used = swap_total -| swap_free;

    return .{
        .total = total,
        .used = used,
        .free = free,
        .cached = cached,
        .buffered = buffered,
        .swap_total = swap_total,
        .swap_used = swap_used,
    };
}

fn parseMemInfoValue(line: []const u8) ?u64 {
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return null;
    var fields = std.mem.tokenizeAny(u8, line[colon + 1 ..], " \t");
    const value = fields.next() orelse return null;
    return std.fmt.parseInt(u64, value, 10) catch null;
}
