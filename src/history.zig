const std = @import("std");

pub const MAX_HISTORY_SAMPLES = 512;

pub const MetricHistory = struct {
    samples: [MAX_HISTORY_SAMPLES]f32 = [_]f32{0} ** MAX_HISTORY_SAMPLES,
    start: usize = 0,
    count: usize = 0,

    pub fn append(self: *MetricHistory, sample: f32) void {
        const clamped = @max(0.0, @min(sample, 100.0));

        if (self.count < self.samples.len) {
            self.samples[(self.start + self.count) % self.samples.len] = clamped;
            self.count += 1;
            return;
        }

        self.samples[self.start] = clamped;
        self.start = (self.start + 1) % self.samples.len;
    }

    pub fn len(self: *const MetricHistory) usize {
        return self.count;
    }

    pub fn sampleAt(self: *const MetricHistory, index: usize) f32 {
        std.debug.assert(index < self.count);
        return self.samples[(self.start + index) % self.samples.len];
    }

    pub fn valueForColumn(self: *const MetricHistory, column: usize, total_columns: usize) ?f32 {
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

pub const RateHistory = struct {
    samples: [MAX_HISTORY_SAMPLES]u64 = [_]u64{0} ** MAX_HISTORY_SAMPLES,
    start: usize = 0,
    count: usize = 0,

    pub fn append(self: *RateHistory, sample: u64) void {
        if (self.count < self.samples.len) {
            self.samples[(self.start + self.count) % self.samples.len] = sample;
            self.count += 1;
            return;
        }

        self.samples[self.start] = sample;
        self.start = (self.start + 1) % self.samples.len;
    }

    pub fn len(self: *const RateHistory) usize {
        return self.count;
    }

    pub fn sampleAt(self: *const RateHistory, index: usize) u64 {
        std.debug.assert(index < self.count);
        return self.samples[(self.start + index) % self.samples.len];
    }

    pub fn maxSample(self: *const RateHistory) u64 {
        if (self.count == 0) return 0;

        var max_value = self.sampleAt(0);
        var idx: usize = 1;
        while (idx < self.count) : (idx += 1) {
            max_value = @max(max_value, self.sampleAt(idx));
        }
        return max_value;
    }

    pub fn valueForColumn(self: *const RateHistory, column: usize, total_columns: usize) ?u64 {
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
