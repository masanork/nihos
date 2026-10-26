//! Bounded AP hex PSRAM commands through MSPI3, without ROM SPI calls.
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
    pub const mosi_length = 0x24;
    pub const miso_length = 0x28;
    pub const misc = 0x34;
    pub const cache_control = 0x3c;
    pub const fifo = 0x58;
    pub const ddr = 0xd4;
    pub const start: u32 = 1 << 18;
    pub const four_byte_address: u32 = 1 << 1;
};

pub const Status = enum(u32) { absent, detected, unsupported, timeout, unstable };
pub const Discovery = struct {
    status: Status,
    configuration: u16 = 0,
    identity: u16 = 0,
    bytes: u32 = 0,
};
pub const Modes = struct { mr0: u32, mr4: u32, mr8: u32 };
pub const Exercise = struct {
    mr0: u32 = 0,
    mr4: u32 = 0,
    mr8: u32 = 0,
    addresses: u32 = 0,
    passes: u32 = 0,
    reads: u32 = 0,
    writes: u32 = 0,
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
        capacity: u32 = 0,

        const Self = @This();
        pub const Error = error{ Busy, Timeout, Faulted, InvalidRegister, InvalidBudget, Unqualified, OutOfRange, ModeMismatch, DataMismatch };
        const Operation = enum(u16) { read_mode = 0x4040, write_mode = 0xc0c0, read_data = 0, write_data = 0x8080 };

        pub fn readPair(self: *Self, address: u32) Error!u16 {
            if (address != 0 and address != 2 and address != 4) return error.InvalidRegister;
            return @truncate(try self.transfer(.read_mode, address, 0, 16, 8));
        }

        noinline fn transfer(self: *Self, operation: Operation, address: u32, value: u32, bits: u6, dummy: u6) Error!u32 {
            if (self.faulted) return error.Faulted;
            if (self.poll_limit == 0) return error.InvalidBudget;
            if (self.io.read(registers.command) & registers.start != 0) return error.Busy;
            const writing = operation == .write_mode or operation == .write_data;
            // 8-line command/address/data, DDR, no byte swapping or variable
            // dummy. CS1 only; the flash controller and its CS0 are untouched.
            self.io.write(registers.control, (1 << 2) | (7 << 4) | (1 << 9));
            self.io.write(registers.ddr, (1 << 5) | 1);
            self.io.write(registers.misc, (self.io.read(registers.misc) & ~@as(u32, 3)) | 1);
            self.io.write(registers.user, 0xc000_0000 | (if (dummy != 0) @as(u32, 1 << 29) else 0) |
                (if (writing) @as(u32, 1 << 27) else @as(u32, 1 << 28)));
            self.io.write(registers.user1, (31 << 26) | (if (dummy != 0) @as(u32, dummy - 1) else 0));
            self.io.write(registers.user2, (15 << 28) | @as(u32, @backingInt(operation)));
            self.io.write(registers.address, address);
            // USER1's 32-bit length is not sufficient on physical P4. Match
            // ROM spi_cmd_config's separate CACHE_USR_ADDR_4BYTE gate, keeping
            // the rest of this MSPI3 register intact.
            self.io.write(registers.cache_control, self.io.read(registers.cache_control) | registers.four_byte_address);
            self.io.write(registers.miso_length, if (writing) 0 else bits - 1);
            self.io.write(registers.mosi_length, if (writing) bits - 1 else 0);
            // A command that silently leaves the FIFO untouched must never
            // look like an absent die, or expose stale identity/capacity.
            self.io.write(registers.fifo, if (writing) value else 0xa5a5_a5a5);
            self.io.write(registers.command, registers.start);
            for (0..self.poll_limit) |_| {
                if (self.io.read(registers.command) & registers.start == 0) {
                    self.transactions += 1;
                    return if (writing) 0 else self.io.read(registers.fifo);
                }
            }
            self.faulted = true;
            return error.Timeout;
        }

        /// Initial data tests use x8, fixed read latency 2/write latency 2.
        /// MMU/AXI x16 operation and high-speed tuning are separate stages.
        pub fn configure(self: *Self, found: Discovery) Error!Modes {
            self.capacity = 0;
            const checked = decode(found.configuration, found.identity);
            if (found.status != .detected or checked.status != .detected or found.bytes != checked.bytes)
                return error.Unqualified;
            const mr4 = try self.readPair(4);
            const mr8 = try self.transfer(.read_mode, 8, 0, 8, 8);
            const desired0 = (found.configuration & 0xffc0) | 0x28;
            const desired4 = (mr4 & 0xff1f) | 0x40;
            const desired8 = (mr8 & 0xb0) | 0x0b;
            _ = try self.transfer(.write_mode, 0, desired0, 16, 0);
            _ = try self.transfer(.write_mode, 4, desired4, 16, 0);
            _ = try self.transfer(.write_mode, 8, desired8, 16, 0);
            if ((try self.readPair(0)) != desired0 or
                (try self.readPair(4)) & 0xff != desired4 & 0xff or
                (try self.transfer(.read_mode, 8, 0, 8, 8)) & 0xff != desired8 or
                (try self.readPair(2)) != found.identity) return error.ModeMismatch;
            self.capacity = found.bytes;
            return .{ .mr0 = desired0 & 0xff, .mr4 = desired4 & 0xff, .mr8 = desired8 };
        }

        fn checkAddress(self: *const Self, address: u32) Error!void {
            if (self.faulted) return error.Faulted;
            if (self.capacity == 0) return error.Unqualified;
            if (address & 3 != 0 or address > self.capacity - 4) return error.OutOfRange;
        }

        pub noinline fn writeWord(self: *Self, address: u32, value: u32) Error!void {
            try self.checkAddress(address);
            _ = try self.transfer(.write_data, address, value, 32, 8);
        }

        pub noinline fn readWord(self: *Self, address: u32) Error!u32 {
            try self.checkAddress(address);
            return self.transfer(.read_data, address, 0, 32, 18);
        }

        /// Destructive boot qualification, before any external memory users.
        /// Write all sampled addresses first, then verify, to catch aliasing.
        pub fn exercise(self: *Self, found: Discovery) Error!Exercise {
            const modes = try self.configure(found);
            var addresses: [26]u32 = undefined;
            addresses[0] = 0;
            var length: usize = 1;
            var offset: u32 = 4;
            while (offset < self.capacity) : (offset *= 2) {
                addresses[length] = offset;
                length += 1;
            }
            addresses[length] = self.capacity - 4;
            length += 1;
            for (0..2) |pass| {
                for (addresses[0..length]) |address| {
                    const value = 0x5a6b_7c8d ^ address;
                    try self.writeWord(address, if (pass == 0) value else ~value);
                }
                for (addresses[0..length]) |address| {
                    const value = 0x5a6b_7c8d ^ address;
                    if (try self.readWord(address) != (if (pass == 0) value else ~value)) {
                        self.capacity = 0;
                        self.faulted = true;
                        return error.DataMismatch;
                    }
                }
            }
            return .{ .mr0 = modes.mr0, .mr4 = modes.mr4, .mr8 = modes.mr8, .addresses = @intCast(length), .passes = 2, .reads = @intCast(length * 2), .writes = @intCast(length * 2) };
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
