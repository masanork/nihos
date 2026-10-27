//! A scripted command-register model, not an electrical PSRAM model.
const std = @import("std");
const psram = @import("psram.zig");
const regs = psram.registers;

const Model = struct {
    words: [64]u32 = @splat(0),
    responses: [4]u16 = .{ 0x0d00, 0xcf, 0x0d00, 0xcf },
    addresses: [4]u32 = @splat(0),
    starts: usize = 0,
    writes: usize = 0,
    polls: u32 = 0,
    pending: u32 = 0,
    latency: u32 = 2,
    stuck: bool = false,
    update_fifo: bool = true,
    valid_phases: bool = true,
    drop_four_byte_gate: bool = false,

    pub fn read(self: *Model, offset: usize) u32 {
        if (offset == regs.command and self.pending != 0) {
            self.polls += 1;
            if (!self.stuck) {
                self.pending -= 1;
                if (self.pending == 0) {
                    self.words[regs.command / 4] &= ~regs.start;
                    if (self.update_fifo) {
                        // With the independent four-byte gate closed, the
                        // requested identity register is not addressable.
                        self.words[regs.fifo / 4] = if (self.words[regs.cache_control / 4] & regs.four_byte_address != 0)
                            self.responses[self.starts - 1]
                        else
                            self.responses[0];
                    }
                }
            }
        }
        return self.words[offset / 4];
    }

    pub fn write(self: *Model, offset: usize, value: u32) void {
        self.writes += 1;
        self.words[offset / 4] = value;
        if (offset == regs.cache_control and self.drop_four_byte_gate)
            self.words[offset / 4] &= ~regs.four_byte_address;
        if (offset == regs.command and value & regs.start != 0) {
            // Fixed register-read protocol: command=16, address=32,
            // dummy=8, input=16 bits, CS1, low FIFO, DDR/octal phases.
            self.valid_phases = self.valid_phases and
                self.words[regs.user2 / 4] == 0xf0004040 and
                self.words[regs.user1 / 4] == 0x7c000007 and
                self.words[regs.user / 4] == 0xf0000000 and
                self.words[regs.control / 4] == 0x274 and
                self.words[regs.ddr / 4] == 0x21 and
                self.words[regs.cache_control / 4] & regs.four_byte_address != 0 and
                self.words[regs.miso_length / 4] == 15 and
                self.words[regs.misc / 4] & 3 == 1;
            self.addresses[self.starts] = self.words[regs.address / 4];
            self.starts += 1;
            self.pending = self.latency;
        }
    }
};

test "discovery waits for completion and repeats both identity pairs" {
    var model = Model{};
    var controller = psram.Controller(*Model){ .io = &model, .poll_limit = 2 };
    const result = controller.discover();
    try std.testing.expectEqual(psram.Status.detected, result.status);
    try std.testing.expectEqual(@as(u32, 32 * 1024 * 1024), result.bytes);
    try std.testing.expectEqual(@as(u32, 4), controller.transactions);
    try std.testing.expectEqual(@as(u32, 8), model.polls);
    try std.testing.expectEqualSlices(u32, &.{ 0, 2, 0, 2 }, &model.addresses);
    try std.testing.expect(model.valid_phases);
}

test "32-bit address length also needs the four-byte gate and preserves other controls" {
    var model = Model{};
    model.words[regs.cache_control / 4] = 0x4000_0200;
    var controller = psram.Controller(*Model){ .io = &model, .poll_limit = 2 };
    try std.testing.expectEqual(psram.Status.detected, controller.discover().status);
    try std.testing.expectEqual(@as(u32, 0x4000_0202), model.words[regs.cache_control / 4]);
    var dropped = Model{ .drop_four_byte_gate = true };
    var rejected = psram.Controller(*Model){ .io = &dropped, .poll_limit = 2 };
    const found = rejected.discover();
    try std.testing.expectEqual(psram.Status.unsupported, found.status);
    try std.testing.expectEqual(@as(u32, 0), found.bytes);
    try std.testing.expectEqual(@as(u32, 31), dropped.words[regs.user1 / 4] >> 26);
}

