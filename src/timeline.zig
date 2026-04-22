const std = @import("std");
const common = @import("sysinfo/common.zig");

pub const MAX_SNAPSHOTS: usize = 180; // ~3 min at 1s intervals
pub const MAX_EVENTS: usize = 500;
pub const MAX_SNAPSHOT_PROCS: usize = 32;

pub const EventKind = enum(u8) {
    cpu_spike,
    mem_pressure,
    proc_birth,
    proc_death,
    thermal_high,
    battery_change,
    disk_spike,
    net_spike,
};

pub const TimelineEvent = struct {
    timestamp_ms: i64,
    kind: EventKind,
    detail_buf: [64]u8,
    detail_len: u8,
    pid: u32,

    pub fn detail(self: *const TimelineEvent) []const u8 {
        return self.detail_buf[0..self.detail_len];
    }

    pub fn kindLabel(self: *const TimelineEvent) []const u8 {
        return switch (self.kind) {
            .cpu_spike => "CPU",
            .mem_pressure => "MEM",
            .proc_birth => "NEW",
            .proc_death => "EXIT",
            .thermal_high => "TEMP",
            .battery_change => "BATT",
            .disk_spike => "DISK",
            .net_spike => "NET",
        };
    }

    pub fn kindChar(self: *const TimelineEvent) u8 {
        return switch (self.kind) {
            .cpu_spike => 'C',
            .mem_pressure => 'M',
            .proc_birth => '+',
            .proc_death => '-',
            .thermal_high => 'T',
            .battery_change => 'B',
            .disk_spike => 'D',
            .net_spike => 'N',
        };
    }
};

/// Compact system snapshot stored for scrubbing.
/// Stores the top MAX_SNAPSHOT_PROCS processes by sort order.
pub const SystemSnapshot = struct {
    timestamp_ms: i64 = 0,
    cpu_usage_pct: f32 = 0,
    cpu_cores: u32 = 0,
    mem: common.MemStats = .{ .total = 0, .used = 0, .free = 0 },
    mem_usage_pct: f32 = 0,
    disk: common.DiskStats = .{},
    net: common.NetStats = .{},
    thermal: common.ThermalStats = .{},
    battery: common.BatteryStats = .{},
    proc_count: u32 = 0,
    procs: [MAX_SNAPSHOT_PROCS]common.ProcStats = undefined,
};

