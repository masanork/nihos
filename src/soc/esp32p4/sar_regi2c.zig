//! Bounded P4 SAR analog-I2C transactions, based on ESP-IDF v5.4.4.
//! This does not establish exclusive ownership, enable clocks, configure the
//! ADC, or qualify entropy. No code here is connected to native SSH yet.
const std = @import("std");
pub const control: usize = 0x50124000;
pub const conf1: usize = 0x5012401c;
pub const conf2: usize = 0x50124020;
const busy: u32 = 1 << 25;
const field: u32 = 0x00ff_ffff;
const sar: u32 = 0x69;
const sar_select: u32 = 1 << 7;

/// The caller must exclusively own the analog master, selector fields and
/// SAR device for the whole transaction, including recovery. It must ensure
/// the master clock is enabled and remains stable. All other analog-I2C users
/// must honor that ownership. Losing ownership makes cleanup unsafe; retain
/// the surrounding reservation until an external system recovery handles the loss.
/// The IO object's owned(), clockReady(), read(), and write() must be bounded.
pub const Transaction = struct {
    const State = enum { idle, running, recovering, complete };
    pub const Result = enum { pending, success, failed, unavailable };
    state: State = .idle,
    saved1: u32 = 0,
    saved2: u32 = 0,
    deadline: u64 = 0,
    previous: u64 = 0,
    value: u8 = 0,
    failed: bool = false,
    ownership_lost: bool = false,

    /// `value == null` reads a register; a value writes the full register.
    /// The SAR register may have changed if a write times out or is cancelled.
    pub fn start(self: *Transaction, io: anytype, register: u8, value: ?u8, now: u64, timeout: u64) !void {
        if (self.state != .idle) return error.Busy;
        if (timeout == 0 or now > std.math.maxInt(u64) - timeout) return error.InvalidDeadline;
        if (!io.owned() or !io.clockReady()) return error.Unavailable;
        if (io.read(control) & busy != 0) return error.Busy;
        self.saved1 = io.read(conf1) & field;
        self.saved2 = io.read(conf2) & field;
        setField(io, conf1, 0);
        setField(io, conf2, sar_select);
        self.deadline = now + timeout;
        self.previous = now;
        self.failed = false;
        self.state = .running;
        const command = sar | (@as(u32, register) << 8) |
            (if (value) |v| (@as(u32, 1) << 24) | (@as(u32, v) << 16) else @as(u32, 0));
        io.write(control, command);
    }

    fn setField(io: anytype, address: usize, bits: u32) void {
        io.write(address, (io.read(address) & ~field) | (bits & field));
    }

    /// At most one BUSY check per poll. The caller must continue polling after
    /// failure, without releasing ownership, until `failed` is returned.
    /// Loss of ownership or clock permanently quarantines this transaction.
    pub fn poll(self: *Transaction, io: anytype, now: u64) Result {
        if (self.state == .idle) return .unavailable;
        if (self.state == .complete) return if (self.failed) .failed else .success;
        if (now < self.previous or now >= self.deadline) self.failed = true;
        self.previous = now;
        if (self.ownership_lost or !io.owned() or !io.clockReady()) {
            self.ownership_lost = true;
            self.failed = true;
            self.state = .recovering;
            return .pending;
        }
        const status = io.read(control);
        if (status & busy != 0) {
            if (self.failed) self.state = .recovering;
            return .pending;
        }
        if (!self.failed) self.value = @truncate(status >> 16);
        // Restoring selectors while the master is busy would corrupt another
        // transaction. Recover only after idle and ownership are rechecked.
        setField(io, conf1, self.saved1);
        setField(io, conf2, self.saved2);
        self.state = .complete;
        return if (self.failed) .failed else .success;
    }
    pub fn cancel(self: *Transaction) void {
        if (self.state == .running or self.state == .recovering) {
            self.failed = true;
            self.state = .recovering;
        }
    }
    pub fn reset(self: *Transaction) bool {
        if (self.state != .complete) return false;
        self.* = .{};
        return true;
    }
};

