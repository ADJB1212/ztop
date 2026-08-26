const std = @import("std");
const common = @import("sysinfo/common.zig");
const config = @import("config.zig");

pub const MAX_SNAPSHOTS: usize = 180; // ~3 min at 1s intervals

pub const MAX_EVENTS: usize = 500;
pub const MAX_SNAPSHOT_PROCS: usize = 32;
pub const MAX_BIRTH_DEATH_PER_TICK: usize = 8;
pub const MAX_BOOKMARKS: usize = 10;

pub const Bookmark = struct {
    timestamp_ms: i64 = 0,
    /// Snapshot absolute index (from oldest = 0) at time of creation.
    snap_abs_idx: usize = 0,
};

pub const MAX_DIFF_PROCS: usize = 16;
const DIFF_CACHE_CAPACITY: usize = 4;

pub const ProcDiffKind = enum {
    appeared,
    disappeared,
    changed,
};

pub const ProcDiffEntry = struct {
    kind: ProcDiffKind,
    name_buf: [64]u8 = std.mem.zeroes([64]u8),
    name_len: u8 = 0,
    pid: u32 = 0,
    cpu_before: f32 = 0,
    cpu_after: f32 = 0,
    mem_before: f32 = 0,
    mem_after: f32 = 0,

    pub fn name(self: *const ProcDiffEntry) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    /// Absolute magnitude of change for sorting (CPU delta + mem delta).
    pub fn magnitude(self: *const ProcDiffEntry) f32 {
        return @abs(self.cpu_after - self.cpu_before) + @abs(self.mem_after - self.mem_before);
    }
};

pub const SnapshotDiff = struct {
    time_delta_ms: i64 = 0,

    // System metric deltas (after - before)
    cpu_before: f32 = 0,
    cpu_after: f32 = 0,
    mem_before_pct: f32 = 0,
    mem_after_pct: f32 = 0,
    mem_before: common.MemStats = .{ .total = 0, .used = 0, .free = 0 },
    mem_after: common.MemStats = .{ .total = 0, .used = 0, .free = 0 },
    disk_read_before: u64 = 0,
    disk_read_after: u64 = 0,
    disk_write_before: u64 = 0,
    disk_write_after: u64 = 0,
    net_rx_before: u64 = 0,
    net_rx_after: u64 = 0,
    net_tx_before: u64 = 0,
    net_tx_after: u64 = 0,
    temp_before: ?f32 = null,
    temp_after: ?f32 = null,

    // Process changes sorted by magnitude
    proc_diffs: [MAX_DIFF_PROCS]ProcDiffEntry = undefined,
    proc_diff_count: usize = 0,
};

