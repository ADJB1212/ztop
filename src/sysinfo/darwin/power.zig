const std = @import("std");
const bindings = @import("bindings.zig");

pub fn EnergyTracker(comptime count: usize) type {
    return struct {
        const Self = @This();
        const Sample = struct { values: [count]u64, time: f64 };
        pub const EnergyReading = struct { watts: [count]f64, seconds: f64 };

        previous: ?Sample = null,
        moved: u3 = 0,
        slices: u8 = 0,
        live_start: ?f64 = null,
        run: [256]Sample = undefined,
        run_count: usize = 0,
        older: ?Sample = null,
        newer: ?Sample = null,

        pub fn observe(self: *Self, values: [count]u64, time: f64, joules_per_unit: f64) ?EnergyReading {
            if (!std.math.isFinite(time)) {
                self.* = .{};
                return null;
            }
            const current = Sample{ .values = values, .time = time };
            const prev = self.previous orelse {
                self.previous = current;
                return null;
            };
            if (time <= prev.time or time - prev.time > 5) {
                self.* = .{ .previous = current };
                return null;
            }
            var changed = false;
            for (values, prev.values) |value, old| {
                if (value < old) {
                    self.* = .{ .previous = current };
                    return null;
                }
                changed = changed or value != old;
            }
            self.previous = current;
            self.moved = (self.moved << 1) | @intFromBool(changed);
            self.slices = @min(self.slices + 1, 3);
            if (changed) {
                if (self.live_start == null) self.live_start = prev.time;
            } else self.live_start = null;

            const change_time = (prev.time + time) / 2;
            if (self.run_count > 0 and time - self.run[self.run_count - 1].time >= 10) self.closeRun();
            if (changed) {
                if (self.run_count == self.run.len) {
                    std.mem.copyForwards(Sample, self.run[0 .. self.run.len - 1], self.run[1..]);
                    self.run_count -= 1;
                }
                self.run[self.run_count] = .{ .values = values, .time = change_time };
                self.run_count += 1;
            }

            if (self.slices < 3) return null;
            // Slow polling can see each piece of one refresh in consecutive slices.
            if (self.moved == 7 and time - self.live_start.? >= 10) return reading(prev, current, joules_per_unit);
            if (self.isBatching()) {
                const last = self.run[self.run_count - 1];
                var from = self.run[0];
                for (self.run[0..self.run_count]) |sample| {
                    if (last.time - sample.time >= 10) from = sample;
                }
                return reading(from, last, joules_per_unit);
            }
            if (self.older) |older| {
                if (self.newer) |newer| return reading(older, newer, joules_per_unit);
            }
            return null;
        }

        fn isBatching(self: *const Self) bool {
            return self.run_count > 1 and self.run[self.run_count - 1].time - self.run[0].time >= 10;
        }

        fn closeRun(self: *Self) void {
            const last = self.run[self.run_count - 1];
            const refresh = Sample{ .values = last.values, .time = if (self.isBatching()) last.time else self.run[0].time };
            self.older = self.newer;
            self.newer = refresh;
            self.run_count = 0;
        }

        fn reading(from: Sample, to: Sample, joules_per_unit: f64) ?EnergyReading {
            const seconds = to.time - from.time;
            if (seconds <= 0) return null;
            var result: EnergyReading = .{ .watts = undefined, .seconds = seconds };
            for (from.values, to.values, &result.watts) |a, b, *watts| {
                if (b < a) return null;
                watts.* = @as(f64, @floatFromInt(b - a)) * joules_per_unit / seconds;
            }
            return result;
        }
    };
}

pub const Reading = struct {
    soc_watts: ?f64 = null,
    gpu_watts: ?f64 = null,
    soc_window_seconds: ?f64 = null,
    gpu_window_seconds: ?f64 = null,
};

pub const Sampler = struct {
    rails: EnergyTracker(4) = .{},
    gpu: EnergyTracker(1) = .{},
    rail_mask: u32 = 0,
    rail_sources: u32 = 0,

    pub fn observe(self: *Sampler, raw: bindings.PowerReadingRaw, time: f64) Reading {
        var result: Reading = .{};
        if (raw.rail_mask != self.rail_mask or raw.rail_sources != self.rail_sources) self.rails = .{};
        self.rail_mask = raw.rail_mask;
        self.rail_sources = raw.rail_sources;
        if (raw.rail_mask != 0) {
            if (self.rails.observe(raw.rails, time, 0.001)) |rails| {
                if (raw.rail_mask == 15) {
                    var total: f64 = 0;
                    for (rails.watts) |watts| total += watts;
                    result.soc_watts = total;
                    result.soc_window_seconds = rails.seconds;
                }
                if (raw.rail_mask & 2 != 0) {
                    result.gpu_watts = rails.watts[1];
                    result.gpu_window_seconds = rails.seconds;
                }
            }
        } else self.rails = .{};
        if (raw.gpu_valid != 0) {
            if (self.gpu.observe(.{raw.gpu_nanojoules}, time, 0.000000001)) |gpu| {
                // Keep the GPU rail in the total; its independent counter covers another span.
                if (result.gpu_window_seconds == null or result.gpu_window_seconds.? > 5) {
                    result.gpu_watts = gpu.watts[0];
                    result.gpu_window_seconds = gpu.seconds;
                }
            }
        } else self.gpu = .{};
        if (raw.soc_valid != 0 and std.math.isFinite(raw.soc_watts) and raw.soc_watts >= 0) {
            result.soc_watts = raw.soc_watts;
            result.soc_window_seconds = null;
        }
        return result;
    }
};

pub fn isPlausibleDieTemperature(value: f64) bool {
    return std.math.isFinite(value) and value > 20 and value < 130;
}
