const std = @import("std");
const common = @import("sysinfo/common.zig");
const MetricHistory = @import("history.zig").MetricHistory;
const SysInfo = @import("sysinfo.zig").SysInfo;

pub const ProcessTraceEventKind = enum {
    state_transition,
    cpu_burst,
    memory_growth,
    thread_spawn,
    thread_exit,
    socket_open,
    socket_close,
    proc_exit,
};

pub const ProcessTraceEvent = struct {
    timestamp_ms: i64,
    kind: ProcessTraceEventKind,
    detail_buf: [128]u8 = std.mem.zeroes([128]u8),
    detail_len: u8 = 0,

    pub fn detail(self: *const ProcessTraceEvent) []const u8 {
        return self.detail_buf[0..self.detail_len];
    }
};

pub const ProcessTracer = struct {
    pid: u32,
    cpu_history: MetricHistory = .{},
    mem_history: MetricHistory = .{},

    events: [1024]ProcessTraceEvent = undefined,
    ev_start: usize = 0,
    ev_count: usize = 0,

    prev_state: common.ProcState = .unknown,
    prev_threads: u32 = 0,
    prev_mem_percent: f32 = 0,
    prev_cpu_percent: f32 = 0,
    prev_sockets: std.ArrayList(common.NetConnection),
    allocator: std.mem.Allocator,

    is_dead: bool = false,

    pub fn init(allocator: std.mem.Allocator, pid: u32) !*ProcessTracer {
        const ptr = try allocator.create(ProcessTracer);
        ptr.* = .{
            .pid = pid,
            .prev_sockets = .empty,
            .allocator = allocator,
        };
        return ptr;
    }

    pub fn deinit(self: *ProcessTracer) void {
        self.prev_sockets.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    fn appendEvent(self: *ProcessTracer, kind: ProcessTraceEventKind, ts: i64, comptime fmt: []const u8, args: anytype) void {
        var ev: ProcessTraceEvent = .{
            .timestamp_ms = ts,
            .kind = kind,
        };
        const written = std.fmt.bufPrint(&ev.detail_buf, fmt, args) catch ev.detail_buf[0..0];
        ev.detail_len = @intCast(written.len);

        if (self.ev_count < self.events.len) {
            self.events[(self.ev_start + self.ev_count) % self.events.len] = ev;
            self.ev_count += 1;
        } else {
            self.events[self.ev_start] = ev;
            self.ev_start = (self.ev_start + 1) % self.events.len;
        }
    }

    pub fn getEvent(self: *const ProcessTracer, index: usize) ?*const ProcessTraceEvent {
        if (index >= self.ev_count) return null;
        return &self.events[(self.ev_start + index) % self.events.len];
    }

    fn netConnectionsEqual(a: *const common.NetConnection, b: *const common.NetConnection) bool {
        if (a.protocol != b.protocol) return false;
        if (a.local_port != b.local_port) return false;
        if (a.remote_port != b.remote_port) return false;
        if (!std.mem.eql(u8, &a.local_addr, &b.local_addr)) return false;
        if (!std.mem.eql(u8, &a.remote_addr, &b.remote_addr)) return false;
        return true;
    }

    pub fn update(self: *ProcessTracer, sys_info: *SysInfo, ts: i64, proc_opt: ?common.ProcStats) void {
        if (self.is_dead) return;

        if (proc_opt == null) {
            self.is_dead = true;
            self.appendEvent(.proc_exit, ts, "Process {d} exited", .{self.pid});
            return;
        }

        const proc = proc_opt.?;

        self.cpu_history.append(proc.cpu_percent);
        self.mem_history.append(proc.mem_percent);

        // State transition
        if (self.prev_state != .unknown and proc.state != self.prev_state) {
            self.appendEvent(.state_transition, ts, "State changed: {s} -> {s}", .{ @tagName(self.prev_state), @tagName(proc.state) });
        }
        self.prev_state = proc.state;

        // CPU burst (> 20% jump)
        if (proc.cpu_percent - self.prev_cpu_percent > 20.0) {
            self.appendEvent(.cpu_burst, ts, "CPU spiked from {d:.1}% to {d:.1}%", .{ self.prev_cpu_percent, proc.cpu_percent });
        }
        self.prev_cpu_percent = proc.cpu_percent;

        // Memory growth (> 5% jump)
        if (proc.mem_percent - self.prev_mem_percent > 5.0) {
            self.appendEvent(.memory_growth, ts, "Memory grew from {d:.1}% to {d:.1}%", .{ self.prev_mem_percent, proc.mem_percent });
        }
        self.prev_mem_percent = proc.mem_percent;

        // Thread changes
        if (self.prev_threads > 0) {
            if (proc.threads > self.prev_threads) {
                self.appendEvent(.thread_spawn, ts, "Threads increased: {d} -> {d}", .{ self.prev_threads, proc.threads });
            } else if (proc.threads < self.prev_threads) {
                self.appendEvent(.thread_exit, ts, "Threads decreased: {d} -> {d}", .{ self.prev_threads, proc.threads });
            }
        }
        self.prev_threads = proc.threads;

        // Socket opens/closes
        const conns = sys_info.getNetConnections(self.allocator) catch &.{};
        defer self.allocator.free(conns);

        var current_proc_conns: std.ArrayList(common.NetConnection) = .empty;
        defer current_proc_conns.deinit(self.allocator);

        for (conns) |c| {
            if (c.pid == self.pid) {
                current_proc_conns.append(self.allocator, c) catch {};
            }
        }

        // Diff sockets
        for (current_proc_conns.items) |curr| {
            var found = false;
            for (self.prev_sockets.items) |prev| {
                if (netConnectionsEqual(&curr, &prev)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                self.appendEvent(.socket_open, ts, "Socket opened: {s} {s}:{d} -> {s}:{d}", .{ @tagName(curr.protocol), std.mem.sliceTo(&curr.local_addr, 0), curr.local_port, std.mem.sliceTo(&curr.remote_addr, 0), curr.remote_port });
            }
        }

        for (self.prev_sockets.items) |prev| {
            var found = false;
            for (current_proc_conns.items) |curr| {
                if (netConnectionsEqual(&curr, &prev)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                self.appendEvent(.socket_close, ts, "Socket closed: {s} {s}:{d} -> {s}:{d}", .{ @tagName(prev.protocol), std.mem.sliceTo(&prev.local_addr, 0), prev.local_port, std.mem.sliceTo(&prev.remote_addr, 0), prev.remote_port });
            }
        }

        self.prev_sockets.clearRetainingCapacity();
        self.prev_sockets.appendSlice(self.allocator, current_proc_conns.items) catch {};
    }
};