const Fake = struct {
    ctrl: u32 = 0,
    a: u32 = 0x1200_3456,
    b: u32 = 0x3400_789a,
    held: bool = true,
    clock: bool = true,
    writes: u32 = 0,
    fn owned(self: *@This()) bool {
        return self.held;
    }
    fn clockReady(self: *@This()) bool {
        return self.clock;
    }
    fn read(self: *@This(), address: usize) u32 {
        return switch (address) {
            control => self.ctrl,
            conf1 => self.a,
            conf2 => self.b,
            else => unreachable,
        };
    }
    fn write(self: *@This(), address: usize, value: u32) void {
        self.writes += 1;
        switch (address) {
            control => self.ctrl = value | busy,
            conf1 => self.a = value,
            conf2 => self.b = value,
            else => unreachable,
        }
    }
};

test "SAR read and write encode commands and restore selectors only after idle" {
    var io: Fake = .{};
    var tx: Transaction = .{};
    try tx.start(&io, 9, null, 10, 10);
    try std.testing.expectEqual(@as(u32, 0x969), io.ctrl & ~busy);
    try std.testing.expectEqual(@as(u32, 0x1200_0000), io.a);
    try std.testing.expectEqual(@as(u32, 0x3400_0080), io.b);
    try std.testing.expectEqual(Transaction.Result.pending, tx.poll(&io, 11));
    io.ctrl = 0xab << 16;
    try std.testing.expectEqual(Transaction.Result.success, tx.poll(&io, 12));
    try std.testing.expectEqual(@as(u8, 0xab), tx.value);
    try std.testing.expectEqual(@as(u32, 0x1200_3456), io.a);
    try std.testing.expectEqual(@as(u32, 0x3400_789a), io.b);
    try std.testing.expect(tx.reset());
    try tx.start(&io, 1, 0x42, 20, 10);
    try std.testing.expectEqual(@as(u32, 0x0142_0169), io.ctrl & ~busy);
}

test "timeout and cancellation retain selectors until busy clears" {
    var io: Fake = .{};
    var tx: Transaction = .{};
    try tx.start(&io, 0, 1, 0, 5);
    try std.testing.expectEqual(Transaction.Result.pending, tx.poll(&io, 5));
    try std.testing.expect(!tx.reset());
    try std.testing.expectEqual(@as(u32, 0x3400_0080), io.b);
    io.ctrl = 0;
    try std.testing.expectEqual(Transaction.Result.failed, tx.poll(&io, 6));
    try std.testing.expectEqual(@as(u32, 0x3400_789a), io.b);
    try std.testing.expect(tx.reset());
    try tx.start(&io, 1, null, 7, 5);
    tx.cancel();
    io.ctrl = 0;
    try std.testing.expectEqual(Transaction.Result.failed, tx.poll(&io, 8));
}

test "lost ownership quarantines indefinitely; busy and invalid starts do not mutate" {
    var io: Fake = .{ .ctrl = busy };
    var tx: Transaction = .{};
    try std.testing.expectError(error.Busy, tx.start(&io, 0, null, 0, 1));
    try std.testing.expectEqual(@as(u32, 0), io.writes);
    io.ctrl = 0;
    try std.testing.expectError(error.InvalidDeadline, tx.start(&io, 0, null, std.math.maxInt(u64), 1));
    try tx.start(&io, 0, null, 1, 10);
    io.held = false;
    io.ctrl = 0;
    const writes = io.writes;
    try std.testing.expectEqual(Transaction.Result.pending, tx.poll(&io, 2));
    try std.testing.expectEqual(writes, io.writes);
    io.held = true;
    try std.testing.expectEqual(Transaction.Result.pending, tx.poll(&io, 3));
    try std.testing.expectEqual(writes, io.writes);
    try std.testing.expect(!tx.reset());
}

test "clock loss and clock rollback never admit a result" {
    var io: Fake = .{ .clock = false };
    var tx: Transaction = .{};
    try std.testing.expectError(error.Unavailable, tx.start(&io, 1, null, 10, 10));
    try std.testing.expectEqual(@as(u32, 0), io.writes);
    io.clock = true;
    try tx.start(&io, 1, null, 10, 10);
    io.ctrl = 0;
    try std.testing.expectEqual(Transaction.Result.failed, tx.poll(&io, 9));
    try std.testing.expect(tx.reset());
    try tx.start(&io, 1, null, 20, 10);
    io.clock = false;
    const writes = io.writes;
    try std.testing.expectEqual(Transaction.Result.pending, tx.poll(&io, 21));
    io.clock = true;
    io.ctrl = 0;
    try std.testing.expectEqual(Transaction.Result.pending, tx.poll(&io, 22));
    try std.testing.expectEqual(writes, io.writes);
}
