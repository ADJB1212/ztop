const std = @import("std");
const render = @import("ztop").render;
const sysinfo = @import("ztop").sysinfo;

// ── helpers ──────────────────────────────────────────────────────────────────

fn makeProc(pid: u32, cpu: f32, mem: f32, disk_r: u64, disk_w: u64) sysinfo.ProcStats {
    var p = std.mem.zeroes(sysinfo.ProcStats);
    p.pid = pid;
    p.cpu_percent = cpu;
    p.mem_percent = mem;
    p.disk_read_ps = disk_r;
    p.disk_write_ps = disk_w;
    return p;
}

fn makeData(
    kind: render.SpikeKind,
    cpu: f32,
    mem: f32,
    disk: u64,
    net: u64,
    procs: []const sysinfo.ProcStats,
) render.WhyBusyData {
    return .{
        .kind = kind,
        .cpu_pct = cpu,
        .mem_pct = mem,
        .disk_rate = disk,
        .net_rate = net,
        .procs = procs,
    };
}

// ── topWhyBusyProcIndices ─────────────────────────────────────────────────────

test "topWhyBusyProcIndices returns empty for empty proc list" {
    var out: [8]usize = undefined;
    const count = render.topWhyBusyProcIndices(&.{}, .cpu, &out);
    try std.testing.expectEqual(@as(usize, 0), count);
}

test "topWhyBusyProcIndices returns single proc" {
    const procs = [_]sysinfo.ProcStats{makeProc(1, 42.0, 10.0, 0, 0)};
    var out: [8]usize = undefined;
    const count = render.topWhyBusyProcIndices(&procs, .cpu, &out);
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqual(@as(usize, 0), out[0]);
}

test "topWhyBusyProcIndices orders by cpu descending" {
    const procs = [_]sysinfo.ProcStats{
        makeProc(1, 10.0, 0, 0, 0),
        makeProc(2, 80.0, 0, 0, 0),
        makeProc(3, 45.0, 0, 0, 0),
    };
    var out: [8]usize = undefined;
    const count = render.topWhyBusyProcIndices(&procs, .cpu, &out);
    try std.testing.expectEqual(@as(usize, 3), count);
    try std.testing.expectEqual(@as(usize, 1), out[0]); // pid 2, cpu 80%
    try std.testing.expectEqual(@as(usize, 2), out[1]); // pid 3, cpu 45%
    try std.testing.expectEqual(@as(usize, 0), out[2]); // pid 1, cpu 10%
}

test "topWhyBusyProcIndices orders by mem descending" {
    const procs = [_]sysinfo.ProcStats{
        makeProc(1, 0, 5.0, 0, 0),
        makeProc(2, 0, 30.0, 0, 0),
        makeProc(3, 0, 15.0, 0, 0),
    };
    var out: [8]usize = undefined;
    const count = render.topWhyBusyProcIndices(&procs, .mem, &out);
    try std.testing.expectEqual(@as(usize, 3), count);
    try std.testing.expectEqual(@as(usize, 1), out[0]); // mem 30%
    try std.testing.expectEqual(@as(usize, 2), out[1]); // mem 15%
    try std.testing.expectEqual(@as(usize, 0), out[2]); // mem 5%
}

test "topWhyBusyProcIndices orders by disk I/O descending" {
    const mb: u64 = 1024 * 1024;
    const procs = [_]sysinfo.ProcStats{
        makeProc(1, 0, 0, 5 * mb, 1 * mb), // 6 MB/s total
        makeProc(2, 0, 0, 20 * mb, 0), // 20 MB/s total
        makeProc(3, 0, 0, 0, 3 * mb), // 3 MB/s total
    };
    var out: [8]usize = undefined;
    const count = render.topWhyBusyProcIndices(&procs, .disk, &out);
    try std.testing.expectEqual(@as(usize, 3), count);
    try std.testing.expectEqual(@as(usize, 1), out[0]); // 20 MB/s
    try std.testing.expectEqual(@as(usize, 0), out[1]); // 6 MB/s
    try std.testing.expectEqual(@as(usize, 2), out[2]); // 3 MB/s
}

test "topWhyBusyProcIndices skips procs with zero metric" {
    const procs = [_]sysinfo.ProcStats{
        makeProc(1, 0, 0, 0, 0), // all zero
        makeProc(2, 50.0, 0, 0, 0),
        makeProc(3, 0, 0, 0, 0), // all zero
    };
    var out: [8]usize = undefined;
    const count = render.topWhyBusyProcIndices(&procs, .cpu, &out);
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqual(@as(usize, 1), out[0]); // only pid 2 has cpu > 0
}

test "topWhyBusyProcIndices respects out slice capacity" {
    const procs = [_]sysinfo.ProcStats{
        makeProc(1, 90.0, 0, 0, 0),
        makeProc(2, 80.0, 0, 0, 0),
        makeProc(3, 70.0, 0, 0, 0),
        makeProc(4, 60.0, 0, 0, 0),
    };
    var out: [2]usize = undefined; // only room for 2
    const count = render.topWhyBusyProcIndices(&procs, .cpu, &out);
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqual(@as(usize, 0), out[0]); // cpu 90%
    try std.testing.expectEqual(@as(usize, 1), out[1]); // cpu 80%
}

