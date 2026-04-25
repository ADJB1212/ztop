const std = @import("std");
const config = @import("../config.zig");
const ProcessColumn = config.ProcessColumn;
const ProcessColumns = config.ProcessColumns;

pub const ProcessTableLayout = struct {
    columns: [config.process_column_order.len]ProcessColumn = undefined,
    count: usize = 0,
    name_width: usize = 0,
    dropped_count: usize = 0,
};

pub const min_process_name_width: usize = 8;

pub fn processColumnWidth(column: ProcessColumn) usize {
    return switch (column) {
        .pid => 6,
        .ppid => 6,
        .state => 9,
        .cpu => 10,
        .mem => 10,
        .threads => 8,
        .disk_read => 11,
        .disk_write => 11,
        .wakeups => 14,
    };
}

pub fn planProcessTableLayout(columns: ProcessColumns, available_width: usize) ProcessTableLayout {
    var layout: ProcessTableLayout = .{};
    var visible_columns: [config.process_column_order.len]ProcessColumn = undefined;
    const visible = columns.visibleOrdered(&visible_columns);

    var fixed_width: usize = 0;
    for (visible) |column| {
        fixed_width += processColumnWidth(column);
    }

    layout.count = visible.len;
    while (layout.count > 0 and available_width < fixed_width + min_process_name_width) {
        layout.count -= 1;
        fixed_width -= processColumnWidth(visible[layout.count]);
        layout.dropped_count += 1;
    }

    if (layout.count > 0) {
        @memcpy(layout.columns[0..layout.count], visible[0..layout.count]);
    }

    layout.name_width = available_width -| fixed_width;
    return layout;
}
