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

test "detectAndRecordEvents detects CPU spike" {
    var tl = Timeline.init();

    const snap = makeSnap(1000, 90.0);
    tl.detectAndRecordEvents(&snap, &.{});

    try std.testing.expect(tl.ev_count >= 1);
    const ev = tl.getEvent(0).?;
    try std.testing.expectEqual(timeline_mod.EventKind.cpu_spike, ev.kind);
}

test "CPU spike cooldown prevents spam" {
    var tl = Timeline.init();

    // First spike
    var snap = makeSnap(1000, 95.0);
    tl.detectAndRecordEvents(&snap, &.{});
    const count_after_first = tl.ev_count;

    // Immediate second spike — should be suppressed by cooldown
    snap = makeSnap(2000, 95.0);
    tl.detectAndRecordEvents(&snap, &.{});
    try std.testing.expectEqual(count_after_first, tl.ev_count);

    // After cooldown ticks (5)
    for (0..4) |i| {
        snap = makeSnap(@intCast(3000 + i * 1000), 50.0);
        tl.detectAndRecordEvents(&snap, &.{});
    }

    // Now another spike should register
    snap = makeSnap(8000, 92.0);
    tl.detectAndRecordEvents(&snap, &.{});
    try std.testing.expect(tl.ev_count > count_after_first);
}

test "eventMaskInRange returns correct bitmask" {
    var tl = Timeline.init();

    const snap1 = makeSnap(1000, 95.0); // triggers cpu_spike
    tl.detectAndRecordEvents(&snap1, &.{});

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
    tl.detectAndRecordEvents(&snap, &.{});
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
    tl.detectAndRecordEvents(&snap1, procs1[0..]);

    // Second tick: PID 20 gone, PID 30 new
    var procs2: [2]common.ProcStats = undefined;
    procs2[0] = std.mem.zeroes(common.ProcStats);
    procs2[0].pid = 10;
    procs2[1] = std.mem.zeroes(common.ProcStats);
    procs2[1].pid = 30;

    var snap2 = makeSnap(2000, 10.0);
    tl.detectAndRecordEvents(&snap2, procs2[0..]);

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

test "birth/death capped at MAX_BIRTH_DEATH_PER_TICK" {
    var tl = Timeline.init();

    // Establish baseline with some PIDs
    var procs1: [4]common.ProcStats = undefined;
    for (&procs1, 0..) |*p, i| {
        p.* = std.mem.zeroes(common.ProcStats);
        p.pid = @intCast(i + 1);
    }
    var snap1 = makeSnap(1000, 10.0);
    tl.detectAndRecordEvents(&snap1, procs1[0..]);

    // New tick: entirely different PIDs (all old die, many new born)
    const new_count = timeline_mod.MAX_BIRTH_DEATH_PER_TICK + 10;
    var procs2: [timeline_mod.MAX_BIRTH_DEATH_PER_TICK + 10]common.ProcStats = undefined;
    for (procs2[0..new_count], 0..) |*p, i| {
        p.* = std.mem.zeroes(common.ProcStats);
        p.pid = @intCast(100 + i);
    }

    var snap2 = makeSnap(2000, 10.0);
    tl.detectAndRecordEvents(&snap2, procs2[0..new_count]);

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
