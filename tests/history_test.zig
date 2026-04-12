const std = @import("std");
const history = @import("ztop").history;

test "MetricHistory preserves insertion order after wrap" {
    var metric_history = history.MetricHistory{};

    for (0..history.MAX_HISTORY_SAMPLES + 3) |idx| {
        metric_history.append(@floatFromInt((idx % 97) + 1));
    }

    try std.testing.expectEqual(@as(usize, history.MAX_HISTORY_SAMPLES), metric_history.len());
    try std.testing.expectEqual(@as(f32, 4), metric_history.sampleAt(0));
    try std.testing.expectEqual(@as(f32, 30), metric_history.sampleAt(metric_history.len() - 1));
}

test "MetricHistory right-aligns when graph is wider than sample count" {
    var metric_history = history.MetricHistory{};
    metric_history.append(10);
    metric_history.append(20);
    metric_history.append(30);

    try std.testing.expectEqual(@as(?f32, null), metric_history.valueForColumn(0, 5));
    try std.testing.expectEqual(@as(?f32, null), metric_history.valueForColumn(1, 5));
    try std.testing.expectEqual(@as(?f32, 10), metric_history.valueForColumn(2, 5));
    try std.testing.expectEqual(@as(?f32, 20), metric_history.valueForColumn(3, 5));
    try std.testing.expectEqual(@as(?f32, 30), metric_history.valueForColumn(4, 5));
}

test "MetricHistory downsamples columns using the peak value in each bucket" {
    var metric_history = history.MetricHistory{};
    const samples = [_]f32{ 10, 40, 20, 70, 30, 50 };
    for (samples) |sample| metric_history.append(sample);

    try std.testing.expectEqual(@as(?f32, 40), metric_history.valueForColumn(0, 3));
    try std.testing.expectEqual(@as(?f32, 70), metric_history.valueForColumn(1, 3));
    try std.testing.expectEqual(@as(?f32, 50), metric_history.valueForColumn(2, 3));
}
