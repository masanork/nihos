//! Fail-closed clock observation for a reserved P4 entropy session.
//! This detects observed changes; it does not own or qualify clocks.

pub const root: usize = 0x500e6004;
pub const mem_sys: usize = 0x500e6008;
pub const apb: usize = 0x500e600c;
pub const source: usize = 0x50111040;
const update: u32 = 1 << 4;

/// The caller must obtain these values from a separately verified boot clock
/// result and retain exclusive clock/power ownership throughout observation.
/// The P4 boot clock currently supports this one observed configuration.
pub const Receipt = struct {
    root: u32,
    mem_sys: u32,
    apb: u32,
    source: u32,
    cpu_hz: u32,
    apb_hz: u32,
};

/// IO supplies bounded owned(), read(address) and counter() ?u64 methods.
/// counter() returns monotonic microseconds or null if unavailable. The clock
/// owner must prevent even transient changes between observations. A loss of
/// ownership, clock mismatch, failed timer read or rollback latches failure.
/// An instance must not be copied while active.
pub fn Guard(comptime IO: type) type {
    return struct {
        const Self = @This();
        io: *IO,
        receipt: Receipt,
        last: u64 = 0,
        active: bool = false,
        failed: bool = false,

        pub fn init(io: *IO, receipt: Receipt) Self {
            return .{ .io = io, .receipt = receipt };
        }
        fn matches(self: *Self) bool {
            return self.receipt.cpu_hz == 360_000_000 and self.receipt.apb_hz == 90_000_000 and
                self.receipt.root & (update | 0x1fffffe0) == 0 and
                self.receipt.mem_sys & 0xff0000ff == 1 and
                self.receipt.apb & 0x00ff0000 == 1 << 16 and self.receipt.source & 3 == 1 and
                self.io.read(root) == self.receipt.root and self.io.read(mem_sys) == self.receipt.mem_sys and
                self.io.read(apb) == self.receipt.apb and self.io.read(source) == self.receipt.source;
        }
        pub fn begin(self: *Self) bool {
            if (self.active or self.failed) return false;
            if (!self.io.owned() or !self.matches()) {
                self.failed = true;
                return false;
            }
            self.last = self.io.counter() orelse {
                self.failed = true;
                return false;
            };
            self.active = true;
            return true;
        }
        pub fn ready(self: *Self) bool {
            if (self.failed) return false;
            if (!self.active and !self.begin()) return false;
            if (!self.io.owned() or !self.matches()) {
                self.failed = true;
                return false;
            }
            const now = self.io.counter() orelse {
                self.failed = true;
                return false;
            };
            if (now < self.last) {
                self.failed = true;
                return false;
            }
            self.last = now;
            return true;
        }
        pub fn cpuHz(self: *Self) u32 {
            return if (self.active and !self.failed) self.receipt.cpu_hz else 0;
        }
        pub fn apbHz(self: *Self) u32 {
            return if (self.active and !self.failed) self.receipt.apb_hz else 0;
        }
        pub fn nowMicros(self: *Self) u64 {
            return if (self.ready()) self.last else 0;
        }
    };
}

const std = @import("std");
const Fake = struct {
    owned_: bool = true,
    root_: u32 = 0,
    mem_: u32 = 1,
    apb_: u32 = 1 << 16,
    source_: u32 = 1,
    now: ?u64 = 10,
    pub fn owned(self: *@This()) bool {
        return self.owned_;
    }
    pub fn counter(self: *@This()) ?u64 {
        return self.now;
    }
    pub fn read(self: *@This(), address: usize) u32 {
        return switch (address) {
            root => self.root_,
            mem_sys => self.mem_,
            apb => self.apb_,
            source => self.source_,
            else => unreachable,
        };
    }
    fn receipt(self: *@This()) Receipt {
        return .{ .root = self.root_, .mem_sys = self.mem_, .apb = self.apb_, .source = self.source_, .cpu_hz = 360_000_000, .apb_hz = 90_000_000 };
    }
};

test "verified boot values remain available while owned and monotonic" {
    var io: Fake = .{};
    var guard = Guard(Fake).init(&io, io.receipt());
    try std.testing.expect(guard.begin() and guard.ready());
    io.now = 11;
    try std.testing.expectEqual(@as(u64, 11), guard.nowMicros());
    try std.testing.expectEqual(@as(u32, 360_000_000), guard.cpuHz());
    try std.testing.expectEqual(@as(u32, 90_000_000), guard.apbHz());
}

test "observed clock change and owner loss latch unavailable" {
    for (0..5) |case| {
        var io: Fake = .{};
        var guard = Guard(Fake).init(&io, io.receipt());
        try std.testing.expect(guard.begin());
        switch (case) {
            0 => io.root_ ^= 1 << 5,
            1 => io.mem_ ^= 1,
            2 => io.apb_ ^= 1 << 16,
            3 => io.source_ ^= 1,
            4 => io.owned_ = false,
            else => unreachable,
        }
        try std.testing.expect(!guard.ready());
        try std.testing.expectEqual(@as(u32, 0), guard.cpuHz());
        io = .{};
        try std.testing.expect(!guard.ready() and !guard.begin());
    }
}

test "invalid initial receipt, timer failure and rollback fail closed" {
    var io: Fake = .{};
    var receipt = io.receipt();
    receipt.cpu_hz = 160_000_000;
    var bad = Guard(Fake).init(&io, receipt);
    try std.testing.expect(!bad.begin());
    io.root_ = 1 << 5;
    var mislabeled = Guard(Fake).init(&io, io.receipt());
    try std.testing.expect(!mislabeled.begin());
    for (0..2) |case| {
        io = .{};
        var guard = Guard(Fake).init(&io, io.receipt());
        try std.testing.expect(guard.begin());
        io.now = if (case == 0) null else 9;
        try std.testing.expectEqual(@as(u64, 0), guard.nowMicros());
        try std.testing.expect(!guard.ready());
    }
}
