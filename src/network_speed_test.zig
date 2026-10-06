const std = @import("std");

pub const State = enum { idle, running, ready, failed };

pub const Result = struct {
    download_mbps: f64,
    upload_mbps: f64,
};

pub const Measurements = struct {
    download_mbps: ?f64 = null,
    upload_mbps: ?f64 = null,

    fn result(self: Measurements) !Result {
        return .{
            .download_mbps = self.download_mbps orelse return error.MissingField,
            .upload_mbps = self.upload_mbps orelse return error.MissingField,
        };
    }
};

fn parseMbps(output: []const u8, label: []const u8) !?f64 {
    const start = (std.mem.indexOf(u8, output, label) orelse return null) + label.len;
    const end = std.mem.indexOf(u8, output[start..], " Mbps") orelse return error.InvalidThroughput;
    const value = std.fmt.parseFloat(f64, output[start..][0..end]) catch return error.InvalidThroughput;
    if (!std.math.isFinite(value) or value < 0) return error.InvalidThroughput;
    return value;
}

pub fn parseProgress(output: []const u8) !Measurements {
    return .{
        .download_mbps = try parseMbps(output, "Downlink: "),
        .upload_mbps = try parseMbps(output, "Uplink: "),
    };
}

pub fn parseResult(output: []const u8) !Result {
    return (Measurements{
        .download_mbps = try parseMbps(output, "Downlink capacity: "),
        .upload_mbps = try parseMbps(output, "Uplink capacity: "),
    }).result();
}

pub const SpeedTest = struct {
    state: State = .idle,
    result: Result = .{ .download_mbps = 0, .upload_mbps = 0 },
    live: Measurements = .{},
    final: Measurements = .{},
    child: ?std.process.Child = null,
    output: [16384]u8 = undefined,
    output_len: usize = 0,
    started: std.Io.Timestamp = .zero,

    pub fn deinit(self: *SpeedTest, io: std.Io) void {
        if (self.child) |*child| child.kill(io);
        self.child = null;
    }

    pub fn start(self: *SpeedTest, io: std.Io) void {
        if (self.state == .running) return;
        self.state = .failed;
        self.output_len = 0;
        self.live = .{};
        self.final = .{};
        var child = std.process.spawn(io, .{
            .argv = &.{ "/usr/bin/script", "-q", "/dev/null", "/usr/bin/networkQuality", "-M", "5" },
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .ignore,
        }) catch return;
        const fd = child.stdout.?.handle;
        const flags = std.c.fcntl(fd, std.c.F.GETFL);
        const nonblock: std.c.O = .{ .NONBLOCK = true };
        if (flags < 0 or std.c.fcntl(fd, std.c.F.SETFL, flags | @as(c_int, @bitCast(nonblock))) < 0) {
            child.kill(io);
            return;
        }
        self.child = child;
        self.started = std.Io.Clock.now(.awake, io);
        self.state = .running;
    }

    pub fn poll(self: *SpeedTest, io: std.Io) bool {
        const child = if (self.child) |*child| child else return false;
        if (self.started.untilNow(io, .awake).toMilliseconds() >= 90_000) {
            self.deinit(io);
            self.state = .failed;
            return true;
        }
        const changed = self.readOutput(child.stdout.?.handle) catch {
            self.deinit(io);
            self.state = .failed;
            return true;
        };
        var status: c_int = 0;
        const pid = std.c.waitpid(child.id.?, &status, std.c.W.NOHANG);
        if (pid == 0) return changed;
        if (pid < 0) {
            if (std.posix.errno(pid) == .INTR) return changed;
            self.deinit(io);
            self.state = .failed;
            return true;
        }
        const output_valid = if (self.readOutput(child.stdout.?.handle)) |_| true else |_| false;
        child.stdout.?.close(io);
        self.child = null;
        self.state = .failed;
        if (status == 0 and output_valid) {
            _ = self.consumeLine(self.output[0..self.output_len]);
            self.result = self.final.result() catch return true;
            self.state = .ready;
        }
        return true;
    }

    fn consumeLine(self: *SpeedTest, line: []const u8) bool {
        const progress = parseProgress(line) catch return false;
        var changed = false;
        if (progress.download_mbps) |value| {
            changed = self.live.download_mbps != value;
            self.live.download_mbps = value;
        }
        if (progress.upload_mbps) |value| {
            changed = changed or self.live.upload_mbps != value;
            self.live.upload_mbps = value;
        }
        if (parseMbps(line, "Downlink capacity: ") catch null) |value| self.final.download_mbps = value;
        if (parseMbps(line, "Uplink capacity: ") catch null) |value| self.final.upload_mbps = value;
        return changed;
    }

    fn readOutput(self: *SpeedTest, fd: std.posix.fd_t) !bool {
        var changed = false;
        while (self.output_len < self.output.len) {
            const n = std.posix.read(fd, self.output[self.output_len..]) catch |err| {
                if (err == error.WouldBlock) return changed;
                return err;
            };
            if (n == 0) return changed;
            self.output_len += n;
            var line_start: usize = 0;
            for (self.output[0..self.output_len], 0..) |byte, i| {
                if (byte == '\r' or byte == '\n') {
                    changed = self.consumeLine(self.output[line_start..i]) or changed;
                    line_start = i + 1;
                }
            }
            std.mem.copyForwards(u8, &self.output, self.output[line_start..self.output_len]);
            self.output_len -= line_start;
        }
        return error.OutputTooLarge;
    }
};