// ── findWhyBusyProcByPid ──────────────────────────────────────────────────────

test "findWhyBusyProcByPid returns null for empty slice" {
    const result = render.findWhyBusyProcByPid(&.{}, 42);
    try std.testing.expectEqual(@as(?sysinfo.ProcStats, null), result);
}

test "findWhyBusyProcByPid returns null when PID absent" {
    const procs = [_]sysinfo.ProcStats{
        makeProc(1, 10.0, 0, 0, 0),
        makeProc(2, 20.0, 0, 0, 0),
    };
    const result = render.findWhyBusyProcByPid(&procs, 99);
    try std.testing.expectEqual(@as(?sysinfo.ProcStats, null), result);
}

test "findWhyBusyProcByPid finds correct proc by PID" {
    const procs = [_]sysinfo.ProcStats{
        makeProc(10, 5.0, 0, 0, 0),
        makeProc(20, 15.0, 0, 0, 0),
        makeProc(30, 25.0, 0, 0, 0),
    };
    const result = render.findWhyBusyProcByPid(&procs, 20);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(u32, 20), result.?.pid);
    try std.testing.expectApproxEqAbs(@as(f32, 15.0), result.?.cpu_percent, 0.01);
}

test "findWhyBusyProcByPid returns first match when duplicates exist" {
    const procs = [_]sysinfo.ProcStats{
        makeProc(5, 10.0, 0, 0, 0),
        makeProc(5, 99.0, 0, 0, 0), // same PID, higher cpu
    };
    const result = render.findWhyBusyProcByPid(&procs, 5);
    try std.testing.expect(result != null);
    try std.testing.expectApproxEqAbs(@as(f32, 10.0), result.?.cpu_percent, 0.01);
}

// ── fmtWhyBusyTimestamp ───────────────────────────────────────────────────────

test "fmtWhyBusyTimestamp returns empty for zero" {
    var buf: [12]u8 = undefined;
    const out = render.fmtWhyBusyTimestamp(0, &buf);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "fmtWhyBusyTimestamp formats known timestamp" {
    var buf: [12]u8 = undefined;
    // 14:32:15 = 14*3600 + 32*60 + 15 = 50400 + 1920 + 15 = 52335 seconds
    const ms: i64 = 52335 * 1000;
    const out = render.fmtWhyBusyTimestamp(ms, &buf);
    try std.testing.expectEqualStrings("14:32:15", out);
}

test "fmtWhyBusyTimestamp zero-pads single-digit components" {
    var buf: [12]u8 = undefined;
    // 01:02:03
    const ms: i64 = (1 * 3600 + 2 * 60 + 3) * 1000;
    const out = render.fmtWhyBusyTimestamp(ms, &buf);
    try std.testing.expectEqualStrings("01:02:03", out);
}

test "fmtWhyBusyTimestamp wraps hours at 24" {
    var buf: [12]u8 = undefined;
    // 25 hours = wraps to 01:00:00
    const ms: i64 = 25 * 3600 * 1000;
    const out = render.fmtWhyBusyTimestamp(ms, &buf);
    try std.testing.expectEqualStrings("01:00:00", out);
}

// ── detectWhyBusyKind ─────────────────────────────────────────────────────────

test "detectWhyBusyKind returns cpu when cpu dominates" {
    const data = makeData(.auto, 75.0, 20.0, 0, 0, &.{});
    try std.testing.expectEqual(render.SpikeKind.cpu, render.detectWhyBusyKind(data));
}

test "detectWhyBusyKind returns mem when mem pct exceeds cpu" {
    const data = makeData(.auto, 30.0, 85.0, 0, 0, &.{});
    try std.testing.expectEqual(render.SpikeKind.mem, render.detectWhyBusyKind(data));
}

test "detectWhyBusyKind returns disk when disk score exceeds both cpu and mem" {
    // disk_score = bytes / (10MB) * 10. At 1 GB/s: score = 1024*1024*1024 / 10MB * 10 ≈ 1024
    const gb: u64 = 1024 * 1024 * 1024;
    const data = makeData(.auto, 20.0, 30.0, gb, 0, &.{});
    try std.testing.expectEqual(render.SpikeKind.disk, render.detectWhyBusyKind(data));
}

test "detectWhyBusyKind defaults to cpu when all metrics are zero" {
    const data = makeData(.auto, 0.0, 0.0, 0, 0, &.{});
    try std.testing.expectEqual(render.SpikeKind.cpu, render.detectWhyBusyKind(data));
}

test "detectWhyBusyKind cpu beats mem when equal" {
    // cpu_pct == mem_pct: cpu wins (checked first, no strict gt for mem)
    const data = makeData(.auto, 50.0, 50.0, 0, 0, &.{});
    try std.testing.expectEqual(render.SpikeKind.cpu, render.detectWhyBusyKind(data));
}
