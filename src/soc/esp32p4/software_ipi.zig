//! Level doorbell supplied by the pinned platform resource owner. Queue
//! publication precedes assertion; acknowledge before acquiring queue data.
const std = @import("std");

pub const Doorbell = struct {
    pending: *volatile u32,

    pub fn fromRegister(address: u32) ?Doorbell {
        if (address == 0 or address & 3 != 0) return null;
        return .{ .pending = @ptrFromInt(address) };
    }

    pub fn raise(self: Doorbell) void {
        asm volatile ("fence iorw, iorw" ::: .{ .memory = true });
        self.pending.* = 1;
        _ = self.pending.*;
        asm volatile ("fence iorw, iorw" ::: .{ .memory = true });
    }

    pub fn acknowledge(self: Doorbell) void {
        self.pending.* = 0;
        _ = self.pending.*;
        asm volatile ("fence iorw, iorw" ::: .{ .memory = true });
    }
};

test "doorbell rejects absent and unaligned MMIO addresses" {
    try std.testing.expect(Doorbell.fromRegister(0) == null);
    try std.testing.expect(Doorbell.fromRegister(3) == null);
    try std.testing.expect(Doorbell.fromRegister(0x5000_0000) != null);
}