const DiffCacheEntry = struct {
    older_offset: usize = 0,
    newer_offset: usize = 0,
    value: SnapshotDiff = undefined,
    valid: bool = false,
};

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

    // Incident bookmarks
    bookmarks: [MAX_BOOKMARKS]Bookmark,
    bookmark_count: usize,

    diff_cache: [DIFF_CACHE_CAPACITY]DiffCacheEntry,
    diff_cache_next: usize,

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
            .bookmarks = undefined,
            .bookmark_count = 0,
            .diff_cache = [_]DiffCacheEntry{.{}} ** DIFF_CACHE_CAPACITY,
            .diff_cache_next = 0,
        };
    }

    fn invalidateDiffCache(self: *Timeline) void {
        for (&self.diff_cache) |*entry| entry.valid = false;
        self.diff_cache_next = 0;
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
        self.invalidateDiffCache();

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
    pub fn detectAndRecordEvents(self: *Timeline, snap: *const SystemSnapshot, procs: []const common.ProcStats, temp_unit: config.TemperatureUnit) void {
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
                self.appendEvent(makeEvent(.thermal_high, ts, 0, "CPU {d:.0}{s}", .{ temp_unit.format(temp), temp_unit.label() }));
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
        // Capped to MAX_BIRTH_DEATH_PER_TICK to prevent event flooding on large churn.
        if (self.prev_pid_count > 0 and procs.len > 0) {
            var bd_count: usize = 0;
            // Deaths: PIDs in prev not in current
            outer_death: for (self.prev_pids[0..self.prev_pid_count]) |prev_pid| {
                if (bd_count >= MAX_BIRTH_DEATH_PER_TICK) break;
                for (procs) |p| {
                    if (p.pid == prev_pid) continue :outer_death;
                }
                self.appendEvent(makeEvent(.proc_death, ts, prev_pid, "PID {d} exited", .{prev_pid}));
                bd_count += 1;
            }
            // Births: PIDs in current not in prev
            outer_birth: for (procs) |p| {
                if (bd_count >= MAX_BIRTH_DEATH_PER_TICK) break;
                for (self.prev_pids[0..self.prev_pid_count]) |prev_pid| {
                    if (p.pid == prev_pid) continue :outer_birth;
                }
                self.appendEvent(makeEvent(.proc_birth, ts, p.pid, "{s} ({d})", .{ p.name(), p.pid }));
                bd_count += 1;
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

    /// Format a duration in seconds as a compact human-readable string (e.g. "45s", "2m30s").
    pub fn formatDuration(buf: []u8, seconds: i64) []const u8 {
        const s: u64 = if (seconds < 0) 0 else @intCast(seconds);
        if (s < 60) {
            return std.fmt.bufPrint(buf, "{d}s", .{s}) catch "?s";
        }
        const m = s / 60;
        const rem = s % 60;
        if (rem == 0) {
            return std.fmt.bufPrint(buf, "{d}m", .{m}) catch "?m";
        }
        return std.fmt.bufPrint(buf, "{d}m{d}s", .{ m, rem }) catch "?";
    }

    /// Add a bookmark at the given scrub offset (0 = newest).
    /// Returns true if added, false if full or duplicate.
    pub fn addBookmark(self: *Timeline, scrub_offset: usize) bool {
        if (self.bookmark_count >= MAX_BOOKMARKS or self.snap_count == 0) return false;
        if (scrub_offset >= self.snap_count) return false;

        const snap = self.getSnapshot(scrub_offset) orelse return false;
        const ts = snap.timestamp_ms;

        // Reject duplicate: same timestamp within 1s of existing bookmark
        for (self.bookmarks[0..self.bookmark_count]) |bm| {
            const diff = if (ts > bm.timestamp_ms) ts - bm.timestamp_ms else bm.timestamp_ms - ts;
            if (diff < 1000) return false;
        }

        self.bookmarks[self.bookmark_count] = .{
            .timestamp_ms = ts,
            .snap_abs_idx = self.snap_count - 1 - scrub_offset,
        };
        self.bookmark_count += 1;
        return true;
    }

    /// Remove the bookmark nearest to the given scrub offset.
    /// Returns true if a bookmark was removed.
    pub fn removeBookmarkNearest(self: *Timeline, scrub_offset: usize) bool {
        if (self.bookmark_count == 0 or self.snap_count == 0) return false;
        const snap = self.getSnapshot(scrub_offset) orelse return false;
        const ts = snap.timestamp_ms;

        var best_idx: usize = 0;
        var best_diff: i64 = std.math.maxInt(i64);
        for (self.bookmarks[0..self.bookmark_count], 0..) |bm, i| {
            const diff = if (ts > bm.timestamp_ms) ts - bm.timestamp_ms else bm.timestamp_ms - ts;
            if (diff < best_diff) {
                best_diff = diff;
                best_idx = i;
            }
        }

        // Remove by swapping with last
        self.bookmark_count -= 1;
        if (best_idx < self.bookmark_count) {
            self.bookmarks[best_idx] = self.bookmarks[self.bookmark_count];
        }
        return true;
    }

    /// Convert a bookmark's timestamp to a current scrub offset.
    /// Returns null if the snapshot has been evicted from the ring buffer.
    fn bookmarkToOffset(self: *const Timeline, bm: Bookmark) ?usize {
        if (self.snap_count == 0) return null;
        // Find snapshot closest to bookmark timestamp
        var best_offset: usize = 0;
        var best_diff: i64 = std.math.maxInt(i64);
        for (0..self.snap_count) |offset| {
            const snap = self.getSnapshot(offset) orelse continue;
            const diff = if (snap.timestamp_ms > bm.timestamp_ms)
                snap.timestamp_ms - bm.timestamp_ms
            else
                bm.timestamp_ms - snap.timestamp_ms;
            if (diff < best_diff) {
                best_diff = diff;
                best_offset = offset;
            }
        }
        // Only match if within 2s (snapshot may have been evicted)
        if (best_diff > 2000) return null;
        return best_offset;
    }

    /// Jump to next bookmark (toward present / lower offset) from current scrub_offset.
    /// Returns new scrub_offset, or null if no bookmark toward present.
    pub fn nextBookmarkOffset(self: *const Timeline, current_offset: usize) ?usize {
        var best: ?usize = null;
        for (self.bookmarks[0..self.bookmark_count]) |bm| {
            const offset = self.bookmarkToOffset(bm) orelse continue;
            if (offset < current_offset) {
                if (best == null or offset > best.?) {
                    best = offset;
                }
            }
        }
        return best;
    }

    /// Jump to prev bookmark (toward past / higher offset) from current scrub_offset.
    /// Returns new scrub_offset, or null if no bookmark toward past.
    pub fn prevBookmarkOffset(self: *const Timeline, current_offset: usize) ?usize {
        var best: ?usize = null;
        for (self.bookmarks[0..self.bookmark_count]) |bm| {
            const offset = self.bookmarkToOffset(bm) orelse continue;
            if (offset > current_offset) {
                if (best == null or offset < best.?) {
                    best = offset;
                }
            }
        }
        return best;
    }

    /// Check if a bookmark exists at a given absolute snapshot index.
    /// Used by the timeline bar renderer to show bookmark markers.
    pub fn hasBookmarkAtAbsIndex(self: *const Timeline, abs_idx: usize) bool {
        if (self.snap_count == 0) return false;
        const snap = self.getSnapshotAtIndex(abs_idx) orelse return false;
        const ts = snap.timestamp_ms;
        for (self.bookmarks[0..self.bookmark_count]) |bm| {
            const diff = if (ts > bm.timestamp_ms) ts - bm.timestamp_ms else bm.timestamp_ms - ts;
            if (diff < 1000) return true;
        }
        return false;
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

    /// Compute a diff between two snapshots identified by scrub offsets.
    /// anchor_offset is the "before" point, cursor_offset is the "after" point.
    /// If anchor is more recent (lower offset), they are swapped so before < after in time.
    /// The returned pointer remains valid until its cache entry is replaced or a
    /// new snapshot is recorded.
    pub fn computeDiff(self: *Timeline, anchor_offset: usize, cursor_offset: usize) ?*const SnapshotDiff {
        const older_offset = @max(anchor_offset, cursor_offset);
        const newer_offset = @min(anchor_offset, cursor_offset);

        for (&self.diff_cache) |*entry| {
            if (entry.valid and entry.older_offset == older_offset and entry.newer_offset == newer_offset) {
                return &entry.value;
            }
        }

        const before_snap = self.getSnapshot(older_offset) orelse return null;
        const after_snap = self.getSnapshot(newer_offset) orelse return null;

        var diff: SnapshotDiff = .{};
        diff.time_delta_ms = after_snap.timestamp_ms - before_snap.timestamp_ms;

        // System metrics
        diff.cpu_before = before_snap.cpu_usage_pct;
        diff.cpu_after = after_snap.cpu_usage_pct;
        diff.mem_before_pct = before_snap.mem_usage_pct;
        diff.mem_after_pct = after_snap.mem_usage_pct;
        diff.mem_before = before_snap.mem;
        diff.mem_after = after_snap.mem;
        diff.disk_read_before = before_snap.disk.read_bytes_ps;
        diff.disk_read_after = after_snap.disk.read_bytes_ps;
        diff.disk_write_before = before_snap.disk.write_bytes_ps;
        diff.disk_write_after = after_snap.disk.write_bytes_ps;
        diff.net_rx_before = before_snap.net.rx_bytes_ps;
        diff.net_rx_after = after_snap.net.rx_bytes_ps;
        diff.net_tx_before = before_snap.net.tx_bytes_ps;
        diff.net_tx_after = after_snap.net.tx_bytes_ps;
        diff.temp_before = before_snap.thermal.cpu_temp;
        diff.temp_after = after_snap.thermal.cpu_temp;

        // Process diffs
        const before_procs = before_snap.procs[0..before_snap.proc_count];
        const after_procs = after_snap.procs[0..after_snap.proc_count];

        // Changed/disappeared: processes in before
        for (before_procs) |bp| {
            if (diff.proc_diff_count >= MAX_DIFF_PROCS) break;
            var found = false;
            for (after_procs) |ap| {
                if (ap.pid == bp.pid) {
                    found = true;
                    // Only include if there's meaningful change
                    const cpu_delta = @abs(ap.cpu_percent - bp.cpu_percent);
                    const mem_delta = @abs(ap.mem_percent - bp.mem_percent);
                    if (cpu_delta >= 1.0 or mem_delta >= 0.5) {
                        var entry = ProcDiffEntry{
                            .kind = .changed,
                            .pid = bp.pid,
                            .cpu_before = bp.cpu_percent,
                            .cpu_after = ap.cpu_percent,
                            .mem_before = bp.mem_percent,
                            .mem_after = ap.mem_percent,
                        };
                        entry.name_len = bp.name_len;
                        @memcpy(entry.name_buf[0..bp.name_len], bp.name_buf[0..bp.name_len]);
                        diff.proc_diffs[diff.proc_diff_count] = entry;
                        diff.proc_diff_count += 1;
                    }
                    break;
                }
            }
            if (!found and diff.proc_diff_count < MAX_DIFF_PROCS) {
                var entry = ProcDiffEntry{
                    .kind = .disappeared,
                    .pid = bp.pid,
                    .cpu_before = bp.cpu_percent,
                    .mem_before = bp.mem_percent,
                };
                entry.name_len = bp.name_len;
                @memcpy(entry.name_buf[0..bp.name_len], bp.name_buf[0..bp.name_len]);
                diff.proc_diffs[diff.proc_diff_count] = entry;
                diff.proc_diff_count += 1;
            }
        }

        // Appeared: processes in after but not in before
        for (after_procs) |ap| {
            if (diff.proc_diff_count >= MAX_DIFF_PROCS) break;
            var found = false;
            for (before_procs) |bp| {
                if (bp.pid == ap.pid) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                var entry = ProcDiffEntry{
                    .kind = .appeared,
                    .pid = ap.pid,
                    .cpu_after = ap.cpu_percent,
                    .mem_after = ap.mem_percent,
                };
                entry.name_len = ap.name_len;
                @memcpy(entry.name_buf[0..ap.name_len], ap.name_buf[0..ap.name_len]);
                diff.proc_diffs[diff.proc_diff_count] = entry;
                diff.proc_diff_count += 1;
            }
        }

        // Sort by magnitude descending
        std.mem.sort(ProcDiffEntry, diff.proc_diffs[0..diff.proc_diff_count], {}, struct {
            fn lessThan(_: void, a: ProcDiffEntry, b: ProcDiffEntry) bool {
                return a.magnitude() > b.magnitude();
            }
        }.lessThan);

        const entry = &self.diff_cache[self.diff_cache_next];
        self.diff_cache_next = (self.diff_cache_next + 1) % self.diff_cache.len;
        entry.* = .{
            .older_offset = older_offset,
            .newer_offset = newer_offset,
            .value = diff,
            .valid = true,
        };
        return &entry.value;
    }

    // ─── Persistence API (methods on Timeline) ────────────────────────────────

    /// Serialize the full timeline to a freshly allocated byte slice.
    /// Caller owns the returned memory and should free it with `allocator.free`.
    pub fn toBytes(self: *const Timeline, allocator: std.mem.Allocator) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);

        // Header: magic + version
        try buf.appendSlice(allocator, &SESSION_MAGIC);
        try appendU32(allocator, &buf, SESSION_VERSION);

        // Snapshots oldest → newest
        try appendU32(allocator, &buf, @intCast(self.snap_count));
        for (0..self.snap_count) |i| {
            const snap = self.getSnapshotAtIndex(i).?;
            try serializeSnapshot(allocator, &buf, snap);
        }

        // Events oldest → newest
        try appendU32(allocator, &buf, @intCast(self.ev_count));
        for (0..self.ev_count) |i| {
            const ev = self.getEvent(i).?;
            try serializeEvent(allocator, &buf, ev);
        }

        // Bookmarks
        try appendU32(allocator, &buf, @intCast(self.bookmark_count));
        for (self.bookmarks[0..self.bookmark_count]) |bm| {
            try appendI64(allocator, &buf, bm.timestamp_ms);
            try appendU64(allocator, &buf, @intCast(bm.snap_abs_idx));
        }

        return buf.toOwnedSlice(allocator);
    }

    /// Reconstruct a Timeline from bytes previously produced by `toBytes`.
    /// Writes into `self` on success; leaves `self` unchanged on error.
    /// Returns error.InvalidSessionFile or error.UnsupportedSessionVersion on format mismatch.
    pub fn fromBytes(self: *Timeline, data: []const u8) !void {
        var r: ByteReader = .{ .data = data };

        const magic = try r.readBytesFixed(4);
        if (!std.mem.eql(u8, magic, &SESSION_MAGIC)) return error.InvalidSessionFile;
        const version = try r.readU32();
        if (version != SESSION_VERSION) return error.UnsupportedSessionVersion;

        self.* = Timeline.init();

        const snap_count = try r.readU32();
        for (0..snap_count) |_| {
            const snap = try deserializeSnapshot(&r);
            self.recordSnapshot(snap, snap.procs[0..snap.proc_count]);
        }

        const ev_count = try r.readU32();
        for (0..ev_count) |_| {
            const ev = try deserializeEvent(&r);
            self.appendEvent(ev);
        }

        const bm_count = try r.readU32();
        for (0..bm_count) |_| {
            const ts = try r.readI64();
            const abs_idx = try r.readU64();
            if (self.bookmark_count < MAX_BOOKMARKS) {
                self.bookmarks[self.bookmark_count] = .{
                    .timestamp_ms = ts,
                    .snap_abs_idx = @intCast(@min(abs_idx, std.math.maxInt(usize))),
                };
                self.bookmark_count += 1;
            }
        }
    }

    /// Persist the timeline to a binary file at `path`.
    /// Creates intermediate directories as needed.
    /// Errors (disk full, permission denied, etc.) are returned to the caller.
    pub fn saveToDisk(self: *const Timeline, io: std.Io, allocator: std.mem.Allocator, path: []const u8) !void {
        const data = try self.toBytes(allocator);
        defer allocator.free(data);

        // Ensure the cache directory exists
        if (std.fs.path.dirname(path)) |parent| {
            std.Io.Dir.cwd().createDirPath(io, parent) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
        }

        try std.Io.Dir.cwd().writeFile(io, .{
            .sub_path = path,
            .data = data,
        });
    }

    /// Load a previously saved timeline from `path` into `self`.
    /// Returns `error.FileNotFound` if the file does not exist.
    /// Returns `error.InvalidSessionFile` / `error.UnsupportedSessionVersion` on format mismatch.
    pub fn loadFromDisk(self: *Timeline, io: std.Io, allocator: std.mem.Allocator, path: []const u8) !void {
        const data = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(SESSION_MAX_BYTES));
        defer allocator.free(data);
        try self.fromBytes(data);
    }
};

/// Magic bytes identifying a ztop session file.
pub const SESSION_MAGIC: [4]u8 = "ZTOP".*;
/// Binary format version. Increment when the schema changes incompatibly.
pub const SESSION_VERSION: u32 = 2;
/// Maximum file size that loadFromDisk will accept (guards against corrupt/huge files).
const SESSION_MAX_BYTES: usize = 4 * 1024 * 1024;

// ─── Binary serialization helpers ────────────────────────────────────────────

fn appendU32(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), val: u32) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, val, .little);
    try buf.appendSlice(gpa, &bytes);
}

