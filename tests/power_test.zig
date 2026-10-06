const std = @import("std");
const darwin = @import("ztop").sysinfo.sys_darwin;
const power = darwin.power;
const Raw = darwin.bindings.PowerReadingRaw;

fn rawReading() Raw {
    var raw = std.mem.zeroes(Raw);
    raw.rail_mask = 15;
    return raw;
}

test "live energy counters report measured elapsed time" {
    var tracker: power.EnergyTracker(1) = .{};
    try std.testing.expectEqual(null, tracker.observe(.{0}, 0, 0.001));
    try std.testing.expectEqual(null, tracker.observe(.{1000}, 0.5, 0.001));
    try std.testing.expectEqual(null, tracker.observe(.{2000}, 1, 0.001));
    for (2..10) |i| try std.testing.expectEqual(null, tracker.observe(.{@as(u64, @intCast(i)) * 2000}, @floatFromInt(i), 0.001));
    const reading = tracker.observe(.{20000}, 10, 0.001).?;
    try std.testing.expectEqual(@as(f64, 2), reading.watts[0]);
    try std.testing.expectEqual(@as(f64, 1), reading.seconds);
}

test "unchanged counters remain unknown until refresh timing is known" {
    var tracker: power.EnergyTracker(1) = .{};
    for (0..100) |i| try std.testing.expectEqual(null, tracker.observe(.{1000}, @floatFromInt(i), 0.001));
}

test "two second batches use a sustained measured window" {
    var tracker: power.EnergyTracker(1) = .{};
    for (0..12) |i| {
        try std.testing.expectEqual(null, tracker.observe(.{@as(u64, @intCast(i / 2)) * 4000}, @floatFromInt(i), 0.001));
    }
    const reading = tracker.observe(.{24000}, 12, 0.001).?;
    try std.testing.expectEqual(@as(f64, 10), reading.seconds);
    try std.testing.expectEqual(@as(f64, 2), reading.watts[0]);
    const held = tracker.observe(.{24000}, 13, 0.001).?;
    try std.testing.expectEqual(reading, held);
}

test "split slow refreshes do not publish the pieces as live power" {
    var tracker: power.EnergyTracker(1) = .{};
    for (0..1820) |i| {
        const energy: u64 = if (i < 1) 0 else if (i < 3) 1000 else if (i < 1801) 2000 else if (i < 1802) 3_000_000 else if (i < 1804) 3_500_000 else 3_602_000;
        const result = tracker.observe(.{energy}, @floatFromInt(i), 0.001);
        if (i < 1814) {
            try std.testing.expectEqual(null, result);
        } else {
            try std.testing.expectEqual(@as(f64, 1800), result.?.seconds);
            try std.testing.expectEqual(@as(f64, 2), result.?.watts[0]);
        }
    }
}

test "sampling gaps and counter resets restart the chain" {
    var tracker: power.EnergyTracker(1) = .{};
    for (0..4) |i| _ = tracker.observe(.{@as(u64, @intCast(i)) * 1000}, @floatFromInt(i), 0.001);
    try std.testing.expectEqual(null, tracker.observe(.{100000}, 100, 0.001));
    try std.testing.expectEqual(null, tracker.observe(.{0}, 101, 0.001));
    try std.testing.expectEqual(null, tracker.observe(.{1000}, 102, 0.001));
    try std.testing.expectEqual(null, tracker.observe(.{2000}, 103, 0.001));
    for (104..111) |i| _ = tracker.observe(.{@as(u64, @intCast(i - 101)) * 1000}, @floatFromInt(i), 0.001);
    try std.testing.expectEqual(@as(f64, 1), tracker.observe(.{10000}, 111, 0.001).?.watts[0]);
    try std.testing.expectEqual(null, tracker.observe(.{11000}, 110, 0.001));
}

test "continuous batches stay bounded" {
    var tracker: power.EnergyTracker(1) = .{};
    for (0..10000) |i| {
        const result = tracker.observe(.{@as(u64, @intCast(i / 2)) * 100}, @as(f64, @floatFromInt(i)) / 20, 0.001);
        if (i > 220) try std.testing.expectApproxEqAbs(@as(f64, 1), result.?.watts[0], 0.00001);
        try std.testing.expect(tracker.run_count <= tracker.run.len);
    }
}

test "independent GPU counter is nanojoules and does not make frozen rails live" {
    var sampler: power.Sampler = .{};
    var raw = rawReading();
    raw.gpu_valid = 1;
    var reading: power.Reading = .{};
    for (0..15) |i| {
        raw.gpu_nanojoules = @as(u64, @intCast(i)) * 500_000_000;
        reading = sampler.observe(raw, @floatFromInt(i));
    }
    try std.testing.expectEqual(null, reading.soc_watts);
    try std.testing.expectEqual(@as(?f64, 0.5), reading.gpu_watts);
    try std.testing.expectEqual(@as(?f64, 1), reading.gpu_window_seconds);
}

