const std = @import("std");
const posix = std.posix;

pub const Tui = struct {
    pub const Color = enum(u8) {
        black = 30,
        red = 31,
        green = 32,
        yellow = 33,
        blue = 34,
        magenta = 35,
        cyan = 36,
        white = 37,
        bright_black = 90,
        bright_red = 91,
        bright_green = 92,
        bright_yellow = 93,
        bright_blue = 94,
        bright_magenta = 95,
        bright_cyan = 96,
        bright_white = 97,
    };

    pub const Style = struct {
        fg: ?Color = null,
        bg: ?Color = null,
        bold: bool = false,
        dim: bool = false,
    };

    original_termios: posix.termios,
    in: std.fs.File,
    out: std.fs.File,

    pub fn init() !Tui {
        const in = std.fs.File.stdin();
        const out = std.fs.File.stdout();
        const original_termios = try posix.tcgetattr(in.handle);

        var raw = original_termios;
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.ISIG = false;
        raw.lflag.IEXTEN = false;
        raw.iflag.IXON = false;
        raw.iflag.ICRNL = false;
        raw.iflag.BRKINT = false;
        raw.iflag.INPCK = false;
        raw.iflag.ISTRIP = false;
        raw.oflag.OPOST = false;
        raw.cflag.CSIZE = .CS8;
        raw.cc[@intFromEnum(posix.V.MIN)] = 0;
        raw.cc[@intFromEnum(posix.V.TIME)] = 1;

        try posix.tcsetattr(in.handle, .FLUSH, raw);

        // Enter alternate buffer and hide cursor
        _ = try out.write("\x1b[?1049h\x1b[?25l");

        return Tui{
            .original_termios = original_termios,
            .in = in,
            .out = out,
        };
    }

    pub fn deinit(self: *Tui) void {
        // Show cursor and exit alternate buffer
        _ = self.out.write("\x1b[?25h\x1b[?1049l") catch {};
        posix.tcsetattr(self.in.handle, .FLUSH, self.original_termios) catch {};
    }

    pub fn clear(self: *Tui) !void {
        _ = try self.out.write("\x1b[0m\x1b[2J\x1b[H");
    }

    pub fn moveCursor(self: *Tui, x: u16, y: u16) !void {
        var buf: [32]u8 = undefined;
        const seq = try std.fmt.bufPrint(&buf, "\x1b[{d};{d}H", .{ y, x });
        _ = try self.out.write(seq);
    }

    pub fn print(self: *Tui, comptime fmt: []const u8, args: anytype) !void {
        try self.out.deprecatedWriter().print(fmt, args);
    }

    pub fn setStyle(self: *Tui, style: Style) !void {
        var buf: [32]u8 = undefined;
        var stream = std.io.fixedBufferStream(&buf);
        const writer = stream.writer();

        try writer.writeAll("\x1b[0");
        if (style.bold) try writer.writeAll(";1");
        if (style.dim) try writer.writeAll(";2");
        if (style.fg) |fg| try writer.print(";{d}", .{@intFromEnum(fg)});
        if (style.bg) |bg| try writer.print(";{d}", .{@intFromEnum(bg) + 10});
        try writer.writeAll("m");

        try self.out.writeAll(stream.getWritten());
    }

    pub fn resetStyle(self: *Tui) !void {
        try self.out.writeAll("\x1b[0m");
    }

    pub fn writeStyled(self: *Tui, style: Style, text: []const u8) !void {
        try self.setStyle(style);
        defer self.resetStyle() catch {};
        try self.out.writeAll(text);
    }

    pub fn printStyled(self: *Tui, style: Style, comptime fmt: []const u8, args: anytype) !void {
        try self.setStyle(style);
        defer self.resetStyle() catch {};
        try self.print(fmt, args);
    }

    pub fn drawBox(self: *Tui, x: u16, y: u16, width: u16, height: u16, title: []const u8) !void {
        try self.drawBoxStyled(x, y, width, height, title, .{}, .{ .bold = true });
    }

    pub fn drawBoxStyled(
        self: *Tui,
        x: u16,
        y: u16,
        width: u16,
        height: u16,
        title: []const u8,
        border_style: Style,
        title_style: Style,
    ) !void {
        try self.setStyle(border_style);

        // Draw top border
        try self.moveCursor(x, y);
        try self.out.writeAll("╭");
        for (0..width - 2) |_| try self.out.writeAll("─");
        try self.out.writeAll("╮");

        // Draw sides
        for (1..height - 1) |i| {
            try self.moveCursor(x, y + @as(u16, @intCast(i)));
            try self.out.writeAll("│");
            try self.moveCursor(x + width - 1, y + @as(u16, @intCast(i)));
            try self.out.writeAll("│");
        }

        // Draw bottom border
        try self.moveCursor(x, y + height - 1);
        try self.out.writeAll("╰");
        for (0..width - 2) |_| try self.out.writeAll("─");
        try self.out.writeAll("╯");
        try self.resetStyle();

        // Draw title
        if (title.len > 0) {
            try self.moveCursor(x + 2, y);
            try self.printStyled(title_style, "┤ {s} ├", .{title});
        }
    }

    pub fn getWinSize(self: *Tui) !struct { width: u16, height: u16 } {
        var winsize: posix.winsize = undefined;
        const err = posix.system.ioctl(self.out.handle, posix.T.IOCGWINSZ, @intFromPtr(&winsize));
        if (posix.errno(err) != .SUCCESS) {
            return error.IoctlFailed;
        }
        return .{ .width = winsize.col, .height = winsize.row };
    }
};