fn appendI64(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), val: i64) !void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(i64, &bytes, val, .little);
    try buf.appendSlice(gpa, &bytes);
}

fn appendU64(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), val: u64) !void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, val, .little);
    try buf.appendSlice(gpa, &bytes);
}

fn appendF32(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), val: f32) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, @bitCast(val), .little);
    try buf.appendSlice(gpa, &bytes);
}

fn appendOptF32(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), val: ?f32) !void {
    if (val) |v| {
        try buf.append(gpa, 1);
        try appendF32(gpa, buf, v);
    } else {
        try buf.append(gpa, 0);
        try buf.appendSlice(gpa, &[4]u8{ 0, 0, 0, 0 });
    }
}

fn serializeSnapshot(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), snap: *const SystemSnapshot) !void {
    try appendI64(gpa, buf, snap.timestamp_ms);
    try appendF32(gpa, buf, snap.cpu_usage_pct);
    try appendU32(gpa, buf, snap.cpu_cores);
    try appendU64(gpa, buf, snap.mem.total);
    try appendU64(gpa, buf, snap.mem.used);
    try appendU64(gpa, buf, snap.mem.free);
    try appendU64(gpa, buf, snap.mem.cached);
    try appendU64(gpa, buf, snap.mem.buffered);
    try appendU64(gpa, buf, snap.mem.swap_total);
    try appendU64(gpa, buf, snap.mem.swap_used);
    try appendF32(gpa, buf, snap.mem_usage_pct);
    try appendU64(gpa, buf, snap.disk.read_bytes_ps);
    try appendU64(gpa, buf, snap.disk.write_bytes_ps);
    try appendU64(gpa, buf, snap.net.rx_bytes_ps);
    try appendU64(gpa, buf, snap.net.tx_bytes_ps);
    try appendU64(gpa, buf, snap.net.rx_bytes);
    try appendU64(gpa, buf, snap.net.tx_bytes);
    try appendOptF32(gpa, buf, snap.thermal.cpu_temp);
    try appendOptF32(gpa, buf, snap.thermal.gpu_temp);
    try appendOptF32(gpa, buf, snap.battery.charge_percent);
    try appendOptF32(gpa, buf, snap.battery.power_draw_w);
    try buf.append(gpa, @intFromEnum(snap.battery.status));
    try appendU32(gpa, buf, snap.proc_count);
    for (snap.procs[0..snap.proc_count]) |p| {
        try appendU32(gpa, buf, p.pid);
        try appendU32(gpa, buf, p.ppid);
        try buf.append(gpa, p.name_len);
        try buf.appendSlice(gpa, p.name_buf[0..p.name_len]);
        try buf.append(gpa, @intFromEnum(p.state));
        try appendF32(gpa, buf, p.cpu_percent);
        try appendF32(gpa, buf, p.mem_percent);
        try appendU32(gpa, buf, p.threads);
        try appendU64(gpa, buf, p.disk_read_ps);
        try appendU64(gpa, buf, p.disk_write_ps);
        try appendU64(gpa, buf, p.wakeups_ps);
        try appendU64(gpa, buf, p.context_switches_ps);
    }
}

