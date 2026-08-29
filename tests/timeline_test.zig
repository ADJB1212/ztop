const std = @import("std");
const timeline_mod = @import("ztop").timeline;
const common = @import("ztop").sysinfo.common;

const Timeline = timeline_mod.Timeline;
const SystemSnapshot = timeline_mod.SystemSnapshot;

fn makeSnap(ts: i64, cpu_pct: f32) SystemSnapshot {
    return .{
        .timestamp_ms = ts,
        .cpu_usage_pct = cpu_pct,
        .mem_usage_pct = 50.0,
    };
}

test "snapshot ring buffer stores and retrieves in order" {
    var tl = Timeline.init();

    tl.recordSnapshot(makeSnap(1000, 10.0), &.{});
    tl.recordSnapshot(makeSnap(2000, 20.0), &.{});
    tl.recordSnapshot(makeSnap(3000, 30.0), &.{});

    try std.testing.expectEqual(@as(usize, 3), tl.snapshotCount());

    // offset 0 = newest
    const newest = tl.getSnapshot(0).?;
    try std.testing.expectEqual(@as(i64, 3000), newest.timestamp_ms);
    try std.testing.expectApproxEqAbs(@as(f32, 30.0), newest.cpu_usage_pct, 0.01);

    // offset 2 = oldest
    const oldest = tl.getSnapshot(2).?;
    try std.testing.expectEqual(@as(i64, 1000), oldest.timestamp_ms);

    // out of range
    try std.testing.expectEqual(@as(?*const SystemSnapshot, null), tl.getSnapshot(3));
}

test "snapshot ring buffer wraps at MAX_SNAPSHOTS" {
    var tl = Timeline.init();

    for (0..timeline_mod.MAX_SNAPSHOTS + 5) |i| {
        tl.recordSnapshot(makeSnap(@intCast(i * 1000), @floatFromInt(i)), &.{});
    }

    try std.testing.expectEqual(timeline_mod.MAX_SNAPSHOTS, tl.snapshotCount());

    // Newest should be the last one written
    const newest = tl.getSnapshot(0).?;
    const expected_ts: i64 = @intCast((timeline_mod.MAX_SNAPSHOTS + 4) * 1000);
    try std.testing.expectEqual(expected_ts, newest.timestamp_ms);

    // Oldest should be 5 (the first 5 were evicted)
    const oldest = tl.getSnapshot(timeline_mod.MAX_SNAPSHOTS - 1).?;
    try std.testing.expectEqual(@as(i64, 5000), oldest.timestamp_ms);
}

test "getSnapshotAtIndex returns absolute indexed snapshots" {
    var tl = Timeline.init();

    tl.recordSnapshot(makeSnap(1000, 10.0), &.{});
    tl.recordSnapshot(makeSnap(2000, 20.0), &.{});
    tl.recordSnapshot(makeSnap(3000, 30.0), &.{});

    // index 0 = oldest
    const first = tl.getSnapshotAtIndex(0).?;
    try std.testing.expectEqual(@as(i64, 1000), first.timestamp_ms);

    const last = tl.getSnapshotAtIndex(2).?;
    try std.testing.expectEqual(@as(i64, 3000), last.timestamp_ms);

    try std.testing.expectEqual(@as(?*const SystemSnapshot, null), tl.getSnapshotAtIndex(3));
}

test "snapshot stores process data" {
    var tl = Timeline.init();

    var procs: [2]common.ProcStats = undefined;
    procs[0] = std.mem.zeroes(common.ProcStats);
    procs[0].pid = 100;
    procs[0].cpu_percent = 50.0;
    procs[1] = std.mem.zeroes(common.ProcStats);
    procs[1].pid = 200;
    procs[1].cpu_percent = 25.0;

    tl.recordSnapshot(makeSnap(1000, 40.0), procs[0..]);

    const snap = tl.getSnapshot(0).?;
    try std.testing.expectEqual(@as(u32, 2), snap.proc_count);
    try std.testing.expectEqual(@as(u32, 100), snap.procs[0].pid);
    try std.testing.expectEqual(@as(u32, 200), snap.procs[1].pid);
}

