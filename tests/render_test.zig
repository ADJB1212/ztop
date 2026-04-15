const std = @import("std");
const config = @import("ztop").config;
const render = @import("ztop").render;

test "planProcessTableLayout keeps enabled columns when width allows" {
    var columns = config.ProcessColumns.defaultsMain();
    columns.ppid = true;

    const layout = render.planProcessTableLayout(columns, 48);

    try std.testing.expectEqual(@as(usize, 5), layout.count);
    try std.testing.expectEqual(@as(usize, 8), layout.name_width);
    try std.testing.expectEqual(@as(usize, 0), layout.dropped_count);
    try std.testing.expectEqual(config.ProcessColumn.pid, layout.columns[0]);
    try std.testing.expectEqual(config.ProcessColumn.ppid, layout.columns[1]);
    try std.testing.expectEqual(config.ProcessColumn.cpu, layout.columns[2]);
    try std.testing.expectEqual(config.ProcessColumn.mem, layout.columns[3]);
    try std.testing.expectEqual(config.ProcessColumn.threads, layout.columns[4]);
}

test "planProcessTableLayout drops trailing columns to preserve name width" {
    const layout = render.planProcessTableLayout(config.ProcessColumns.all(), 40);

    try std.testing.expectEqual(@as(usize, 4), layout.count);
    try std.testing.expectEqual(@as(usize, 9), layout.name_width);
    try std.testing.expectEqual(@as(usize, 4), layout.dropped_count);
    try std.testing.expect(layout.name_width >= render.min_process_name_width);
    try std.testing.expectEqual(config.ProcessColumn.pid, layout.columns[0]);
    try std.testing.expectEqual(config.ProcessColumn.ppid, layout.columns[1]);
    try std.testing.expectEqual(config.ProcessColumn.state, layout.columns[2]);
    try std.testing.expectEqual(config.ProcessColumn.cpu, layout.columns[3]);
}
