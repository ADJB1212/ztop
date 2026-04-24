const std = @import("std");
const bindings = @import("bindings.zig");
const c = bindings.c;

pub fn copyCFStringLikeValue(value_ref: *const anyopaque, dest: []u8) ?usize {
    if (dest.len == 0) return null;

    const type_id = c.CFGetTypeID(value_ref);
    if (type_id == c.CFStringGetTypeID()) {
        if (c.CFStringGetCString(@ptrCast(value_ref), dest.ptr, @intCast(dest.len), c.kCFStringEncodingUTF8) == 0) {
            return null;
        }
        return std.mem.indexOfScalar(u8, dest, 0) orelse dest.len;
    }

    if (type_id == c.CFDataGetTypeID()) {
        const data_ref: c.CFDataRef = @ptrCast(value_ref);
        const bytes = c.CFDataGetBytePtr(data_ref);
        const b = bytes orelse return null;

        const data_len: usize = @intCast(@max(c.CFDataGetLength(data_ref), 0));
        const bounded_len = @min(data_len, dest.len - 1);
        if (bounded_len == 0) return null;

        @memcpy(dest[0..bounded_len], b[0..bounded_len]);
        return std.mem.indexOfScalar(u8, dest[0..bounded_len], 0) orelse bounded_len;
    }

    return null;
}

pub fn readServiceNumber(service: c.io_registry_entry_t, key: c.CFStringRef) ?u64 {
    const value_ref = c.IORegistryEntryCreateCFProperty(service, key, null, 0) orelse return null;
    defer c.CFRelease(value_ref);
    return getCFNumberValue(value_ref);
}

pub fn getCFDictionaryU64(dict: c.CFDictionaryRef, key: c.CFStringRef) u64 {
    const value = c.CFDictionaryGetValue(dict, key) orelse return 0;
    return getCFNumberValue(value) orelse 0;
}

pub fn getCFDictionaryNumber(dict: c.CFDictionaryRef, key: c.CFStringRef) ?u64 {
    const value = c.CFDictionaryGetValue(dict, key) orelse return null;
    return getCFNumberValue(value);
}

pub fn getCFDictionaryNumberFromCString(dict: c.CFDictionaryRef, key_ptr: [*:0]const u8) ?u64 {
    const key = c.CFStringCreateWithCString(null, key_ptr, c.kCFStringEncodingUTF8) orelse return null;
    defer c.CFRelease(key);
    return getCFDictionaryNumber(dict, key);
}

pub fn getCFDictionaryValueFromCString(dict: c.CFDictionaryRef, key_ptr: [*:0]const u8) ?*const anyopaque {
    const key = c.CFStringCreateWithCString(null, key_ptr, c.kCFStringEncodingUTF8) orelse return null;
    defer c.CFRelease(key);
    return c.CFDictionaryGetValue(dict, key);
}

pub fn getCFNumberValue(value: *const anyopaque) ?u64 {
    if (c.CFGetTypeID(value) != c.CFNumberGetTypeID()) return null;

    var raw: i64 = 0;
    if (c.CFNumberGetValue(@ptrCast(value), c.kCFNumberSInt64Type, &raw) == 0 or raw < 0) return null;

    return @intCast(raw);
}

pub fn getCFSignedNumberValue(value: *const anyopaque) ?i64 {
    if (c.CFGetTypeID(value) != c.CFNumberGetTypeID()) return null;

    var raw: i64 = 0;
    if (c.CFNumberGetValue(@ptrCast(value), c.kCFNumberSInt64Type, &raw) == 0) return null;

    return raw;
}

pub fn getCFDictionarySignedNumberFromCString(dict: c.CFDictionaryRef, key_ptr: [*:0]const u8) ?i64 {
    const key = c.CFStringCreateWithCString(null, key_ptr, c.kCFStringEncodingUTF8) orelse return null;
    defer c.CFRelease(key);
    const value = c.CFDictionaryGetValue(dict, key) orelse return null;
    return getCFSignedNumberValue(value);
}
