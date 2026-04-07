pub const EditAction = enum {
    none,
    submit,
    cancel,
};

pub fn applyInputBytes(dest: []u8, len: *usize, input: []const u8) EditAction {
    for (input) |ch| {
        switch (ch) {
            '\r', '\n' => return .submit,
            '\x1b' => return .cancel,
            127, '\x08' => {
                if (len.* > 0) len.* = len.* - 1;
            },
            else => if (ch >= 32 and ch <= 126 and len.* < dest.len) {
                dest[len.*] = ch;
                len.* += 1;
            },
        }
    }

    return .none;
}