fn serializeEvent(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), ev: *const TimelineEvent) !void {
    try appendI64(gpa, buf, ev.timestamp_ms);
    try buf.append(gpa, @intFromEnum(ev.kind));
    try appendU32(gpa, buf, ev.pid);
    try buf.append(gpa, ev.detail_len);
    try buf.appendSlice(gpa, ev.detail_buf[0..ev.detail_len]);
}

// ─── Binary deserialization helpers ──────────────────────────────────────────

const ByteReader = struct {
    data: []const u8,
    pos: usize = 0,

    fn readByte(r: *ByteReader) !u8 {
        if (r.pos >= r.data.len) return error.UnexpectedEndOfFile;
        const val = r.data[r.pos];
        r.pos += 1;
        return val;
    }

    fn readBytesFixed(r: *ByteReader, comptime n: usize) !*const [n]u8 {
        if (r.pos + n > r.data.len) return error.UnexpectedEndOfFile;
        const ptr: *const [n]u8 = r.data[r.pos..][0..n];
        r.pos += n;
        return ptr;
    }

    fn readSlice(r: *ByteReader, n: usize) ![]const u8 {
        if (r.pos + n > r.data.len) return error.UnexpectedEndOfFile;
        const slice = r.data[r.pos .. r.pos + n];
        r.pos += n;
        return slice;
    }

    fn readU32(r: *ByteReader) !u32 {
        return std.mem.readInt(u32, try r.readBytesFixed(4), .little);
    }

    fn readI64(r: *ByteReader) !i64 {
        return std.mem.readInt(i64, try r.readBytesFixed(8), .little);
    }

    fn readU64(r: *ByteReader) !u64 {
        return std.mem.readInt(u64, try r.readBytesFixed(8), .little);
    }

    fn readF32(r: *ByteReader) !f32 {
        return @bitCast(try r.readU32());
    }

    fn readOptF32(r: *ByteReader) !?f32 {
        const present = try r.readByte();
        const val = try r.readF32();
        return if (present != 0) val else null;
    }
};