/// Rolling event recorder + snapshot ring buffer.
/// This struct is ~2MB; must be heap-allocated with allocator.create(Timeline).
pub const Timeline = struct {
    // Snapshot ring buffer (newest overwrites oldest)
    snapshots: [MAX_SNAPSHOTS]SystemSnapshot,
    snap_start: usize, // oldest index in ring
    snap_count: usize,

    // Event ring buffer
    events: [MAX_EVENTS]TimelineEvent,
    ev_start: usize,
    ev_count: usize,

    // State for birth/death detection
    prev_pids: [common.MAX_PROCS]u32,
    prev_pid_count: usize,
    prev_battery_status: common.BatteryStatus,

    // Cooldowns to suppress event spam (in ticks)
    cpu_spike_cooldown: u8,
    mem_spike_cooldown: u8,
    thermal_cooldown: u8,
    disk_spike_cooldown: u8,
    net_spike_cooldown: u8,

    pub fn init() Timeline {
        return .{
            .snapshots = undefined,
            .snap_start = 0,
            .snap_count = 0,
            .events = undefined,
            .ev_start = 0,
            .ev_count = 0,
            .prev_pids = undefined,
            .prev_pid_count = 0,
            .prev_battery_status = .unknown,
            .cpu_spike_cooldown = 0,
            .mem_spike_cooldown = 0,
            .thermal_cooldown = 0,
            .disk_spike_cooldown = 0,
            .net_spike_cooldown = 0,
        };
    }

    pub fn snapshotCount(self: *const Timeline) usize {
        return self.snap_count;
    }

    /// Get snapshot at offset from newest (0 = most recent).
    pub fn getSnapshot(self: *const Timeline, offset: usize) ?*const SystemSnapshot {
        if (self.snap_count == 0 or offset >= self.snap_count) return null;
        const idx = (self.snap_start + self.snap_count - 1 - offset) % MAX_SNAPSHOTS;
        return &self.snapshots[idx];
    }

    /// Get snapshot at absolute index (0 = oldest).
    pub fn getSnapshotAtIndex(self: *const Timeline, index: usize) ?*const SystemSnapshot {
        if (index >= self.snap_count) return null;
        return &self.snapshots[(self.snap_start + index) % MAX_SNAPSHOTS];
    }

    /// Append a snapshot. Stores the first MAX_SNAPSHOT_PROCS processes from procs.
    pub fn recordSnapshot(self: *Timeline, snap: SystemSnapshot, procs: []const common.ProcStats) void {
        var s = snap;
        const proc_count = @min(procs.len, MAX_SNAPSHOT_PROCS);
        s.proc_count = @intCast(proc_count);
        for (0..proc_count) |i| {
            s.procs[i] = procs[i];
        }

        if (self.snap_count < MAX_SNAPSHOTS) {
            self.snapshots[(self.snap_start + self.snap_count) % MAX_SNAPSHOTS] = s;
            self.snap_count += 1;
        } else {
            self.snapshots[self.snap_start] = s;
            self.snap_start = (self.snap_start + 1) % MAX_SNAPSHOTS;
        }
    }

    fn appendEvent(self: *Timeline, event: TimelineEvent) void {
        if (self.ev_count < MAX_EVENTS) {
            self.events[(self.ev_start + self.ev_count) % MAX_EVENTS] = event;
            self.ev_count += 1;
        } else {
            self.events[self.ev_start] = event;
            self.ev_start = (self.ev_start + 1) % MAX_EVENTS;
        }
    }

    fn makeEvent(kind: EventKind, ts: i64, pid: u32, comptime fmt: []const u8, args: anytype) TimelineEvent {
        var ev: TimelineEvent = .{
            .timestamp_ms = ts,
            .kind = kind,
            .detail_buf = std.mem.zeroes([64]u8),
            .detail_len = 0,
            .pid = pid,
        };
        const written = std.fmt.bufPrint(&ev.detail_buf, fmt, args) catch ev.detail_buf[0..0];
        ev.detail_len = @intCast(written.len);
        return ev;
    }

    /// Detect events by comparing snap against previous state, then record them.
    /// Call this before recordSnapshot on each fetch tick.
    pub fn detectAndRecordEvents(self: *Timeline, snap: *const SystemSnapshot, procs: []const common.ProcStats) void {
        const ts = snap.timestamp_ms;

        if (self.cpu_spike_cooldown > 0) self.cpu_spike_cooldown -= 1;
        if (self.mem_spike_cooldown > 0) self.mem_spike_cooldown -= 1;
        if (self.thermal_cooldown > 0) self.thermal_cooldown -= 1;
        if (self.disk_spike_cooldown > 0) self.disk_spike_cooldown -= 1;
        if (self.net_spike_cooldown > 0) self.net_spike_cooldown -= 1;

        // CPU spike (>80%)
        if (snap.cpu_usage_pct >= 80.0 and self.cpu_spike_cooldown == 0) {
            self.appendEvent(makeEvent(.cpu_spike, ts, 0, "CPU {d:.0}%", .{snap.cpu_usage_pct}));
            self.cpu_spike_cooldown = 5;
        }

        // Memory pressure (>85%)
        if (snap.mem_usage_pct >= 85.0 and self.mem_spike_cooldown == 0) {
            self.appendEvent(makeEvent(.mem_pressure, ts, 0, "MEM {d:.0}%", .{snap.mem_usage_pct}));
            self.mem_spike_cooldown = 5;
        }

        // Thermal high (CPU >85°C)
        if (snap.thermal.cpu_temp) |temp| {
            if (temp >= 85.0 and self.thermal_cooldown == 0) {
                self.appendEvent(makeEvent(.thermal_high, ts, 0, "CPU {d:.0}C", .{temp}));
                self.thermal_cooldown = 10;
            }
        }

        // Battery status change
        if (snap.battery.status != self.prev_battery_status and self.prev_battery_status != .unknown) {
            self.appendEvent(makeEvent(.battery_change, ts, 0, "{s}", .{@tagName(snap.battery.status)}));
        }
        self.prev_battery_status = snap.battery.status;

        // Disk spike (>100 MB/s combined)
        const disk_total = snap.disk.read_bytes_ps + snap.disk.write_bytes_ps;
        if (disk_total > 100 * 1024 * 1024 and self.disk_spike_cooldown == 0) {
            self.appendEvent(makeEvent(.disk_spike, ts, 0, "Disk {d:.0}MB/s", .{
                @as(f32, @floatFromInt(disk_total)) / (1024.0 * 1024.0),
            }));
            self.disk_spike_cooldown = 5;
        }

        // Net spike (>10 MB/s combined)
        const net_total = snap.net.rx_bytes_ps + snap.net.tx_bytes_ps;
        if (net_total > 10 * 1024 * 1024 and self.net_spike_cooldown == 0) {
            self.appendEvent(makeEvent(.net_spike, ts, 0, "Net {d:.0}MB/s", .{
                @as(f32, @floatFromInt(net_total)) / (1024.0 * 1024.0),
            }));
            self.net_spike_cooldown = 5;
        }

        // Process births/deaths (skip on first tick when no baseline)
        if (self.prev_pid_count > 0 and procs.len > 0) {
            // Deaths: PIDs in prev not in current
            outer_death: for (self.prev_pids[0..self.prev_pid_count]) |prev_pid| {
                for (procs) |p| {
                    if (p.pid == prev_pid) continue :outer_death;
                }
                self.appendEvent(makeEvent(.proc_death, ts, prev_pid, "PID {d} exited", .{prev_pid}));
            }
            // Births: PIDs in current not in prev
            outer_birth: for (procs) |p| {
                for (self.prev_pids[0..self.prev_pid_count]) |prev_pid| {
                    if (p.pid == prev_pid) continue :outer_birth;
                }
                self.appendEvent(makeEvent(.proc_birth, ts, p.pid, "{s} ({d})", .{ p.name(), p.pid }));
            }
        }

        // Update PID baseline
        const new_count = @min(procs.len, common.MAX_PROCS);
        self.prev_pid_count = new_count;
        for (procs[0..new_count], 0..) |p, i| {
            self.prev_pids[i] = p.pid;
        }
    }

    /// Get event at logical index (0 = oldest).
    pub fn getEvent(self: *const Timeline, index: usize) ?*const TimelineEvent {
        if (index >= self.ev_count) return null;
        return &self.events[(self.ev_start + index) % MAX_EVENTS];
    }

    /// Return bitmask of EventKind bits for all events in [ts_start, ts_end].
    pub fn eventMaskInRange(self: *const Timeline, ts_start: i64, ts_end: i64) u8 {
        var mask: u8 = 0;
        for (0..self.ev_count) |i| {
            const ev = self.getEvent(i) orelse break;
            if (ev.timestamp_ms >= ts_start and ev.timestamp_ms <= ts_end) {
                const bit = @as(u3, @intCast(@intFromEnum(ev.kind) & 7));
                mask |= @as(u8, 1) << bit;
            }
        }
        return mask;
    }

    /// Collect events near a snapshot (within ±1 second). Returns count written.
    pub fn getEventsNearSnapshot(
        self: *const Timeline,
        snap_offset: usize,
        out: []TimelineEvent,
    ) usize {
        const snap = self.getSnapshot(snap_offset) orelse return 0;
        const ts = snap.timestamp_ms;
        var count: usize = 0;
        for (0..self.ev_count) |i| {
            if (count >= out.len) break;
            const ev = self.getEvent(i) orelse break;
            const diff = ts - ev.timestamp_ms;
            if (diff >= -1000 and diff <= 1000) {
                out[count] = ev.*;
                count += 1;
            }
        }
        return count;
    }
};
