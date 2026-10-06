const std = @import("std");

pub const State = enum { idle, running, ready, failed };

pub const Result = struct {
    download_mbps: f64,
    upload_mbps: f64,
};

pub fn parseResult(allocator: std.mem.Allocator, output: []const u8) !Result {
    const Metrics = struct { dl_throughput: f64, ul_throughput: f64 };
    const parsed = try std.json.parseFromSlice(Metrics, allocator, output, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const metrics = parsed.value;
    if (!std.math.isFinite(metrics.dl_throughput) or !std.math.isFinite(metrics.ul_throughput) or
        metrics.dl_throughput < 0 or metrics.ul_throughput < 0)
        return error.InvalidThroughput;
    return .{ .download_mbps = metrics.dl_throughput / 1_000_000, .upload_mbps = metrics.ul_throughput / 1_000_000 };
}

pub const SpeedTest = struct {
    state: State = .idle,
    result: Result = .{ .download_mbps = 0, .upload_mbps = 0 },
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
        var child = std.process.spawn(io, .{
            .argv = &.{ "/usr/bin/networkQuality", "-c" },
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

    pub fn poll(self: *SpeedTest, allocator: std.mem.Allocator, io: std.Io) bool {
        const child = if (self.child) |*child| child else return false;
        if (self.started.untilNow(io, .awake).toMilliseconds() >= 90_000) {
            self.deinit(io);
            self.state = .failed;
            return true;
        }
        self.readOutput(child.stdout.?.handle) catch {
            self.deinit(io);
            self.state = .failed;
            return true;
        };
        var status: c_int = 0;
        const pid = std.c.waitpid(child.id.?, &status, std.c.W.NOHANG);
        if (pid == 0) return false;
        if (pid < 0) {
            if (std.posix.errno(pid) == .INTR) return false;
            self.deinit(io);
            self.state = .failed;
            return true;
        }
        const output_valid = if (self.readOutput(child.stdout.?.handle)) true else |_| false;
        child.stdout.?.close(io);
        self.child = null;
        self.state = .failed;
        if (status == 0 and output_valid) {
            self.result = parseResult(allocator, self.output[0..self.output_len]) catch return true;
            self.state = .ready;
        }
        return true;
    }

    fn readOutput(self: *SpeedTest, fd: std.posix.fd_t) !void {
        while (self.output_len < self.output.len) {
            const n = std.posix.read(fd, self.output[self.output_len..]) catch |err| {
                if (err == error.WouldBlock) return;
                return err;
            };
            if (n == 0) return;
            self.output_len += n;
        }
        return error.OutputTooLarge;
    }
};
