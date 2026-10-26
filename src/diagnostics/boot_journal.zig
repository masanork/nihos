//! One-writer bounded byte log. Caller owns interrupt/core serialization.
//! Keeps diagnostic text before a display, filesystem, or allocator exists.
const std = @import("std");
pub fn Journal(comptime capacity: usize) type {
    if (capacity == 0) @compileError("journal requires storage");
    return struct {
        const Self = @This();
        bytes: [capacity]u8 = @splat(0),
        head: usize = 0,
        length: usize = 0,
        dropped: u64 = 0,
        pub fn append(self: *Self, message: []const u8) void {
            for (message) |byte| {
                if (self.length == capacity) {
                    self.bytes[self.head] = byte;
                    self.head = (self.head + 1) % capacity;
                    self.dropped +|= 1;
                } else {
                    self.bytes[(self.head + self.length) % capacity] = byte;
                    self.length += 1;
                }
            }
        }
        /// Two chronological spans, invalidated by the next append.
        pub fn spans(self: *const Self) [2][]const u8 {
            const first = @min(self.length, capacity - self.head);
            return .{ self.bytes[self.head..][0..first], self.bytes[0 .. self.length - first] };
        }
    };
}

test "log survives wrap and large appends in exact byte order" {
    var log = Journal(5){};
    log.append("abc");
    log.append("defghijk");
    const parts = log.spans();
    var copied: [5]u8 = undefined;
    @memcpy(copied[0..parts[0].len], parts[0]);
    @memcpy(copied[parts[0].len..], parts[1]);
    try std.testing.expectEqualStrings("ghijk", &copied);
    try std.testing.expectEqual(@as(u64, 6), log.dropped);
}
