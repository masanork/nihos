//! Translate a free-running counter into scheduler ticks without drift.
//! A delayed interrupt advances elapsed time once, rather than replaying an
//! interrupt for each missed period. Callers supply serialized counter reads.

const std = @import("std");

pub const Advance = struct {
    elapsed_ticks: u64,
    next_deadline: u64,
};

pub const TickClock = struct {
    period: u32,
    accounted_ticks: u64 = 0,
    last_counter: u64 = 0,

    pub fn init(period: u32) ?TickClock {
        if (period == 0) return null;
        return .{ .period = period };
    }

    /// Counter wrap/reset and arithmetic overflow fail without changing time.
    pub fn observe(self: *TickClock, counter: u64) ?Advance {
        if (counter < self.last_counter) return null;
        const total = counter / self.period;
        const following = std.math.add(u64, total, 1) catch return null;
        const deadline = std.math.mul(u64, following, self.period) catch return null;
        const elapsed = total - self.accounted_ticks;
        self.accounted_ticks = total;
        self.last_counter = counter;
        return .{ .elapsed_ticks = elapsed, .next_deadline = deadline };
    }

    /// Serialized owner refresh. Arming can cross the deadline itself; retry
    /// at most four times, accounting each elapsed tick only once (ADR 0007).
    pub fn refresh(self: *TickClock, policy: anytype, timer: anytype, armed: bool) bool {
        for (0..4) |_| {
            const now = timer.counter() orelse return false;
            const advance = self.observe(now) orelse return false;
            if (!policy.elapse(advance.elapsed_ticks)) return false;
            if (!armed) return true;
            if (!timer.armAt(advance.next_deadline)) return false;
            const after = timer.counter() orelse return false;
            if (after < now) return false;
            if (after < advance.next_deadline) return true;
            if (!timer.clearPending()) return false;
        }
        return false;
    }
};

test "late delivery catches up elapsed ticks and retains the original phase" {
    var clock = TickClock.init(1000).?;
    const late = clock.observe(3501).?;
    try std.testing.expectEqual(@as(u64, 3), late.elapsed_ticks);
    try std.testing.expectEqual(@as(u64, 4000), late.next_deadline);
    const early = clock.observe(3999).?;
    try std.testing.expectEqual(@as(u64, 0), early.elapsed_ticks);
    const next = clock.observe(4002).?;
    try std.testing.expectEqual(@as(u64, 1), next.elapsed_ticks);
    try std.testing.expectEqual(@as(u64, 5000), next.next_deadline);
    try std.testing.expectEqual(@as(u64, 4), clock.accounted_ticks);
}

test "bad clock input fails without changing accounted time" {
    try std.testing.expect(TickClock.init(0) == null);
    var clock = TickClock.init(1000).?;
    _ = clock.observe(4000).?;
    try std.testing.expect(clock.observe(3999) == null);
    try std.testing.expect(clock.observe(std.math.maxInt(u64)) == null);
    try std.testing.expectEqual(@as(u64, 4), clock.accounted_ticks);
    try std.testing.expectEqual(@as(u64, 4000), clock.last_counter);
}

const RefreshFixture = struct {
    counter_value: u64 = 900,
    arm_delay: u64 = 1100,
    arms: u32 = 0,
    clears: u32 = 0,
    ticks: u64 = 0,
    fail_arm: bool = false,
    fail_clear: bool = false,
    pub fn counter(self: *@This()) ?u64 {
        return self.counter_value;
    }
    pub fn armAt(self: *@This(), _: u64) bool {
        self.arms += 1;
        self.counter_value += self.arm_delay;
        return !self.fail_arm;
    }
    pub fn clearPending(self: *@This()) bool {
        self.clears += 1;
        self.arm_delay = 0;
        return !self.fail_clear;
    }
    pub fn elapse(self: *@This(), ticks: u64) bool {
        self.ticks += ticks;
        return true;
    }
};

test "refresh catches deadline crossed during arming without replaying elapsed ticks" {
    var clock = TickClock.init(1000).?;
    var fixture = RefreshFixture{};
    try std.testing.expect(clock.refresh(&fixture, &fixture, true));
    try std.testing.expectEqual(@as(u32, 2), fixture.arms);
    try std.testing.expectEqual(@as(u32, 1), fixture.clears);
    try std.testing.expectEqual(@as(u64, 2), fixture.ticks);
    try std.testing.expect(clock.refresh(&fixture, &fixture, true));
    try std.testing.expectEqual(@as(u64, 2), fixture.ticks);
}
test "refresh bounds catch-up and propagates timer failures; disarmed owner only accounts time" {
    var clock = TickClock.init(1000).?;
    var fixture = RefreshFixture{ .fail_arm = true };
    try std.testing.expect(!clock.refresh(&fixture, &fixture, true));
    clock = TickClock.init(1000).?;
    fixture = .{ .fail_clear = true };
    try std.testing.expect(!clock.refresh(&fixture, &fixture, true));
    clock = TickClock.init(1000).?;
    fixture = .{ .counter_value = 3500 };
    try std.testing.expect(clock.refresh(&fixture, &fixture, false));
    try std.testing.expectEqual(@as(u64, 3), fixture.ticks);
    try std.testing.expectEqual(@as(u32, 0), fixture.arms);
    const Slow = struct {
        base: RefreshFixture = .{},
        pub fn counter(self: *@This()) ?u64 {
            return self.base.counter();
        }
        pub fn armAt(self: *@This(), next: u64) bool {
            return self.base.armAt(next);
        }
        pub fn clearPending(self: *@This()) bool {
            self.base.clears += 1;
            return true;
        }
    };
    clock = TickClock.init(1000).?;
    var slow = Slow{};
    fixture = .{};
    try std.testing.expect(!clock.refresh(&fixture, &slow, true));
    try std.testing.expectEqual(@as(u32, 4), slow.base.arms);
    try std.testing.expectEqual(@as(u32, 4), slow.base.clears);
}
