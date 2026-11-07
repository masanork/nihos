//! P4 RNG and LP timer register access for the SSH entropy backend.
//! This is not a resource owner, clock provider, or entropy qualification.

pub const rng_register: usize = 0x501101a4;
pub const timer_update: usize = 0x50112010;
pub const timer_value_low: usize = 0x50112014;
const timer_snapshot: u32 = 1 << 28;

/// Caller must already own RNG, ADC, analog, power/clock and LP timer resources.
/// Clock supplies bounded ready(), cpuHz(), apbHz() and nowMicros() callbacks.
/// Access supplies bounded read(), write() and cycles() callbacks; MMIO writes
/// must be ordered before later reads. Neither interface qualifies the source.
pub fn Hardware(comptime Access: type, comptime Clock: type) type {
    return struct {
        const Self = @This();
        access: *Access,
        clock: *Clock,

        pub fn clockReady(self: *Self) bool {
            return self.clock.ready();
        }
        pub fn cpuHz(self: *Self) u32 {
            return self.clock.cpuHz();
        }
        pub fn apbHz(self: *Self) u32 {
            return self.clock.apbHz();
        }
        pub fn nowMicros(self: *Self) u64 {
            return self.clock.nowMicros();
        }
        pub fn cycles(self: *Self) u32 {
            return self.access.cycles();
        }
        pub fn readRng(self: *Self) u32 {
            return self.access.read(rng_register);
        }
        /// Matches the IDF P4 LP timer buffer-0 snapshot sequence. This shifts
        /// the snapshot buffers, so exclusion from other snapshot users matters.
        pub fn lowTimerByte(self: *Self) u8 {
            self.access.write(timer_update, self.access.read(timer_update) | timer_snapshot);
            return @truncate(self.access.read(timer_value_low));
        }
        pub fn read(self: *Self, address: usize) u32 {
            return self.access.read(address);
        }
        pub fn write(self: *Self, address: usize, value: u32) void {
            self.access.write(address, value);
        }
    };
}

/// Raw P4 access. Use only with the reservation and clock guarantees above.
pub const NativeAccess = struct {
    pub fn read(_: *@This(), address: usize) u32 {
        return @as(*const volatile u32, @ptrFromInt(address)).*;
    }
    pub fn write(_: *@This(), address: usize, value: u32) void {
        @as(*volatile u32, @ptrFromInt(address)).* = value;
        asm volatile ("fence iorw,iorw" ::: .{ .memory = true });
    }
    pub fn cycles(_: *@This()) u32 {
        return asm volatile ("csrr %[value], mcycle"
            : [value] "=r" (-> u32),
        );
    }
};

const std = @import("std");
test "P4 snapshot preserves timer control and reads the new buffer" {
    const Access = struct {
        update: u32 = 0x60000000,
        buffer: u32 = 0,
        calls: u8 = 0,
        pub fn read(self: *@This(), address: usize) u32 {
            self.calls += 1;
            return switch (address) {
                timer_update => self.update,
                timer_value_low => self.buffer,
                rng_register => 0x12345678,
                else => unreachable,
            };
        }
        pub fn write(self: *@This(), address: usize, value: u32) void {
            std.debug.assert(address == timer_update);
            self.calls += 1;
            self.update = value;
            if (value & timer_snapshot != 0) self.buffer = 0xabcdef92;
        }
        pub fn cycles(_: *@This()) u32 {
            return 42;
        }
    };
    const Clock = struct {
        pub fn ready(_: *@This()) bool {
            return true;
        }
        pub fn cpuHz(_: *@This()) u32 {
            return 360_000_000;
        }
        pub fn apbHz(_: *@This()) u32 {
            return 90_000_000;
        }
        pub fn nowMicros(_: *@This()) u64 {
            return 123;
        }
    };
    var access: Access = .{};
    var clock: Clock = .{};
    var hw = Hardware(Access, Clock){ .access = &access, .clock = &clock };
    try std.testing.expectEqual(@as(u8, 0x92), hw.lowTimerByte());
    try std.testing.expectEqual(@as(u32, 0x70000000), access.update);
    try std.testing.expectEqual(@as(u8, 3), access.calls);
    try std.testing.expectEqual(@as(u32, 0x12345678), hw.readRng());
    try std.testing.expect(hw.clockReady() and hw.cpuHz() == 360_000_000 and hw.apbHz() == 90_000_000);
    try std.testing.expect(hw.nowMicros() == 123 and hw.cycles() == 42);
}
