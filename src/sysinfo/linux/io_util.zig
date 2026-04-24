const std = @import("std");

pub fn readDirFile(io: std.Io, dir: *std.Io.Dir, sub_path: []const u8, buf: []u8) ![]const u8 {
    const file = try dir.openFile(io, sub_path, .{});
    defer file.close(io);
    const len = file.readStreaming(io, &.{buf}) catch |err| switch (err) {
        error.EndOfStream => 0,
        else => |e| return e,
    };
    return buf[0..len];
}

pub fn readAbsoluteFile(io: std.Io, path: []const u8, buf: []u8) ![]const u8 {
    const file = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);
    const len = file.readStreaming(io, &.{buf}) catch |err| switch (err) {
        error.EndOfStream => 0,
        else => |e| return e,
    };
    return buf[0..len];
}

pub fn readIntFromDir(io: std.Io, dir: *std.Io.Dir, comptime T: type, sub_path: []const u8) !T {
    var buf: [64]u8 = undefined;
    const contents = try readDirFile(io, dir, sub_path, &buf);
    return std.fmt.parseInt(T, std.mem.trim(u8, contents, " \t\r\n"), 10);
}

pub fn readHexIntFromDir(io: std.Io, dir: *std.Io.Dir, comptime T: type, sub_path: []const u8) !T {
    var buf: [64]u8 = undefined;
    const contents = try readDirFile(io, dir, sub_path, &buf);
    var trimmed = std.mem.trim(u8, contents, " \t\r\n");
    if (std.mem.startsWith(u8, trimmed, "0x") or std.mem.startsWith(u8, trimmed, "0X")) {
        trimmed = trimmed[2..];
    }
    return std.fmt.parseInt(T, trimmed, 16);
}
