//! P4 SAR analog setup for RNG, following ESP-IDF v5.4.4.
//! Caller supplies exclusive ADC, analog bus, clock and power ownership.
//! This does not sample or qualify entropy and is not wired to native SSH.
const std = @import("std");
const bus = @import("sar_regi2c.zig");

/// Poll-driven analog setup. All three original registers are captured before
/// writing. Any attempted write is treated as possibly completed, including a
/// timeout, and must be restored before releasing the surrounding ownership.
/// The caller must stop the ADC digital timer before calling restore().
pub const Analog = struct {
    const Phase = enum { idle, read_low, read_high, read_control, write_high, write_low, write_control, ready, restore_control, restore_low, restore_high, finished, quarantined };
    pub const Status = enum { pending, ready, restored, failed, unavailable };
    phase: Phase = .idle,
    txn: bus.Transaction = .{},
    inflight: bool = false,
    dirty: bool = false,
    aborting: bool = false,
    setup_failed: bool = false,
    low: u8 = 0,
    high: u8 = 0,
    control: u8 = 0,
    deadline: u64 = 0,
    last: u64 = 0,
    transaction_timeout: u64 = 0,

    pub fn begin(self: *Analog, io: anytype, now: u64, timeout: u64, transaction_timeout: u64) !void {
        if (self.phase != .idle) return error.Busy;
        if (timeout == 0 or transaction_timeout == 0 or now > std.math.maxInt(u64) - timeout) return error.InvalidDeadline;
        if (!io.owned() or !io.clockReady()) return error.Unavailable;
        self.deadline = now + timeout;
        self.last = now;
        self.transaction_timeout = transaction_timeout;
        self.phase = .read_low;
    }

    /// Called only after stopping any ADC digital conversion. During setup,
    /// cancellation is also safe because digital conversion has not started.
    pub fn restore(self: *Analog) void {
        if (self.phase == .idle or self.phase == .finished or self.phase == .quarantined) return;
        self.aborting = true;
        if (self.inflight) self.txn.cancel() else self.startRestore();
    }

    fn startRestore(self: *Analog) void {
        self.phase = if (self.dirty) .restore_control else .finished;
    }
    fn cleaning(self: *const Analog) bool {
        return self.phase == .restore_control or self.phase == .restore_low or self.phase == .restore_high;
    }
    fn next(self: *Analog) void {
        self.phase = switch (self.phase) {
            .read_low => .read_high,
            .read_high => .read_control,
            .read_control => .write_high,
            .write_high => .write_low,
            .write_low => .write_control,
            .write_control => .ready,
            .restore_control => .restore_low,
            .restore_low => .restore_high,
            .restore_high => .finished,
            else => unreachable,
        };
    }

    /// Each call starts or polls at most one transaction. A permanently busy
    /// master or lost ownership keeps the lease quarantined; callers must not
    /// release shared resources until restored or external recovery completes.
    pub fn poll(self: *Analog, io: anytype, now: u64) Status {
        if (self.phase == .idle) return .unavailable;
        if (self.phase == .finished) return if (self.setup_failed) .failed else .restored;
        if (self.phase == .quarantined) return .unavailable;
        if (!io.owned() or !io.clockReady()) {
            self.phase = .quarantined;
            return .unavailable;
        }
        if (!self.cleaning() and self.phase != .ready and (now < self.last or now >= self.deadline)) {
            self.setup_failed = true;
            self.restore();
        }
        self.last = now;
        if (self.phase == .ready) return .ready;
        if (self.phase == .finished) return if (self.setup_failed) .failed else .restored;
        if (self.inflight) {
            const result = self.txn.poll(io, now);
            if (result == .pending) return .pending;
            if (result == .unavailable) {
                self.phase = .quarantined;
                return .unavailable;
            }
            const byte = self.txn.value;
            if (!self.txn.reset()) {
                self.phase = .quarantined;
                return .unavailable;
            }
            self.inflight = false;
            if (self.aborting and !self.cleaning()) {
                self.startRestore();
                return .pending;
            }
            if (result == .failed) {
                if (!self.cleaning()) {
                    self.setup_failed = true;
                    self.startRestore();
                }
                // A failed restoration may have written the byte; retry it.
                return .pending;
            }
            switch (self.phase) {
                .read_low => self.low = byte,
                .read_high => self.high = byte,
                .read_control => self.control = byte,
                else => {},
            }
            self.next();
            return .pending;
        }
        const operation: struct { reg: u8, value: ?u8 } = switch (self.phase) {
            .read_low => .{ .reg = 0, .value = null },
            .read_high => .{ .reg = 1, .value = null },
            .read_control => .{ .reg = 9, .value = null },
            .write_high => .{ .reg = 1, .value = (self.high & 0xf0) | 0x08 },
            .write_low => .{ .reg = 0, .value = 0x76 },
            .write_control => .{ .reg = 9, .value = (self.control & 0xe0) | 0x10 },
            .restore_control => .{ .reg = 9, .value = self.control },
            .restore_low => .{ .reg = 0, .value = self.low },
            .restore_high => .{ .reg = 1, .value = self.high },
            else => return .pending,
        };
        self.txn.start(io, operation.reg, operation.value, now, self.transaction_timeout) catch |err| switch (err) {
            error.Busy => return .pending,
            else => {
                if (self.cleaning()) return .pending;
                self.setup_failed = true;
                self.startRestore();
                return .pending;
            },
        };
        if (operation.value != null and !self.cleaning()) self.dirty = true;
        self.inflight = true;
        return .pending;
    }
};