test "SoC total uses the GPU share over the rail window" {
    var sampler: power.Sampler = .{};
    var raw = rawReading();
    raw.gpu_valid = 1;
    var reading: power.Reading = .{};
    for (0..42) |i| {
        raw.rails = @splat(if (i < 1) 0 else if (i < 21) 1000 else 21000);
        raw.gpu_nanojoules = @as(u64, @intCast(i)) * 500_000_000;
        reading = sampler.observe(raw, @floatFromInt(i));
    }
    try std.testing.expectEqual(@as(?f64, 4), reading.soc_watts);
    try std.testing.expectEqual(@as(?f64, 20), reading.soc_window_seconds);
    try std.testing.expectEqual(@as(?f64, 0.5), reading.gpu_watts);
    try std.testing.expectEqual(@as(?f64, 1), reading.gpu_window_seconds);
}

test "missing or failed power readings clear prior values" {
    var sampler: power.Sampler = .{};
    var raw = rawReading();
    var prior: power.Reading = .{};
    for (0..15) |i| {
        raw.rails = @splat(@as(u64, @intCast(i)) * 1000);
        prior = sampler.observe(raw, @floatFromInt(i));
    }
    try std.testing.expectEqual(@as(?f64, 4), prior.soc_watts);
    try std.testing.expectEqual(@as(?f64, 1), prior.gpu_watts);
    try std.testing.expectEqual(power.Reading{}, sampler.observe(std.mem.zeroes(Raw), 15));
    raw.rail_mask = 2;
    try std.testing.expectEqual(null, sampler.observe(raw, 16).soc_watts);
}

test "direct SMC power is independent of pending rails" {
    var sampler: power.Sampler = .{};
    var raw = rawReading();
    raw.soc_valid = 1;
    raw.soc_watts = 8;
    const reading = sampler.observe(raw, 0);
    try std.testing.expectEqual(@as(?f64, 8), reading.soc_watts);
    try std.testing.expectEqual(null, reading.soc_window_seconds);
    raw.soc_watts = std.math.nan(f64);
    try std.testing.expectEqual(null, sampler.observe(raw, 1).soc_watts);
}

test "changing energy sources restarts the rail baseline" {
    var sampler: power.Sampler = .{};
    var raw = rawReading();
    var prior: power.Reading = .{};
    for (0..15) |i| {
        raw.rails = @splat(@as(u64, @intCast(i)) * 1000);
        prior = sampler.observe(raw, @floatFromInt(i));
    }
    try std.testing.expectEqual(@as(?f64, 4), prior.soc_watts);
    raw.rail_sources = 15;
    raw.rails = @splat(100_000);
    try std.testing.expectEqual(null, sampler.observe(raw, 15).soc_watts);
}

test "consecutive split refresh pieces stay unknown at slow polling cadence" {
    var tracker: power.EnergyTracker(1) = .{};
    try std.testing.expectEqual(null, tracker.observe(.{0}, 0, 0.001));
    try std.testing.expectEqual(null, tracker.observe(.{1000}, 1.5, 0.001));
    try std.testing.expectEqual(null, tracker.observe(.{2000}, 3, 0.001));
    try std.testing.expectEqual(null, tracker.observe(.{3000}, 4.5, 0.001));
    for (5..20) |i| try std.testing.expectEqual(null, tracker.observe(.{3000}, @floatFromInt(i), 0.001));
}

fn decode(kind: *const [4]u8, bytes: []const u8) ?f64 {
    var value: f64 = 0;
    const data_type = std.mem.readInt(u32, kind, .big);
    return if (darwin.bindings.ztop_smc_decode(data_type, bytes.ptr, @intCast(bytes.len), &value)) value else null;
}

test "SMC ioft decodes signed little endian fixed point" {
    try std.testing.expectApproxEqAbs(@as(f64, 34.2), decode("ioft", &.{ 0x33, 0x33, 0x22, 0, 0, 0, 0, 0 }).?, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 51.85), decode("ioft", &.{ 0x9a, 0xd9, 0x33, 0, 0, 0, 0, 0 }).?, 0.01);
    try std.testing.expectEqual(@as(?f64, -1), decode("ioft", &.{ 0, 0, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff }));
    try std.testing.expectEqual(@as(?f64, 0), decode("ioft", &@as([8]u8, @splat(0))));
    try std.testing.expectEqual(null, decode("ioft", &.{ 0x33, 0x33 }));
}

test "SMC scalar decoding rejects short unknown and nonfinite values" {
    try std.testing.expectEqual(@as(?f64, 1.75), decode("fpe2", &.{ 0, 7 }));
    try std.testing.expectEqual(null, decode("flt ", &.{ 0, 0 }));
    try std.testing.expectEqual(null, decode("ui32", &.{ 0, 0, 0 }));
    try std.testing.expectEqual(null, decode("ch8*", &.{ 0, 0 }));
    try std.testing.expectEqual(null, decode("flt ", std.mem.asBytes(&std.math.nan(f32))));
}

test "SMC die temperatures reject the reported artefacts" {
    for ([_]f64{ 0, 5.3, 6, 6.7, 7.4, 8.4, 20, 130, std.math.nan(f64), std.math.inf(f64) }) |value| {
        try std.testing.expectEqual(false, power.isPlausibleDieTemperature(value));
    }
    for ([_]f64{ 37.3, 39.2, 42, 54.8, 63.4, 67.7 }) |value| {
        try std.testing.expectEqual(true, power.isPlausibleDieTemperature(value));
    }
}
