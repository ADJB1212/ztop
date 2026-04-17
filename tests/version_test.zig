const std = @import("std");
const cli = @import("ztop").cli;

test "detectAction recognizes --version" {
    const args = [_][]const u8{ "ztop", "--version" };
    try std.testing.expectEqual(cli.Action.print_version, cli.detectAction(&args));
}

test "detectAction ignores unrelated args" {
    const args = [_][]const u8{ "ztop", "--help" };
    try std.testing.expectEqual(cli.Action.run, cli.detectAction(&args));
}
