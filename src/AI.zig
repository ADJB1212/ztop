const std = @import("std");

pub const StreamCallback = *const fn (chunk: ?[*:0]const u8, context: ?*anyopaque) callconv(.c) void;

extern "c" fn fm_is_available() c_int;
extern "c" fn fm_generate_text(prompt: ?[*:0]const u8) ?[*:0]u8;
extern "c" fn fm_generate_diagnosis(prompt: ?[*:0]const u8) ?[*:0]u8;
extern "c" fn fm_stream_text(prompt: ?[*:0]const u8, callback: ?StreamCallback, context: ?*anyopaque) c_int;
extern "c" fn fm_free_string(ptr: ?[*:0]u8) void;

var cached_available: std.atomic.Value(u8) = std.atomic.Value(u8).init(0);

pub fn isAvailable() bool {
    const cached = cached_available.load(.monotonic);
    if (cached != 0) return cached == 2;
    const avail = fm_is_available() != 0;
    cached_available.store(if (avail) 2 else 1, .monotonic);
    return avail;
}

pub fn generateText(allocator: std.mem.Allocator, prompt: [:0]const u8) ![:0]u8 {
    const raw = fm_generate_text(prompt.ptr) orelse return error.GenerationFailed;
    defer fm_free_string(raw);
    const slice = std.mem.span(raw);
    if (std.mem.startsWith(u8, slice, "ERROR:")) return error.GenerationFailed;
    return allocator.dupeZ(u8, slice);
}

pub fn generateDiagnosis(allocator: std.mem.Allocator, prompt: [:0]const u8) ![:0]u8 {
    const raw = fm_generate_diagnosis(prompt.ptr) orelse return error.GenerationFailed;
    defer fm_free_string(raw);
    const slice = std.mem.span(raw);
    return allocator.dupeZ(u8, slice);
}

pub fn streamText(prompt: [:0]const u8, callback: StreamCallback, context: ?*anyopaque) !void {
    const status = fm_stream_text(prompt.ptr, callback, context);
    if (status != 0) return error.StreamingFailed;
}

pub const DiagnosticState = enum { idle, querying, ready, failed };

pub const AsyncQuery = struct {
    lock: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    status: DiagnosticState = .idle,
    use_structured: bool = true,
    last_sig: u64 = 0,
    result_buf: [1024]u8 = undefined,
    result_len: usize = 0,

    pub fn init() AsyncQuery {
        return .{};
    }

    fn acquireLock(self: *AsyncQuery) void {
        while (self.lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    fn releaseLock(self: *AsyncQuery) void {
        self.lock.store(false, .release);
    }

    pub fn request(self: *AsyncQuery, sig: u64, prompt: []const u8) bool {
        self.acquireLock();
        if (self.status == .querying or (self.status == .ready and self.last_sig == sig)) {
            self.releaseLock();
            return false;
        }
        self.status = .querying;
        self.last_sig = sig;
        self.releaseLock();

        const prompt_copy = std.heap.c_allocator.dupeZ(u8, prompt) catch {
            self.acquireLock();
            self.status = .failed;
            self.releaseLock();
            return false;
        };

        const thread = std.Thread.spawn(.{}, worker, .{ self, prompt_copy }) catch {
            std.heap.c_allocator.free(prompt_copy);
            self.acquireLock();
            self.status = .failed;
            self.releaseLock();
            return false;
        };
        thread.detach();
        return true;
    }

    fn worker(self: *AsyncQuery, prompt: [:0]u8) void {
        defer std.heap.c_allocator.free(prompt);
        const res_or_err = if (self.use_structured)
            generateDiagnosis(std.heap.c_allocator, prompt)
        else
            generateText(std.heap.c_allocator, prompt);

        if (res_or_err) |response| {
            defer std.heap.c_allocator.free(response);
            self.acquireLock();
            defer self.releaseLock();
            const copy_len = @min(response.len, self.result_buf.len);
            @memcpy(self.result_buf[0..copy_len], response[0..copy_len]);
            self.result_len = copy_len;
            self.status = .ready;
        } else |_| {
            self.acquireLock();
            self.status = .failed;
            self.releaseLock();
        }
    }

    pub fn getStatus(self: *AsyncQuery) DiagnosticState {
        self.acquireLock();
        defer self.releaseLock();
        return self.status;
    }

    pub fn getResult(self: *AsyncQuery, out_buf: []u8) ?[]const u8 {
        self.acquireLock();
        defer self.releaseLock();
        if (self.status != .ready) return null;
        const len = @min(self.result_len, out_buf.len);
        @memcpy(out_buf[0..len], self.result_buf[0..len]);
        return out_buf[0..len];
    }
};

pub const ParsedDiagnosis = struct {
    explanation: []const u8 = "",
    bottleneck: []const u8 = "",
    advice: []const u8 = "",
};

pub fn parseDiagnosisJson(allocator: std.mem.Allocator, json_str: []const u8) !std.json.Parsed(ParsedDiagnosis) {
    return std.json.parseFromSlice(ParsedDiagnosis, allocator, json_str, .{ .ignore_unknown_fields = true });
}
