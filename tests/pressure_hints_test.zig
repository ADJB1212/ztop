const std = @import("std");
const render = @import("ztop").render;
const sysinfo = @import("ztop").sysinfo;
const timeline_mod = @import("ztop").timeline;

// ── helpers ───────────────────────────────────────────────────────────────────

const MB: u64 = 1024 * 1024;

fn makeProc(pid: u32, cpu: f32, mem: f32, disk_w: u64) sysinfo.ProcStats {
    var p = std.mem.zeroes(sysinfo.ProcStats);
    p.pid = pid;
    p.cpu_percent = cpu;
    p.mem_percent = mem;
    p.disk_write_ps = disk_w;
    return p;
}

fn makeProcNamed(pid: u32, cpu: f32, mem: f32, disk_w: u64, name: []const u8) sysinfo.ProcStats {
    var p = makeProc(pid, cpu, mem, disk_w);
    const n = @min(name.len, p.name_buf.len);
    @memcpy(p.name_buf[0..n], name[0..n]);
    p.name_len = @intCast(n);
    return p;
}

fn makeProcThreads(pid: u32, threads: u32) sysinfo.ProcStats {
    var p = std.mem.zeroes(sysinfo.ProcStats);
    p.pid = pid;
    p.threads = threads;
    return p;
}

fn makeMem(total: u64, used: u64, swap_total: u64, swap_used: u64, cached: u64) sysinfo.common.MemStats {
    return .{
        .total = total,
        .used = used,
        .free = total - used,
        .cached = cached,
        .swap_total = swap_total,
        .swap_used = swap_used,
    };
}

fn makeConn(pid: u32, state: sysinfo.common.NetConnState) sysinfo.common.NetConnection {
    var c = std.mem.zeroes(sysinfo.common.NetConnection);
    c.pid = pid;
    c.protocol = .tcp;
    c.state = state;
    return c;
}

fn emptyTimeline() timeline_mod.Timeline {
    return timeline_mod.Timeline.init();
}

fn buildHints(
    mem: sysinfo.common.MemStats,
    mem_pct: f32,
    cpu_pct: f32,
    disk_rate: u64,
    thermal_temp: ?f32,
    procs: []const sysinfo.ProcStats,
    conns: []const sysinfo.common.NetConnection,
    tl: *const timeline_mod.Timeline,
) render.PressureHintsData {
    const thermal: sysinfo.common.ThermalStats = .{ .cpu_temp = thermal_temp };
    return render.buildPressureHints(mem, mem_pct, cpu_pct, disk_rate, 0, thermal, procs, conns, tl, .celsius);
}

fn findPattern(data: render.PressureHintsData, pattern: render.PatternKind) ?render.PressureHint {
    for (data.hints[0..data.hint_count]) |h| {
        if (h.pattern == pattern) return h;
    }
    return null;
}

// ── no hints when system healthy ──────────────────────────────────────────────

test "no hints when everything is calm" {
    const tl = emptyTimeline();
    const mem = makeMem(16 * 1024 * MB, 4 * 1024 * MB, 0, 0, 4 * 1024 * MB);
    const data = buildHints(mem, 25.0, 10.0, 1 * MB, null, &.{}, &.{}, &tl);
    try std.testing.expectEqual(@as(usize, 0), data.hint_count);
}

// ── swap ──────────────────────────────────────────────────────────────────────

test "swap pressure: no hint when swap_total is zero" {
    const tl = emptyTimeline();
    const mem = makeMem(8 * 1024 * MB, 6 * 1024 * MB, 0, 0, 0);
    const data = buildHints(mem, 75.0, 30.0, 0, null, &.{}, &.{}, &tl);
    try std.testing.expectEqual(@as(?render.PressureHint, null), findPattern(data, .swap_pressure));
    try std.testing.expectEqual(@as(?render.PressureHint, null), findPattern(data, .swap_storm));
}

test "swap pressure: no hint when swap < 15%" {
    const tl = emptyTimeline();
    // 10% swap used
    const mem = makeMem(8 * 1024 * MB, 6 * 1024 * MB, 4 * 1024 * MB, 400 * MB, 0);
    const data = buildHints(mem, 75.0, 30.0, 0, null, &.{}, &.{}, &tl);
    try std.testing.expectEqual(@as(?render.PressureHint, null), findPattern(data, .swap_pressure));
}

