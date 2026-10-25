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
