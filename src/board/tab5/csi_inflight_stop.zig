//! In-flight disable diagnostic policy, host tested and connected through the
//! native adapter. Calls run under the existing serialized domain owner.
//! Success is an observation, not permission to reuse DMA resources.
const std = @import("std");
const ProgressSnapshot = @import("csi_first_frame.zig").ProgressSnapshot;
pub const Result = enum { idle, pending, observed, pinned };
pub const Status = struct { disabled: bool = false, done: bool = false, error_seen: bool = false };
pub const State = struct {
    result: Result = .idle,
    polls: u32 = 0,
    lease: u32 = 0,
    sample_offset: u32 = 0,
    /// A serialized adapter must validate the token against the real channel
    /// and frame owners, provide a fresh bracketed hardware sample, and latch
    /// shared controller faults. No pointer or DMA lease is released here.
    fn safe(self: *State, hw: anytype) bool {
        return self.lease != 0 and hw.owned(self.lease) and !hw.commonFault(self.lease);
    }
    pub fn start(self: *State, hw: anytype, lease: u32) bool {
        return self.startAt(hw, lease, 1);
    }
    pub fn startAt(self: *State, hw: anytype, lease: u32, min_offset: u32) bool {
        if (self.result != .idle) return false;
        self.result = .pinned;
        self.lease = lease;
        if (!self.safe(hw)) return false;
        const sample = hw.snapshot() orelse return false;
        const offset = sample.offset() orelse return false;
        if (min_offset == 0 or offset < min_offset or !self.safe(hw) or !hw.active() or !hw.eventGenerationEnabled() or !hw.signalsMasked()) return false;
        self.sample_offset = offset;
        const before = hw.status();
        if (before.done or before.error_seen or !self.safe(hw)) return false;
        // Clear only this channel's disabled notification, never errors or DONE.
        hw.clearDisabled();
        const cleared = hw.status();
        if (cleared.disabled or cleared.done or cleared.error_seen or !self.safe(hw)) return false;
        if (!hw.stopProducer() or !self.safe(hw)) return false;
        if (!hw.stopBridge() or !self.safe(hw)) return false;
        if (!hw.requestDisable() or !self.safe(hw)) return false;
        self.result = .pending;
        return true;
    }
    pub fn poll(self: *State, hw: anytype) Result {
        if (self.result != .pending) return self.result;
        self.polls += 1;
        if (!self.safe(hw)) {
            self.result = .pinned;
            return self.result;
        }
        const s = hw.status();
        const active = hw.active();
        const fifo = hw.fifoRemaining();
        if (s.error_seen or s.done or !hw.eventGenerationEnabled() or !hw.signalsMasked() or !self.safe(hw)) {
            self.result = .pinned;
        } else if (s.disabled and !active and fifo == 0) {
            self.result = .observed;
        } else if (self.polls >= 1024) {
            self.result = .pinned;
        }
        return self.result;
    }
};
const valid: ProgressSnapshot = .{ .base = 100, .length = 10, .address = 101, .enabled_before = true, .enabled_after = true, .status_before = 0, .status_after = 0 };
const Fake = struct {
    running: bool = true,
    token: u32 = 7,
    fault: bool = false,
    lose_on_snapshot: bool = false,
    lose_on_producer: bool = false,
    sample: ?ProgressSnapshot = valid,
    snapshots: u32 = 0,
    generation: bool = true,
    masked: bool = true,
    event: Status = .{},
    fifo: u32 = 0,
    clear_works: bool = true,
    producer_ok: bool = true,
    bridge_ok: bool = true,
    request_ok: bool = true,
    calls: [4]u8 = @splat(0),
    count: usize = 0,
    fn record(self: *Fake, n: u8) void {
        self.calls[self.count] = n;
        self.count += 1;
    }
    fn owned(self: *Fake, lease: u32) bool {
        return lease != 0 and self.token == lease;
    }
    fn commonFault(self: *Fake, _: u32) bool {
        return self.fault;
    }
    fn snapshot(self: *Fake) ?ProgressSnapshot {
        self.snapshots += 1;
        if (self.lose_on_snapshot) self.token += 1;
        return self.sample;
    }
    fn active(self: *Fake) bool {
        return self.running;
    }
    fn eventGenerationEnabled(self: *Fake) bool {
        return self.generation;
    }
    fn signalsMasked(self: *Fake) bool {
        return self.masked;
    }
    fn status(self: *Fake) Status {
        return self.event;
    }
    fn clearDisabled(self: *Fake) void {
        self.record(1);
        if (self.clear_works) self.event.disabled = false;
    }
    fn stopProducer(self: *Fake) bool {
        self.record(2);
        if (self.lose_on_producer) self.token += 1;
        return self.producer_ok;
    }
    fn stopBridge(self: *Fake) bool {
        self.record(3);
        return self.bridge_ok;
    }
    fn requestDisable(self: *Fake) bool {
        self.record(4);
        return self.request_ok;
    }
    fn fifoRemaining(self: *Fake) u32 {
        return self.fifo;
    }
};
test "requires fresh disabled status, channel stopped and empty FIFO" {
    var hw: Fake = .{ .event = .{ .disabled = true } };
    var state: State = .{};
    try std.testing.expect(state.start(&hw, 7));
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, hw.calls[0..hw.count]);
    hw.running = false;
    try std.testing.expectEqual(Result.pending, state.poll(&hw));
    hw.event.disabled = true;
    hw.fifo = 1;
    try std.testing.expectEqual(Result.pending, state.poll(&hw));
    hw.fifo = 0;
    try std.testing.expectEqual(Result.observed, state.poll(&hw));
}
test "stale notification, completed transfer, and setup failures never observe success" {
    var hw: Fake = .{ .clear_works = false, .event = .{ .disabled = true } };
    var state: State = .{};
    try std.testing.expect(!state.start(&hw, 7));
    try std.testing.expectEqual(Result.pinned, state.result);
    for (0..5) |i| {
        hw = .{};
        state = .{};
        switch (i) {
            0 => hw.event.done = true,
            1 => hw.producer_ok = false,
            2 => hw.bridge_ok = false,
            3 => hw.request_ok = false,
            4 => hw.generation = false,
            else => unreachable,
        }
        try std.testing.expect(!state.start(&hw, 7));
        try std.testing.expectEqual(Result.pinned, state.result);
    }
    state = .{};
    hw = .{};
    hw.sample = .{ .base = 100, .length = 10, .address = 110, .enabled_before = true, .enabled_after = true, .status_before = 0, .status_after = 0 };
    try std.testing.expect(!state.start(&hw, 7));
}
test "race, lost interrupt configuration, and timeout quarantine" {
    for (0..4) |i| {
        var state: State = .{};
        var hw: Fake = .{};
        try std.testing.expect(state.start(&hw, 7));
        switch (i) {
            0 => hw.event.done = true,
            1 => hw.event.error_seen = true,
            2 => hw.generation = false,
            3 => hw.masked = false,
            else => unreachable,
        }
        try std.testing.expectEqual(Result.pinned, state.poll(&hw));
    }
    var state: State = .{};
    var hw: Fake = .{};
    try std.testing.expect(state.start(&hw, 7));
    for (0..1023) |_| try std.testing.expectEqual(Result.pending, state.poll(&hw));
    try std.testing.expectEqual(Result.pinned, state.poll(&hw));
}

