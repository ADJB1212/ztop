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
        underline: bool = false,
    };

    pub const CursorStyle = enum(u8) {
        blinking_block = 1,
        steady_block = 2,
        blinking_underline = 3,
        steady_underline = 4,
        blinking_bar = 5,
        steady_bar = 6,
    };

    pub const TerminalFeatures = struct {
        synchronized_output: bool,
    };

    original_termios: posix.termios,
    in: std.fs.File,
    out: std.fs.File,
    features: TerminalFeatures,
    cursor_visible: bool,
    cursor_style: CursorStyle,
    frame_active: bool,

    pub fn shouldEnableSynchronizedOutput(term_program: ?[]const u8) bool {
        if (term_program) |name| {
            return !std.mem.eql(u8, name, "Apple_Terminal");
        }
        return true;
    }

    pub fn cursorStyleSequence(style: CursorStyle) []const u8 {
        return switch (style) {
            .blinking_block => "\x1b[1 q",
            .steady_block => "\x1b[2 q",
            .blinking_underline => "\x1b[3 q",
            .steady_underline => "\x1b[4 q",
            .blinking_bar => "\x1b[5 q",
            .steady_bar => "\x1b[6 q",
        };
    }

    pub fn styleSequence(buf: []u8, style: Style) ![]const u8 {
        var stream = std.io.fixedBufferStream(buf);
        const writer = stream.writer();

        try writer.writeAll("\x1b[0");
        if (style.bold) try writer.writeAll(";1");
        if (style.dim) try writer.writeAll(";2");
        if (style.underline) try writer.writeAll(";4");
        if (style.fg) |fg| try writer.print(";{d}", .{@intFromEnum(fg)});
        if (style.bg) |bg| try writer.print(";{d}", .{@intFromEnum(bg) + 10});
        try writer.writeAll("m");

        return stream.getWritten();
    }

    pub fn writeHyperlinkTo(writer: anytype, uri: []const u8, label: []const u8) !void {
        try writer.writeAll("\x1b]8;;");
        try writer.writeAll(uri);
        try writer.writeAll("\x1b\\");
        try writer.writeAll(label);
        try writer.writeAll("\x1b]8;;\x1b\\");
    }

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

        const features = TerminalFeatures{
            .synchronized_output = shouldEnableSynchronizedOutput(if (posix.getenv("TERM_PROGRAM")) |term_program| term_program else null),
        };

        // Enter alternate buffer and hide cursor
        try out.writeAll("\x1b[?1049h\x1b[?25l");

        return Tui{
            .original_termios = original_termios,
            .in = in,
            .out = out,
            .features = features,
            .cursor_visible = false,
            .cursor_style = .steady_block,
            .frame_active = false,
        };
    }

    pub fn deinit(self: *Tui) void {
        self.endFrame() catch {};
        self.resetStyle() catch {};
        self.setCursorStyle(.steady_block) catch {};
        self.setCursorVisible(true) catch {};
        self.out.writeAll("\x1b[?1049l") catch {};
        posix.tcsetattr(self.in.handle, .FLUSH, self.original_termios) catch {};
    }

    pub fn beginFrame(self: *Tui) !void {
        if (!self.features.synchronized_output or self.frame_active) return;

        try self.out.writeAll("\x1b[?2026h");
        self.frame_active = true;
    }

    pub fn endFrame(self: *Tui) !void {
        if (!self.frame_active) return;

        try self.out.writeAll("\x1b[?2026l");
        self.frame_active = false;
    }

    pub fn clear(self: *Tui) !void {
        try self.out.writeAll("\x1b[0m\x1b[2J\x1b[H");
    }

    pub fn moveCursor(self: *Tui, x: u16, y: u16) !void {
        var buf: [32]u8 = undefined;
        const seq = try std.fmt.bufPrint(&buf, "\x1b[{d};{d}H", .{ y, x });
        _ = try self.out.write(seq);
    }

    pub fn setCursorVisible(self: *Tui, visible: bool) !void {
        if (self.cursor_visible == visible) return;

        try self.out.writeAll(if (visible) "\x1b[?25h" else "\x1b[?25l");
        self.cursor_visible = visible;
    }

    pub fn setCursorStyle(self: *Tui, style: CursorStyle) !void {
        if (self.cursor_style == style) return;

        try self.out.writeAll(cursorStyleSequence(style));
        self.cursor_style = style;
    }

    pub fn print(self: *Tui, comptime fmt: []const u8, args: anytype) !void {
        try self.out.deprecatedWriter().print(fmt, args);
    }

    pub fn setStyle(self: *Tui, style: Style) !void {
        var buf: [32]u8 = undefined;
        const seq = try styleSequence(&buf, style);
        try self.out.writeAll(seq);
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

    pub fn writeHyperlink(self: *Tui, uri: []const u8, label: []const u8) !void {
        try writeHyperlinkTo(self.out.deprecatedWriter(), uri, label);
    }

    pub fn writeStyledHyperlink(self: *Tui, style: Style, uri: []const u8, label: []const u8) !void {
        try self.setStyle(style);
        defer self.resetStyle() catch {};
        try self.writeHyperlink(uri, label);
    }

    pub fn drawBox(self: *Tui, x: u16, y: u16, width: u16, height: u16, title: []const u8) !void {
        try self.drawBoxStyled(x, y, width, height, title, .{}, .{ .bold = true });
    }

    pub fn drawBoxStyled(self: *Tui, x: u16, y: u16, width: u16, height: u16, title: []const u8, border_style: Style, title_style: Style) !void {
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
