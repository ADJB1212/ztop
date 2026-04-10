const std = @import("std");
const tui = @import("ztop").tui;

test "Tui.Color enums" {
    try std.testing.expectEqual(@as(u8, 30), @intFromEnum(tui.Tui.Color.black));
    try std.testing.expectEqual(@as(u8, 31), @intFromEnum(tui.Tui.Color.red));
    try std.testing.expectEqual(@as(u8, 37), @intFromEnum(tui.Tui.Color.white));
    try std.testing.expectEqual(@as(u8, 97), @intFromEnum(tui.Tui.Color.bright_white));
}

test "cursor style sequences match VT cursor styles" {
    try std.testing.expectEqualStrings("\x1b[2 q", tui.Tui.cursorStyleSequence(.steady_block));
    try std.testing.expectEqualStrings("\x1b[6 q", tui.Tui.cursorStyleSequence(.steady_bar));
}

test "style sequence supports underline" {
    var buf: [32]u8 = undefined;
    const seq = try tui.Tui.styleSequence(&buf, .{
        .fg = .bright_cyan,
        .bold = true,
        .underline = true,
    });

    try std.testing.expectEqualStrings("\x1b[0;1;4;96m", seq);
}

test "synchronized output is disabled for Apple Terminal" {
    try std.testing.expect(!tui.Tui.shouldEnableSynchronizedOutput("Apple_Terminal"));
    try std.testing.expect(tui.Tui.shouldEnableSynchronizedOutput("iTerm.app"));
    try std.testing.expect(tui.Tui.shouldEnableSynchronizedOutput(null));
}

test "hyperlink writer emits OSC 8 wrapper" {
    var buf: [128]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);

    try tui.Tui.writeHyperlinkTo(stream.writer(), "https://example.com", "example");

    try std.testing.expectEqualStrings("\x1b]8;;https://example.com\x1b\\example\x1b]8;;\x1b\\", stream.getWritten());
}
