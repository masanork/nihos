const std = @import("std");
const scheduler = @import("scheduler.zig");
const events = @import("remote_events.zig");
const Ring = @import("spsc_ring.zig").SpscRing(events.Notification, 3);
const Inbox = events.Inbox(Ring);
const Doorbell = struct {
    inbox: *Inbox,
    rings: u32 = 0,
    published: usize = 0,

    pub fn raise(self: *Doorbell) void {
        self.rings += 1;
        self.published = self.inbox.ring.countApprox();
    }
};

fn notification(handle: scheduler.TaskHandle, bits: u32) events.Notification {
    return .{ .slot = handle.slot, .generation = handle.generation, .bits = bits };
}

test "remote event publishes before doorbell and full or invalid posts do not ring" {
    var inbox = Inbox{};
    var doorbell = Doorbell{ .inbox = &inbox };
    const handle = scheduler.TaskHandle{ .slot = 0, .generation = 1 };
    try std.testing.expectEqual(events.PostResult.invalid, inbox.post(notification(handle, 0), &doorbell));
    try std.testing.expectEqual(events.PostResult.invalid, inbox.post(.{ .slot = 0, .generation = 0, .bits = 1 }, &doorbell));
    for (1..4) |bits| try std.testing.expectEqual(events.PostResult.queued, inbox.post(notification(handle, @intCast(bits)), &doorbell));
    try std.testing.expectEqual(@as(usize, 3), doorbell.published);
    try std.testing.expectEqual(events.PostResult.full, inbox.post(notification(handle, 8), &doorbell));
    try std.testing.expectEqual(@as(u32, 3), doorbell.rings);
}

test "remote notifications register before wait and wake after registration" {
    var inbox = Inbox{};
    var doorbell = Doorbell{ .inbox = &inbox };
    var policy = scheduler.Scheduler(2, 2){};
    const target = policy.add(0).?;
    const idle = policy.add(1).?;
    _ = policy.schedule().?;
    _ = inbox.post(notification(target, 0x8000_0001), &doorbell);
    const first = inbox.drain(&policy, 3, &doorbell);
    try std.testing.expectEqual(@as(u32, 1), first.delivered);
    try std.testing.expectEqual(@as(u32, 0), first.woken);
    try std.testing.expectEqual(@as(u32, 0x8000_0000), policy.waitEvents(target, 0x8000_0000).?.received);
    _ = policy.waitEvents(target, 2).?;
    try std.testing.expectEqual(idle, policy.schedule().?);
    _ = inbox.post(notification(target, 2), &doorbell);
    const second = inbox.drain(&policy, 3, &doorbell);
    try std.testing.expectEqual(@as(u32, 1), second.woken);
    try std.testing.expectEqual(target, policy.schedule().?);
    try std.testing.expectEqual(@as(?u32, 2), policy.takeEventResult(target));
    try std.testing.expectEqual(@as(u32, 1), policy.waitEvents(target, 1).?.received);
}

test "bounded remote drain retains later records and keeps a ready reply" {
    var inbox = Inbox{};
    var doorbell = Doorbell{ .inbox = &inbox };
    var policy = scheduler.Scheduler(2, 2){};
    const target = policy.add(0).?;
    _ = policy.add(1).?;
    _ = policy.schedule().?;
    _ = policy.waitEvents(target, 1).?;
    _ = policy.schedule().?;
    _ = inbox.post(notification(target, 1), &doorbell);
    _ = inbox.post(notification(target, 3), &doorbell);
    const first = inbox.drain(&policy, 1, &doorbell);
    try std.testing.expectEqual(@as(u32, 1), first.woken);
    try std.testing.expectEqual(@as(usize, 1), inbox.ring.countApprox());
    try std.testing.expectEqual(@as(u32, 3), doorbell.rings);
    const second = inbox.drain(&policy, 1, &doorbell);
    try std.testing.expectEqual(@as(u32, 3), doorbell.rings);
    try std.testing.expectEqual(@as(u32, 1), second.delivered);
    try std.testing.expectEqual(@as(u32, 0), second.woken);
    try std.testing.expectEqual(target, policy.schedule().?);
    try std.testing.expectEqual(@as(?u32, 1), policy.takeEventResult(target));
    try std.testing.expectEqual(@as(u32, 3), policy.waitEvents(target, 3).?.received);
}

test "queued old generations and completed targets are dropped on owner delivery" {
    var inbox = Inbox{};
    var doorbell = Doorbell{ .inbox = &inbox };
    var policy = scheduler.Scheduler(2, 2){};
    const old = policy.add(0).?;
    const idle = policy.add(1).?;
    _ = policy.schedule().?;
    _ = inbox.post(notification(old, 1), &doorbell);
    _ = policy.exitCurrent(17).?;
    try std.testing.expect(policy.remove(old));
    const replacement = policy.add(0).?;
    _ = inbox.post(notification(replacement, 2), &doorbell);
    const result = inbox.drain(&policy, 3, &doorbell);
    try std.testing.expectEqual(@as(u32, 1), result.rejected);
    try std.testing.expectEqual(@as(u32, 1), result.delivered);
    try std.testing.expectEqual(@as(u32, 2), policy.snapshot(replacement).?.pending_events);
    try std.testing.expectEqual(replacement, policy.schedule().?);
    _ = policy.exitCurrent(19).?;
    try std.testing.expectEqual(idle, policy.schedule().?);
    _ = inbox.post(notification(replacement, 4), &doorbell);
    try std.testing.expectEqual(@as(u32, 1), inbox.drain(&policy, 3, &doorbell).rejected);
}
