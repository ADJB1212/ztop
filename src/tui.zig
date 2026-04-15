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

    pub const MouseButton = enum {
        left,
        middle,
        right,
        none,
    };

    pub const MouseAction = enum {
        press,
        release,
        drag,
        scroll_up,
        scroll_down,
    };

    pub const MouseEvent = struct {
        x: u16,
        y: u16,
        button: MouseButton,
        action: MouseAction,
        shift: bool = false,
        alt: bool = false,
        ctrl: bool = false,
    };

    pub const InputToken = union(enum) {
        byte: u8,
        enter,
        escape,
        arrow_up,
        arrow_down,
        mouse: MouseEvent,
    };

    pub const ParsedInputToken = struct {
        token: InputToken,
        used: usize,
    };

    pub const InputParseResult = union(enum) {
        parsed: ParsedInputToken,
        incomplete,
        invalid: usize,
    };

    const ParsedMouseNumber = struct {
        value: u16,
        used: usize,
    };

    const MouseNumberParseResult = union(enum) {
        parsed: ParsedMouseNumber,
        incomplete,
        invalid: usize,
    };

    original_termios: posix.termios,
    io: std.Io,
    in: std.Io.File,
    out: std.Io.File,
    features: TerminalFeatures,
    cursor_visible: bool,
    cursor_style: CursorStyle,
    frame_active: bool,
    nerd_fonts: bool,

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

    pub fn mouseModeSequence(enable: bool) []const u8 {
        return if (enable)
            "\x1b[?1000h\x1b[?1006h"
        else
            "\x1b[?1006l\x1b[?1000l";
    }

    pub fn styleSequence(buf: []u8, style: Style) ![]const u8 {
        var writer: std.Io.Writer = .fixed(buf);

        try writer.writeAll("\x1b[0");
        if (style.bold) try writer.writeAll(";1");
        if (style.dim) try writer.writeAll(";2");
        if (style.underline) try writer.writeAll(";4");
        if (style.fg) |fg| try writer.print(";{d}", .{@intFromEnum(fg)});
        if (style.bg) |bg| try writer.print(";{d}", .{@intFromEnum(bg) + 10});
        try writer.writeAll("m");

        return writer.buffered();
    }

    pub fn writeHyperlinkTo(writer: *std.Io.Writer, uri: []const u8, label: []const u8) !void {
        try writer.writeAll("\x1b]8;;");
        try writer.writeAll(uri);
        try writer.writeAll("\x1b\\");
        try writer.writeAll(label);
        try writer.writeAll("\x1b]8;;\x1b\\");
        try writer.flush();
    }

    fn parseMouseNumber(bytes: []const u8, start: usize) MouseNumberParseResult {
        if (start >= bytes.len) return .incomplete;

        var idx = start;
        var value: u32 = 0;
        var saw_digit = false;

        while (idx < bytes.len) : (idx += 1) {
            const ch = bytes[idx];
            if (ch < '0' or ch > '9') break;
            saw_digit = true;
            value = value * 10 + (ch - '0');
        }

        if (!saw_digit) return .{ .invalid = 1 };
        if (value > std.math.maxInt(u16)) return .{ .invalid = 1 };

        return .{ .parsed = .{ .value = @intCast(value), .used = idx } };
    }

    pub fn parseInputToken(bytes: []const u8) InputParseResult {
        if (bytes.len == 0) return .incomplete;

        const first = bytes[0];
        if (first == '\r' or first == '\n') {
            return .{ .parsed = .{ .token = .enter, .used = 1 } };
        }
        if (first != '\x1b') {
            return .{ .parsed = .{ .token = .{ .byte = first }, .used = 1 } };
        }
        if (bytes.len == 1) {
            return .{ .parsed = .{ .token = .escape, .used = 1 } };
        }
        if (bytes[1] != '[') {
            return .{ .parsed = .{ .token = .escape, .used = 1 } };
        }
        if (bytes.len < 3) return .incomplete;

        switch (bytes[2]) {
            'A' => return .{ .parsed = .{ .token = .arrow_up, .used = 3 } },
            'B' => return .{ .parsed = .{ .token = .arrow_down, .used = 3 } },
            '<' => {
                const cb_result = parseMouseNumber(bytes, 3);
                const cb_end = switch (cb_result) {
                    .parsed => |parsed| parsed.used,
                    .incomplete => return .incomplete,
                    .invalid => |used| return .{ .invalid = used },
                };
                if (cb_end >= bytes.len) return .incomplete;
                if (bytes[cb_end] != ';') return .{ .invalid = 1 };

                const x_result = parseMouseNumber(bytes, cb_end + 1);
                const x_end = switch (x_result) {
                    .parsed => |parsed| parsed.used,
                    .incomplete => return .incomplete,
                    .invalid => |used| return .{ .invalid = used },
                };
                if (x_end >= bytes.len) return .incomplete;
                if (bytes[x_end] != ';') return .{ .invalid = 1 };

                const y_result = parseMouseNumber(bytes, x_end + 1);
                const parsed_y = switch (y_result) {
                    .parsed => |parsed| parsed,
                    .incomplete => return .incomplete,
                    .invalid => |used| return .{ .invalid = used },
                };
                if (parsed_y.used >= bytes.len) return .incomplete;

                const suffix = bytes[parsed_y.used];
                if (suffix != 'M' and suffix != 'm') return .{ .invalid = 1 };

                const cb_value = switch (cb_result) {
                    .parsed => |parsed| parsed.value,
                    else => unreachable,
                };
                const x_value = switch (x_result) {
                    .parsed => |parsed| parsed.value,
                    else => unreachable,
                };
                const y_value = parsed_y.value;

                const button_bits = cb_value & 0b11;
                const wheel = (cb_value & 0b0100_0000) != 0;
                const motion = (cb_value & 0b0010_0000) != 0;
                const button: MouseButton = if (wheel or button_bits == 3)
                    .none
                else switch (button_bits) {
                    0 => .left,
                    1 => .middle,
                    2 => .right,
                    else => .none,
                };
                const action: MouseAction = if (wheel)
                    switch (button_bits) {
                        0 => .scroll_up,
                        1 => .scroll_down,
                        else => .press,
                    }
                else if (suffix == 'm')
                    .release
                else if (motion)
                    .drag
                else
                    .press;

                return .{
                    .parsed = .{
                        .token = .{
                            .mouse = .{
                                .x = x_value,
                                .y = y_value,
                                .button = button,
                                .action = action,
                                .shift = (cb_value & 0b0000_0100) != 0,
                                .alt = (cb_value & 0b0000_1000) != 0,
                                .ctrl = (cb_value & 0b0001_0000) != 0,
                            },
                        },
                        .used = parsed_y.used + 1,
                    },
                };
            },
            else => {
                for (bytes[2..], 2..) |ch, idx| {
                    if (ch >= 0x40 and ch <= 0x7e) {
                        return .{ .invalid = idx + 1 };
                    }
                }
                return .incomplete;
            },
        }
    }

    pub fn init(io: std.Io, nerd_fonts: bool, term_program: ?[]const u8) !Tui {
        const in = std.Io.File.stdin();
        const out = std.Io.File.stdout();
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
            .synchronized_output = shouldEnableSynchronizedOutput(term_program),
        };

        // Enter alternate buffer, hide cursor, and enable mouse reporting.
        try out.writeStreamingAll(io, "\x1b[?1049h\x1b[?25l");
        try out.writeStreamingAll(io, mouseModeSequence(true));

        return Tui{
            .original_termios = original_termios,
            .io = io,
            .in = in,
            .out = out,
            .features = features,
            .cursor_visible = false,
            .cursor_style = .steady_block,
            .frame_active = false,
            .nerd_fonts = nerd_fonts,
        };
    }

    pub fn deinit(self: *Tui) void {
        self.endFrame() catch {};
        self.resetStyle() catch {};
        self.setCursorStyle(.steady_block) catch {};
        self.setCursorVisible(true) catch {};
        self.out.writeStreamingAll(self.io, mouseModeSequence(false)) catch {};
        self.out.writeStreamingAll(self.io, "\x1b[?1049l") catch {};
        posix.tcsetattr(self.in.handle, .FLUSH, self.original_termios) catch {};
    }

    pub fn beginFrame(self: *Tui) !void {
        if (!self.features.synchronized_output or self.frame_active) return;

        try self.out.writeStreamingAll(self.io, "\x1b[?2026h");
        self.frame_active = true;
    }

    pub fn endFrame(self: *Tui) !void {
        if (!self.frame_active) return;

        try self.out.writeStreamingAll(self.io, "\x1b[?2026l");
        self.frame_active = false;
    }

    pub fn clear(self: *Tui) !void {
        try self.out.writeStreamingAll(self.io, "\x1b[0m\x1b[2J\x1b[H");
    }

    pub fn moveCursor(self: *Tui, x: u16, y: u16) !void {
        var buf: [32]u8 = undefined;
        const seq = try std.fmt.bufPrint(&buf, "\x1b[{d};{d}H", .{ y, x });
        _ = try self.out.writeStreamingAll(self.io, seq);
    }

    pub fn setCursorVisible(self: *Tui, visible: bool) !void {
        if (self.cursor_visible == visible) return;

        try self.out.writeStreamingAll(self.io, if (visible) "\x1b[?25h" else "\x1b[?25l");
        self.cursor_visible = visible;
    }

    pub fn setCursorStyle(self: *Tui, style: CursorStyle) !void {
        if (self.cursor_style == style) return;

        try self.out.writeStreamingAll(self.io, cursorStyleSequence(style));
        self.cursor_style = style;
    }

    pub fn print(self: *Tui, comptime fmt: []const u8, args: anytype) !void {
        var buf: [1024]u8 = undefined;
        var w = self.out.writer(self.io, &buf);
        try w.interface.print(fmt, args);
        try w.interface.flush();
    }

    pub fn setStyle(self: *Tui, style: Style) !void {
        var buf: [32]u8 = undefined;
        const seq = try styleSequence(&buf, style);
        try self.out.writeStreamingAll(self.io, seq);
    }

    pub fn resetStyle(self: *Tui) !void {
        try self.out.writeStreamingAll(self.io, "\x1b[0m");
    }

    pub fn writeStyled(self: *Tui, style: Style, text: []const u8) !void {
        try self.setStyle(style);
        defer self.resetStyle() catch {};
        try self.out.writeStreamingAll(self.io, text);
    }

    pub fn printStyled(self: *Tui, style: Style, comptime fmt: []const u8, args: anytype) !void {
        try self.setStyle(style);
        defer self.resetStyle() catch {};
        try self.print(fmt, args);
    }

    pub fn writeHyperlink(self: *Tui, uri: []const u8, label: []const u8) !void {
        var buf: [1024]u8 = undefined;
        var writer = self.out.writer(self.io, &buf);

        try writeHyperlinkTo(&writer.interface, uri, label);
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
        try self.out.writeStreamingAll(self.io, "╭");
        for (0..width - 2) |_| try self.out.writeStreamingAll(self.io, "─");
        try self.out.writeStreamingAll(self.io, "╮");

        // Draw sides
        for (1..height - 1) |i| {
            try self.moveCursor(x, y + @as(u16, @intCast(i)));
            try self.out.writeStreamingAll(self.io, "│");
            try self.moveCursor(x + width - 1, y + @as(u16, @intCast(i)));
            try self.out.writeStreamingAll(self.io, "│");
        }

        // Draw bottom border
        try self.moveCursor(x, y + height - 1);
        try self.out.writeStreamingAll(self.io, "╰");
        for (0..width - 2) |_| try self.out.writeStreamingAll(self.io, "─");
        try self.out.writeStreamingAll(self.io, "╯");
        try self.resetStyle();

        // Draw title
        if (title.len > 0) {
            try self.moveCursor(x + 2, y);
            if (self.nerd_fonts) {
                if (std.mem.startsWith(u8, title, "CPU")) {
                    try self.printStyled(title_style, "┤  {s} ├", .{title});
                } else if (std.mem.startsWith(u8, title, "Memory")) {
                    try self.printStyled(title_style, "┤  {s} ├", .{title});
                } else if (std.mem.startsWith(u8, title, "Disk")) {
                    try self.printStyled(title_style, "┤ 󰋊 {s} ├", .{title});
                } else if (std.mem.startsWith(u8, title, "Network") or std.mem.startsWith(u8, title, "Connections")) {
                    try self.printStyled(title_style, "┤ 󰈀 {s} ├", .{title});
                } else if (std.mem.startsWith(u8, title, "GPU")) {
                    try self.printStyled(title_style, "┤ 󰢮 {s} ├", .{title});
                } else if (std.mem.startsWith(u8, title, "Sensors") or std.mem.startsWith(u8, title, "Thermal")) {
                    try self.printStyled(title_style, "┤  {s} ├", .{title});
                } else if (std.mem.startsWith(u8, title, "Battery")) {
                    try self.printStyled(title_style, "┤ 󰁹 {s} ├", .{title});
                } else if (std.mem.startsWith(u8, title, "Processes") or std.mem.startsWith(u8, title, "Threads")) {
                    try self.printStyled(title_style, "┤ 󰒋 {s} ├", .{title});
                } else if (std.mem.startsWith(u8, title, "Help")) {
                    try self.printStyled(title_style, "┤ 󰋖 {s} ├", .{title});
                } else {
                    try self.printStyled(title_style, "┤ {s} ├", .{title});
                }
            } else {
                try self.printStyled(title_style, "┤ {s} ├", .{title});
            }
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
