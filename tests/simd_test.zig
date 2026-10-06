const std = @import("std");
const simd = @import("ztop").simd;

test "SIMD ASCII matching agrees with scalar matching for every byte" {
    var a: [33]u8 = undefined;
    var b: [33]u8 = undefined;
    for (0..256) |byte| {
        @memset(&a, @intCast(byte));
        @memset(&b, std.ascii.toLower(@intCast(byte)));
        try std.testing.expect(simd.eqlIgnoreCase(&a, &b));
        for (0..a.len) |mismatch| {
            b[mismatch] +%= 1;
            try std.testing.expectEqual(std.ascii.eqlIgnoreCase(&a, &b), simd.eqlIgnoreCase(&a, &b));
            b[mismatch] -%= 1;
        }
    }
    try std.testing.expect(!simd.eqlIgnoreCase("a", "aa"));
}

test "SIMD substring search handles unaligned matches boundaries and tails" {
    var storage: [130]u8 = undefined;
    for (0..storage.len) |i| storage[i] = @intCast((i * 37 + 11) % 256);
    for (0..4) |alignment| {
        for (0..97) |len| {
            const text = storage[alignment..][0..len];
            for (0..@min(len + 1, 34)) |needle_len| {
                const start = (len - needle_len) / 2;
                var needle: [34]u8 = undefined;
                for (text[start..][0..needle_len], 0..) |byte, i| needle[i] = std.ascii.toUpper(byte);
                const query = needle[0..needle_len];
                try std.testing.expectEqual(std.ascii.findIgnoreCase(text, query) != null, simd.containsIgnoreCase(text, query));
                if (needle_len > 0) {
                    needle[needle_len / 2] +%= 1;
                    try std.testing.expectEqual(std.ascii.findIgnoreCase(text, query) != null, simd.containsIgnoreCase(text, query));
                }
            }
        }
    }
    try std.testing.expect(!simd.containsIgnoreCase("a", "aa"));
    try std.testing.expect(simd.containsIgnoreCase("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaB", "aAb"));
    try std.testing.expect(!simd.containsIgnoreCase("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "aba"));
}

test "SIMD ASCII prefix stops at each non ASCII byte and respects slice bounds" {
    var storage: [81]u8 = @splat('a');
    for (0..4) |alignment| {
        for (0..65) |len| {
            const text = storage[alignment..][0..len];
            try std.testing.expectEqual(len, simd.asciiPrefixLen(text));
            for (0..len) |index| {
                text[index] = 0x80;
                try std.testing.expectEqual(index, simd.asciiPrefixLen(text));
                text[index] = 'a';
            }
        }
    }
}