test "a stuck command has a fixed poll budget and poisons reuse" {
    var model = Model{ .stuck = true };
    var controller = psram.Controller(*Model){ .io = &model, .poll_limit = 3 };
    try std.testing.expectError(error.Timeout, controller.readPair(0));
    const writes = model.writes;
    try std.testing.expectError(error.Faulted, controller.readPair(2));
    try std.testing.expectEqual(@as(u32, 3), model.polls);
    try std.testing.expectEqual(@as(usize, 1), model.starts);
    try std.testing.expectEqual(writes, model.writes);
    try std.testing.expectEqual(@as(u32, 0), controller.transactions);
}

test "busy controller invalid register and empty budget do not overwrite registers" {
    var model = Model{};
    var controller = psram.Controller(*Model){ .io = &model, .poll_limit = 2 };
    model.words[regs.command / 4] = regs.start;
    try std.testing.expectError(error.Busy, controller.readPair(0));
    model.words[regs.command / 4] = 0;
    try std.testing.expectError(error.InvalidRegister, controller.readPair(1));
    controller.poll_limit = 0;
    try std.testing.expectError(error.InvalidBudget, controller.readPair(0));
    try std.testing.expectEqual(@as(usize, 0), model.writes);
}

test "a changed identity cannot publish either capacity" {
    var model = Model{ .responses = .{ 0x0d00, 0xcf, 0x0d00, 0xcd } };
    var controller = psram.Controller(*Model){ .io = &model, .poll_limit = 2 };
    const result = controller.discover();
    try std.testing.expectEqual(psram.Status.unstable, result.status);
    try std.testing.expectEqual(@as(u32, 0), result.bytes);
}

test "untouched FIFO cannot look like a detected or absent die" {
    var model = Model{ .update_fifo = false };
    var controller = psram.Controller(*Model){ .io = &model, .poll_limit = 2 };
    const result = controller.discover();
    try std.testing.expectEqual(psram.Status.unsupported, result.status);
    try std.testing.expectEqual(@as(u16, 0xa5a5), result.configuration);
    try std.testing.expectEqual(@as(u32, 0), result.bytes);
}

test "late completion cannot be counted as successful discovery" {
    var model = Model{ .latency = 3 };
    var controller = psram.Controller(*Model){ .io = &model, .poll_limit = 2 };
    const result = controller.discover();
    try std.testing.expectEqual(psram.Status.timeout, result.status);
    try std.testing.expectEqual(@as(u32, 0), result.bytes);
    try std.testing.expectEqual(@as(u32, 0), controller.transactions);
}

