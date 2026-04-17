const std = @import("std");

pub const Action = enum {
    run,
    print_version,
};

pub fn detectAction(args: []const []const u8) Action {
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--version")) return .print_version;
    }
    return .run;
}
