const std = @import("std");
const builtin = @import("builtin");

test {
    _ = @import("common_test.zig");
    _ = @import("config_test.zig");
    _ = @import("history_test.zig");
    _ = @import("process_commands_test.zig");
    _ = @import("render_test.zig");
    _ = @import("text_input_test.zig");
    _ = @import("tui_test.zig");
    _ = @import("linux_test.zig");
    _ = @import("sysinfo_test.zig");
    if (builtin.target.os.tag == .macos) _ = @import("darwin_test.zig");
}