const Device = struct {
    words: [64]u32 = @splat(0),
    modes: [16]u8 = .{ 0, 0x0d, 0xcf, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    memory: [26]Cell = @splat(.{}),
    pending: u32 = 0,
    alias_mask: u32 = 0xffff_ffff,
    drop_modes: bool = false,
    corrupt_data: bool = false,
    stall_data_write: bool = false,
    data_reads: u32 = 0,
    data_writes: u32 = 0,
    valid_phases: bool = true,
    enforce_mode_dummy: bool = false,

    const Cell = struct { address: u32 = 0, value: u32 = 0, occupied: bool = false };

    pub fn read(self: *Device, offset: usize) u32 {
        if (offset == regs.command and self.pending != 0) {
            if (!(self.stall_data_write and self.opcode() == 0x8080)) {
                self.pending -= 1;
                if (self.pending == 0) {
                    self.complete();
                    self.words[regs.command / 4] &= ~regs.start;
                }
            }
        }
        return self.words[offset / 4];
    }

    pub fn write(self: *Device, offset: usize, value: u32) void {
        self.words[offset / 4] = value;
        if (offset == regs.command and value & regs.start != 0) self.pending = 2;
    }

    fn opcode(self: *const Device) u16 {
        return @truncate(self.words[regs.user2 / 4]);
    }

    fn cell(self: *Device, address: u32) *Cell {
        for (&self.memory) |*entry| if (entry.occupied and entry.address == address) return entry;
        for (&self.memory) |*entry| {
            if (!entry.occupied) {
                entry.* = .{ .address = address, .occupied = true };
                return entry;
            }
        }
        unreachable;
    }

    fn complete(self: *Device) void {
        const operation = self.opcode();
        const writing = operation == 0xc0c0 or operation == 0x8080;
        const mode = operation == 0x4040 or operation == 0xc0c0;
        const fast = self.modes[0] & 0x1c == 0x10;
        const dummy: u32 = if (operation == 0xc0c0) 0 else if (operation == 0) (if (fast) 26 else 18) else (if (fast) 12 else 8);
        const address = self.words[regs.address / 4];
        if (self.enforce_mode_dummy and operation == 0x4040 and self.words[regs.user1 / 4] & 63 != dummy - 1) {
            self.words[regs.fifo / 4] = 0xa5a5a5a5;
            return;
        }
        const count: u32 = if (mode) (if (operation == 0x4040 and address == 8) 8 else 16) else 32;
        const expected_user: u32 = 0xc0000000 | (if (dummy == 0) @as(u32, 0) else 1 << 29) |
            (if (writing) @as(u32, 1 << 27) else 1 << 28);
        self.valid_phases = self.valid_phases and
            self.words[regs.user2 / 4] >> 28 == 15 and
            self.words[regs.user1 / 4] >> 26 == 31 and
            self.words[regs.user1 / 4] & 63 == (if (dummy == 0) 0 else dummy - 1) and
            self.words[regs.user / 4] == expected_user and
            self.words[regs.control / 4] == 0x274 and self.words[regs.ddr / 4] == 0x21 and
            self.words[regs.misc / 4] & 3 == 1 and
            self.words[regs.mosi_length / 4] == (if (writing) count - 1 else 0) and
            self.words[regs.miso_length / 4] == (if (writing) 0 else count - 1);
        if (operation == 0x4040) {
            const index: usize = @intCast(address);
            self.words[regs.fifo / 4] = @as(u32, self.modes[index]) |
                (if (count == 16) @as(u32, self.modes[index + 1]) << 8 else 0);
        } else if (operation == 0xc0c0) {
            if (!self.drop_modes) self.modes[@intCast(address)] = @truncate(self.words[regs.fifo / 4]);
        } else if (operation == 0x8080) {
            self.cell(address & self.alias_mask).value = self.words[regs.fifo / 4];
            self.data_writes += 1;
        } else if (operation == 0) {
            self.words[regs.fifo / 4] = self.cell(address & self.alias_mask).value ^ @as(u32, @intFromBool(self.corrupt_data));
            self.data_reads += 1;
        } else unreachable;
    }
};

test "mode readback and both full-address-set data passes complete" {
    var device = Device{};
    var controller = psram.Controller(*Device){ .io = &device, .poll_limit = 2 };
    const found = controller.discover();
    const result = try controller.exercise(found);
    try std.testing.expectEqual(@as(u32, 25), result.addresses);
    try std.testing.expectEqual(@as(u32, 2), result.passes);
    try std.testing.expectEqual(@as(u32, 50), device.data_writes);
    try std.testing.expectEqual(@as(u32, 50), device.data_reads);
    try std.testing.expectEqual(@as(u32, 113), controller.transactions);
    try std.testing.expectEqual(@as(u32, 0x28), result.mr0);
    try std.testing.expectEqual(@as(u32, 0x40), result.mr4);
    try std.testing.expectEqual(@as(u32, 0x0b), result.mr8);
    try std.testing.expect(device.valid_phases);
}

test "each sampled address-line alias is detected before capacity can be used again" {
    for (2..25) |bit| {
        var device = Device{ .alias_mask = ~(@as(u32, 1) << @as(u5, @intCast(bit))) };
        var controller = psram.Controller(*Device){ .io = &device, .poll_limit = 2 };
        const found = controller.discover();
        try std.testing.expectError(error.DataMismatch, controller.exercise(found));
        try std.testing.expectEqual(@as(u32, 0), controller.capacity);
        try std.testing.expectError(error.Faulted, controller.readWord(0));
    }
}

test "lost mode writes prevent all data commands" {
    var device = Device{ .drop_modes = true };
    var controller = psram.Controller(*Device){ .io = &device, .poll_limit = 2 };
    const found = controller.discover();
    try std.testing.expectError(error.ModeMismatch, controller.configure(found));
    try std.testing.expectError(error.Unqualified, controller.writeWord(0, 1));
    try std.testing.expectEqual(@as(u32, 0), device.data_writes);
}

test "a timed out data write poisons further reads and writes" {
    var device = Device{ .stall_data_write = true };
    var controller = psram.Controller(*Device){ .io = &device, .poll_limit = 2 };
    const found = controller.discover();
    _ = try controller.configure(found);
    try std.testing.expectError(error.Timeout, controller.writeWord(0, 1));
    try std.testing.expectError(error.Faulted, controller.readWord(0));
    try std.testing.expectError(error.Faulted, controller.writeWord(4, 2));
    try std.testing.expectEqual(@as(u32, 0), device.data_writes);
}

test "data access requires verified identity and respects the final word boundary" {
    var device = Device{};
    var controller = psram.Controller(*Device){ .io = &device, .poll_limit = 2 };
    try std.testing.expectError(error.Unqualified, controller.readWord(0));
    var found = controller.discover();
    found.bytes *= 2;
    try std.testing.expectError(error.Unqualified, controller.configure(found));
    found.bytes /= 2;
    _ = try controller.configure(found);
    const before = controller.transactions;
    try std.testing.expectError(error.OutOfRange, controller.readWord(found.bytes));
    try std.testing.expectError(error.OutOfRange, controller.writeWord(found.bytes - 2, 1));
    try std.testing.expectError(error.OutOfRange, controller.readWord(0xffff_fffc));
    try std.testing.expectEqual(before, controller.transactions);
    try controller.writeWord(found.bytes - 4, 0x12345678);
    try std.testing.expectEqual(@as(u32, 0x12345678), try controller.readWord(found.bytes - 4));
}

test "data corruption revokes the command capacity" {
    var device = Device{ .corrupt_data = true };
    var controller = psram.Controller(*Device){ .io = &device, .poll_limit = 2 };
    const found = controller.discover();
    try std.testing.expectError(error.DataMismatch, controller.exercise(found));
    try std.testing.expectEqual(@as(u32, 0), controller.capacity);
}

test "200 MHz mode transition updates mode latency before data qualification" {
    var device = Device{};
    var controller = psram.Controller(*Device){ .io = &device, .poll_limit = 2 };
    const found = controller.discover();
    const modes = try controller.configureProfile(found, .fast200x16);
    try std.testing.expectEqualDeep(psram.Modes{ .mr0 = 0x30, .mr4 = 0x20, .mr8 = 0x4b }, modes);
    try controller.writeWord(0, 0x5a6b7c8d);
    try std.testing.expectEqual(@as(u32, 0x5a6b7c8d), try controller.readWord(0));
    try std.testing.expect(device.valid_phases);
    _ = try controller.configureProfile(found, .safe20x8);
    try controller.writeWord(0, 0xa55aff00);
    try std.testing.expectEqual(@as(u32, 0xa55aff00), try controller.readWord(0));
    try std.testing.expect(device.valid_phases);
}

test "retained 200 MHz mode can be identified and returned to conservative boot mode" {
    var device = Device{ .enforce_mode_dummy = true };
    device.modes[0] = 0x30;
    device.modes[4] = 0x20;
    device.modes[8] = 0x4b;
    var controller = psram.Controller(*Device){ .io = &device, .poll_limit = 2 };
    const found = controller.discoverRetained();
    try std.testing.expectEqual(psram.Status.detected, found.status);
    try std.testing.expectEqual(@as(u32, 8), controller.transactions);
    const modes = try controller.configure(found);
    try std.testing.expectEqualDeep(psram.Modes{ .mr0 = 0x28, .mr4 = 0x40, .mr8 = 0x0b }, modes);
    try controller.writeWord(0, 0x7fff8000);
    try std.testing.expectEqual(@as(u32, 0x7fff8000), try controller.readWord(0));
    try std.testing.expect(device.valid_phases);
}
