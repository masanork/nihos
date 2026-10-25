//! Pure decoding for ESP32-P4 CLIC `mcause` values.
//!
//! Hardware entry code should preserve the raw value: on CLIC, bits above the
//! low cause field also carry the previous interrupt level and privilege mode.

const std = @import("std");

pub const interrupt_bit: u32 = 0x8000_0000;
pub const minhv_bit: u32 = 0x4000_0000;
pub const previous_privilege_mask: u32 = 0x3000_0000;
pub const previous_level_mask: u32 = 0x00ff_0000;
pub const reason_mask: u32 = 0x0000_0fff;

pub const Kind = enum {
    exception,
    interrupt,
};

pub const Cause = struct {
    raw: u32,
    kind: Kind,
    reason: u12,
    minhv: bool,
    previous_privilege: u2,
    previous_interrupt_level: u8,

    pub fn decode(raw: u32) Cause {
        return .{
            .raw = raw,
            .kind = if (raw & interrupt_bit != 0) .interrupt else .exception,
            .reason = @intCast(raw & reason_mask),
            .minhv = raw & minhv_bit != 0,
            .previous_privilege = @intCast((raw & previous_privilege_mask) >> 28),
            .previous_interrupt_level = @intCast((raw & previous_level_mask) >> 16),
        };
    }

    pub fn isException(self: Cause, reason: Exception) bool {
        return self.kind == .exception and self.reason == @backingInt(reason);
    }
};

pub const Exception = enum(u12) {
    instruction_address_misaligned = 0,
    instruction_access_fault = 1,
    illegal_instruction = 2,
    breakpoint = 3,
    load_address_misaligned = 4,
    load_access_fault = 5,
    store_address_misaligned = 6,
    store_access_fault = 7,
    environment_call_from_user = 8,
    environment_call_from_machine = 11,
};

test "CLIC interrupt metadata and reason are decoded independently" {
    const cause = Cause.decode(
        interrupt_bit | minhv_bit | (3 << 28) | (42 << 16) | 0x123,
    );
    try std.testing.expectEqual(Kind.interrupt, cause.kind);
    try std.testing.expectEqual(@as(u12, 0x123), cause.reason);
    try std.testing.expect(cause.minhv);
    try std.testing.expectEqual(@as(u2, 3), cause.previous_privilege);
    try std.testing.expectEqual(@as(u8, 42), cause.previous_interrupt_level);
}

test "exception matching does not confuse the interrupt bit" {
    const illegal = Cause.decode(2);
    try std.testing.expect(illegal.isException(.illegal_instruction));
    const interrupt = Cause.decode(interrupt_bit | 2);
    try std.testing.expect(!interrupt.isException(.illegal_instruction));
}