test "swap pressure: hint when swap >= 15%" {
    const tl = emptyTimeline();
    const mem = makeMem(8 * 1024 * MB, 6 * 1024 * MB, 4 * 1024 * MB, 800 * MB, 0); // 20% used
    const data = buildHints(mem, 75.0, 30.0, 0, null, &.{}, &.{}, &tl);
    const h = findPattern(data, .swap_pressure);
    try std.testing.expect(h != null);
    try std.testing.expectEqual(render.HintSeverity.warn, h.?.severity);
}

test "swap pressure: critical severity when swap > 70%" {
    const tl = emptyTimeline();
    const mem = makeMem(8 * 1024 * MB, 6 * 1024 * MB, 2 * 1024 * MB, 1536 * MB, 0); // 75% used
    const data = buildHints(mem, 80.0, 30.0, 0, null, &.{}, &.{}, &tl);
    // Either swap_pressure or swap_storm may fire depending on timeline state
    const h = findPattern(data, .swap_pressure) orelse findPattern(data, .swap_storm);
    try std.testing.expect(h != null);
    try std.testing.expectEqual(render.HintSeverity.critical, h.?.severity);
}

test "swap storm: detected when swap growing in timeline" {
    var tl = timeline_mod.Timeline.init();
    // Record old snapshot with low swap
    var old_snap = std.mem.zeroes(timeline_mod.SystemSnapshot);
    old_snap.mem = makeMem(8 * 1024 * MB, 4 * 1024 * MB, 4 * 1024 * MB, 400 * MB, 0); // 10% swap
    // Fill 31 snapshots so getSnapshot(30) returns the old one
    for (0..31) |_| {
        tl.recordSnapshot(old_snap, &.{});
    }
    // Current state: swap at 40%
    const mem = makeMem(8 * 1024 * MB, 6 * 1024 * MB, 4 * 1024 * MB, 1600 * MB, 0);
    const data = buildHints(mem, 75.0, 30.0, 0, null, &.{}, &.{}, &tl);
    const h = findPattern(data, .swap_storm);
    try std.testing.expect(h != null);
}

test "swap pressure: culprit is top memory consumer" {
    const tl = emptyTimeline();
    const mem = makeMem(8 * 1024 * MB, 6 * 1024 * MB, 4 * 1024 * MB, 1200 * MB, 0); // 30% swap
    const procs = [_]sysinfo.ProcStats{
        makeProc(10, 5.0, 20.0, 0),
        makeProc(20, 2.0, 55.0, 0), // highest mem
        makeProc(30, 1.0, 10.0, 0),
    };
    const data = buildHints(mem, 80.0, 30.0, 0, null, &procs, &.{}, &tl);
    const h = findPattern(data, .swap_pressure) orelse findPattern(data, .swap_storm);
    try std.testing.expect(h != null);
    try std.testing.expectEqual(@as(u32, 20), h.?.culprit_pid);
}

// ── runaway writer ────────────────────────────────────────────────────────────

test "runaway writer: no hint when disk total < 5 MB/s" {
    const tl = emptyTimeline();
    const mem = makeMem(8 * 1024 * MB, 4 * 1024 * MB, 0, 0, 0);
    const procs = [_]sysinfo.ProcStats{makeProc(1, 10.0, 5.0, 4 * MB)};
    const data = buildHints(mem, 50.0, 10.0, 4 * MB, null, &procs, &.{}, &tl);
    try std.testing.expectEqual(@as(?render.PressureHint, null), findPattern(data, .runaway_writer));
}

test "runaway writer: no hint when single proc write < 8 MB/s" {
    const tl = emptyTimeline();
    const mem = makeMem(8 * 1024 * MB, 4 * 1024 * MB, 0, 0, 0);
    const procs = [_]sysinfo.ProcStats{makeProc(1, 10.0, 5.0, 7 * MB)};
    const data = buildHints(mem, 50.0, 10.0, 20 * MB, null, &procs, &.{}, &tl);
    try std.testing.expectEqual(@as(?render.PressureHint, null), findPattern(data, .runaway_writer));
}

test "runaway writer: hint when single proc dominates writes" {
    const tl = emptyTimeline();
    const mem = makeMem(8 * 1024 * MB, 4 * 1024 * MB, 0, 0, 0);
    const procs = [_]sysinfo.ProcStats{makeProc(42, 5.0, 2.0, 30 * MB)};
    const data = buildHints(mem, 40.0, 5.0, 30 * MB, null, &procs, &.{}, &tl);
    const h = findPattern(data, .runaway_writer);
    try std.testing.expect(h != null);
    try std.testing.expectEqual(@as(u32, 42), h.?.culprit_pid);
}

