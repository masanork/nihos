//! Bounded serial commands. The path is borrowed only until the next feed;
//! the trusted service copies it before returning from submit.
const std = @import("std");
pub const Command = struct { path: []const u8 };
pub const Parser = struct {
    buffer: [517]u8 = @splat(0),
    length: usize = 0,
    collecting: bool = false,
    overflow: bool = false,
    pub fn feed(self: *Parser, byte: u8, result: *?Command) bool {
        result.* = null;
        if (!self.collecting) {
            if (byte != ':') return false;
            self.collecting = true;
            self.length = 0;
            self.overflow = false;
            return true;
        }
        if (byte == 0x1b) {
            self.collecting = false;
            return false;
        }
        if (byte == '\r' or byte == '\n') {
            self.collecting = false;
            if (!self.overflow) {
                const line = self.buffer[0..self.length];
                if (std.mem.eql(u8, line, "storage")) result.* = .{ .path = "" } else if (std.mem.startsWith(u8, line, "read ") and line.len > 5) {
                    result.* = .{ .path = line[5..] };
                }
            }
        } else if (byte < 0x20 or byte == 0x7f) {
            self.overflow = true;
        } else if (self.length < self.buffer.len and !self.overflow) {
            self.buffer[self.length] = byte;
            self.length += 1;
        } else self.overflow = true;
        return true;
    }
};
test "only complete bounded paths dispatch, escape and overflow cancel" {
    var parser: Parser = .{};
    var result: ?Command = null;
    try std.testing.expect(!parser.feed('a', &result));
    for (":read Memo.txt") |byte| {
        try std.testing.expect(parser.feed(byte, &result));
        try std.testing.expect(result == null);
    }
    _ = parser.feed('\n', &result);
    try std.testing.expectEqualStrings("Memo.txt", result.?.path);
    for (":storage\r") |byte| _ = parser.feed(byte, &result);
    try std.testing.expectEqual(@as(usize, 0), result.?.path.len);
    for (":read ") |byte| _ = parser.feed(byte, &result);
    for (0..512) |_| _ = parser.feed('x', &result);
    _ = parser.feed('\n', &result);
    try std.testing.expectEqual(@as(usize, 512), result.?.path.len);
    for (":read ") |byte| _ = parser.feed(byte, &result);
    for (0..513) |_| _ = parser.feed('x', &result);
    _ = parser.feed('\n', &result);
    try std.testing.expect(result == null);
    for (":read ") |byte| _ = parser.feed(byte, &result);
    try std.testing.expect(!parser.feed(0x1b, &result));
    for (":read bad\x00name\n") |byte| _ = parser.feed(byte, &result);
    try std.testing.expect(result == null);
}
