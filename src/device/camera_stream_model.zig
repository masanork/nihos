//! Host-only ownership model for a bounded two-buffer camera stream.
//! No hardware, cache operation, pointer revocation, or DMA retirement is implemented.
//! One serialized owner must validate every hardware observation and client release.
const std = @import("std");
pub const Error = error{ Busy, Stale, Invalid, Pinned, Exhausted, NotReady };
pub const State = enum { free, dma, ready, borrowed, pinned };
pub const Token = struct { slot: u1, generation: u64 };
pub const Retirement = struct {
    producer_stopped: bool,
    channel_stopped: bool,
    fifo_drained: bool,
    irq_drained: bool,
    cache_to_cpu: bool,
    fault_free: bool,
    fn clean(self: Retirement) bool {
        return self.producer_stopped and self.channel_stopped and self.fifo_drained and
            self.irq_drained and self.cache_to_cpu and self.fault_free;
    }
};
const Slot = struct { state: State = .free, generation: u64 = 0 };
pub const Stream = struct {
    slots: [2]Slot = @splat(.{}),
    generation: u64 = 0,
    quarantined: bool = false,
    fn check(self: *Stream, t: Token) Error!*Slot {
        const slot = &self.slots[t.slot];
        if (t.generation == 0 or slot.generation != t.generation or slot.state == .free) return error.Stale;
        return slot;
    }
    /// On return the producer may write only to this slot. A full queue applies
    /// backpressure; it never overwrites a frame still held by a client.
    pub fn begin(self: *Stream) Error!Token {
        if (self.quarantined) return error.Pinned;
        for (self.slots) |slot| if (slot.state == .dma) {
            return error.Busy;
        };
        if (self.generation == std.math.maxInt(u64)) return error.Exhausted;
        for (&self.slots, 0..) |*slot, i| {
            if (slot.state == .free) {
                self.generation += 1;
                slot.* = .{ .state = .dma, .generation = self.generation };
                return .{ .slot = @intCast(i), .generation = self.generation };
            }
        }
        return error.Busy;
    }
    /// Facts are independent observations supplied by the adapter. A negative
    /// or uncertain fact quarantines all allocations, even previously borrowed
    /// ones, because common hardware faults may have unknown provenance.
    pub fn retire(self: *Stream, token: Token, facts: Retirement, completed: bool) Error!void {
        const slot = try self.check(token);
        if (self.quarantined) return error.Pinned;
        if (slot.state != .dma) return error.NotReady;
        if (!facts.clean()) {
            self.quarantined = true;
            for (&self.slots) |*s| s.state = .pinned;
            return error.Pinned;
        }
        slot.state = if (completed) .ready else .free;
    }
    pub fn borrow(self: *Stream, token: Token) Error!void {
        const slot = try self.check(token);
        if (self.quarantined) return error.Pinned;
        if (slot.state != .ready) return error.NotReady;
        slot.state = .borrowed;
    }
    pub fn release(self: *Stream, token: Token) Error!void {
        const slot = try self.check(token);
        if (self.quarantined) return error.Pinned;
        if (slot.state != .borrowed and slot.state != .ready) return error.NotReady;
        slot.state = .free;
    }
};
const clean: Retirement = .{ .producer_stopped = true, .channel_stopped = true, .fifo_drained = true, .irq_drained = true, .cache_to_cpu = true, .fault_free = true };
test "backpressure protects borrowed frame and stale generations" {
    var s: Stream = .{};
    const a = try s.begin();
    try s.retire(a, clean, true);
    try s.borrow(a);
    const b = try s.begin();
    try std.testing.expect(a.slot != b.slot);
    try s.retire(b, clean, true);
    try std.testing.expectError(error.Busy, s.begin());
    try s.release(a);
    const c = try s.begin();
    try std.testing.expectEqual(a.slot, c.slot);
    try std.testing.expectError(error.Stale, s.release(a));
    try std.testing.expectError(error.Stale, s.retire(a, clean, true));
    try s.retire(c, clean, false);
    try s.release(b);
}
test "each missing retirement observation quarantines both buffers" {
    inline for (.{ "producer_stopped", "channel_stopped", "fifo_drained", "irq_drained", "cache_to_cpu", "fault_free" }) |field| {
        var s: Stream = .{};
        const a = try s.begin();
        try s.retire(a, clean, true);
        try s.borrow(a);
        const b = try s.begin();
        var bad = clean;
        @field(bad, field) = false;
        try std.testing.expectError(error.Pinned, s.retire(b, bad, true));
        try std.testing.expectError(error.Pinned, s.begin());
        try std.testing.expectError(error.Pinned, s.release(a));
        try std.testing.expectError(error.Pinned, s.retire(b, clean, true));
    }
}
test "only one DMA and no premature publication or release" {
    var s: Stream = .{};
    const a = try s.begin();
    try std.testing.expectError(error.Busy, s.begin());
    try std.testing.expectError(error.NotReady, s.borrow(a));
    try std.testing.expectError(error.NotReady, s.release(a));
    try s.retire(a, clean, false);
    try std.testing.expectError(error.Stale, s.borrow(a));
}
