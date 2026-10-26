//! Bounded read-only SDHC/SDXC boot probe, slot 0, 1-bit, 400 kHz.
//! Command/PIO registers: pinned ESP-IDF v5.4.4 sdmmc register definitions.
//! One fixed internal DMA buffer/descriptor, no IRQ, filesystem or write/erase.
const std = @import("std");
pub const base: u32 = 0x5008_3000;
pub const regs = struct {
    pub const ctrl = 0x00;
    pub const clkdiv = 0x08;
    pub const clkena = 0x10;
    pub const timeout = 0x14;
    pub const width = 0x18;
    pub const block = 0x1c;
    pub const bytes = 0x20;
    pub const mask = 0x24;
    pub const argument = 0x28;
    pub const command = 0x2c;
    pub const response = 0x30;
    pub const interrupts = 0x44;
    pub const status = 0x48;
    pub const threshold = 0x4c;
    pub const dma_mode = 0x80;
    pub const demand = 0x84;
    pub const descriptor = 0x88;
    pub const dma_status = 0x8c;
    pub const dma_mask = 0x90;
    pub const fifo = 0x200;
};
const start: u32 = 1 << 31;
const done: u32 = 1 << 2;
const data_over: u32 = 1 << 3;
const errors: u32 = 0xbfc2; // response/data timeout, CRC, HLE, FIFO, framing.
pub const Error = error{ InvalidCommand, Timeout, Controller, Response, Unsupported, InvalidAddress, ShortRead };

pub fn allowed(index: u6) bool {
    return switch (index) {
        0, 2, 3, 7, 8, 9, 13, 17, 41, 55 => true,
        else => false,
    };
}

pub fn sectorCount(csd: [4]u32) Error!u64 {
    if (csd[3] >> 30 != 1) return error.Unsupported;
    const size = ((@as(u64, csd[2]) << 16) | (csd[1] >> 16)) & 0x3f_ffff;
    return (size + 1) * 1024;
}

pub fn crc32(bytes: []const u8) u32 {
    var value: u32 = 0xffff_ffff;
    for (bytes) |byte| {
        value ^= byte;
        for (0..8) |_| value = (value >> 1) ^ (if (value & 1 != 0) @as(u32, 0xedb8_8320) else 0);
    }
    return ~value;
}