test "runaway writer: log-named process surfaces at lower share threshold" {
    const tl = emptyTimeline();
    const mem = makeMem(8 * 1024 * MB, 4 * 1024 * MB, 0, 0, 0);
    // logd writes 10 MB/s but total is 100 MB/s (only 10% share — below 40%)
    const procs = [_]sysinfo.ProcStats{makeProcNamed(7, 2.0, 1.0, 10 * MB, "logd")};
    const data = buildHints(mem, 40.0, 5.0, 100 * MB, null, &procs, &.{}, &tl);
    const h = findPattern(data, .runaway_writer);
    try std.testing.expect(h != null);
    try std.testing.expectEqual(@as(u32, 7), h.?.culprit_pid);
}

test "runaway writer: critical severity above 50 MB/s" {
    const tl = emptyTimeline();
    const mem = makeMem(8 * 1024 * MB, 4 * 1024 * MB, 0, 0, 0);
    const procs = [_]sysinfo.ProcStats{makeProc(1, 5.0, 2.0, 60 * MB)};
    const data = buildHints(mem, 40.0, 5.0, 60 * MB, null, &procs, &.{}, &tl);
    const h = findPattern(data, .runaway_writer);
    try std.testing.expect(h != null);
    try std.testing.expectEqual(render.HintSeverity.critical, h.?.severity);
}

test "runaway writer: warn severity below 50 MB/s" {
    const tl = emptyTimeline();
    const mem = makeMem(8 * 1024 * MB, 4 * 1024 * MB, 0, 0, 0);
    const procs = [_]sysinfo.ProcStats{makeProc(1, 5.0, 2.0, 20 * MB)};
    const data = buildHints(mem, 40.0, 5.0, 20 * MB, null, &procs, &.{}, &tl);
    const h = findPattern(data, .runaway_writer);
    try std.testing.expect(h != null);
    try std.testing.expectEqual(render.HintSeverity.warn, h.?.severity);
}

// ── reconnect loop ────────────────────────────────────────────────────────────

test "reconnect loop: no hint when no connections" {
    const tl = emptyTimeline();
    const mem = makeMem(8 * 1024 * MB, 4 * 1024 * MB, 0, 0, 0);
    const data = buildHints(mem, 40.0, 5.0, 0, null, &.{}, &.{}, &tl);
    try std.testing.expectEqual(@as(?render.PressureHint, null), findPattern(data, .reconnect_loop));
}

test "reconnect loop: no hint when TIME_WAIT count < 15" {
    const tl = emptyTimeline();
    const mem = makeMem(8 * 1024 * MB, 4 * 1024 * MB, 0, 0, 0);
    var conns: [10]sysinfo.common.NetConnection = undefined;
    for (&conns) |*c| c.* = makeConn(99, .time_wait);
    const data = buildHints(mem, 40.0, 5.0, 0, null, &.{}, &conns, &tl);
    try std.testing.expectEqual(@as(?render.PressureHint, null), findPattern(data, .reconnect_loop));
}

test "reconnect loop: hint when single PID has >= 15 TIME_WAIT" {
    const tl = emptyTimeline();
    const mem = makeMem(8 * 1024 * MB, 4 * 1024 * MB, 0, 0, 0);
    var conns: [20]sysinfo.common.NetConnection = undefined;
    for (&conns) |*c| c.* = makeConn(55, .time_wait);
    const data = buildHints(mem, 40.0, 5.0, 0, null, &.{}, &conns, &tl);
    const h = findPattern(data, .reconnect_loop);
    try std.testing.expect(h != null);
    try std.testing.expectEqual(@as(u32, 55), h.?.culprit_pid);
}

test "reconnect loop: CLOSE_WAIT also counts" {
    const tl = emptyTimeline();
    const mem = makeMem(8 * 1024 * MB, 4 * 1024 * MB, 0, 0, 0);
    var conns: [20]sysinfo.common.NetConnection = undefined;
    for (&conns) |*c| c.* = makeConn(77, .close_wait);
    const data = buildHints(mem, 40.0, 5.0, 0, null, &.{}, &conns, &tl);
    const h = findPattern(data, .reconnect_loop);
    try std.testing.expect(h != null);
    try std.testing.expectEqual(@as(u32, 77), h.?.culprit_pid);
}

