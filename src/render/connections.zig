const std = @import("std");
const Tui = @import("../tui.zig").Tui;
const config = @import("../config.zig");
const common = @import("../sysinfo/common.zig");
const util = @import("util.zig");

pub const Layout = struct {
    widths: [6]usize,

    pub fn init(width: usize) Layout {
        if (width < 16) return .{ .widths = .{ @min(width, 4), 0, 0, 0, 0, width -| 5 } };
        const process_width = @min(24, @max(8, width / 5));
        const pid_width: usize = if (width >= 60) 7 else 0;
        const state_width: usize = if (width >= 90) 11 else 0;
        const gaps: usize = 3 + @as(usize, @intFromBool(pid_width > 0)) + @as(usize, @intFromBool(state_width > 0));
        const endpoint_width = width - 4 - process_width - pid_width - state_width - gaps;
        return .{ .widths = .{ 4, endpoint_width / 2, endpoint_width - endpoint_width / 2, state_width, pid_width, process_width } };
    }
};

pub fn formatEndpoint(buf: []u8, address: []const u8, port: u16, width: usize) []const u8 {
    var full_buf: [64]u8 = undefined;
    const full = if (port == 0)
        address
    else if (std.mem.indexOfScalar(u8, address, ':') != null)
        std.fmt.bufPrint(&full_buf, "[{s}]:{d}", .{ address, port }) catch address
    else
        std.fmt.bufPrint(&full_buf, "{s}:{d}", .{ address, port }) catch address;
    const clipped_width = @min(width, buf.len);
    if (full.len <= clipped_width) {
        @memcpy(buf[0..full.len], full);
        return buf[0..full.len];
    }
    if (clipped_width < 5) {
        @memcpy(buf[0..clipped_width], full[0..clipped_width]);
        return buf[0..clipped_width];
    }
    const tail_width = @min(10, (clipped_width - 3) / 2);
    const head_width = clipped_width - 3 - tail_width;
    @memcpy(buf[0..head_width], full[0..head_width]);
    @memcpy(buf[head_width..][0..3], "...");
    @memcpy(buf[head_width + 3 ..][0..tail_width], full[full.len - tail_width ..]);
    return buf[0..clipped_width];
}

pub fn renderRow(app_tui: *Tui, theme: config.Theme, layout: Layout, conn: ?common.NetConnection, selected: bool) !void {
    var local_buf: [64]u8 = undefined;
    var remote_buf: [64]u8 = undefined;
    var pid_buf: [16]u8 = undefined;
    const cells: [6][]const u8 = if (conn) |c| .{
        @tagName(c.protocol),
        formatEndpoint(&local_buf, std.mem.sliceTo(&c.local_addr, 0), c.local_port, layout.widths[1]),
        formatEndpoint(&remote_buf, std.mem.sliceTo(&c.remote_addr, 0), c.remote_port, layout.widths[2]),
        if (c.protocol == .tcp or c.protocol == .tcp6) @tagName(c.state) else "-",
        std.fmt.bufPrint(&pid_buf, "{d}", .{c.pid}) catch "?",
        c.name(),
    } else .{ "TYPE", "LOCAL", "REMOTE", "STATE", "PID", "PROCESS" };
    var first = true;
    for (cells, layout.widths, 0..) |cell, width, i| {
        if (width == 0) continue;
        const style: Tui.Style = .{
            .bg = if (selected) theme.selection_bg else null,
            .fg = if (conn == null) theme.muted else if (selected) theme.selection_fg else if (i == 5) theme.process_title else if (i == 3 or i == 4) theme.muted else theme.text,
            .bold = conn == null,
        };
        if (!first) try app_tui.writeStyledSpaces(style, 1);
        first = false;
        const clipped = util.clipUtf8(cell, width);
        const length = std.unicode.utf8CountCodepoints(clipped) catch clipped.len;
        const padding = width - length;
        if (i == 4) try app_tui.writeStyledSpaces(style, padding);
        try app_tui.writeStyled(style, clipped);
        if (i != 4) try app_tui.writeStyledSpaces(style, padding);
    }
}
