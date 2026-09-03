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