test "reconnect loop: established connections do not count" {
    const tl = emptyTimeline();
    const mem = makeMem(8 * 1024 * MB, 4 * 1024 * MB, 0, 0, 0);
    var conns: [30]sysinfo.common.NetConnection = undefined;
    for (&conns) |*c| c.* = makeConn(88, .established);
    const data = buildHints(mem, 40.0, 5.0, 0, null, &.{}, &conns, &tl);
    try std.testing.expectEqual(@as(?render.PressureHint, null), findPattern(data, .reconnect_loop));
}

test "reconnect loop: picks worst offender across multiple PIDs" {
    const tl = emptyTimeline();
    const mem = makeMem(8 * 1024 * MB, 4 * 1024 * MB, 0, 0, 0);
    // PID 1 = 5, PID 2 = 20, PID 3 = 10
    var conns: [35]sysinfo.common.NetConnection = undefined;
    for (conns[0..5]) |*c| c.* = makeConn(1, .time_wait);
    for (conns[5..25]) |*c| c.* = makeConn(2, .time_wait);
    for (conns[25..35]) |*c| c.* = makeConn(3, .time_wait);
    const data = buildHints(mem, 40.0, 5.0, 0, null, &.{}, &conns, &tl);
    const h = findPattern(data, .reconnect_loop);
    try std.testing.expect(h != null);
    try std.testing.expectEqual(@as(u32, 2), h.?.culprit_pid); // PID 2 has 20
}

test "reconnect loop: critical when > 50 TIME_WAIT" {
    const tl = emptyTimeline();
    const mem = makeMem(8 * 1024 * MB, 4 * 1024 * MB, 0, 0, 0);
    var conns: [55]sysinfo.common.NetConnection = undefined;
    for (&conns) |*c| c.* = makeConn(11, .time_wait);
    const data = buildHints(mem, 40.0, 5.0, 0, null, &.{}, &conns, &tl);
    const h = findPattern(data, .reconnect_loop);
    try std.testing.expect(h != null);
    try std.testing.expectEqual(render.HintSeverity.critical, h.?.severity);
}

// ── FD pressure ───────────────────────────────────────────────────────────────

test "fd pressure: no hint when threads < 400" {
    const tl = emptyTimeline();
    const mem = makeMem(8 * 1024 * MB, 4 * 1024 * MB, 0, 0, 0);
    const procs = [_]sysinfo.ProcStats{makeProcThreads(1, 300)};
    const data = buildHints(mem, 40.0, 5.0, 0, null, &procs, &.{}, &tl);
    try std.testing.expectEqual(@as(?render.PressureHint, null), findPattern(data, .fd_pressure));
}

test "fd pressure: hint when threads >= 400" {
    const tl = emptyTimeline();
    const mem = makeMem(8 * 1024 * MB, 4 * 1024 * MB, 0, 0, 0);
    const procs = [_]sysinfo.ProcStats{makeProcThreads(42, 500)};
    const data = buildHints(mem, 40.0, 5.0, 0, null, &procs, &.{}, &tl);
    const h = findPattern(data, .fd_pressure);
    try std.testing.expect(h != null);
    try std.testing.expectEqual(@as(u32, 42), h.?.culprit_pid);
    try std.testing.expectEqual(render.HintSeverity.warn, h.?.severity);
}

test "fd pressure: critical when threads > 1000" {
    const tl = emptyTimeline();
    const mem = makeMem(8 * 1024 * MB, 4 * 1024 * MB, 0, 0, 0);
    const procs = [_]sysinfo.ProcStats{makeProcThreads(7, 1500)};
    const data = buildHints(mem, 40.0, 5.0, 0, null, &procs, &.{}, &tl);
    const h = findPattern(data, .fd_pressure);
    try std.testing.expect(h != null);
    try std.testing.expectEqual(render.HintSeverity.critical, h.?.severity);
}

test "fd pressure: picks process with most threads" {
    const tl = emptyTimeline();
    const mem = makeMem(8 * 1024 * MB, 4 * 1024 * MB, 0, 0, 0);
    const procs = [_]sysinfo.ProcStats{
        makeProcThreads(1, 450),
        makeProcThreads(2, 800),
        makeProcThreads(3, 600),
    };
    const data = buildHints(mem, 40.0, 5.0, 0, null, &procs, &.{}, &tl);
    const h = findPattern(data, .fd_pressure);
    try std.testing.expect(h != null);
    try std.testing.expectEqual(@as(u32, 2), h.?.culprit_pid);
}

