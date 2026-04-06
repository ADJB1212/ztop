const std = @import("std");

test {
    _ = @import("common_test.zig");
    _ = @import("tui_test.zig");
    _ = @import("linux_test.zig");
    _ = @import("sysinfo_test.zig");
}