const Fake = struct {
    ctrl: u32 = 0,
    conf1: u32 = 0x2345,
    conf2: u32 = 0x5678,
    regs: [10]u8 = .{ 0xa1, 0xf2, 0, 0, 0, 0, 0, 0, 0, 0xac },
    held: bool = true,
    clock: bool = true,
    stuck: bool = false,
    writes: u32 = 0,
    pub fn owned(self: *@This()) bool {
        return self.held;
    }
    pub fn clockReady(self: *@This()) bool {
        return self.clock;
    }
    pub fn read(self: *@This(), addr: usize) u32 {
        return switch (addr) {
            bus.control => self.ctrl | (if (self.stuck) @as(u32, 1 << 25) else 0),
            bus.control1 => 0,
            bus.conf1 => self.conf1,
            bus.conf2 => self.conf2,
            else => unreachable,
        };
    }
    pub fn write(self: *@This(), addr: usize, value: u32) void {
        self.writes += 1;
        switch (addr) {
            bus.conf1 => self.conf1 = value,
            bus.conf2 => self.conf2 = value,
            bus.control => {
                const reg: usize = (value >> 8) & 255;
                if (value & (1 << 24) != 0) self.regs[reg] = @truncate(value >> 16);
                self.ctrl = @as(u32, self.regs[reg]) << 16;
            },
            else => unreachable,
        }
    }
};

fn runTo(analog: *Analog, io: *Fake, now: *u64, expected: Analog.Status) !void {
    for (0..200) |_| {
        const status = analog.poll(io, now.*);
        now.* += 1;
        if (status == expected) return;
        if (status != .pending) return error.UnexpectedStatus;
    }
    return error.DidNotComplete;
}

test "setup applies P4 SAR fields and restores all original bytes" {
    var io: Fake = .{};
    const original = io.regs;
    var analog: Analog = .{};
    var now: u64 = 0;
    try analog.begin(&io, now, 100, 20);
    try runTo(&analog, &io, &now, .ready);
    try std.testing.expectEqual(@as(u8, 0x76), io.regs[0]);
    try std.testing.expectEqual(@as(u8, 0xf8), io.regs[1]);
    try std.testing.expectEqual(@as(u8, 0xb0), io.regs[9]);
    analog.restore();
    try runTo(&analog, &io, &now, .restored);
    try std.testing.expectEqualSlices(u8, &original, &io.regs);
    try std.testing.expectEqual(@as(u32, 0x2345), io.conf1);
    try std.testing.expectEqual(@as(u32, 0x5678), io.conf2);
}

test "cancel after an indeterminate write restores the snapshot" {
    var io: Fake = .{};
    const original = io.regs;
    var analog: Analog = .{};
    var now: u64 = 0;
    try analog.begin(&io, now, 100, 20);
    while (analog.phase != .write_low or !analog.inflight) : (now += 1) _ = analog.poll(&io, now);
    analog.restore();
    try runTo(&analog, &io, &now, .restored);
    try std.testing.expectEqualSlices(u8, &original, &io.regs);
}

test "stuck bus and lost ownership do not release or restore unsafely" {
    var io: Fake = .{};
    var analog: Analog = .{};
    var now: u64 = 0;
    try analog.begin(&io, now, 20, 4);
    while (analog.phase != .write_high or !analog.inflight) : (now += 1) _ = analog.poll(&io, now);
    io.stuck = true;
    const writes = io.writes;
    for (0..30) |_| {
        _ = analog.poll(&io, now);
        now += 1;
    }
    try std.testing.expectEqual(writes, io.writes);
    io.stuck = false;
    try runTo(&analog, &io, &now, .failed);
    try std.testing.expectEqual(@as(u8, 0xf2), io.regs[1]);
    var other: Analog = .{};
    try other.begin(&io, now, 30, 4);
    io.held = false;
    const before = io.writes;
    try std.testing.expectEqual(Analog.Status.unavailable, other.poll(&io, now));
    io.held = true;
    try std.testing.expectEqual(Analog.Status.unavailable, other.poll(&io, now + 1));
    try std.testing.expectEqual(before, io.writes);
}