test "fresh snapshot and matching live lease are required throughout" {
    var hw: Fake = .{};
    var state: State = .{};
    try std.testing.expect(!state.start(&hw, 6));
    try std.testing.expectEqual(@as(u32, 0), hw.snapshots);
    try std.testing.expectEqual(@as(usize, 0), hw.count);
    hw = .{ .lose_on_snapshot = true };
    state = .{};
    try std.testing.expect(!state.start(&hw, 7));
    try std.testing.expectEqual(@as(usize, 0), hw.count);
    hw = .{ .lose_on_producer = true };
    state = .{};
    try std.testing.expect(!state.start(&hw, 7));
    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, hw.calls[0..hw.count]);
    hw = .{};
    state = .{};
    try std.testing.expect(state.start(&hw, 7));
    try std.testing.expectEqual(@as(u32, 1), hw.snapshots);
    hw.token = 8;
    hw.event.disabled = true;
    hw.running = false;
    try std.testing.expectEqual(Result.pinned, state.poll(&hw));
    hw = .{};
    state = .{};
    try std.testing.expect(state.start(&hw, 7));
    hw.fault = true;
    hw.event.disabled = true;
    hw.running = false;
    try std.testing.expectEqual(Result.pinned, state.poll(&hw));
}

test "fresh snapshot must meet requested progress threshold" {
    var hw: Fake = .{};
    var state: State = .{};
    try std.testing.expect(!state.startAt(&hw, 7, 2));
    try std.testing.expectEqual(@as(usize, 0), hw.count);
    hw = .{};
    state = .{};
    try std.testing.expect(state.startAt(&hw, 7, 1));
    try std.testing.expectEqual(@as(u32, 1), state.sample_offset);
}
