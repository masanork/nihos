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

    pub fn read(self: *Model, offset: usize) u32 {
        if (offset == regs.command and self.pending != 0) {
            self.polls += 1;
            if (!self.stuck) {
                self.pending -= 1;
                if (self.pending == 0) {
                    self.words[regs.command / 4] &= ~regs.start;
                    if (self.update_fifo) self.words[regs.fifo / 4] = self.responses[self.starts - 1];
                }
            }
        }
        return self.words[offset / 4];
    }

    pub fn write(self: *Model, offset: usize, value: u32) void {
        self.writes += 1;
        self.words[offset / 4] = value;
        if (offset == regs.command and value & regs.start != 0) {
            // Fixed register-read protocol: command=16, address=32,
            // dummy=8, input=16 bits, CS1, low FIFO, DDR/octal phases.
            self.valid_phases = self.valid_phases and
                self.words[regs.user2 / 4] == 0xf0004040 and
                self.words[regs.user1 / 4] == 0x7c000007 and
                self.words[regs.user / 4] == 0xf0000000 and
                self.words[regs.control / 4] == 0x274 and
                self.words[regs.ddr / 4] == 0x21 and
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
