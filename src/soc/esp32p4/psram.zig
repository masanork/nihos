//! Read-only AP hex PSRAM discovery through MSPI3, without ROM SPI calls.
//! Register/protocol facts: ESP-IDF v5.4.4 spi1_mem_s_reg.h and
//! esp_psram_impl_ap_hex.c. Detection alone never grants memory access.
const std = @import("std");

pub const registers = struct {
    pub const command = 0x00;
    pub const address = 0x04;
    pub const control = 0x08;
    pub const user = 0x18;
    pub const user1 = 0x1c;
    pub const user2 = 0x20;
    pub const miso_length = 0x28;
    pub const misc = 0x34;
    pub const fifo = 0x58;
    pub const ddr = 0xd4;
    pub const start: u32 = 1 << 18;
};

pub const Status = enum(u32) { absent, detected, unsupported, timeout, unstable };
pub const Discovery = struct {
    status: Status,
    configuration: u16 = 0,
    identity: u16 = 0,
    bytes: u32 = 0,
};

pub fn decode(configuration: u16, identity: u16) Discovery {
    if ((configuration == 0 and identity == 0) or
        (configuration == 0xffff and identity == 0xffff)) return .{ .status = .absent, .configuration = configuration, .identity = identity };
    const vendor = (configuration >> 8) & 0x1f;
    const density = identity & 7;
    const good_die = (identity >> 5) & 7;
    const bytes: u32 = switch (density) {
        1 => 4 * 1024 * 1024,
        3 => 8 * 1024 * 1024,
        5 => 16 * 1024 * 1024,
        7 => 32 * 1024 * 1024,
        6 => 64 * 1024 * 1024,
        else => 0,
    };
    const supported = (vendor == 0x0d or vendor == 0x1a) and good_die == 6 and bytes != 0;
    return .{
        .status = if (supported) .detected else .unsupported,
        .configuration = configuration,
        .identity = identity,
        .bytes = if (supported) bytes else 0,
    };
}

/// IO supplies read/write of MSPI3-relative register offsets. Single owner,
/// before CPU1 release. A timeout poisons the controller until hardware reset.
pub fn Controller(comptime IO: type) type {
    return struct {
        io: IO,
        poll_limit: u32,
        faulted: bool = false,
        transactions: u32 = 0,

        const Self = @This();
        pub const Error = error{ Busy, Timeout, Faulted, InvalidRegister, InvalidBudget };

        pub fn readPair(self: *Self, address: u32) Error!u16 {
            if (self.faulted) return error.Faulted;
            if (address != 0 and address != 2) return error.InvalidRegister;
            if (self.poll_limit == 0) return error.InvalidBudget;
            if (self.io.read(registers.command) & registers.start != 0) return error.Busy;
            // 8-line command/address/data, DDR, no byte swapping or variable
            // dummy. CS1 only; the flash controller and its CS0 are untouched.
            self.io.write(registers.control, (1 << 2) | (7 << 4) | (1 << 9));
            self.io.write(registers.ddr, (1 << 5) | 1);
            self.io.write(registers.misc, (self.io.read(registers.misc) & ~@as(u32, 3)) | 1);
            self.io.write(registers.user, 0xf000_0000);
            self.io.write(registers.user1, (31 << 26) | 7);
            self.io.write(registers.user2, (15 << 28) | 0x4040);
            self.io.write(registers.address, address);
            self.io.write(registers.miso_length, 15);
            // A command that silently leaves the FIFO untouched must never
            // look like an absent die, or expose stale identity/capacity.
            self.io.write(registers.fifo, 0xa5a5_a5a5);
            self.io.write(registers.command, registers.start);
            for (0..self.poll_limit) |_| {
                if (self.io.read(registers.command) & registers.start == 0) {
                    self.transactions += 1;
                    return @truncate(self.io.read(registers.fifo));
                }
            }
            self.faulted = true;
            return error.Timeout;
        }

        pub fn discover(self: *Self) Discovery {
            const configuration = self.readPair(0) catch return .{ .status = .timeout };
            const identity = self.readPair(2) catch return .{ .status = .timeout };
            const repeated_configuration = self.readPair(0) catch return .{ .status = .timeout };
            const repeated_identity = self.readPair(2) catch return .{ .status = .timeout };
            if (configuration != repeated_configuration or identity != repeated_identity)
                return .{ .status = .unstable, .configuration = configuration, .identity = identity };
            return decode(configuration, identity);
        }
    };
}

test "all supported densities and vendors decode without guessing capacity" {
    const densities = [_]u16{ 1, 3, 5, 7, 6 };
    const sizes = [_]u32{ 4, 8, 16, 32, 64 };
    for ([_]u16{ 0x0d, 0x1a }) |vendor| {
        for (densities, sizes) |density, size| {
            const result = decode((vendor << 8) | 0x24, 0xc0 | density);
            try std.testing.expectEqual(Status.detected, result.status);
            try std.testing.expectEqual(size * 1024 * 1024, result.bytes);
        }
    }
}

test "absent invalid density bad die unknown vendor and stale FIFO never expose memory" {
    for ([_][2]u16{ .{ 0, 0 }, .{ 0xffff, 0xffff } }) |pair| {
        try std.testing.expectEqual(Status.absent, decode(pair[0], pair[1]).status);
    }
    for ([_][2]u16{ .{ 0x0d24, 0xc0 }, .{ 0x0d24, 0xc2 }, .{ 0x0d24, 0xc4 }, .{ 0x0d24, 0x07 }, .{ 0x1024, 0xc7 }, .{ 0xa5a5, 0xa5a5 }, .{ 0, 0xc7 } }) |pair| {
        const result = decode(pair[0], pair[1]);
        try std.testing.expectEqual(Status.unsupported, result.status);
        try std.testing.expectEqual(@as(u32, 0), result.bytes);
    }
}
