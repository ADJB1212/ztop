const std = @import("std");

pub const MAX_HISTORY_SAMPLES = 512;

pub fn History(comptime T: type, comptime clamp_max: ?T) type {
    return struct {
        const Self = @This();
        samples: [MAX_HISTORY_SAMPLES]T = [_]T{0} ** MAX_HISTORY_SAMPLES,
        start: usize = 0,
        count: usize = 0,

        pub fn append(self: *Self, sample: T) void {
            const final_val = if (clamp_max) |max_val|
                switch (@typeInfo(T)) {
                    .float => @max(0.0, @min(sample, max_val)),
                    .int => @max(0, @min(sample, max_val)),
                    else => @compileError("Unsupported type for clamping"),
                }
            else
                sample;

            if (self.count < self.samples.len) {
                self.samples[(self.start + self.count) % self.samples.len] = final_val;
                self.count += 1;
                return;
            }

            self.samples[self.start] = final_val;
            self.start = (self.start + 1) % self.samples.len;
        }

        pub fn len(self: *const Self) usize {
            return self.count;
        }

        pub fn sampleAt(self: *const Self, index: usize) T {
            std.debug.assert(index < self.count);
            return self.samples[(self.start + index) % self.samples.len];
        }

        pub fn maxSample(self: *const Self) T {
            if (self.count == 0) return 0;
            var max_value = self.sampleAt(0);
            var idx: usize = 1;
            while (idx < self.count) : (idx += 1) {
                max_value = @max(max_value, self.sampleAt(idx));
            }
            return max_value;
        }

        pub fn valueForColumn(self: *const Self, column: usize, total_columns: usize) ?T {
            if (self.count == 0 or total_columns == 0 or column >= total_columns) return null;

            if (self.count <= total_columns) {
                const left_pad = total_columns - self.count;
                if (column < left_pad) return null;
                return self.sampleAt(column - left_pad);
            }

            const bucket_start = (column * self.count) / total_columns;
            const bucket_end = std.math.divCeil(usize, (column + 1) * self.count, total_columns) catch self.count;

            var max_value = self.sampleAt(bucket_start);
            var idx = bucket_start + 1;
            while (idx < bucket_end and idx < self.count) : (idx += 1) {
                max_value = @max(max_value, self.sampleAt(idx));
            }

            return max_value;
        }
    };
}

pub const MetricHistory = History(f32, 100.0);
pub const RateHistory = History(u64, null);
