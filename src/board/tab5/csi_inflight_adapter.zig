//! Experimental binding layer between the in-flight stop policy and a board
//! backend. Native diagnostics use the snapshot and stop policy. The backend
//! must serialize channel, frame,
//! sensor and common-fault access under the existing owner.
const std = @import("std");
pub const policy = @import("csi_inflight_stop.zig");
pub const first_frame = @import("csi_first_frame.zig");
const Progress = first_frame.ProgressSnapshot;
pub const Frame = struct { identity: u64, base: u32, length: u32, dma_owned: bool };
const done: u32 = 2;
const errors: u32 = 0x07ffffe0;
const disabled: u32 = 1 << 30;

pub fn Adapter(comptime Io: type) type {
    return struct {
        const Self = @This();
        io: *Io,
        lease: u32,
        frame: Frame,
        // domain returns null on token/observation failure, otherwise latched
        // common fault. Missing state always fails closed.
        pub fn owned(self: *Self, token: u32) bool {
            if (token == 0 or token != self.lease or self.io.domain(token) == null) return false;
            const f = self.io.frame() orelse return false;
            return self.frame.identity != 0 and f.dma_owned and f.identity == self.frame.identity and f.base == self.frame.base and f.length == self.frame.length;
        }
        pub fn commonFault(self: *Self, token: u32) bool {
            return (self.io.domain(token) orelse return true) != 0;
        }
        pub fn snapshot(self: *Self) ?Progress {
            const f = self.io.frame() orelse return null;
            if (!f.dma_owned or f.identity == 0 or f.identity != self.frame.identity or f.base != self.frame.base or f.length != self.frame.length) return null;
            const active_before = self.io.active();
            const status_before = self.io.status();
            const dar = self.io.dar();
            const status_after = self.io.status();
            const active_after = self.io.active();
            return .{ .base = f.base, .length = f.length, .address = dar, .enabled_before = active_before, .enabled_after = active_after, .status_before = status_before, .status_after = status_after };
        }
        pub fn active(self: *Self) bool {
            return self.io.active();
        }
        pub fn eventGenerationEnabled(self: *Self) bool {
            return self.io.generation();
        }
        pub fn signalsMasked(self: *Self) bool {
            return self.io.masked();
        }
        pub fn status(self: *Self) policy.Status {
            const value = self.io.status();
            return .{ .done = value & done != 0, .error_seen = value & errors != 0, .disabled = value & disabled != 0 };
        }
        pub fn clearDisabled(self: *Self) void {
            self.io.clearDisabled();
        }
        pub fn stopProducer(self: *Self) bool {
            return self.io.sensorOff();
        }
        pub fn stopBridge(self: *Self) bool {
            return self.io.bridgeOff();
        }
        pub fn requestDisable(self: *Self) bool {
            return self.io.requestDisable();
        }
        pub fn fifoRemaining(self: *Self) u32 {
            return self.io.fifo();
        }
    };
}
const initial: Frame = .{ .identity = 9, .base = 1000, .length = 100, .dma_owned = true };
const FakeIo = struct {
    current: ?Frame = initial,
    token: u32 = 7,
    fault: u32 = 0,
    status_bits: u32 = 0,
    enabled: bool = true,
    generator: bool = true,
    signals_masked: bool = true,
    destination: u32 = 1050,
    remaining: u32 = 0,
    fail_domain: bool = false,
    lose_on_sensor: bool = false,
    sensor_ok: bool = true,
    requested: bool = false,
    clear_mask: u32 = 0,
    fn domain(self: *FakeIo, token: u32) ?u32 {
        return if (self.fail_domain or token != self.token) null else self.fault;
    }
    fn frame(self: *FakeIo) ?Frame {
        return self.current;
    }
    fn active(self: *FakeIo) bool {
        return self.enabled;
    }
    fn status(self: *FakeIo) u32 {
        return self.status_bits;
    }
    fn dar(self: *FakeIo) u32 {
        return self.destination;
    }
    fn generation(self: *FakeIo) bool {
        return self.generator;
    }
    fn masked(self: *FakeIo) bool {
        return self.signals_masked;
    }
    fn clearDisabled(self: *FakeIo) void {
        self.clear_mask = disabled;
        self.status_bits &= ~disabled;
    }
    fn sensorOff(self: *FakeIo) bool {
        if (self.lose_on_sensor) self.token += 1;
        return self.sensor_ok;
    }
    fn bridgeOff(_: *FakeIo) bool {
        return true;
    }
    fn requestDisable(self: *FakeIo) bool {
        if (self.status_bits & (done | errors | disabled) != 0 or !self.enabled) return false;
        self.requested = true;
        return true;
    }
    fn fifo(self: *FakeIo) u32 {
        return self.remaining;
    }
};
fn setup(io: *FakeIo) Adapter(FakeIo) {
    return .{ .io = io, .lease = 7, .frame = initial };
}
test "binding walks candidate stop while preserving lease" {
    var io: FakeIo = .{ .status_bits = disabled };
    var adapter = setup(&io);
    var state: policy.State = .{};
    try std.testing.expect(state.start(&adapter, 7));
    try std.testing.expectEqual(disabled, io.clear_mask);
    try std.testing.expect(io.requested);
    io.enabled = false;
    io.status_bits = disabled;
    try std.testing.expectEqual(policy.Result.observed, state.poll(&adapter));
    try std.testing.expect(io.current.?.dma_owned);
}
test "frame changes, missing lease, common fault, sensor failure fail closed" {
    for (0..7) |i| {
        var io: FakeIo = .{};
        switch (i) {
            0 => io.current = null,
            1 => io.current.?.identity += 1,
            2 => io.current.?.dma_owned = false,
            3 => io.fail_domain = true,
            4 => io.fault = 1,
            5 => io.lose_on_sensor = true,
            6 => io.sensor_ok = false,
            else => unreachable,
        }
        var adapter = setup(&io);
        var state: policy.State = .{};
        try std.testing.expect(!state.start(&adapter, 7));
        try std.testing.expectEqual(policy.Result.pinned, state.result);
        try std.testing.expect(!io.requested);
    }
}
test "fault or frame substitution while waiting cannot become success" {
    for (0..3) |i| {
        var io: FakeIo = .{};
        var adapter = setup(&io);
        var state: policy.State = .{};
        try std.testing.expect(state.start(&adapter, 7));
        io.enabled = false;
        io.status_bits = disabled;
        switch (i) {
            0 => io.fault = 1,
            1 => io.current.?.base += 64,
            2 => io.fail_domain = true,
            else => unreachable,
        }
        try std.testing.expectEqual(policy.Result.pinned, state.poll(&adapter));
    }
}
