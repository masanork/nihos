const std = @import("std");
const Ring = @import("spsc_ring.zig").SpscRing(u32, 3);
const Channel = @import("spsc_channel.zig").SpscChannel(Ring, Events);

const Action = union(enum) { stale, push: u32, pop, fail: i32 };
const Events = struct {
    pub const Handle = u16;
    ring: ?*Ring = null,
    actions: []const Action = &.{},
    waits: usize = 0,
    posts: usize = 0,
    post_status: i32 = 0,
    last_target: u16 = 0,
    last_bits: u32 = 0,
    last_count: usize = 0,

    pub fn post(self: *Events, target: Handle, bits: u32) i32 {
        self.posts += 1;
        self.last_target = target;
        self.last_bits = bits;
        self.last_count = self.ring.?.countApprox();
        return self.post_status;
    }

    pub fn wait(self: *Events, mask: u32) union(enum) { received: u32, failed: i32 } {
        if (self.waits == self.actions.len) return .{ .failed = -99 };
        const action = self.actions[self.waits];
        self.waits += 1;
        switch (action) {
            .stale => {},
            .push => |value| if (!self.ring.?.tryPush(value)) return .{ .failed = -98 },
            .pop => if (self.ring.?.tryPop() == null) return .{ .failed = -97 },
            .fail => |code| return .{ .failed = code },
        }
        return .{ .received = mask };
    }
};

fn init() Channel {
    return Channel.init(.{}, 10, 20, 1, 2).?;
}

test "channel publishes data and released space before notifying the peer" {
    var channel = init();
    channel.events.ring = &channel.ring;
    try std.testing.expectEqual(Channel.ReceiveResult.empty, channel.tryReceive());
    for (0..3) |index| try std.testing.expectEqual(Channel.SendResult.sent, channel.trySend(@intCast(index)));
    try std.testing.expectEqual(@as(u16, 20), channel.events.last_target);
    try std.testing.expectEqual(@as(u32, 1), channel.events.last_bits);
    try std.testing.expectEqual(@as(usize, 3), channel.events.last_count);
    try std.testing.expectEqual(Channel.SendResult.full, channel.trySend(100));
    try std.testing.expectEqual(@as(usize, 3), channel.events.posts);
    for (0..3) |expected| {
        const received = channel.tryReceive().item;
        try std.testing.expectEqual(@as(u32, @intCast(expected)), received.value);
        try std.testing.expectEqual(@as(i32, 0), received.space_notification);
    }
    try std.testing.expectEqual(@as(u16, 10), channel.events.last_target);
    try std.testing.expectEqual(@as(u32, 2), channel.events.last_bits);
    try std.testing.expectEqual(@as(usize, 0), channel.events.last_count);
    try std.testing.expectEqual(@as(usize, 0), channel.events.waits);
}

test "receive tolerates stale events and publication in the check to wait gap" {
    var channel = init();
    channel.events.ring = &channel.ring;
    channel.events.actions = &.{ .stale, .{ .push = 77 } };
    try std.testing.expectEqual(@as(u32, 77), channel.receive().item.value);
    try std.testing.expectEqual(@as(usize, 2), channel.events.waits);
    try std.testing.expect(channel.ring.tryPop() == null);
}

test "send rechecks full queue after stale events and release before wait" {
    var channel = init();
    channel.events.ring = &channel.ring;
    for (0..3) |index| try std.testing.expectEqual(Channel.SendResult.sent, channel.trySend(@intCast(index)));
    channel.events.actions = &.{ .stale, .pop };
    try std.testing.expectEqual(Channel.SendResult.sent, channel.send(3));
    try std.testing.expectEqual(@as(usize, 2), channel.events.waits);
    for (1..4) |expected| try std.testing.expectEqual(@as(u32, @intCast(expected)), channel.ring.tryPop().?);
}

test "post failure reports committed ownership on both channel directions" {
    var channel = init();
    channel.events.ring = &channel.ring;
    channel.events.post_status = -3;
    try std.testing.expectEqual(@as(i32, -3), channel.send(42).published_unnotified);
    try std.testing.expectEqual(@as(usize, 1), channel.ring.countApprox());
    const received = channel.receive().item;
    try std.testing.expectEqual(@as(u32, 42), received.value);
    try std.testing.expectEqual(@as(i32, -3), received.space_notification);
    try std.testing.expect(channel.ring.tryPop() == null);
}

test "wait failure leaves an uncommitted send and empty receive unchanged" {
    var channel = init();
    channel.events.ring = &channel.ring;
    channel.events.actions = &.{.{ .fail = -4 }};
    try std.testing.expectEqual(@as(i32, -4), channel.receive().wait_failed);
    for (0..3) |index| try std.testing.expectEqual(Channel.SendResult.sent, channel.trySend(@intCast(index)));
    channel.events.waits = 0;
    try std.testing.expectEqual(@as(i32, -4), channel.send(100).wait_failed);
    for (0..3) |expected| try std.testing.expectEqual(@as(u32, @intCast(expected)), channel.ring.tryPop().?);
    try std.testing.expect(channel.ring.tryPop() == null);
}

test "channel event reservations require one nonzero bit per endpoint" {
    try std.testing.expect(Channel.init(.{}, 10, 20, 0, 2) == null);
    try std.testing.expect(Channel.init(.{}, 10, 20, 1, 3) == null);
    try std.testing.expect(Channel.init(.{}, 10, 20, 0x8000_0000, 2) != null);
}