pub fn Controller(comptime IO: type) type {
    return struct {
        io: IO,
        poll_limit: u32 = 200_000,
        last_command: u32 = 0,
        last_interrupts: u32 = 0,
        last_response: u32 = 0,
        last_status: u32 = 0,
        words_read: u32 = 0,
        commands: u32 = 0,
        rca: u32 = 0,
        sectors: u64 = 0,
        faulted: bool = false,
        cleanup_failed: bool = false,
        const Self = @This();

        fn pollClear(self: *Self, offset: usize, bits: u32) Error!void {
            for (0..self.poll_limit) |_| {
                if (self.io.read(offset) & bits == 0) return;
                self.io.delay(1);
            }
            return error.Timeout;
        }

        fn clockUpdate(self: *Self) Error!void {
            self.io.write(regs.interrupts, 0xffff_ffff);
            self.io.write(regs.command, start | (1 << 29) | (1 << 21) | (1 << 13));
            try self.pollClear(regs.command, start);
            if (self.io.read(regs.interrupts) & (1 << 12) != 0) return error.Controller;
        }

        pub fn prepare(self: *Self) Error!void {
            self.io.write(regs.ctrl, 7);
            try self.pollClear(regs.ctrl, 7);
            self.io.write(regs.ctrl, 0); // Interrupts and DMA both disabled.
            self.io.write(regs.mask, 0);
            self.io.write(regs.timeout, 0xffff_ffff);
            self.io.write(regs.width, 0);
            self.io.write(regs.clkena, 0);
            try self.clockUpdate();
            self.io.write(regs.clkdiv, 50); // 40 MHz / (2 * 50).
            try self.clockUpdate();
            self.io.write(regs.clkena, 1); // Continuous clock during power-up.
            try self.clockUpdate();
        }

        pub fn command(self: *Self, index: u6, argument: u32) Error![4]u32 {
            // Reject before any register access, including status/FIFO resets.
            if (!allowed(index)) return error.InvalidCommand;
            if (self.faulted) return error.Controller;
            self.last_command = index;
            try self.pollClear(regs.command, start);
            try self.pollClear(regs.status, 1 << 9);
            self.io.write(regs.interrupts, 0xffff_ffff);
            self.io.write(regs.argument, argument);
            var flags: u32 = start | (1 << 29) | index;
            if (index == 0) flags |= 1 << 15 else flags |= (1 << 6) | (1 << 13);
            if (index != 0 and index != 41) flags |= 1 << 8;
            if (index == 2 or index == 9) flags |= 1 << 7;
            if (index == 17) flags |= 1 << 9;
            self.io.write(regs.command, flags);
            self.commands += 1;
            for (0..self.poll_limit) |_| {
                const status = self.io.read(regs.interrupts);
                self.last_interrupts = status;
                if (status & errors != 0) return error.Controller;
                if (status & done != 0) {
                    var result: [4]u32 = undefined;
                    for (&result, 0..) |*word, i| word.* = self.io.read(regs.response + 4 * i);
                    self.last_response = result[0];
                    return result;
                }
                self.io.delay(1);
            }
            return error.Timeout;
        }

        fn r1(self: *Self, index: u6, argument: u32) Error!u32 {
            const response = try self.command(index, argument);
            if (response[0] & 0xfdff_e008 != 0) return error.Response;
            return response[0];
        }

        pub fn identify(self: *Self) Error!void {
            _ = try self.command(0, 0);
            self.io.delay(10_000);
            if ((try self.command(8, 0x1aa))[0] & 0xfff != 0x1aa) return error.Unsupported;
            var ready = false;
            for (0..200) |_| {
                _ = try self.r1(55, 0);
                const response = try self.command(41, 0x40ff_8000);
                if (response[0] & 0x8000_0000 != 0) {
                    if (response[0] & 0x4000_0000 == 0 or response[0] & 0x00ff_8000 == 0) return error.Unsupported;
                    ready = true;
                    break;
                }
                self.io.delay(10_000);
            }
            if (!ready) return error.Timeout;
            _ = try self.command(2, 0);
            const response = try self.command(3, 0);
            self.rca = response[0] & 0xffff_0000;
            if (self.rca == 0 or response[0] & 0xe000 != 0) return error.Response;
            self.sectors = try sectorCount(try self.command(9, self.rca));
            _ = try self.r1(7, self.rca);
            const status = try self.r1(13, self.rca);
            if ((status >> 9) & 15 != 4 or status & 0x100 == 0) return error.Response;
        }

        fn stopDma(self: *Self) Error!void {
            self.io.write(regs.dma_mode, 0);
            self.io.write(regs.ctrl, (self.io.read(regs.ctrl) & ~@as(u32, (1 << 25) | (1 << 5))) | 4);
            try self.pollClear(regs.ctrl, 4);
        }

        pub fn readSector(self: *Self, lba: u32, buffer: *[512]u8) Error!void {
            if (self.rca == 0 or lba >= self.sectors) return error.InvalidAddress;
            if (self.faulted) return error.Controller;
            self.words_read = 0;
            self.io.write(regs.ctrl, self.io.read(regs.ctrl) | 6);
            try self.pollClear(regs.ctrl, 6);
            self.io.delay(10);
            self.io.write(regs.dma_mode, 1);
            try self.pollClear(regs.dma_mode, 1);
            const descriptor = self.io.prepareDma() orelse return error.Controller;
            self.io.write(regs.block, 512);
            self.io.write(regs.bytes, 512);
            self.io.write(regs.dma_status, 0xffff_ffff);
            self.io.write(regs.dma_mask, 0);
            self.io.write(regs.descriptor, descriptor);
            self.io.write(regs.ctrl, self.io.read(regs.ctrl) | (1 << 25) | (1 << 5));
            self.io.write(regs.dma_mode, 0x82);
            self.io.write(regs.demand, 1);
            errdefer {
                self.faulted = true;
                self.stopDma() catch {
                    self.cleanup_failed = true;
                };
            }
            _ = try self.r1(17, lba);
            for (0..self.poll_limit) |_| {
                const interrupts = self.io.read(regs.interrupts);
                self.last_interrupts = interrupts;
                self.last_status = self.io.read(regs.dma_status);
                if (interrupts & errors != 0 or self.last_status & 0x34 != 0) return error.Controller;
                if (interrupts & (done | data_over) == done | data_over) {
                    try self.stopDma();
                    if (!self.io.finishDma(buffer)) return error.ShortRead;
                    self.words_read = 128;
                    return;
                }
                self.io.delay(1);
            }
            return error.Timeout;
        }
    };
}

