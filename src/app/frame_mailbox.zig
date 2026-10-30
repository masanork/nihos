//! One foreground caller and one worker. Never reset until the worker is reaped.
const std = @import("std");
pub const Command = extern struct { id: u32 = 0, operation: u32 = 0, selected: u32 = 0, address: u32 = 0, length: u32 = 0 };
pub const Mailbox = struct {
    phase: std.atomic.Value(u32) = .init(0),
    request: Command = .{},
    sequence: u32 = 0,
    status: i32 = 0,

    pub fn submit(self: *Mailbox, command: Command) ?u32 {
        if (self.phase.load(.acquire) != 0 or self.sequence == std.math.maxInt(u32)) return null;
        self.sequence += 1;
        self.request = command;
        self.request.id = self.sequence;
        self.phase.store(1, .release);
        return self.sequence;
    }
    pub fn take(self: *Mailbox) ?Command {
        if (self.phase.load(.acquire) != 1) return null;
        const command = self.request;
        self.phase.store(3, .release);
        return command;
    }
    pub fn complete(self: *Mailbox, id: u32, status: i32) bool {
        if (self.phase.load(.acquire) != 3 or self.request.id != id) return false;
        self.status = status;
        self.phase.store(2, .release);
        return true;
    }
    pub fn collect(self: *Mailbox, id: u32) ?i32 {
        if (self.phase.load(.acquire) != 2 or self.request.id != id) return null;
        const status = self.status;
        self.request = .{}; // No frame pointer survives a completed callback.
        self.phase.store(0, .release);
        return status;
    }
};

test "in-flight frame cannot be replaced or acknowledged by an old response" {
    var box: Mailbox = .{};
    const first = box.submit(.{ .operation = 2, .address = 0x48000100, .length = 25600 }).?;
    try std.testing.expect(box.submit(.{ .operation = 3 }) == null);
    try std.testing.expect(!box.complete(first, 0));
    try std.testing.expectEqual(@as(u32, 0x48000100), box.take().?.address);
    try std.testing.expect(box.take() == null);
    try std.testing.expect(!box.complete(first + 1, 0));
    try std.testing.expect(box.complete(first, -48));
    try std.testing.expect(box.collect(first + 1) == null);
    try std.testing.expectEqual(@as(?i32, -48), box.collect(first));
    try std.testing.expectEqual(@as(u32, 0), box.request.address);
    const second = box.submit(.{ .operation = 3 }).?;
    _ = box.take();
    try std.testing.expect(!box.complete(first, 0));
    try std.testing.expect(box.complete(second, 0));
    try std.testing.expectEqual(@as(?i32, 0), box.collect(second));
    box.sequence = std.math.maxInt(u32);
    try std.testing.expect(box.submit(.{ .operation = 1 }) == null);
}
