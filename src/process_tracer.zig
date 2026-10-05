const std = @import("std");
const common = @import("sysinfo/common.zig");
const MetricHistory = @import("history.zig").MetricHistory;
const SysInfo = @import("sysinfo.zig").SysInfo;

const SocketKey = struct {
    protocol: common.NetProtocol,
    local_port: u16,
    remote_port: u16,
    local_addr: [46]u8,
    remote_addr: [46]u8,

    fn fromConnection(conn: common.NetConnection) SocketKey {
        return .{
            .protocol = conn.protocol,
            .local_port = conn.local_port,
            .remote_port = conn.remote_port,
            .local_addr = conn.local_addr,
            .remote_addr = conn.remote_addr,
        };
    }
};

const SocketSet = std.AutoHashMapUnmanaged(SocketKey, void);

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
    prev_socket_set: SocketSet = .empty,
    current_socket_set: SocketSet = .empty,
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
        self.prev_socket_set.deinit(self.allocator);
        self.current_socket_set.deinit(self.allocator);
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
        const conns = sys_info.getProcNetConnections(self.allocator, self.pid) catch &.{};
        defer self.allocator.free(conns);

        self.updateSockets(conns, ts) catch {};
    }

    pub fn updateSockets(self: *ProcessTracer, conns: []const common.NetConnection, ts: i64) !void {
        try self.prev_sockets.ensureTotalCapacity(self.allocator, conns.len);
        try self.current_socket_set.ensureTotalCapacity(self.allocator, @intCast(conns.len));
        self.current_socket_set.clearRetainingCapacity();
        for (conns) |conn| {
            self.current_socket_set.putAssumeCapacity(SocketKey.fromConnection(conn), {});
        }

        for (conns) |curr| {
            if (!self.prev_socket_set.contains(SocketKey.fromConnection(curr))) {
                self.appendEvent(.socket_open, ts, "Socket opened: {s} {s}:{d} -> {s}:{d}", .{ @tagName(curr.protocol), std.mem.sliceTo(&curr.local_addr, 0), curr.local_port, std.mem.sliceTo(&curr.remote_addr, 0), curr.remote_port });
            }
        }

        for (self.prev_sockets.items) |prev| {
            if (!self.current_socket_set.contains(SocketKey.fromConnection(prev))) {
                self.appendEvent(.socket_close, ts, "Socket closed: {s} {s}:{d} -> {s}:{d}", .{ @tagName(prev.protocol), std.mem.sliceTo(&prev.local_addr, 0), prev.local_port, std.mem.sliceTo(&prev.remote_addr, 0), prev.remote_port });
            }
        }

        self.prev_sockets.clearRetainingCapacity();
        self.prev_sockets.appendSliceAssumeCapacity(conns);
        std.mem.swap(SocketSet, &self.prev_socket_set, &self.current_socket_set);
    }
};