test "computeDiff memoizes recent comparisons and invalidates on append" {
    var tl = Timeline.init();
    tl.recordSnapshot(makeSnap(1000, 10.0), &.{});
    tl.recordSnapshot(makeSnap(2000, 20.0), &.{});
    tl.recordSnapshot(makeSnap(3000, 30.0), &.{});

    const first = tl.computeDiff(2, 0).?;
    const adjacent = tl.computeDiff(1, 0).?;
    const repeated = tl.computeDiff(2, 0).?;

    try std.testing.expect(first != adjacent);
    try std.testing.expectEqual(first, repeated);
    try std.testing.expectEqual(@as(i64, 2000), repeated.time_delta_ms);

    tl.recordSnapshot(makeSnap(4000, 40.0), &.{});
    const refreshed = tl.computeDiff(2, 0).?;
    try std.testing.expectEqual(@as(i64, 2000), refreshed.time_delta_ms);
    try std.testing.expectEqual(@as(f32, 20.0), refreshed.cpu_before);
    try std.testing.expectEqual(@as(f32, 40.0), refreshed.cpu_after);
}

test "detectAndRecordEvents detects CPU spike" {
    var tl = Timeline.init();

    const snap = makeSnap(1000, 90.0);
    tl.detectAndRecordEvents(&snap, &.{}, .celsius);

    try std.testing.expect(tl.ev_count >= 1);
    const ev = tl.getEvent(0).?;
    try std.testing.expectEqual(timeline_mod.EventKind.cpu_spike, ev.kind);
}

test "CPU spike cooldown prevents spam" {
    var tl = Timeline.init();

    // First spike
    var snap = makeSnap(1000, 95.0);
    tl.detectAndRecordEvents(&snap, &.{}, .celsius);
    const count_after_first = tl.ev_count;

    // Immediate second spike — should be suppressed by cooldown
    snap = makeSnap(2000, 95.0);
    tl.detectAndRecordEvents(&snap, &.{}, .celsius);
    try std.testing.expectEqual(count_after_first, tl.ev_count);

    // After cooldown ticks (5)
    for (0..4) |i| {
        snap = makeSnap(@intCast(3000 + i * 1000), 50.0);
        tl.detectAndRecordEvents(&snap, &.{}, .celsius);
    }

    // Now another spike should register
    snap = makeSnap(8000, 92.0);
    tl.detectAndRecordEvents(&snap, &.{}, .celsius);

    try std.testing.expect(tl.ev_count > count_after_first);
}

test "eventMaskInRange returns correct bitmask" {
    var tl = Timeline.init();

    const snap1 = makeSnap(1000, 95.0); // triggers cpu_spike
    tl.detectAndRecordEvents(&snap1, &.{}, .celsius);

    const mask = tl.eventMaskInRange(500, 1500);
    const cpu_bit = @as(u8, 1) << @intFromEnum(timeline_mod.EventKind.cpu_spike);
    try std.testing.expect(mask & cpu_bit != 0);

    // Out of range
    const mask2 = tl.eventMaskInRange(5000, 6000);
    try std.testing.expectEqual(@as(u8, 0), mask2);
}

test "getEventsNearSnapshot collects nearby events" {
    var tl = Timeline.init();

    const snap = makeSnap(1000, 95.0); // triggers cpu_spike at ts=1000
    tl.detectAndRecordEvents(&snap, &.{}, .celsius);

    tl.recordSnapshot(snap, &.{});

    var out: [8]timeline_mod.TimelineEvent = undefined;
    const count = tl.getEventsNearSnapshot(0, &out);
    try std.testing.expect(count >= 1);
    try std.testing.expectEqual(timeline_mod.EventKind.cpu_spike, out[0].kind);
}

test "birth/death detection finds new and exited processes" {
    var tl = Timeline.init();

    // First tick: establish baseline
    var procs1: [2]common.ProcStats = undefined;
    procs1[0] = std.mem.zeroes(common.ProcStats);
    procs1[0].pid = 10;
    procs1[1] = std.mem.zeroes(common.ProcStats);
    procs1[1].pid = 20;

    var snap1 = makeSnap(1000, 10.0);
    tl.detectAndRecordEvents(&snap1, procs1[0..], .celsius);

    // Second tick: PID 20 gone, PID 30 new
    var procs2: [2]common.ProcStats = undefined;
    procs2[0] = std.mem.zeroes(common.ProcStats);
    procs2[0].pid = 10;
    procs2[1] = std.mem.zeroes(common.ProcStats);
    procs2[1].pid = 30;

    var snap2 = makeSnap(2000, 10.0);
    tl.detectAndRecordEvents(&snap2, procs2[0..], .celsius);

    // Should have a death (PID 20) and a birth (PID 30)
    var found_death = false;
    var found_birth = false;
    for (0..tl.ev_count) |i| {
        const ev = tl.getEvent(i).?;
        if (ev.kind == .proc_death and ev.pid == 20) found_death = true;
        if (ev.kind == .proc_birth and ev.pid == 30) found_birth = true;
    }
    try std.testing.expect(found_death);
    try std.testing.expect(found_birth);
}

