const std = @import("std");
const bindings = @import("bindings.zig");
const c = bindings.c;

var static_argmax_buf: [64 * 1024]u8 = undefined;

pub fn readLaunchCommand(pid: c_int, dest: []u8) ![]const u8 {
    var argmax: usize = 0;
    var argmax_len: usize = @sizeOf(usize);
    if (bindings.sysctlbyname("kern.argmax", &argmax, &argmax_len, null, 0) == 0 and argmax > @sizeOf(c_int) and argmax <= static_argmax_buf.len) {
        const buf = try std.heap.page_allocator.alloc(u8, argmax);
        defer std.heap.page_allocator.free(buf);

        var mib = [_]c_int{ c.CTL_KERN, c.KERN_PROCARGS2, pid };
        var len = argmax;
        if (c.sysctl(&mib, mib.len, &static_argmax_buf, &len, null, 0) == 0) {
            if (parseKernProcArgs(static_argmax_buf[0..len], dest)) |cmd| return cmd;
        }
    }

    var path_buf: [std.fs.max_path_bytes]u8 = std.mem.zeroes([std.fs.max_path_bytes]u8);
    const path_len = bindings.proc_pidpath(pid, &path_buf, @intCast(path_buf.len));
    if (path_len > 0) {
        const bounded_len: usize = @intCast(@min(path_len, dest.len));
        @memcpy(dest[0..bounded_len], path_buf[0..bounded_len]);
        return dest[0..bounded_len];
    }

    return dest[0..0];
}

fn parseKernProcArgs(raw: []const u8, dest: []u8) ?[]const u8 {
    if (raw.len <= @sizeOf(c_int)) return null;

    const argc = std.mem.readInt(c_int, raw[0..@sizeOf(c_int)], @import("builtin").cpu.arch.endian());
    if (argc <= 0) return null;

    var offset: usize = @sizeOf(c_int);
    while (offset < raw.len and raw[offset] != 0) : (offset += 1) {}
    while (offset < raw.len and raw[offset] == 0) : (offset += 1) {}

    var write_idx: usize = 0;
    var args_seen: c_int = 0;
    while (offset < raw.len and args_seen < argc) : (args_seen += 1) {
        const arg_start = offset;
        while (offset < raw.len and raw[offset] != 0) : (offset += 1) {}
        const arg = raw[arg_start..offset];
        if (arg.len > 0) {
            if (write_idx > 0 and write_idx < dest.len) {
                dest[write_idx] = ' ';
                write_idx += 1;
            }

            const available = dest.len -| write_idx;
            if (available == 0) break;

            const copy_len = @min(arg.len, available);
            @memcpy(dest[write_idx .. write_idx + copy_len], arg[0..copy_len]);
            write_idx += copy_len;
            if (copy_len < arg.len) break;
        }

        while (offset < raw.len and raw[offset] == 0) : (offset += 1) {}
    }

    if (write_idx == 0) return null;
    return dest[0..write_idx];
}
