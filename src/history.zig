const std = @import("std");

pub const MAX_HISTORY_SAMPLES = 512;

pub fn History(comptime T: type, comptime clamp_max: ?T) type {
    return struct {
        const Self = @This();
        // Apple Silicon's NEON registers are 128 bits wide.
        const vector_bytes = 16;
        const vector_lanes = vector_bytes / @sizeOf(T);
        const ValueVector = @Vector(vector_lanes, T);

        samples: [MAX_HISTORY_SAMPLES]T = [_]T{0} ** MAX_HISTORY_SAMPLES,
        start: usize = 0,
        count: usize = 0,

        fn maxSlice(values: []const T) T {
            std.debug.assert(values.len > 0);

            var idx: usize = 0;
            var max_value = values[0];

            if (values.len >= vector_lanes) {
                var vector_max: ValueVector = values[0..vector_lanes].*;
                idx = vector_lanes;

                while (idx + vector_lanes <= values.len) : (idx += vector_lanes) {
                    const chunk: ValueVector = values[idx..][0..vector_lanes].*;
                    vector_max = @max(vector_max, chunk);
                }

                max_value = @reduce(.Max, vector_max);
            }

            while (idx < values.len) : (idx += 1) {
                max_value = @max(max_value, values[idx]);
            }

            return max_value;
        }

        fn maxLogicalRange(self: *const Self, logical_start: usize, logical_end: usize) T {
            std.debug.assert(logical_start < logical_end);
            std.debug.assert(logical_end <= self.count);

            const physical_start = (self.start + logical_start) % self.samples.len;
            const range_len = logical_end - logical_start;
            const first_len = @min(range_len, self.samples.len - physical_start);
            var max_value = maxSlice(self.samples[physical_start .. physical_start + first_len]);

            const remaining = range_len - first_len;
            if (remaining > 0) {
                max_value = @max(max_value, maxSlice(self.samples[0..remaining]));
            }

            return max_value;
        }

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
            return self.maxLogicalRange(0, self.count);
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

            return self.maxLogicalRange(bucket_start, @min(bucket_end, self.count));
        }

        pub fn valuesForColumns(self: *const Self, values: []?T) void {
            for (values, 0..) |*value, column| {
                value.* = self.valueForColumn(column, values.len);
            }
        }
    };
}

pub const MetricHistory = History(f32, 100.0);
pub const RateHistory = History(u64, null);