test "birth/death PID sets handle hash collisions" {
    var tl = Timeline.init();
    var baseline = [_]common.ProcStats{
        std.mem.zeroes(common.ProcStats),
        std.mem.zeroes(common.ProcStats),
    };
    baseline[0].pid = 1;
    baseline[1].pid = 4097;
    var first = makeSnap(1000, 10.0);
    tl.detectAndRecordEvents(&first, &baseline, .celsius);

    var current = [_]common.ProcStats{
        std.mem.zeroes(common.ProcStats),
        std.mem.zeroes(common.ProcStats),
    };
    current[0].pid = 4097;
    current[1].pid = 8193;
    var second = makeSnap(2000, 10.0);
    tl.detectAndRecordEvents(&second, &current, .celsius);

    var found_death = false;
    var found_birth = false;
    for (0..tl.ev_count) |i| {
        const event = tl.getEvent(i).?;
        if (event.kind == .proc_death and event.pid == 1) found_death = true;
        if (event.kind == .proc_birth and event.pid == 8193) found_birth = true;
    }
    try std.testing.expect(found_death);
    try std.testing.expect(found_birth);
}

test "birth/death capped at MAX_BIRTH_DEATH_PER_TICK" {
    var tl = Timeline.init();

    // Establish baseline with some PIDs
    var procs1: [4]common.ProcStats = undefined;
    for (&procs1, 0..) |*p, i| {
        p.* = std.mem.zeroes(common.ProcStats);
        p.pid = @intCast(i + 1);
    }
    var snap1 = makeSnap(1000, 10.0);
    tl.detectAndRecordEvents(&snap1, procs1[0..], .celsius);

    // New tick: entirely different PIDs (all old die, many new born)
    const new_count = timeline_mod.MAX_BIRTH_DEATH_PER_TICK + 10;
    var procs2: [timeline_mod.MAX_BIRTH_DEATH_PER_TICK + 10]common.ProcStats = undefined;
    for (procs2[0..new_count], 0..) |*p, i| {
        p.* = std.mem.zeroes(common.ProcStats);
        p.pid = @intCast(100 + i);
    }

    var snap2 = makeSnap(2000, 10.0);
    tl.detectAndRecordEvents(&snap2, procs2[0..new_count], .celsius);

    // Count birth+death events at ts=2000
    var bd_count: usize = 0;
    for (0..tl.ev_count) |i| {
        const ev = tl.getEvent(i).?;
        if (ev.timestamp_ms == 2000 and (ev.kind == .proc_birth or ev.kind == .proc_death)) {
            bd_count += 1;
        }
    }
    try std.testing.expect(bd_count <= timeline_mod.MAX_BIRTH_DEATH_PER_TICK);
}

test "formatDuration formats seconds correctly" {
    var buf: [16]u8 = undefined;

    try std.testing.expectEqualStrings("0s", Timeline.formatDuration(&buf, 0));
    try std.testing.expectEqualStrings("45s", Timeline.formatDuration(&buf, 45));
    try std.testing.expectEqualStrings("1m", Timeline.formatDuration(&buf, 60));
    try std.testing.expectEqualStrings("2m30s", Timeline.formatDuration(&buf, 150));
    try std.testing.expectEqualStrings("3m", Timeline.formatDuration(&buf, 180));
    try std.testing.expectEqualStrings("0s", Timeline.formatDuration(&buf, -5));
}

// ─── Session persistence (toBytes / fromBytes) ────────────────────────────────

test "toBytes/fromBytes empty timeline round-trips cleanly" {
    const allocator = std.testing.allocator;

    const tl = Timeline.init();
    const bytes = try tl.toBytes(allocator);
    defer allocator.free(bytes);

    var restored: Timeline = undefined;
    try restored.fromBytes(bytes);
    try std.testing.expectEqual(@as(usize, 0), restored.snapshotCount());
    try std.testing.expectEqual(@as(usize, 0), restored.ev_count);
    try std.testing.expectEqual(@as(usize, 0), restored.bookmark_count);
}