fn deserializeSnapshot(r: *ByteReader) !SystemSnapshot {
    var snap: SystemSnapshot = .{
        .timestamp_ms = try r.readI64(),
        .cpu_usage_pct = try r.readF32(),
        .cpu_cores = try r.readU32(),
        .mem = .{
            .total = try r.readU64(),
            .used = try r.readU64(),
            .free = try r.readU64(),
            .cached = try r.readU64(),
            .buffered = try r.readU64(),
            .swap_total = try r.readU64(),
            .swap_used = try r.readU64(),
        },
        .mem_usage_pct = try r.readF32(),
        .disk = .{
            .read_bytes_ps = try r.readU64(),
            .write_bytes_ps = try r.readU64(),
        },
        .net = .{
            .rx_bytes_ps = try r.readU64(),
            .tx_bytes_ps = try r.readU64(),
            .rx_bytes = try r.readU64(),
            .tx_bytes = try r.readU64(),
        },
        .thermal = .{
            .cpu_temp = try r.readOptF32(),
            .gpu_temp = try r.readOptF32(),
        },
        .battery = .{
            .charge_percent = try r.readOptF32(),
            .power_draw_w = try r.readOptF32(),
            .status = std.enums.fromInt(common.BatteryStatus, try r.readByte()) orelse .unknown,
        },
        .proc_count = 0,
        .procs = undefined,
    };

    const proc_count = try r.readU32();
    snap.proc_count = @intCast(@min(proc_count, MAX_SNAPSHOT_PROCS));
    for (0..proc_count) |i| {
        const pid = try r.readU32();
        const ppid = try r.readU32();
        const name_len = try r.readByte();
        const name_data = try r.readSlice(name_len);
        const state_raw = try r.readByte();
        const cpu_percent = try r.readF32();
        const mem_percent = try r.readF32();
        const threads = try r.readU32();
        const disk_read_ps = try r.readU64();
        const disk_write_ps = try r.readU64();
        const wakeups_ps = try r.readU64();
        const context_switches_ps = try r.readU64();
        if (i < MAX_SNAPSHOT_PROCS) {
            var p: common.ProcStats = std.mem.zeroes(common.ProcStats);
            p.pid = pid;
            p.ppid = ppid;
            p.name_len = name_len;
            const copy_len = @min(name_len, @as(u8, 64));
            @memcpy(p.name_buf[0..copy_len], name_data[0..copy_len]);
            p.state = std.enums.fromInt(common.ProcState, state_raw) orelse .unknown;
            p.cpu_percent = cpu_percent;
            p.mem_percent = mem_percent;
            p.threads = threads;
            p.disk_read_ps = disk_read_ps;
            p.disk_write_ps = disk_write_ps;
            p.wakeups_ps = wakeups_ps;
            p.context_switches_ps = context_switches_ps;
            snap.procs[i] = p;
        }
    }

    return snap;
}

fn deserializeEvent(r: *ByteReader) !TimelineEvent {
    const ts = try r.readI64();
    const kind_raw = try r.readByte();
    const pid = try r.readU32();
    const detail_len = try r.readByte();
    const detail_data = try r.readSlice(detail_len);

    var ev: TimelineEvent = .{
        .timestamp_ms = ts,
        .kind = std.enums.fromInt(EventKind, kind_raw) orelse .cpu_spike,
        .pid = pid,
        .detail_buf = std.mem.zeroes([64]u8),
        .detail_len = detail_len,
    };
    const copy_len = @min(detail_len, @as(u8, 64));
    @memcpy(ev.detail_buf[0..copy_len], detail_data[0..copy_len]);
    return ev;
}
