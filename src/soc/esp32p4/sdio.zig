//! Boot-exclusive slot-1 SDIO host. Register/command facts: ESP-IDF v5.4.4.
//! Polling only; the IO owner supplies clock/pads and quarantined DMA storage.
const std = @import("std");
pub const base: u32 = 0x50083000;
pub const regs = struct {
    pub const ctrl = 0x00;
    pub const divider = 0x08;
    pub const source = 0x0c;
    pub const clock = 0x10;
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
    pub const dma_mode = 0x80;
    pub const demand = 0x84;
    pub const descriptor = 0x88;
    pub const dma_status = 0x8c;
    pub const dma_mask = 0x90;
};
const start: u32 = 1 << 31;
const slot: u32 = 1 << 16;
const done: u32 = 1 << 2;
const data_over: u32 = 1 << 3;
const errors: u32 = 0xbfc2;
pub const Error = error{ InvalidArgument, NoOwnership, NotReady, Retired, Timeout, Controller, Response, Unsupported, Dma };

pub fn allowed(index: u6) bool {
    return switch (index) {
        0, 3, 5, 7, 52, 53 => true,
        else => false,
    };
}

pub fn argument52(function: u8, address: u32, value: ?u8) Error!u32 {
    if (function > 1 or address > 0x1ffff) return error.InvalidArgument;
    return (@as(u32, function) << 28) | (address << 9) |
        (if (value) |byte| (@as(u32, 1) << 31) | (1 << 27) | byte else @as(u32, 0));
}

pub fn argument53(address: u32, length: usize, writing: bool) Error!u32 {
    if (address > 0x1ffff or length == 0 or length > 512 or length % 4 != 0) return error.InvalidArgument;
    const blocks = length == 512;
    return (if (writing) @as(u32, 1) << 31 else 0) | (1 << 28) | (1 << 26) |
        (if (blocks) @as(u32, 1) << 27 else 0) | (address << 9) |
        (if (blocks) @as(u32, 1) else @as(u32, @intCast(length)));
}