test "toBytes/fromBytes preserves snapshot scalar fields" {
    const allocator = std.testing.allocator;

    var tl = Timeline.init();
    var snap = makeSnap(42_000, 77.5);
    snap.cpu_cores = 8;
    snap.mem = .{ .total = 16 * 1024 * 1024 * 1024, .used = 8 * 1024 * 1024 * 1024, .free = 8 * 1024 * 1024 * 1024 };
    snap.mem_usage_pct = 50.0;
    snap.disk = .{ .read_bytes_ps = 100_000, .write_bytes_ps = 200_000 };
    snap.net = .{ .rx_bytes_ps = 1_000_000, .tx_bytes_ps = 500_000, .rx_bytes = 99, .tx_bytes = 88 };
    snap.thermal = .{ .cpu_temp = 72.3, .gpu_temp = null };
    snap.battery = .{ .charge_percent = 85.0, .power_draw_w = 12.5, .status = .discharging };
    tl.recordSnapshot(snap, &.{});

    const bytes = try tl.toBytes(allocator);
    defer allocator.free(bytes);

    var restored: Timeline = undefined;
    try restored.fromBytes(bytes);
    try std.testing.expectEqual(@as(usize, 1), restored.snapshotCount());

    const s = restored.getSnapshot(0).?;
    try std.testing.expectEqual(@as(i64, 42_000), s.timestamp_ms);
    try std.testing.expectApproxEqAbs(@as(f32, 77.5), s.cpu_usage_pct, 0.001);
    try std.testing.expectEqual(@as(u32, 8), s.cpu_cores);
    try std.testing.expectEqual(@as(u64, 100_000), s.disk.read_bytes_ps);
    try std.testing.expectEqual(@as(u64, 1_000_000), s.net.rx_bytes_ps);
    try std.testing.expectEqual(@as(u64, 88), s.net.tx_bytes);
    try std.testing.expect(s.thermal.cpu_temp != null);
    try std.testing.expectApproxEqAbs(@as(f32, 72.3), s.thermal.cpu_temp.?, 0.01);
    try std.testing.expectEqual(@as(?f32, null), s.thermal.gpu_temp);
    try std.testing.expect(s.battery.charge_percent != null);
    try std.testing.expectApproxEqAbs(@as(f32, 85.0), s.battery.charge_percent.?, 0.001);
    try std.testing.expectEqual(common.BatteryStatus.discharging, s.battery.status);
}

test "toBytes/fromBytes preserves snapshot process list" {
    const allocator = std.testing.allocator;

    var tl = Timeline.init();
    var procs: [3]common.ProcStats = undefined;
    for (&procs, 0..) |*p, i| {
        p.* = std.mem.zeroes(common.ProcStats);
        p.pid = @intCast(100 + i);
        p.ppid = 1;
        const name = "proc";
        p.name_len = @intCast(name.len);
        @memcpy(p.name_buf[0..name.len], name);
        p.cpu_percent = @as(f32, @floatFromInt(i)) * 10.0;
        p.mem_percent = 5.0;
        p.threads = 4;
        p.disk_read_ps = 1024 * @as(u64, @intCast(i + 1));
        p.disk_write_ps = 512;
        p.state = .sleeping;
    }

    tl.recordSnapshot(makeSnap(5_000, 30.0), procs[0..]);

    const bytes = try tl.toBytes(allocator);
    defer allocator.free(bytes);

    var restored: Timeline = undefined;
    try restored.fromBytes(bytes);
    const s = restored.getSnapshot(0).?;
    try std.testing.expectEqual(@as(u32, 3), s.proc_count);
    try std.testing.expectEqual(@as(u32, 100), s.procs[0].pid);
    try std.testing.expectEqual(@as(u32, 102), s.procs[2].pid);
    try std.testing.expectApproxEqAbs(@as(f32, 20.0), s.procs[2].cpu_percent, 0.001);
    try std.testing.expectEqual(common.ProcState.sleeping, s.procs[0].state);
    try std.testing.expectEqualStrings("proc", s.procs[1].name_buf[0..s.procs[1].name_len]);
    try std.testing.expectEqual(@as(u64, 2048), s.procs[1].disk_read_ps);
}

test "toBytes/fromBytes preserves multiple snapshots in order" {
    const allocator = std.testing.allocator;

    var tl = Timeline.init();
    tl.recordSnapshot(makeSnap(1_000, 10.0), &.{});
    tl.recordSnapshot(makeSnap(2_000, 20.0), &.{});
    tl.recordSnapshot(makeSnap(3_000, 30.0), &.{});

    const bytes = try tl.toBytes(allocator);
    defer allocator.free(bytes);

    var restored: Timeline = undefined;
    try restored.fromBytes(bytes);
    try std.testing.expectEqual(@as(usize, 3), restored.snapshotCount());

    // getSnapshot(0) = newest
    try std.testing.expectEqual(@as(i64, 3_000), restored.getSnapshot(0).?.timestamp_ms);
    try std.testing.expectEqual(@as(i64, 2_000), restored.getSnapshot(1).?.timestamp_ms);
    try std.testing.expectEqual(@as(i64, 1_000), restored.getSnapshot(2).?.timestamp_ms);
}

