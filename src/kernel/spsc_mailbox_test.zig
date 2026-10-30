const std = @import("std");
const SpscMailbox = @import("spsc_mailbox.zig").SpscMailbox;
const SpscChannel = @import("spsc_channel.zig").SpscChannel;

test "mailbox copies one item and refuses full or retired storage" {
    const Item = struct { bytes: [192]u8 };
    var slot = Item{ .bytes = @splat(0xcc) };
    var mailbox = SpscMailbox(Item).init();
    var caller = Item{ .bytes = @splat(7) };
    try std.testing.expect(!mailbox.tryPush(caller));
    try std.testing.expect(mailbox.tryPop() == null);
    try std.testing.expect(mailbox.bindStorage(&slot));
    try std.testing.expect(!mailbox.bindStorage(&slot));
    try std.testing.expect(mailbox.tryPush(caller));
    @memset(&caller.bytes, 0xff);
    try std.testing.expect(!mailbox.tryPush(caller));
    try std.testing.expect(mailbox.detachAfterQuiescence() == null);
    const received = mailbox.tryPop().?;
    try std.testing.expect(std.mem.allEqual(u8, &received.bytes, 7));
    try std.testing.expect(mailbox.tryPush(caller));
    try std.testing.expect(std.mem.allEqual(u8, &received.bytes, 7));
    _ = mailbox.tryPop();
    try std.testing.expect(mailbox.detachAfterQuiescence().? == &slot);
    @memset(&slot.bytes, 0xa5);
    try std.testing.expect(!mailbox.bindStorage(&slot));
    try std.testing.expect(!mailbox.tryPush(caller));
    try std.testing.expect(mailbox.tryPop() == null);
    try std.testing.expect(mailbox.detachAfterQuiescence() == null);
    try std.testing.expect(std.mem.allEqual(u8, &slot.bytes, 0xa5));
    try std.testing.expectEqual(@as(usize, 0), mailbox.countApprox());
}

test "mailbox refuses payload storage overlapping either publication cursor" {
    var mailbox = SpscMailbox(usize).init();
    var slot: usize = 0;
    try std.testing.expect(!mailbox.bindStorage(&mailbox.write.raw));
    try std.testing.expect(!mailbox.bindStorage(&mailbox.read.raw));
    try std.testing.expect(mailbox.bindStorage(&slot));
    try std.testing.expect(mailbox.tryPush(77));
    try std.testing.expectEqual(@as(usize, 77), mailbox.tryPop().?);
    try std.testing.expect(mailbox.detachAfterQuiescence().? == &slot);
}

// Yield on backpressure so both host threads progress under single-CPU tracing.
test "mailbox counters wrap under full backpressure across host threads" {
    const Mailbox = SpscMailbox(u32);
    var slot: u32 = 0;
    var mailbox = Mailbox.init();
    try std.testing.expect(mailbox.bindStorage(&slot));
    const near_wrap = std.math.maxInt(usize) - 1;
    mailbox.write.store(near_wrap, .monotonic);
    mailbox.read.store(near_wrap, .monotonic);
    const Producer = struct {
        fn run(target: *Mailbox) void {
            for (0..100_000) |index| {
                while (!target.tryPush(@intCast(index))) std.Thread.yield() catch {};
            }
        }
    };
    const producer = try std.Thread.spawn(.{}, Producer.run, .{&mailbox});
    var ordered = true;
    for (0..100_000) |expected| {
        const item = while (true) {
            if (mailbox.tryPop()) |value| break value;
            std.Thread.yield() catch {};
        };
        if (item != expected) ordered = false;
    }
    producer.join();
    try std.testing.expect(ordered);
    try std.testing.expect(mailbox.detachAfterQuiescence().? == &slot);
}

const Events = struct {
    pub const Handle = u8;
    mailbox: ?*SpscMailbox(u32) = null,
    waits: usize = 0,
    posts: usize = 0,
    pub fn post(self: *Events, _: Handle, _: u32) i32 {
        self.posts += 1;
        return 0;
    }
    pub fn wait(self: *Events, mask: u32) union(enum) { received: u32, failed: i32 } {
        self.waits += 1;
        if (self.waits == 2 and self.mailbox.?.tryPop() == null) return .{ .failed = -1 };
        return .{ .received = mask };
    }
};

test "one-slot channel rechecks stale wake before reusing the released item" {
    const Channel = SpscChannel(SpscMailbox(u32), Events);
    var slot: u32 = 0;
    var channel = Channel.init(.{}, 1, 2, 4, 8).?;
    try std.testing.expect(channel.ring.bindStorage(&slot));
    channel.events.mailbox = &channel.ring;
    try std.testing.expectEqual(Channel.SendResult.sent, channel.trySend(41));
    try std.testing.expectEqual(Channel.SendResult.full, channel.trySend(42));
    try std.testing.expectEqual(Channel.SendResult.sent, channel.send(42));
    try std.testing.expectEqual(@as(usize, 2), channel.events.waits);
    try std.testing.expectEqual(@as(usize, 2), channel.events.posts);
    try std.testing.expectEqual(@as(u32, 42), channel.tryReceive().item.value);
    try std.testing.expect(channel.ring.detachAfterQuiescence().? == &slot);
}