pub fn Controller(comptime IO: type) type {
    return struct {
        pub const TransportError = Error;
        io: IO,
        poll_limit: u32 = 10_000,
        prepared: bool = false,
        selected: bool = false,
        four_bit: bool = false,
        faulted: bool = false,
        cleanup_failed: bool = false,
        commands: u32 = 0,
        last_command: u32 = 0,
        last_interrupts: u32 = 0,
        last_response: u32 = 0,
        last_dma: u32 = 0,
        rca: u32 = 0,
        ocr: u32 = 0,
        const Self = @This();

        fn clear(self: *Self, address: usize, bits: u32) Error!void {
            for (0..self.poll_limit) |_| {
                if (self.io.read(address) & bits == 0) return;
                self.io.delay(1);
            }
            return error.Timeout;
        }

        fn clockUpdate(self: *Self) Error!void {
            self.io.write(regs.interrupts, 0xffffffff);
            self.io.write(regs.command, start | slot | (1 << 29) | (1 << 21) | (1 << 13));
            try self.clear(regs.command, start);
            if (self.io.read(regs.interrupts) & (1 << 12) != 0) return error.Controller;
        }

        /// Resets the shared controller. Call only before storage/CPU1 can use
        /// it. This is not a live multi-slot arbiter or an IRQ service.
        pub fn prepare(self: *Self, exclusive: bool) Error!void {
            if (!exclusive) return error.NoOwnership;
            if (self.faulted) return error.Retired;
            if (self.prepared) return error.InvalidArgument;
            errdefer self.faulted = true;
            self.io.write(regs.ctrl, 7);
            try self.clear(regs.ctrl, 7);
            self.io.write(regs.ctrl, 0);
            self.io.write(regs.mask, 0);
            self.io.write(regs.timeout, 0xffffffff);
            self.io.write(regs.width, 0);
            self.io.write(regs.clock, 0);
            try self.clockUpdate();
            self.io.write(regs.source, 4); // Slot 1 uses divider 1.
            self.io.write(regs.divider, 50 << 8); // Supplied 40 MHz / 100.
            try self.clockUpdate();
            self.io.write(regs.clock, 2);
            try self.clockUpdate();
            if (self.io.read(regs.clock) & 3 != 2 or self.io.read(regs.divider) & 0xff00 != 50 << 8 or
                self.io.read(regs.source) & 15 != 4) return error.Controller;
            self.prepared = true;
        }

        pub fn command(self: *Self, index: u6, argument: u32, writing: ?bool) Error!u32 {
            if (!allowed(index) or (index == 53) != (writing != null)) return error.InvalidArgument;
            if (index == 52 and (argument >> 28) & 7 > 1) return error.InvalidArgument;
            if (index == 53 and ((argument >> 28) & 7 != 1 or ((argument >> 31) != 0) != writing.?)) return error.InvalidArgument;
            if (self.faulted) return error.Retired;
            if (!self.prepared) return error.NotReady;
            errdefer self.faulted = true;
            try self.clear(regs.command, start);
            try self.clear(regs.status, 1 << 9);
            self.io.write(regs.interrupts, 0xffffffff);
            self.io.write(regs.argument, argument);
            var flags = start | slot | (1 << 29) | @as(u32, index);
            if (index == 0) flags |= 1 << 15 else flags |= (1 << 6) | (1 << 13);
            if (index != 0 and index != 5) flags |= 1 << 8;
            if (writing) |write| flags |= (1 << 9) | (if (write) @as(u32, 1) << 10 else 0);
            self.last_command = index;
            self.io.write(regs.command, flags);
            self.commands +|= 1;
            for (0..self.poll_limit) |_| {
                self.last_interrupts = self.io.read(regs.interrupts);
                if (self.last_interrupts & errors != 0) return error.Controller;
                if (self.last_interrupts & done != 0) {
                    self.last_response = self.io.read(regs.response);
                    if ((index == 52 or index == 53) and self.last_response & 0xcb00 != 0) return error.Response;
                    return self.last_response;
                }
                self.io.delay(1);
            }
            return error.Timeout;
        }

        pub fn identify(self: *Self) Error!void {
            if (self.selected) return error.InvalidArgument;
            errdefer self.faulted = true;
            _ = try self.command(0, 0, null);
            self.io.delay(1000);
            self.ocr = try self.command(5, 0, null);
            if ((self.ocr >> 28) & 7 == 0 or self.ocr & 0x00ff8000 == 0 or self.ocr & (1 << 27) != 0) return error.Unsupported;
            var ready = false;
            for (0..100) |_| {
                self.ocr = try self.command(5, self.ocr & 0x00ff8000, null);
                if (self.ocr & (1 << 31) != 0) {
                    ready = true;
                    break;
                }
                self.io.delay(1000);
            }
            if (!ready) return error.Timeout;
            const r6 = try self.command(3, 0, null);
            self.rca = r6 & 0xffff0000;
            if (self.rca == 0 or r6 & 0xe000 != 0) return error.Response;
            const r1 = try self.command(7, self.rca, null);
            if (r1 & 0xfdffe008 != 0) return error.Response;
            try self.clear(regs.status, 1 << 9);
            self.selected = true;
        }

        pub fn readByte(self: *Self, function: u8, address: u32) Error!u8 {
            const argument = try argument52(function, address, null);
            if (!self.selected) return error.NotReady;
            return @truncate(try self.command(52, argument, null));
        }

        pub fn writeByte(self: *Self, function: u8, address: u32, value: u8) Error!void {
            const argument = try argument52(function, address, value);
            if (!self.selected) return error.NotReady;
            const response = try self.command(52, argument, null);
            if (@as(u8, @truncate(response)) != value) {
                self.faulted = true;
                return error.Response;
            }
        }

        /// Write a self-clearing event register. R5 errors are still fatal;
        /// the protocol owner must obtain its acknowledgement from the peer.
        pub fn writeDoorbell(self: *Self, function: u8, address: u32, value: u8) Error!void {
            const argument = try argument52(function, address, value);
            if (!self.selected) return error.NotReady;
            _ = try self.command(52, argument, null);
        }

        pub fn enableFunction(self: *Self) Error!void {
            errdefer self.faulted = true;
            try self.writeByte(0, 2, (try self.readByte(0, 2)) | 2);
            var ready = false;
            for (0..50) |_| {
                if (try self.readByte(0, 3) & 2 != 0) {
                    ready = true;
                    break;
                }
                self.io.delay(1000);
            }
            if (!ready) return error.Timeout;
            try self.writeByte(0, 0x10, 0);
            try self.writeByte(0, 0x11, 2);
            try self.writeByte(0, 0x110, 0);
            try self.writeByte(0, 0x111, 2);
            try self.writeByte(0, 4, 3);
            try self.writeByte(0, 7, ((try self.readByte(0, 7)) & 0xfc) | 2);
            self.io.fourBitPins();
            self.io.write(regs.width, 2);
            if (self.io.read(regs.width) & 0x00030003 != 2) return error.Controller;
            self.four_bit = true;
        }

        fn stopDma(self: *Self) Error!void {
            self.io.write(regs.dma_mode, 0);
            self.io.write(regs.ctrl, (self.io.read(regs.ctrl) & ~@as(u32, (1 << 25) | (1 << 5))) | 4);
            try self.clear(regs.ctrl, 4);
        }

        fn transfer(self: *Self, address: u32, source: []const u8, destination: []u8, writing: bool) Error!void {
            const length = if (writing) source.len else destination.len;
            const argument = try argument53(address, length, writing);
            if (self.faulted) return error.Retired;
            if (!self.selected or !self.four_bit) return error.NotReady;
            errdefer {
                self.faulted = true;
                self.stopDma() catch {
                    self.cleanup_failed = true;
                };
            }
            self.io.write(regs.ctrl, self.io.read(regs.ctrl) | 6);
            try self.clear(regs.ctrl, 6);
            self.io.write(regs.dma_mode, 1);
            try self.clear(regs.dma_mode, 1);
            const descriptor = self.io.prepareDma(writing, source, length) orelse return error.Dma;
            self.io.write(regs.block, @intCast(length));
            self.io.write(regs.bytes, @intCast(length));
            self.io.write(regs.dma_status, 0xffffffff);
            self.io.write(regs.dma_mask, 0);
            self.io.write(regs.descriptor, descriptor);
            self.io.write(regs.ctrl, self.io.read(regs.ctrl) | (1 << 25) | (1 << 5));
            self.io.write(regs.dma_mode, 0x82);
            self.io.write(regs.demand, 1);
            _ = try self.command(53, argument, writing);
            for (0..self.poll_limit) |_| {
                self.last_interrupts = self.io.read(regs.interrupts);
                self.last_dma = self.io.read(regs.dma_status);
                if (self.last_interrupts & errors != 0 or self.last_dma & 0x34 != 0) return error.Dma;
                if (self.last_interrupts & (done | data_over) == done | data_over) {
                    try self.stopDma();
                    if (!self.io.finishDma(writing, destination)) return error.Dma;
                    return;
                }
                self.io.delay(1);
            }
            return error.Timeout;
        }

        pub fn readBytes(self: *Self, address: u32, destination: []u8) Error!void {
            return self.transfer(address, &.{}, destination, false);
        }
        pub fn writeBytes(self: *Self, address: u32, source: []const u8) Error!void {
            return self.transfer(address, source, &.{}, true);
        }
        pub fn readWord(self: *Self, address: u32) Error!u32 {
            var bytes: [4]u8 = @splat(0);
            try self.readBytes(address, &bytes);
            return std.mem.readInt(u32, &bytes, .little);
        }
        pub fn writeWord(self: *Self, address: u32, value: u32) Error!void {
            var bytes: [4]u8 = @splat(0);
            std.mem.writeInt(u32, &bytes, value, .little);
            try self.writeBytes(address, &bytes);
        }
    };
}
