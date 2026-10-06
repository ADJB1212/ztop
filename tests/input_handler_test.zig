const std = @import("std");
const input_handler = @import("ztop").input_handler;

test "applyInputBytes appends a full pasted chunk" {
    var buf: [32]u8 = undefined;
    var len: usize = 0;

    const action = input_handler.applyInputBytes(&buf, &len, "show zombie");

    try std.testing.expectEqual(input_handler.EditAction.none, action);
    try std.testing.expectEqual(@as(usize, 11), len);
    try std.testing.expectEqualStrings("show zombie", buf[0..len]);
}

test "applyInputBytes handles backspace inside a pasted chunk" {
    var buf: [32]u8 = undefined;
    var len: usize = 0;

    _ = input_handler.applyInputBytes(&buf, &len, "sho");
    const action = input_handler.applyInputBytes(&buf, &len, "w\x08 zombie");

    try std.testing.expectEqual(input_handler.EditAction.none, action);
    try std.testing.expectEqualStrings("sho zombie", buf[0..len]);
}

test "applyInputBytes stops on submit and cancel" {
    var submit_buf: [32]u8 = undefined;
    var submit_len: usize = 0;

    const submit_action = input_handler.applyInputBytes(&submit_buf, &submit_len, "show zombie\nignored");
    try std.testing.expectEqual(input_handler.EditAction.submit, submit_action);
    try std.testing.expectEqualStrings("show zombie", submit_buf[0..submit_len]);

    var cancel_buf: [32]u8 = undefined;
    var cancel_len: usize = 0;

    const cancel_action = input_handler.applyInputBytes(&cancel_buf, &cancel_len, "show\x1bignored");
    try std.testing.expectEqual(input_handler.EditAction.cancel, cancel_action);
    try std.testing.expectEqualStrings("show", cancel_buf[0..cancel_len]);
}

test "process sort keys include disk read and write" {
    const SortBy = @import("ztop").sysinfo.SortBy;

    try std.testing.expectEqual(SortBy.disk_read, input_handler.processSortForKey('r', 2).?);
    try std.testing.expectEqual(SortBy.disk_write, input_handler.processSortForKey('w', 2).?);
    try std.testing.expectEqual(@as(?SortBy, null), input_handler.processSortForKey('r', 1));
    try std.testing.expectEqual(@as(?SortBy, null), input_handler.processSortForKey('w', 5));
    try std.testing.expect(input_handler.sortAvailableOnTab(.disk_read, 2));
    try std.testing.expect(!input_handler.sortAvailableOnTab(.disk_read, 1));
    try std.testing.expect(input_handler.sortAvailableOnTab(.cpu, 1));
}

test "input batches preserve split escape sequences and fill the available buffer" {
    const ztop = @import("ztop");
    var fds: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.pipe(&fds));
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);
    const output: std.Io.File = .{ .handle = fds[1], .flags = .{ .nonblocking = false } };
    var app_tui: ztop.tui.Tui = undefined;
    app_tui.io = std.testing.io;
    app_tui.in = .{ .handle = fds[0], .flags = .{ .nonblocking = false } };
    var input_buf: [128]u8 = undefined;
    var input_len: usize = 0;
    var filter_buf: [32]u8 = undefined;
    var filter_len: usize = 0;
    var show_help = false;
    var show_column_picker = false;
    var is_cmd_mode = false;
    var is_filtering = true;
    var quit = false;
    var sort_by: ztop.sysinfo.SortBy = .cpu;
    var tab: u8 = 1;
    var ctx: input_handler.Context = undefined;
    ctx.app_tui = &app_tui;
    ctx.input_buf = &input_buf;
    ctx.input_len = &input_len;
    ctx.filter_buf = &filter_buf;
    ctx.filter_len = &filter_len;
    ctx.show_help = &show_help;
    ctx.show_column_picker = &show_column_picker;
    ctx.is_cmd_mode = &is_cmd_mode;
    ctx.is_filtering = &is_filtering;
    ctx.quit_flag = &quit;
    ctx.sort_by = &sort_by;
    ctx.current_tab = &tab;

    const paste = "abcdefghijklmnopqrstuvwx";
    try output.writeStreamingAll(std.testing.io, paste ++ "\x1b[");
    try std.testing.expect(try input_handler.handleAvailableInput(&ctx));
    try std.testing.expectEqualStrings(paste, filter_buf[0..filter_len]);
    try std.testing.expectEqualStrings("\x1b[", input_buf[0..input_len]);
    try output.writeStreamingAll(std.testing.io, "Az");
    try std.testing.expect(try input_handler.handleAvailableInput(&ctx));
    try std.testing.expectEqualStrings(paste ++ "z", filter_buf[0..filter_len]);
    try std.testing.expectEqual(@as(usize, 0), input_len);

    filter_len = 0;
    const burst: [128]u8 = @splat('x');
    try output.writeStreamingAll(std.testing.io, &burst);
    try std.testing.expect(try input_handler.handleAvailableInput(&ctx));
    try std.testing.expectEqualStrings(burst[0..32], filter_buf[0..filter_len]);
    try std.testing.expectEqual(@as(usize, 0), input_len);
}
