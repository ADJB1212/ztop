const std = @import("std");

const lanes = 16;
const Bytes = @Vector(lanes, u8);

fn lower(bytes: Bytes) Bytes {
    const uppercase = bytes -% @as(Bytes, @splat('A')) <= @as(Bytes, @splat('Z' - 'A'));
    return @select(u8, uppercase, bytes | @as(Bytes, @splat(0x20)), bytes);
}

pub fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var offset: usize = 0;
    while (a.len - offset >= lanes) : (offset += lanes) {
        if (@reduce(.Or, lower(a[offset..][0..lanes].*) != lower(b[offset..][0..lanes].*))) return false;
    }
    return std.ascii.eqlIgnoreCase(a[offset..], b[offset..]);
}

pub fn containsIgnoreCase(text: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > text.len) return false;
    const count = text.len - needle.len + 1;
    const first: Bytes = @splat(std.ascii.toLower(needle[0]));
    const last: Bytes = @splat(std.ascii.toLower(needle[needle.len - 1]));
    var offset: usize = 0;
    while (count - offset >= lanes) : (offset += lanes) {
        const starts = lower(text[offset..][0..lanes].*) == first;
        const ends = lower(text[offset + needle.len - 1 ..][0..lanes].*) == last;
        var candidates = @as(u16, @bitCast(starts)) & @as(u16, @bitCast(ends));
        while (candidates != 0) : (candidates &= candidates - 1) {
            const index = offset + @ctz(candidates);
            if (eqlIgnoreCase(text[index..][0..needle.len], needle)) return true;
        }
    }
    return std.ascii.findIgnoreCase(text[offset..], needle) != null;
}

pub fn asciiPrefixLen(text: []const u8) usize {
    var offset: usize = 0;
    while (text.len - offset >= lanes) : (offset += lanes) {
        const bytes: Bytes = text[offset..][0..lanes].*;
        if (@reduce(.Or, bytes) >= 128) break;
    }
    while (offset < text.len and text[offset] < 128) : (offset += 1) {}
    return offset;
}