test "toBytes/fromBytes preserves events" {
    const allocator = std.testing.allocator;

    var tl = Timeline.init();
    // Drive a CPU spike event
    const snap = makeSnap(10_000, 95.0);
    tl.detectAndRecordEvents(&snap, &.{}, .celsius);

    try std.testing.expect(tl.ev_count >= 1);

    const bytes = try tl.toBytes(allocator);
    defer allocator.free(bytes);

    var restored: Timeline = undefined;
    try restored.fromBytes(bytes);
    try std.testing.expectEqual(tl.ev_count, restored.ev_count);

    const ev = restored.getEvent(0).?;
    try std.testing.expectEqual(timeline_mod.EventKind.cpu_spike, ev.kind);
    try std.testing.expectEqual(@as(i64, 10_000), ev.timestamp_ms);
}

test "toBytes/fromBytes preserves bookmarks" {
    const allocator = std.testing.allocator;

    var tl = Timeline.init();
    tl.recordSnapshot(makeSnap(1_000, 10.0), &.{});
    tl.recordSnapshot(makeSnap(2_000, 50.0), &.{});
    tl.recordSnapshot(makeSnap(3_000, 90.0), &.{});

    const added = tl.addBookmark(1); // bookmark offset-1 snapshot
    try std.testing.expect(added);
    try std.testing.expectEqual(@as(usize, 1), tl.bookmark_count);

    const bytes = try tl.toBytes(allocator);
    defer allocator.free(bytes);

    var restored: Timeline = undefined;
    try restored.fromBytes(bytes);
    try std.testing.expectEqual(@as(usize, 1), restored.bookmark_count);
    // The bookmark timestamp should match the snapshot we bookmarked
    const bm_ts = restored.bookmarks[0].timestamp_ms;
    try std.testing.expect(bm_ts == 2_000);
}

test "toBytes/fromBytes round-trips a wrapped ring buffer" {
    const allocator = std.testing.allocator;

    var tl = Timeline.init();
    // Overfill so the ring wraps
    for (0..timeline_mod.MAX_SNAPSHOTS + 10) |i| {
        tl.recordSnapshot(makeSnap(@intCast(i * 1000), @floatFromInt(i % 100)), &.{});
    }
    try std.testing.expectEqual(timeline_mod.MAX_SNAPSHOTS, tl.snapshotCount());

    const bytes = try tl.toBytes(allocator);
    defer allocator.free(bytes);

    var restored: Timeline = undefined;
    try restored.fromBytes(bytes);
    try std.testing.expectEqual(timeline_mod.MAX_SNAPSHOTS, restored.snapshotCount());

    // Newest snapshot should match
    const orig_newest = tl.getSnapshot(0).?;
    const rest_newest = restored.getSnapshot(0).?;
    try std.testing.expectEqual(orig_newest.timestamp_ms, rest_newest.timestamp_ms);
    try std.testing.expectApproxEqAbs(orig_newest.cpu_usage_pct, rest_newest.cpu_usage_pct, 0.001);

    // Oldest snapshot should also match
    const orig_oldest = tl.getSnapshot(timeline_mod.MAX_SNAPSHOTS - 1).?;
    const rest_oldest = restored.getSnapshot(timeline_mod.MAX_SNAPSHOTS - 1).?;
    try std.testing.expectEqual(orig_oldest.timestamp_ms, rest_oldest.timestamp_ms);
}

test "fromBytes rejects invalid magic bytes" {
    var bad: [8]u8 = .{ 'Z', 'B', 'A', 'D', 1, 0, 0, 0 };
    var tl: Timeline = undefined;
    try std.testing.expectError(error.InvalidSessionFile, tl.fromBytes(&bad));
}

test "fromBytes rejects unsupported version" {
    // Build a minimal valid header but bump the version
    var buf: [8]u8 = undefined;
    @memcpy(buf[0..4], &timeline_mod.SESSION_MAGIC);
    std.mem.writeInt(u32, buf[4..8], timeline_mod.SESSION_VERSION + 1, .little);
    var tl: Timeline = undefined;
    try std.testing.expectError(error.UnsupportedSessionVersion, tl.fromBytes(&buf));
}

test "fromBytes returns error on truncated data" {
    // A valid header but nothing after it — readU32 for snap_count should fail
    var buf: [8]u8 = undefined;
    @memcpy(buf[0..4], &timeline_mod.SESSION_MAGIC);
    std.mem.writeInt(u32, buf[4..8], timeline_mod.SESSION_VERSION, .little);
    var tl: Timeline = undefined;
    try std.testing.expectError(error.UnexpectedEndOfFile, tl.fromBytes(&buf));
}
