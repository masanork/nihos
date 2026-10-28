//! Cooperative deadline over serialized, monotonically increasing microseconds.
//! A missing/reset counter latches a stop reason; no wall-clock fallback, task
//! kill, buffer release, or claim that polling bounds time spent inside IO.
const std = @import("std");
pub const Reason = enum { none, deadline, clock_unavailable, clock_regressed };
pub const Clock = struct {
    pub const Failure = enum { none, unavailable, regressed };
    pub const Error = error{ ClockUnavailable, ClockRegressed };
    last_us: u64,
    failure: Failure = .none,
    pub fn init(sample_us: ?u64) Error!Clock {
        return .{ .last_us = sample_us orelse return error.ClockUnavailable };
    }
    /// Check raw counter continuity before converting into the ledger's ms.
    /// The instance must outlive every lease that shares this clock domain.
    pub fn milliseconds(self: *Clock, sample_us: ?u64) Error!u64 {
        switch (self.failure) {
            .unavailable => return error.ClockUnavailable,
            .regressed => return error.ClockRegressed,
            .none => {},
        }
        const now = sample_us orelse {
            self.failure = .unavailable;
            return error.ClockUnavailable;
        };
        if (now < self.last_us) {
            self.failure = .regressed;
            return error.ClockRegressed;
        }
        self.last_us = now;
        return now / 1000;
    }
};
pub const Deadline = struct {
    started_us: u64,
    last_us: u64,
    duration_us: u64,
    reason: Reason = .none,

    pub fn init(sample_us: ?u64, duration_us: u64) error{ InvalidArgument, ClockUnavailable }!Deadline {
        if (duration_us == 0) return error.InvalidArgument;
        const now = sample_us orelse return error.ClockUnavailable;
        return .{ .started_us = now, .last_us = now, .duration_us = duration_us };
    }
    pub fn poll(self: *Deadline, sample_us: ?u64) Reason {
        if (self.reason != .none) return self.reason;
        const now = sample_us orelse {
            self.reason = .clock_unavailable;
            return self.reason;
        };
        if (now < self.last_us) {
            self.reason = .clock_regressed;
            return self.reason;
        }
        self.last_us = now;
        // Subtraction stays valid even near u64 exhaustion. Do not form an
        // absolute deadline by adding duration to started_us.
        if (now - self.started_us >= self.duration_us) self.reason = .deadline;
        return self.reason;
    }
};

test "microsecond deadline is inclusive and sticky without millisecond rounding" {
    var deadline = try Deadline.init(1001, 2);
    try std.testing.expectEqual(Reason.none, deadline.poll(1002));
    try std.testing.expectEqual(Reason.deadline, deadline.poll(1003));
    try std.testing.expectEqual(Reason.deadline, deadline.poll(1001));
    try std.testing.expectEqual(Reason.deadline, deadline.poll(null));
}
test "missing counter at start fails and later failure cannot recover silently" {
    try std.testing.expectError(error.ClockUnavailable, Deadline.init(null, 1));
    var deadline = try Deadline.init(0, 1000);
    try std.testing.expectEqual(Reason.none, deadline.poll(0));
    try std.testing.expectEqual(Reason.clock_unavailable, deadline.poll(null));
    try std.testing.expectEqual(Reason.clock_unavailable, deadline.poll(2000));
    try std.testing.expectEqual(@as(u64, 0), deadline.last_us);
}
test "submillisecond regression is detected before any conversion" {
    var deadline = try Deadline.init(1001, 1000);
    try std.testing.expectEqual(Reason.none, deadline.poll(1002));
    try std.testing.expectEqual(Reason.clock_regressed, deadline.poll(1001));
    try std.testing.expectEqual(Reason.clock_regressed, deadline.poll(2000));
    try std.testing.expectEqual(@as(u64, 1002), deadline.last_us);
}
test "deadline arithmetic does not overflow or wrap the source counter" {
    try std.testing.expectError(error.InvalidArgument, Deadline.init(0, 0));
    var deadline = try Deadline.init(std.math.maxInt(u64) - 2, 2);
    try std.testing.expectEqual(Reason.none, deadline.poll(std.math.maxInt(u64) - 1));
    try std.testing.expectEqual(Reason.deadline, deadline.poll(std.math.maxInt(u64)));
    deadline = try Deadline.init(std.math.maxInt(u64) - 2, 3);
    try std.testing.expectEqual(Reason.clock_regressed, deadline.poll(0));
}
test "a delayed progress poll expires without pretending to run at the boundary" {
    var deadline = try Deadline.init(7, 100);
    try std.testing.expectEqual(Reason.none, deadline.poll(106));
    try std.testing.expectEqual(Reason.deadline, deadline.poll(10007));
    try std.testing.expectEqual(@as(u64, 10007), deadline.last_us);
}

test "ledger clock preserves submillisecond regression checks and latches failure" {
    var clock = try Clock.init(1001);
    try std.testing.expectEqual(@as(u64, 1), try clock.milliseconds(1002));
    try std.testing.expectError(error.ClockRegressed, clock.milliseconds(1001));
    try std.testing.expectError(error.ClockRegressed, clock.milliseconds(2000));
    try std.testing.expectEqual(@as(u64, 1002), clock.last_us);
}
test "ledger clock rejects initial missing sample and never reuses a missing time" {
    try std.testing.expectError(error.ClockUnavailable, Clock.init(null));
    var clock = try Clock.init(0);
    try std.testing.expectEqual(@as(u64, 0), try clock.milliseconds(0));
    try std.testing.expectError(error.ClockUnavailable, clock.milliseconds(null));
    try std.testing.expectError(error.ClockUnavailable, clock.milliseconds(1000));
    try std.testing.expectEqual(@as(u64, 0), clock.last_us);
}
test "ledger clock converts elapsed input without overflowing at u64 limit" {
    var clock = try Clock.init(std.math.maxInt(u64) - 1);
    try std.testing.expectEqual(std.math.maxInt(u64) / 1000, try clock.milliseconds(std.math.maxInt(u64)));
    try std.testing.expectError(error.ClockRegressed, clock.milliseconds(0));
}
