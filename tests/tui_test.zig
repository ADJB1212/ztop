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

test "mouse mode sequences match SGR mouse reporting" {
    try std.testing.expectEqualStrings("\x1b[?1000h\x1b[?1006h", tui.Tui.mouseModeSequence(true));
    try std.testing.expectEqualStrings("\x1b[?1006l\x1b[?1000l", tui.Tui.mouseModeSequence(false));
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

test "parseInputToken parses mouse press and scroll events" {
    const click = tui.Tui.parseInputToken("\x1b[<0;12;7M");
    switch (click) {
        .parsed => |parsed| {
            try std.testing.expectEqual(@as(usize, 10), parsed.used);
            switch (parsed.token) {
                .mouse => |mouse| {
                    try std.testing.expectEqual(tui.Tui.MouseAction.press, mouse.action);
                    try std.testing.expectEqual(tui.Tui.MouseButton.left, mouse.button);
                    try std.testing.expectEqual(@as(u16, 12), mouse.x);
                    try std.testing.expectEqual(@as(u16, 7), mouse.y);
                },
                else => return error.UnexpectedToken,
            }
        },
        else => return error.UnexpectedParseResult,
    }

    const scroll = tui.Tui.parseInputToken("\x1b[<65;40;18M");
    switch (scroll) {
        .parsed => |parsed| switch (parsed.token) {
            .mouse => |mouse| {
                try std.testing.expectEqual(tui.Tui.MouseAction.scroll_down, mouse.action);
                try std.testing.expectEqual(tui.Tui.MouseButton.none, mouse.button);
                try std.testing.expectEqual(@as(u16, 40), mouse.x);
                try std.testing.expectEqual(@as(u16, 18), mouse.y);
            },
            else => return error.UnexpectedToken,
        },
        else => return error.UnexpectedParseResult,
    }
}