test "only the fixed read-only command set is admitted" {
    const IO = struct {
        pub fn read(_: @This(), _: usize) u32 {
            unreachable;
        }
        pub fn write(_: @This(), _: usize, _: u32) void {
            unreachable;
        }
        pub fn delay(_: @This(), _: u32) void {
            unreachable;
        }
    };
    var controller = Controller(IO){ .io = .{} };
    for (0..64) |index| {
        const command_index: u6 = @intCast(index);
        if (!allowed(command_index)) try std.testing.expectError(error.InvalidCommand, controller.command(command_index, 0));
    }
}

test "CSD v2 sector count retains the 2 TiB limit and rejects other layouts" {
    try std.testing.expectEqual(@as(u64, 1024), try sectorCount(.{ 0, 0, 0, 1 << 30 }));
    try std.testing.expectEqual(@as(u64, 1) << 32, try sectorCount(.{ 0, 0xffff_0000, 0x3f, 1 << 30 }));
    try std.testing.expectError(error.Unsupported, sectorCount(.{ 0, 0, 0, 0 }));
    try std.testing.expectEqual(@as(u32, 0xcbf4_3926), crc32("123456789"));
}

const DmaModel = struct {
    complete: bool = true,
    owned: bool = false,
    fail_prepare: bool = false,
    dma_error: u32 = 0,
    prepared: u32 = 0,
    stopped: u32 = 0,
    command_word: u32 = 0,
    pub fn read(self: *@This(), offset: usize) u32 {
        return switch (offset) {
            regs.interrupts => done | (if (self.complete) data_over else @as(u32, 0)),
            regs.response => 0x900,
            regs.dma_status => self.dma_error,
            else => 0,
        };
    }
    pub fn write(self: *@This(), offset: usize, value: u32) void {
        if (offset == regs.command) self.command_word = value;
        if (offset == regs.dma_mode and value == 0) self.stopped += 1;
    }
    pub fn delay(_: *@This(), _: u32) void {}
    pub fn prepareDma(self: *@This()) ?u32 {
        self.prepared += 1;
        return if (self.fail_prepare) null else 0x4ff1_0000;
    }
    pub fn finishDma(self: *@This(), output: *[512]u8) bool {
        if (self.owned) return false;
        for (output, 0..) |*byte, i| byte.* = @truncate(i);
        return true;
    }
};

test "DMA read is read-only bounded and stopped before publishing a complete sector" {
    var model = DmaModel{};
    var controller = Controller(*DmaModel){ .io = &model, .poll_limit = 4, .rca = 1 << 16, .sectors = 8 };
    var output: [512]u8 = @splat(0xa5);
    try controller.readSector(7, &output);
    try std.testing.expectEqual(@as(u32, 1), model.prepared);
    try std.testing.expectEqual(@as(u32, 1), model.stopped);
    try std.testing.expectEqual(@as(u32, 17), model.command_word & 63);
    try std.testing.expect(model.command_word & (1 << 9) != 0 and model.command_word & (1 << 10) == 0);
    try std.testing.expectEqual(@as(u32, 128), controller.words_read);
    try std.testing.expectEqual(@as(u8, 0xff), output[511]);
    try std.testing.expectError(error.InvalidAddress, controller.readSector(8, &output));
    try std.testing.expectEqual(@as(u32, 1), model.prepared);
}

test "DMA errors timeouts and retained ownership do not publish data and stop the engine" {
    for (0..4) |fault| {
        var model = DmaModel{ .complete = fault != 0, .owned = fault == 1, .dma_error = if (fault == 2) 4 else 0, .fail_prepare = fault == 3 };
        var controller = Controller(*DmaModel){ .io = &model, .poll_limit = 4, .rca = 1 << 16, .sectors = 8 };
        var output: [512]u8 = @splat(0xa5);
        if (fault == 0) try std.testing.expectError(error.Timeout, controller.readSector(0, &output)) else if (fault == 1)
            try std.testing.expectError(error.ShortRead, controller.readSector(0, &output))
        else
            try std.testing.expectError(error.Controller, controller.readSector(0, &output));
        if (fault != 3) try std.testing.expect(model.stopped != 0);
        for (output) |byte| try std.testing.expectEqual(@as(u8, 0xa5), byte);
    }
}