// ── memory leak ───────────────────────────────────────────────────────────────

test "memory leak: no hint when not enough history" {
    const tl = emptyTimeline(); // 0 snapshots
    const mem = makeMem(8 * 1024 * MB, 5 * 1024 * MB, 0, 0, 0);
    const procs = [_]sysinfo.ProcStats{makeProc(1, 5.0, 10.0, 0)};
    const data = buildHints(mem, 65.0, 10.0, 0, null, &procs, &.{}, &tl);
    try std.testing.expectEqual(@as(?render.PressureHint, null), findPattern(data, .memory_leak));
}

test "memory leak: no hint when system mem_pct < 50%" {
    var tl = timeline_mod.Timeline.init();
    const old_snap = std.mem.zeroes(timeline_mod.SystemSnapshot);
    const old_proc = makeProc(1, 5.0, 5.0, 0);
    for (0..61) |_| tl.recordSnapshot(old_snap, &.{old_proc});
    const procs = [_]sysinfo.ProcStats{makeProc(1, 5.0, 10.0, 0)};
    const mem = makeMem(8 * 1024 * MB, 3 * 1024 * MB, 0, 0, 0);
    const data = buildHints(mem, 37.0, 10.0, 0, null, &procs, &.{}, &tl);
    try std.testing.expectEqual(@as(?render.PressureHint, null), findPattern(data, .memory_leak));
}

test "memory leak: no hint when growth < 3pp" {
    var tl = timeline_mod.Timeline.init();
    const old_snap = std.mem.zeroes(timeline_mod.SystemSnapshot);
    const old_proc = makeProc(1, 5.0, 8.0, 0); // was 8%
    for (0..61) |_| tl.recordSnapshot(old_snap, &.{old_proc});
    const procs = [_]sysinfo.ProcStats{makeProc(1, 5.0, 9.5, 0)}; // now 9.5%, delta = 1.5pp
    const mem = makeMem(8 * 1024 * MB, 5 * 1024 * MB, 0, 0, 0);
    const data = buildHints(mem, 62.0, 10.0, 0, null, &procs, &.{}, &tl);
    try std.testing.expectEqual(@as(?render.PressureHint, null), findPattern(data, .memory_leak));
}

test "memory leak: hint when process mem grows >= 3pp over 60 snapshots" {
    var tl = timeline_mod.Timeline.init();
    const old_snap = std.mem.zeroes(timeline_mod.SystemSnapshot);
    const old_proc = makeProc(5, 2.0, 5.0, 0); // was 5%
    for (0..61) |_| tl.recordSnapshot(old_snap, &.{old_proc});
    const procs = [_]sysinfo.ProcStats{makeProc(5, 2.0, 10.0, 0)}; // now 10%, delta = 5pp
    const mem = makeMem(8 * 1024 * MB, 5 * 1024 * MB, 0, 0, 0);
    const data = buildHints(mem, 62.0, 10.0, 0, null, &procs, &.{}, &tl);
    const h = findPattern(data, .memory_leak);
    try std.testing.expect(h != null);
    try std.testing.expectEqual(@as(u32, 5), h.?.culprit_pid);
}

test "memory leak: critical severity when growth > 8pp" {
    var tl = timeline_mod.Timeline.init();
    const old_snap = std.mem.zeroes(timeline_mod.SystemSnapshot);
    const old_proc = makeProc(3, 2.0, 2.0, 0);
    for (0..61) |_| tl.recordSnapshot(old_snap, &.{old_proc});
    const procs = [_]sysinfo.ProcStats{makeProc(3, 2.0, 12.0, 0)}; // +10pp
    const mem = makeMem(8 * 1024 * MB, 5 * 1024 * MB, 0, 0, 0);
    const data = buildHints(mem, 62.0, 10.0, 0, null, &procs, &.{}, &tl);
    const h = findPattern(data, .memory_leak);
    try std.testing.expect(h != null);
    try std.testing.expectEqual(render.HintSeverity.critical, h.?.severity);
}

