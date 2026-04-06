const std = @import("std");
const tui = @import("ztop").tui;

test "Tui.Color enums" {
    try std.testing.expectEqual(@as(u8, 30), @intFromEnum(tui.Tui.Color.black));
    try std.testing.expectEqual(@as(u8, 31), @intFromEnum(tui.Tui.Color.red));
    try std.testing.expectEqual(@as(u8, 37), @intFromEnum(tui.Tui.Color.white));
    try std.testing.expectEqual(@as(u8, 97), @intFromEnum(tui.Tui.Color.bright_white));
}
