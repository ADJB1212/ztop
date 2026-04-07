const std = @import("std");
const text_input = @import("ztop").text_input;

test "applyInputBytes appends a full pasted chunk" {
    var buf: [32]u8 = undefined;
    var len: usize = 0;

    const action = text_input.applyInputBytes(&buf, &len, "show zombie");

    try std.testing.expectEqual(text_input.EditAction.none, action);
    try std.testing.expectEqual(@as(usize, 11), len);
    try std.testing.expectEqualStrings("show zombie", buf[0..len]);
}

test "applyInputBytes handles backspace inside a pasted chunk" {
    var buf: [32]u8 = undefined;
    var len: usize = 0;

    _ = text_input.applyInputBytes(&buf, &len, "sho");
    const action = text_input.applyInputBytes(&buf, &len, "w\x08 zombie");

    try std.testing.expectEqual(text_input.EditAction.none, action);
    try std.testing.expectEqualStrings("sho zombie", buf[0..len]);
}

test "applyInputBytes stops on submit and cancel" {
    var submit_buf: [32]u8 = undefined;
    var submit_len: usize = 0;

    const submit_action = text_input.applyInputBytes(&submit_buf, &submit_len, "show zombie\nignored");
    try std.testing.expectEqual(text_input.EditAction.submit, submit_action);
    try std.testing.expectEqualStrings("show zombie", submit_buf[0..submit_len]);

    var cancel_buf: [32]u8 = undefined;
    var cancel_len: usize = 0;

    const cancel_action = text_input.applyInputBytes(&cancel_buf, &cancel_len, "show\x1bignored");
    try std.testing.expectEqual(text_input.EditAction.cancel, cancel_action);
    try std.testing.expectEqualStrings("show", cancel_buf[0..cancel_len]);
}