test "memory leak: no hint for PIDs that did not exist previously" {
    var tl = timeline_mod.Timeline.init();
    const old_snap = std.mem.zeroes(timeline_mod.SystemSnapshot);
    const old_proc = makeProc(1, 2.0, 2.0, 0);
    for (0..61) |_| tl.recordSnapshot(old_snap, &.{old_proc});
    // PID 99 is new — not in old snapshot
    const procs = [_]sysinfo.ProcStats{makeProc(99, 2.0, 25.0, 0)};
    const mem = makeMem(8 * 1024 * MB, 5 * 1024 * MB, 0, 0, 0);
    const data = buildHints(mem, 62.0, 10.0, 0, null, &procs, &.{}, &tl);
    try std.testing.expectEqual(@as(?render.PressureHint, null), findPattern(data, .memory_leak));
}

// ── CPU runaway ───────────────────────────────────────────────────────────────

test "cpu runaway: no hint when system cpu < 70%" {
    const tl = emptyTimeline();
    const mem = makeMem(8 * 1024 * MB, 4 * 1024 * MB, 0, 0, 0);
    const procs = [_]sysinfo.ProcStats{makeProc(1, 95.0, 2.0, 0)};
    const data = buildHints(mem, 40.0, 60.0, 0, null, &procs, &.{}, &tl);
    try std.testing.expectEqual(@as(?render.PressureHint, null), findPattern(data, .runaway_cpu));
}

test "cpu runaway: no hint when top proc cpu < 85%" {
    const tl = emptyTimeline();
    const mem = makeMem(8 * 1024 * MB, 4 * 1024 * MB, 0, 0, 0);
    const procs = [_]sysinfo.ProcStats{makeProc(1, 80.0, 2.0, 0)};
    const data = buildHints(mem, 40.0, 75.0, 0, null, &procs, &.{}, &tl);
    try std.testing.expectEqual(@as(?render.PressureHint, null), findPattern(data, .runaway_cpu));
}

test "cpu runaway: hint when single proc >= 85% and system >= 70%" {
    const tl = emptyTimeline();
    const mem = makeMem(8 * 1024 * MB, 4 * 1024 * MB, 0, 0, 0);
    const procs = [_]sysinfo.ProcStats{makeProc(8, 90.0, 2.0, 0)};
    const data = buildHints(mem, 40.0, 75.0, 0, null, &procs, &.{}, &tl);
    const h = findPattern(data, .runaway_cpu);
    try std.testing.expect(h != null);
    try std.testing.expectEqual(@as(u32, 8), h.?.culprit_pid);
}

test "cpu runaway: critical when top proc > 150%" {
    const tl = emptyTimeline();
    const mem = makeMem(8 * 1024 * MB, 4 * 1024 * MB, 0, 0, 0);
    const procs = [_]sysinfo.ProcStats{makeProc(9, 200.0, 2.0, 0)};
    const data = buildHints(mem, 40.0, 85.0, 0, null, &procs, &.{}, &tl);
    const h = findPattern(data, .runaway_cpu);
    try std.testing.expect(h != null);
    try std.testing.expectEqual(render.HintSeverity.critical, h.?.severity);
}

// ── thermal throttle ──────────────────────────────────────────────────────────

test "thermal throttle: no hint when temp null" {
    const tl = emptyTimeline();
    const mem = makeMem(8 * 1024 * MB, 4 * 1024 * MB, 0, 0, 0);
    const data = buildHints(mem, 40.0, 80.0, 0, null, &.{}, &.{}, &tl);
    try std.testing.expectEqual(@as(?render.PressureHint, null), findPattern(data, .thermal_throttle));
}

test "thermal throttle: no hint when temp < 85°C" {
    const tl = emptyTimeline();
    const mem = makeMem(8 * 1024 * MB, 4 * 1024 * MB, 0, 0, 0);
    const data = buildHints(mem, 40.0, 80.0, 0, 70.0, &.{}, &.{}, &tl);
    try std.testing.expectEqual(@as(?render.PressureHint, null), findPattern(data, .thermal_throttle));
}

test "thermal throttle: hint at 85°C" {
    const tl = emptyTimeline();
    const mem = makeMem(8 * 1024 * MB, 4 * 1024 * MB, 0, 0, 0);
    const data = buildHints(mem, 40.0, 80.0, 0, 85.0, &.{}, &.{}, &tl);
    const h = findPattern(data, .thermal_throttle);
    try std.testing.expect(h != null);
    try std.testing.expectEqual(render.HintSeverity.warn, h.?.severity);
}

