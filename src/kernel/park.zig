//! Check exit and wait while interrupt handling is masked. A pending locally
//! enabled interrupt must still resume the architecture's wait instruction.
const std = @import("std");

pub fn once(exit: *const std.atomic.Value(bool), interrupts: anytype) bool {
    const previous = interrupts.mask();
    defer interrupts.restore(previous);
    if (exit.load(.acquire)) return false;
    interrupts.wait();
    return true;
}

const TestInterrupts = struct {
    exit: *std.atomic.Value(bool),
    masked: bool = false,
    waited: bool = false,
    restored: bool = false,
    stop_at_mask: bool = false,
    stop_at_wait: bool = false,
    pending: bool = false,

    fn mask(self: *TestInterrupts) bool {
        const previous = self.masked;
        self.masked = true;
        if (self.stop_at_mask) self.exit.store(true, .release);
        return previous;
    }

    fn wait(self: *TestInterrupts) void {
        std.debug.assert(self.masked);
        self.waited = true;
        if (self.stop_at_wait) {
            self.exit.store(true, .release);
            self.pending = true;
        }
        // Model a pending IRQ resuming WFI even though handling is masked.
        std.debug.assert(self.pending);
    }

    fn restore(self: *TestInterrupts, previous: bool) void {
        self.masked = previous;
        self.restored = true;
    }
};

test "park observes exit after masking and never waits after stop" {
    var exit = std.atomic.Value(bool).init(false);
    var interrupts = TestInterrupts{ .exit = &exit, .stop_at_mask = true };
    try std.testing.expect(!once(&exit, &interrupts));
    try std.testing.expect(!interrupts.waited);
    try std.testing.expect(interrupts.restored and !interrupts.masked);
}

test "park keeps handling masked through a check to wait notification" {
    var exit = std.atomic.Value(bool).init(false);
    var interrupts = TestInterrupts{ .exit = &exit, .stop_at_wait = true };
    try std.testing.expect(once(&exit, &interrupts));
    try std.testing.expect(exit.load(.acquire));
    try std.testing.expect(interrupts.waited and interrupts.restored and !interrupts.masked);
    interrupts.waited = false;
    try std.testing.expect(!once(&exit, &interrupts));
    try std.testing.expect(!interrupts.waited);
}

test "park preserves a caller that already masked interrupt handling" {
    var exit = std.atomic.Value(bool).init(false);
    var interrupts = TestInterrupts{ .exit = &exit, .masked = true, .pending = true };
    try std.testing.expect(once(&exit, &interrupts));
    try std.testing.expect(interrupts.restored and interrupts.masked);
}
