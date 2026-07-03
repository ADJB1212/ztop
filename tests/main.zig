const std = @import("std");

test {
    _ = @import("common_test.zig");
    _ = @import("config_test.zig");
    _ = @import("history_test.zig");
    _ = @import("process_commands_test.zig");
    _ = @import("render_test.zig");
    _ = @import("why_busy_test.zig");
    _ = @import("pressure_hints_test.zig");
    _ = @import("input_handler_test.zig");
    _ = @import("timeline_test.zig");
    _ = @import("tui_test.zig");
    _ = @import("version_test.zig");
    _ = @import("sysinfo_test.zig");
    _ = @import("darwin_test.zig");
}