test "thermal throttle: critical at >= 95°C" {
    const tl = emptyTimeline();
    const mem = makeMem(8 * 1024 * MB, 4 * 1024 * MB, 0, 0, 0);
    const data = buildHints(mem, 40.0, 80.0, 0, 97.0, &.{}, &.{}, &tl);
    const h = findPattern(data, .thermal_throttle);
    try std.testing.expect(h != null);
    try std.testing.expectEqual(render.HintSeverity.critical, h.?.severity);
}

// ── cache starvation ──────────────────────────────────────────────────────────

test "cache starvation: no hint when mem_pct < 80%" {
    const tl = emptyTimeline();
    // 0% cache, but low memory pressure
    const mem = makeMem(8 * 1024 * MB, 4 * 1024 * MB, 0, 0, 0);
    const data = buildHints(mem, 50.0, 30.0, 0, null, &.{}, &.{}, &tl);
    try std.testing.expectEqual(@as(?render.PressureHint, null), findPattern(data, .cache_starvation));
}

test "cache starvation: no hint when cache > 5% of total" {
    const tl = emptyTimeline();
    const total = 8 * 1024 * MB;
    const mem = makeMem(total, 7 * 1024 * MB, 0, 0, total / 10); // 10% cache
    const data = buildHints(mem, 87.0, 30.0, 0, null, &.{}, &.{}, &tl);
    try std.testing.expectEqual(@as(?render.PressureHint, null), findPattern(data, .cache_starvation));
}

test "cache starvation: hint when mem > 80% and cache <= 5%" {
    const tl = emptyTimeline();
    const total = 8 * 1024 * MB;
    // cache = 2% of total
    const mem = makeMem(total, 7500 * MB, 0, 0, total / 50);
    const data = buildHints(mem, 93.0, 30.0, 0, null, &.{}, &.{}, &tl);
    const h = findPattern(data, .cache_starvation);
    try std.testing.expect(h != null);
    try std.testing.expectEqual(render.HintSeverity.warn, h.?.severity);
}

// ── hint count cap ────────────────────────────────────────────────────────────

test "hint count never exceeds MAX_HINTS" {
    var tl = timeline_mod.Timeline.init();
    const old_snap = std.mem.zeroes(timeline_mod.SystemSnapshot);
    const old_proc = makeProc(1, 2.0, 2.0, 0);
    for (0..61) |_| tl.recordSnapshot(old_snap, &.{old_proc});

    // Construct a pathological state that would trigger many hints simultaneously
    const total = 8 * 1024 * MB;
    // High swap (swap pressure), low cache (cache starvation), mem > 80%
    const mem = makeMem(total, 7 * 1024 * MB, 4 * 1024 * MB, 3 * 1024 * MB, total / 100);
    const procs = [_]sysinfo.ProcStats{
        makeProcNamed(1, 95.0, 12.0, 60 * MB, "logd"), // runaway cpu + log writer + mem leak
        makeProcThreads(2, 1200), // FD pressure
    };
    var conns: [55]sysinfo.common.NetConnection = undefined;
    for (&conns) |*c| c.* = makeConn(1, .time_wait); // reconnect loop

    const data = render.buildPressureHints(
        mem,
        87.0, // mem_pct
        80.0, // cpu_pct
        60 * MB, // disk_rate
        0,
        .{ .cpu_temp = 96.0 }, // thermal throttle
        &procs,
        &conns,
        &tl,
        .celsius,
    );

    try std.testing.expect(data.hint_count <= render.MAX_PRESSURE_HINTS);
}

// ── PressureHintsData context fields ─────────────────────────────────────────

test "buildPressureHints stores context metrics in returned data" {
    const tl = emptyTimeline();
    const mem = makeMem(16 * 1024 * MB, 8 * 1024 * MB, 0, 0, 2 * 1024 * MB);
    const data = buildHints(mem, 50.0, 33.0, 10 * MB, 72.0, &.{}, &.{}, &tl);
    try std.testing.expectApproxEqAbs(@as(f32, 50.0), data.mem_pct, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 33.0), data.cpu_pct, 0.01);
    try std.testing.expectEqual(@as(u64, 10 * MB), data.disk_rate);
    try std.testing.expectApproxEqAbs(@as(f32, 72.0), data.thermal.cpu_temp.?, 0.01);
    try std.testing.expectEqual(mem.total, data.mem.total);
    try std.testing.expectEqual(mem.used, data.mem.used);
}
