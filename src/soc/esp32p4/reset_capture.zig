//! Read-only snapshot before native watchdog/timer initialization.
//! ESP-IDF v5.4.4 esp32p4 hw_ver1 lp_clkrst/hp_sys_clkrst/timer_group
//! register definitions and esp32p4.rom.ld. Saved PCs are raw ROM storage:
//! no validity or attribution to the most recent reset is implied.
const std = @import("std");

pub const Snapshot = struct {
    cpu0: u32,
    ack: u32 = 1,
    raw_cause: u32,
    lp: u32,
    cpu1: u32,
    reset_flags: u32,
    saved_pc0: u32,
    saved_pc1: u32,
    clock_gates: u32,
    wdt_valid: u32,
    wdt0: u32,
    wdt1: u32,
};

/// IO exposes only read32; no reset flag clear, clock enable or WDT write.
pub inline fn sample(io: anytype, saved_pc: usize) Snapshot {
    const raw = io.read32(0x50111010);
    const gates = io.read32(0x500e601c);
    const valid = (gates >> 21) & 3;
    return .{
        .cpu0 = (raw >> 7) & 63,
        .raw_cause = raw,
        .lp = raw & 63,
        .cpu1 = (raw >> 14) & 63,
        .reset_flags = ((raw >> 6) & 1) | (((raw >> 13) & 1) << 1) | (((raw >> 20) & 1) << 2),
        .saved_pc0 = io.read32(saved_pc),
        .saved_pc1 = io.read32(saved_pc + 4),
        .clock_gates = gates,
        .wdt_valid = valid,
        .wdt0 = if (valid & 1 != 0) io.read32(0x500c2048) else 0,
        .wdt1 = if (valid & 2 != 0) io.read32(0x500c3048) else 0,
    };
}

const Model = struct {
    gates: u32,
    reads: u32 = 0,
    fn read32(self: *Model, address: usize) u32 {
        self.reads += 1;
        return switch (address) {
            0x50111010 => 0x80000000 | (1 << 20) | (23 << 14) | (1 << 13) | (7 << 7) | (1 << 6) | 16,
            0x500e601c => self.gates,
            0x4ff3fff8 => 0x4fc12345,
            0x4ff3fffc => 0xffffffff,
            0x500c2048 => if (self.gates & (1 << 21) != 0) 0xdeadbeef else unreachable,
            0x500c3048 => if (self.gates & (1 << 22) != 0) 0x80000001 else unreachable,
            else => unreachable,
        };
    }
};

test "snapshot decodes all causes and flags while retaining raw saved PCs" {
    var io = Model{ .gates = 3 << 21 };
    const result = sample(&io, 0x4ff3fff8);
    try std.testing.expectEqual(@as(u32, 7), result.cpu0);
    try std.testing.expectEqual(@as(u32, 16), result.lp);
    try std.testing.expectEqual(@as(u32, 23), result.cpu1);
    try std.testing.expectEqual(@as(u32, 7), result.reset_flags);
    try std.testing.expectEqual(@as(u32, 0x8015e3d0), result.raw_cause);
    try std.testing.expectEqual(@as(u32, 0x4fc12345), result.saved_pc0);
    try std.testing.expectEqual(@as(u32, 0xffffffff), result.saved_pc1);
    try std.testing.expectEqual(@as(u32, 0xdeadbeef), result.wdt0);
    try std.testing.expectEqual(@as(u32, 0x80000001), result.wdt1);
}

test "gated watchdogs are never read and absent values cannot imply disabled" {
    for (0..4) |mask| {
        var io = Model{ .gates = @as(u32, @intCast(mask)) << 21 };
        const result = sample(&io, 0x4ff3fff8);
        try std.testing.expectEqual(@as(u32, @intCast(mask)), result.wdt_valid);
        try std.testing.expectEqual(4 + @as(u32, @popCount(@as(u2, @intCast(mask)))), io.reads);
        if (mask & 1 == 0) try std.testing.expectEqual(@as(u32, 0), result.wdt0);
        if (mask & 2 == 0) try std.testing.expectEqual(@as(u32, 0), result.wdt1);
    }
}
