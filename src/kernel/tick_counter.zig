//! Bounded handoff from a timer interrupt to scheduler code.
//!
//! The interrupt path never blocks or allocates. Pending ticks saturate rather
//! than wrap so overload remains observable and cannot silently move time
//! backwards. The scheduler drains the counter outside interrupt context.

const std = @import("std");

pub const TickCounter = struct {
    value: std.atomic.Value(u32) = .init(0),

    /// Records one interrupt. Returns false after the counter has saturated.
    pub fn noteInterrupt(self: *TickCounter) bool {
        var observed = self.value.load(.monotonic);
        while (observed != std.math.maxInt(u32)) {
            if (self.value.cmpxchgWeak(
                observed,
                observed + 1,
                .release,
                .monotonic,
            )) |changed| {
                observed = changed;
            } else {
                return true;
            }
        }
        return false;
    }

    pub fn pending(self: *const TickCounter) u32 {
        return self.value.load(.acquire);
    }

    pub fn takePending(self: *TickCounter) u32 {
        return self.value.swap(0, .acquire);
    }

    pub fn reset(self: *TickCounter) void {
        self.value.store(0, .release);
    }
};

test "pending ticks drain exactly once" {
    var counter = TickCounter{};
    try std.testing.expect(counter.noteInterrupt());
    try std.testing.expect(counter.noteInterrupt());
    try std.testing.expectEqual(@as(u32, 2), counter.pending());
    try std.testing.expectEqual(@as(u32, 2), counter.takePending());
    try std.testing.expectEqual(@as(u32, 0), counter.takePending());
}

test "interrupt producers do not lose increments" {
    var counter = TickCounter{};
    const Worker = struct {
        fn run(shared: *TickCounter) void {
            for (0..25_000) |_| {
                if (!shared.noteInterrupt()) unreachable;
            }
        }
    };

    var threads: [4]std.Thread = undefined;
    for (&threads) |*thread| thread.* = try std.Thread.spawn(.{}, Worker.run, .{&counter});
    for (threads) |thread| thread.join();
    try std.testing.expectEqual(@as(u32, 100_000), counter.takePending());
}
