//! Bounded read-only SDHC/SDXC boot probe, slot 0, optional 4-bit/20 MHz.
//! Command/PIO registers: pinned ESP-IDF v5.4.4 sdmmc register definitions.
//! Normal native buses remain read-only; an opt-in, test-only CMD24 primitive
//! requires a write-capable bus and is not registered by normal startup.
//! One fixed internal DMA buffer/descriptor; no IRQ or filesystem.
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
pub const Error = error{ InvalidCommand, NoOwnership, Timeout, Controller, Response, Unsupported, InvalidAddress, ShortRead, Cancelled, Removed };
pub const StopReason = enum { none, cancelled, removed };
pub const Quiescence = struct {
    device_idle: bool = true,
    descriptors_released: bool = true,
    cache_handed_back: bool = true,
    pub fn complete(self: Quiescence) bool {
        return self.device_idle and self.descriptors_released and self.cache_handed_back;
    }
};
const Proceed = struct {
    pub fn stopReason(_: @This()) StopReason {
        return .none;
    }
};
fn checkStop(control: anytype) Error!void {
    switch (control.stopReason()) {
        .none => {},
        .cancelled => return error.Cancelled,
        .removed => return error.Removed,
    }
}

pub fn allowed(index: u6) bool {
    return switch (index) {
        0, 2, 3, 6, 7, 8, 9, 13, 17, 41, 51, 55 => true,
        else => false,
    };
}

pub fn scrWidths(scr: [8]u8) Error!u32 {
    if (scr[0] >> 4 != 0 or scr[1] & 1 == 0) return error.Unsupported;
    return scr[1] & 15;
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

pub fn sampleLba(index: u32, count: u32, sectors: u64) ?u32 {
    if (count < 2 or index >= count or sectors < 2 or sectors > @as(u64, 1) << 32) return null;
    return @intCast(@as(u64, index) * (sectors - 1) / (count - 1));
}

pub fn foldSample(previous: u32, lba: u32, checksum: u32) u32 {
    var value = previous;
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u32, bytes[0..4], lba, .little);
    std.mem.writeInt(u32, bytes[4..8], checksum, .little);
    for (bytes) |byte| value = (value ^ byte) *% 16777619;
    return value;
}

test "distributed sample addresses include both ends and cannot overflow a 2 TiB card" {
    try std.testing.expectEqual(@as(u32, 0), sampleLba(0, 1024, @as(u64, 1) << 32).?);
    try std.testing.expectEqual(@as(u32, 0xffff_ffff), sampleLba(1023, 1024, @as(u64, 1) << 32).?);
    try std.testing.expect(sampleLba(1024, 1024, 2048) == null);
    try std.testing.expect(sampleLba(0, 1, 2048) == null);
    try std.testing.expect(sampleLba(0, 2, (@as(u64, 1) << 32) + 1) == null);
    try std.testing.expect(foldSample(0x811c9dc5, 1, 2) != foldSample(0x811c9dc5, 2, 1));
}

pub fn Controller(comptime IO: type) type {
    return struct {
        io: IO,
        poll_limit: u32 = 200_000,
        ready_poll_limit: u32 = 5_000,
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
        quiescence: Quiescence = .{},
        bus_bits: u32 = 1,
        clock_khz: u32 = 400,
        scr_widths: u32 = 0,
        host_width: u32 = 0,
        divider: u32 = 50,
        const Self = @This();
        const BusType = switch (@typeInfo(IO)) {
            .pointer => |info| info.child,
            else => IO,
        };
        const shared = @hasDecl(BusType, "shared_host") and BusType.shared_host;
        const write_enabled = if (@hasDecl(BusType, "experimental_sd_write")) BusType.experimental_sd_write else false;
        fn owns(self: *const Self) bool {
            return if (shared) self.io.ownsSlot(0) else true;
        }
        // Native storage owners run with mapped Flash/cache available. IRQs
        // only publish resident flags and never enter these routines.
        const runtime_section = if (@hasDecl(BusType, "runtime_section")) BusType.runtime_section else if (@import("builtin").os.tag == .macos) "__TEXT,__text" else ".text";

        fn pollClear(self: *Self, offset: usize, bits: u32) Error!void {
            return self.pollClearControlled(offset, bits, Proceed{});
        }

        fn pollClearControlled(self: *Self, offset: usize, bits: u32, control: anytype) Error!void {
            for (0..self.poll_limit) |_| {
                try checkStop(control);
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

        pub fn prepare(self: *Self) linksection(runtime_section) Error!void {
            if (shared) return error.NoOwnership;
            return self.preparePort(true);
        }

        pub fn prepareShared(self: *Self) linksection(runtime_section) Error!void {
            if (!shared or !self.owns()) return error.NoOwnership;
            return self.preparePort(false);
        }

        fn preparePort(self: *Self, reset: bool) linksection(runtime_section) Error!void {
            // A new initialization must never overwrite quarantined staging.
            if (!self.quiescence.complete()) return error.Controller;
            const bits: u32 = if (reset) 7 else 6;
            self.io.write(regs.ctrl, bits);
            try self.pollClear(regs.ctrl, bits);
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
            self.host_width = self.io.read(regs.width) & 0x0001_0001;
            self.divider = self.io.read(regs.clkdiv) & 255;
            if (self.host_width != 0 or self.divider != 50 or self.io.read(regs.clkena) & 1 != 1) return error.Controller;
        }

        pub fn command(self: *Self, index: u6, argument: u32) Error![4]u32 {
            return self.commandControlled(index, argument, Proceed{});
        }

        fn commandControlled(self: *Self, index: u6, argument: u32, control: anytype) Error![4]u32 {
            return self.commandTransferControlled(index, argument, control, false);
        }

        fn commandTransferControlled(self: *Self, index: u6, argument: u32, control: anytype, write_transfer: bool) Error![4]u32 {
            // CMD24 is only admitted by the explicitly enabled write path.
            // Reject before any register access, including status/FIFO resets.
            if (!self.owns()) return error.NoOwnership;
            if (!allowed(index) and !(write_enabled and write_transfer and index == 24)) return error.InvalidCommand;
            if (self.faulted) return error.Controller;
            self.last_command = index;
            try self.pollClearControlled(regs.command, start, control);
            try self.pollClearControlled(regs.status, 1 << 9, control);
            self.io.write(regs.interrupts, 0xffff_ffff);
            self.io.write(regs.argument, argument);
            var flags: u32 = start | (1 << 29) | index;
            if (index == 0) flags |= 1 << 15 else flags |= (1 << 6) | (1 << 13);
            if (index != 0 and index != 41) flags |= 1 << 8;
            if (index == 2 or index == 9) flags |= 1 << 7;
            if (index == 17 or index == 51 or index == 24) flags |= 1 << 9;
            if (index == 24) flags |= 1 << 10;
            self.io.write(regs.command, flags);
            self.commands += 1;
            for (0..self.poll_limit) |_| {
                try checkStop(control);
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

        pub fn identify(self: *Self) linksection(runtime_section) Error!void {
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

        fn stopDma(self: *Self) linksection(runtime_section) Error!void {
            self.quiescence.device_idle = false;
            // Polling owner: mask both interrupt sources before draining them.
            self.io.write(regs.mask, 0);
            self.io.write(regs.dma_mask, 0);
            self.io.write(regs.dma_mode, 0);
            self.io.write(regs.ctrl, (self.io.read(regs.ctrl) & ~@as(u32, (1 << 25) | (1 << 5) | (1 << 4))) | 4);
            try self.pollClear(regs.ctrl, 4);
            try self.pollClear(regs.dma_status, 15 << 13); // IDMAC FSM must be idle.
            if (self.io.read(regs.ctrl) & ((1 << 25) | (1 << 5) | (1 << 4) | 4) != 0 or
                self.io.read(regs.dma_mode) != 0 or self.io.read(regs.mask) != 0 or self.io.read(regs.dma_mask) != 0) return error.Controller;
            self.io.write(regs.interrupts, 0xffff_ffff);
            self.io.write(regs.dma_status, 0xffff_ffff);
            self.quiescence.device_idle = true;
        }

        fn releaseDma(self: *Self) linksection(runtime_section) Error!void {
            self.quiescence.descriptors_released = false;
            self.quiescence.cache_handed_back = false;
            self.io.write(regs.descriptor, 0);
            if (self.io.read(regs.descriptor) != 0 or !self.io.releaseDma()) return error.Controller;
            self.quiescence.descriptors_released = true;
            self.quiescence.cache_handed_back = true;
        }

        fn appPrefix(self: *Self) Error!void {
            const response = try self.r1(55, self.rca);
            if (response & (1 << 5) == 0) return error.Response;
        }

        pub fn switchFourBit(self: *Self) Error!void {
            if (self.rca == 0 or self.faulted or self.bus_bits != 1) return error.Controller;
            errdefer self.faulted = true;
            var buffer: [512]u8 = undefined;
            try self.appPrefix();
            try self.readTransfer(51, 0, 8, &buffer);
            self.scr_widths = try scrWidths(buffer[0..8].*);
            if (self.scr_widths & 4 == 0) return error.Unsupported;
            try self.appPrefix();
            _ = try self.r1(6, 2); // ACMD6 changes volatile card bus width only.
            self.io.fourBitPins();
            self.io.write(regs.width, 1);
            self.host_width = self.io.read(regs.width) & 0x0001_0001;
            if (self.host_width != 1) return error.Controller;
            self.bus_bits = 4;
        }

        pub fn switch20MHz(self: *Self) Error!void {
            if (self.faulted or self.bus_bits != 4 or self.clock_khz != 400) return error.Controller;
            errdefer self.faulted = true;
            self.io.write(regs.clkena, 0);
            try self.clockUpdate();
            self.io.write(regs.clkdiv, 1); // Retained 40 MHz host / (2 * 1).
            try self.clockUpdate();
            self.io.write(regs.clkena, 1);
            try self.clockUpdate();
            self.divider = self.io.read(regs.clkdiv) & 255;
            if (self.divider != 1 or self.io.read(regs.clkena) & 1 != 1) return error.Controller;
            self.clock_khz = 20_000;
        }

        pub fn readSector(self: *Self, lba: u32, buffer: *[512]u8) linksection(runtime_section) Error!void {
            return self.readSectorControlled(lba, buffer, Proceed{});
        }

        /// control reads owner-published resident flags; it must not free memory,
        /// manipulate MMIO or reenter the controller from an interrupt.
        pub inline fn readSectorControlled(self: *Self, lba: u32, buffer: *[512]u8, control: anytype) Error!void {
            if (self.rca == 0 or lba >= self.sectors) return error.InvalidAddress;
            return self.readTransferControlled(17, lba, 512, buffer, control);
        }

        /// Experimental CMD24 primitive. It is not enabled for the normal
        /// native bus. A failure after launch has an unknown media outcome;
        /// card-ready is not a power-loss durability barrier.
        pub fn writeSectorControlled(self: *Self, lba: u32, source: *const [512]u8, control: anytype) Error!void {
            if (comptime !write_enabled) return error.InvalidCommand;
            if (!self.owns()) return error.NoOwnership;
            if (self.rca == 0 or lba >= self.sectors) return error.InvalidAddress;
            if (self.faulted or !self.quiescence.complete()) return error.Controller;
            try checkStop(control);
            self.io.write(regs.ctrl, self.io.read(regs.ctrl) | 6);
            try self.pollClearControlled(regs.ctrl, 6, control);
            self.io.delay(10);
            self.io.write(regs.dma_mode, 1);
            try self.pollClearControlled(regs.dma_mode, 1, control);
            // prepareWriteDma copies into owned staging and must return null
            // only when no DMA-visible resource was retained.
            const descriptor = self.io.prepareWriteDma(source) orelse return error.Controller;
            self.quiescence = .{ .device_idle = false, .descriptors_released = false, .cache_handed_back = false };
            errdefer {
                self.faulted = true;
                if (!self.quiescence.complete()) {
                    self.stopDma() catch {
                        self.cleanup_failed = true;
                    };
                    if (self.quiescence.device_idle) self.releaseDma() catch {
                        self.cleanup_failed = true;
                    };
                }
            }
            self.io.write(regs.block, 512);
            self.io.write(regs.bytes, 512);
            self.io.write(regs.dma_status, 0xffff_ffff);
            self.io.write(regs.dma_mask, 0);
            self.io.write(regs.descriptor, descriptor);
            self.io.write(regs.ctrl, self.io.read(regs.ctrl) | (1 << 25) | (1 << 5));
            self.io.write(regs.dma_mode, 0x82);
            self.io.write(regs.demand, 1);
            const response = try self.commandTransferControlled(24, lba, control, true);
            if (response[0] & 0xfdff_e008 != 0) return error.Response;
            var transferred = false;
            for (0..self.poll_limit) |_| {
                try checkStop(control);
                self.last_interrupts = self.io.read(regs.interrupts);
                self.last_status = self.io.read(regs.dma_status);
                if (self.last_interrupts & errors != 0 or self.last_status & 0x34 != 0) return error.Controller;
                if (self.last_interrupts & (done | data_over) == done | data_over) {
                    try self.stopDma();
                    try checkStop(control);
                    if (!self.io.finishWriteDma()) return error.Controller;
                    try self.releaseDma();
                    transferred = true;
                    break;
                }
                self.io.delay(1);
            }
            if (!transferred) return error.Timeout;
            for (0..self.ready_poll_limit) |_| {
                try checkStop(control);
                // Card programming may hold DAT0 busy for longer than a
                // normal command timeout. Wait before issuing CMD13.
                if (self.io.read(regs.status) & (1 << 9) != 0) {
                    self.io.delay(1_000);
                    continue;
                }
                const status = (try self.commandControlled(13, self.rca, control))[0];
                if (status & 0xfdff_e008 != 0) return error.Response;
                if (status & 0x100 != 0 and (status >> 9) & 15 == 4) return;
                self.io.delay(1_000);
            }
            return error.Timeout;
        }

        fn readTransfer(self: *Self, index: u6, argument: u32, length: u32, buffer: *[512]u8) Error!void {
            return self.readTransferControlled(index, argument, length, buffer, Proceed{});
        }

        inline fn readTransferControlled(self: *Self, index: u6, argument: u32, length: u32, buffer: *[512]u8, control: anytype) Error!void {
            if (!((index == 17 and length == 512) or (index == 51 and length == 8))) return error.InvalidCommand;
            if (!self.owns()) return error.NoOwnership;
            if (self.faulted or !self.quiescence.complete()) return error.Controller;
            try checkStop(control);
            self.words_read = 0;
            self.io.write(regs.ctrl, self.io.read(regs.ctrl) | 6);
            try self.pollClear(regs.ctrl, 6);
            self.io.delay(10);
            self.io.write(regs.dma_mode, 1);
            try self.pollClear(regs.dma_mode, 1);
            const descriptor = self.io.prepareDma(length) orelse return error.Controller;
            self.quiescence = .{ .device_idle = false, .descriptors_released = false, .cache_handed_back = false };
            self.io.write(regs.block, length);
            self.io.write(regs.bytes, length);
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
                if (self.quiescence.device_idle) self.releaseDma() catch {
                    self.cleanup_failed = true;
                };
            }
            const response = try self.commandControlled(index, argument, control);
            if (response[0] & 0xfdff_e008 != 0) return error.Response;
            for (0..self.poll_limit) |_| {
                try checkStop(control);
                const interrupts = self.io.read(regs.interrupts);
                self.last_interrupts = interrupts;
                self.last_status = self.io.read(regs.dma_status);
                if (interrupts & errors != 0 or self.last_status & 0x34 != 0) return error.Controller;
                if (interrupts & (done | data_over) == done | data_over) {
                    try self.stopDma();
                    try checkStop(control);
                    if (!self.io.finishDma(buffer, length)) return error.ShortRead;
                    try self.releaseDma();
                    self.words_read = length / 4;
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
    pub const experimental_sd_write = true;
    write_command: u32 = 0,
    write_prepared: u32 = 0,
    write_finished: u32 = 0,
    write_fail_finish: bool = false,
    card_busy: bool = false,
    host_busy_after_write: bool = false,
    written: [512]u8 = @splat(0),
    complete: bool = true,
    owned: bool = false,
    fail_prepare: bool = false,
    dma_error: u32 = 0,
    stall_stop: bool = false,
    stall_fsm: bool = false,
    fail_release: bool = false,
    releases: u32 = 0,
    responses: u32 = 0,
    descriptor_stuck: bool = false,
    prepared: u32 = 0,
    stopped: u32 = 0,
    command_word: u32 = 0,
    pub fn read(self: *@This(), offset: usize) u32 {
        if (offset == regs.response) self.responses += 1;
        return switch (offset) {
            regs.interrupts => done | (if (self.complete) data_over else @as(u32, 0)),
            regs.response => if (self.card_busy and self.command_word & 63 == 13) 0xe00 else 0x900,
            regs.status => if (self.host_busy_after_write and self.write_command != 0) 1 << 9 else 0,
            regs.dma_status => self.dma_error | (if (self.stall_fsm) @as(u32, 2 << 13) else 0),
            regs.ctrl => if (self.stall_stop and self.stopped != 0) 4 else 0,
            regs.descriptor => if (self.descriptor_stuck) 0x4ff1_0000 else 0,
            else => 0,
        };
    }
    pub fn write(self: *@This(), offset: usize, value: u32) void {
        if (offset == regs.command) {
            self.command_word = value;
            if (value & 63 == 24) self.write_command = value;
        }
        if (offset == regs.dma_mode and value == 0) self.stopped += 1;
    }
    pub fn delay(_: *@This(), _: u32) void {}
    pub fn prepareDma(self: *@This(), _: u32) ?u32 {
        self.prepared += 1;
        return if (self.fail_prepare) null else 0x4ff1_0000;
    }
    pub fn prepareWriteDma(self: *@This(), source: *const [512]u8) ?u32 {
        self.write_prepared += 1;
        if (self.fail_prepare) return null;
        self.written = source.*;
        return 0x4ff1_0000;
    }
    pub fn finishWriteDma(self: *@This()) bool {
        self.write_finished += 1;
        return !self.owned and !self.write_fail_finish;
    }
    pub fn finishDma(self: *@This(), output: *[512]u8, _: u32) bool {
        if (self.owned) return false;
        for (output, 0..) |*byte, i| byte.* = @truncate(i);
        return true;
    }
    pub fn releaseDma(self: *@This()) bool {
        std.debug.assert(self.stopped != 0 and !self.stall_stop and !self.stall_fsm);
        self.releases += 1;
        return !self.fail_release;
    }
};

test "cancel and removal stop at command data and copy boundaries without publishing bytes" {
    const Control = struct {
        model: *DmaModel,
        phase: u32,
        reason: StopReason,
        pub fn stopReason(self: @This()) StopReason {
            const stop_now = switch (self.phase) {
                0 => true,
                1 => self.model.command_word != 0,
                2 => self.model.responses != 0,
                else => self.model.stopped != 0,
            };
            return if (stop_now) self.reason else .none;
        }
    };
    for ([_]StopReason{ .cancelled, .removed }) |reason| {
        for (0..4) |phase| {
            var model = DmaModel{};
            var controller = Controller(*DmaModel){ .io = &model, .poll_limit = 4, .rca = 1 << 16, .sectors = 8 };
            var data: [512]u8 = @splat(0xa5);
            const result = controller.readSectorControlled(0, &data, Control{ .model = &model, .phase = @intCast(phase), .reason = reason });
            if (reason == .cancelled) try std.testing.expectError(error.Cancelled, result) else try std.testing.expectError(error.Removed, result);
            try std.testing.expect(controller.quiescence.complete());
            for (data) |byte| try std.testing.expectEqual(@as(u8, 0xa5), byte);
            if (phase == 0) {
                try std.testing.expectEqual(@as(u32, 0), model.prepared);
            } else {
                try std.testing.expect(controller.faulted);
                try std.testing.expect(model.releases > 0);
                try std.testing.expectError(error.Controller, controller.readSector(0, &data));
            }
        }
    }
}

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
    for (0..5) |fault| {
        var model = DmaModel{ .complete = fault != 0, .owned = fault == 1, .dma_error = if (fault == 2) 4 else 0, .fail_prepare = fault == 3, .stall_stop = fault == 4 };
        var controller = Controller(*DmaModel){ .io = &model, .poll_limit = 4, .rca = 1 << 16, .sectors = 8 };
        var output: [512]u8 = @splat(0xa5);
        if (fault == 0 or fault == 4) try std.testing.expectError(error.Timeout, controller.readSector(0, &output)) else if (fault == 1)
            try std.testing.expectError(error.ShortRead, controller.readSector(0, &output))
        else
            try std.testing.expectError(error.Controller, controller.readSector(0, &output));
        if (fault != 3) try std.testing.expect(model.stopped != 0);
        if (fault != 3) {
            try std.testing.expect(controller.faulted);
            const prepared = model.prepared;
            try std.testing.expectError(error.Controller, controller.readSector(0, &output));
            try std.testing.expectEqual(prepared, model.prepared);
        }
        if (fault == 4) try std.testing.expect(controller.cleanup_failed);
        for (output) |byte| try std.testing.expectEqual(@as(u8, 0xa5), byte);
    }
}

const WidthModel = struct {
    width: u32 = 0,
    divider: u32 = 50,
    clock_enable: u32 = 1,
    last_index: u32 = 0,
    trace: [4]u32 = @splat(0),
    count: usize = 0,
    pins_switched: bool = false,
    deny_app: bool = false,
    drop_width: bool = false,
    drop_clock: bool = false,
    widths: u8 = 5,
    length: u32 = 0,
    pub fn read(self: *@This(), offset: usize) u32 {
        return switch (offset) {
            regs.interrupts => done | data_over,
            regs.response => 0x900 | (if (self.last_index == 55 and !self.deny_app) @as(u32, 0x20) else 0),
            regs.width => self.width,
            regs.clkdiv => self.divider,
            regs.clkena => self.clock_enable,
            else => 0,
        };
    }
    pub fn write(self: *@This(), offset: usize, value: u32) void {
        if (offset == regs.width and !self.drop_width) self.width = value;
        if (offset == regs.clkdiv and !self.drop_clock) self.divider = value;
        if (offset == regs.clkena) self.clock_enable = value;
        if (offset == regs.command and value & (1 << 21) == 0) {
            self.last_index = value & 63;
            self.trace[self.count] = self.last_index;
            self.count += 1;
        }
    }
    pub fn delay(_: *@This(), _: u32) void {}
    pub fn fourBitPins(self: *@This()) void {
        self.pins_switched = true;
    }
    pub fn prepareDma(self: *@This(), length: u32) ?u32 {
        self.length = length;
        return 0x4ff1_0000;
    }
    pub fn finishDma(self: *@This(), output: *[512]u8, length: u32) bool {
        std.debug.assert(self.length == 8 and length == 8);
        output[0..8].* = .{ 2, self.widths, 0, 0, 0, 0, 0, 0 };
        return true;
    }
    pub fn releaseDma(_: *@This()) bool {
        return true;
    }
};

test "4-bit transition requires SCR and APP_CMD before ACMD6 and verifies the host" {
    var model = WidthModel{};
    var controller = Controller(*WidthModel){ .io = &model, .poll_limit = 4, .rca = 1 << 16 };
    try controller.prepare();
    try std.testing.expectError(error.Controller, controller.switch20MHz());
    try std.testing.expectEqual(@as(usize, 0), model.count);
    try controller.switchFourBit();
    try std.testing.expectEqualSlices(u32, &.{ 55, 51, 55, 6 }, &model.trace);
    try std.testing.expect(model.pins_switched);
    try std.testing.expectEqual(@as(u32, 5), controller.scr_widths);
    try std.testing.expectEqual(@as(u32, 4), controller.bus_bits);
    try controller.switch20MHz();
    try std.testing.expectEqual(@as(u32, 20_000), controller.clock_khz);
    try std.testing.expectEqual(@as(u32, 1), controller.divider);
}

test "initial 1-bit width and 400 kHz divider are also read back" {
    var model = WidthModel{ .width = 0x10001, .drop_width = true };
    var controller = Controller(*WidthModel){ .io = &model, .poll_limit = 4 };
    try std.testing.expectError(error.Controller, controller.prepare());
}

test "missing APP_CMD unsupported SCR and dropped host configuration stop switching" {
    for (0..4) |fault| {
        var model = WidthModel{ .deny_app = fault == 0, .widths = if (fault == 1) 1 else 5, .drop_width = fault == 2, .drop_clock = fault == 3 };
        var controller = Controller(*WidthModel){ .io = &model, .poll_limit = 4, .rca = 1 << 16 };
        switch (fault) {
            0 => try std.testing.expectError(error.Response, controller.switchFourBit()),
            1 => try std.testing.expectError(error.Unsupported, controller.switchFourBit()),
            2 => try std.testing.expectError(error.Controller, controller.switchFourBit()),
            3 => {
                try controller.switchFourBit();
                try std.testing.expectError(error.Controller, controller.switch20MHz());
            },
            else => unreachable,
        }
        try std.testing.expect(controller.faulted);
        const commands = model.count;
        try std.testing.expectError(error.Controller, controller.switchFourBit());
        try std.testing.expectEqual(commands, model.count);
        if (fault < 2) try std.testing.expect(!model.pins_switched);
    }
    try std.testing.expectError(error.Unsupported, scrWidths(.{ 0x10, 5, 0, 0, 0, 0, 0, 0 }));
    try std.testing.expectError(error.Unsupported, scrWidths(.{ 0, 4, 0, 0, 0, 0, 0, 0 }));
}

test "experimental CMD24 stages a sector, drains DMA, and waits for card ready" {
    var model = DmaModel{};
    var controller = Controller(*DmaModel){ .io = &model, .poll_limit = 4, .ready_poll_limit = 3, .rca = 1 << 16, .sectors = 8 };
    var bytes: [512]u8 = undefined;
    for (&bytes, 0..) |*byte, i| byte.* = @truncate(i);
    try std.testing.expectError(error.InvalidCommand, controller.command(24, 0));
    try controller.writeSectorControlled(7, &bytes, Proceed{});
    try std.testing.expectEqualSlices(u8, &bytes, &model.written);
    try std.testing.expectEqual(@as(u32, 24), model.write_command & 63);
    try std.testing.expect(model.write_command & (1 << 9) != 0 and model.write_command & (1 << 10) != 0);
    try std.testing.expectEqual(@as(u32, 1), model.write_finished);
    try std.testing.expectEqual(@as(u32, 1), model.releases);
    try std.testing.expectEqual(@as(u32, 13), model.command_word & 63);
    try std.testing.expect(controller.quiescence.complete());
    try std.testing.expectError(error.InvalidAddress, controller.writeSectorControlled(8, &bytes, Proceed{}));
    try std.testing.expectEqual(@as(u32, 1), model.write_prepared);
}

test "write failures retire the controller and retain unsafe DMA ownership" {
    const bytes: [512]u8 = @splat(0x5a);
    for (0..6) |fault| {
        var model = DmaModel{ .complete = fault != 0, .dma_error = if (fault == 1) 4 else 0, .write_fail_finish = fault == 2, .stall_stop = fault == 3, .card_busy = fault == 4, .host_busy_after_write = fault == 5 };
        var controller = Controller(*DmaModel){ .io = &model, .poll_limit = 3, .ready_poll_limit = 2, .rca = 1 << 16, .sectors = 8 };
        if (fault == 0 or fault == 3 or fault == 4 or fault == 5)
            try std.testing.expectError(error.Timeout, controller.writeSectorControlled(0, &bytes, Proceed{}))
        else
            try std.testing.expectError(error.Controller, controller.writeSectorControlled(0, &bytes, Proceed{}));
        try std.testing.expect(controller.faulted);
        try std.testing.expectEqual(fault != 3, controller.quiescence.complete());
        try std.testing.expectEqual(fault == 3, controller.cleanup_failed);
        try std.testing.expectError(error.Controller, controller.writeSectorControlled(0, &bytes, Proceed{}));
        try std.testing.expectEqual(@as(u32, 1), model.write_prepared);
    }
}

test "ordinary bus cannot issue the experimental write command" {
    const ReadOnlyBus = struct {};
    var controller = Controller(ReadOnlyBus){ .io = .{} };
    const bytes: [512]u8 = @splat(0);
    try std.testing.expectError(error.InvalidCommand, controller.writeSectorControlled(0, &bytes, Proceed{}));
}

test "write cancellation and removal quarantine launched transfers" {
    const Control = struct {
        model: *DmaModel,
        reason: StopReason,
        phase: u8,
        pub fn stopReason(self: @This()) StopReason {
            const stopped = switch (self.phase) {
                0 => true,
                1 => self.model.write_command != 0,
                2 => self.model.write_finished != 0,
                else => unreachable,
            };
            return if (stopped) self.reason else .none;
        }
    };
    const bytes: [512]u8 = @splat(0x5a);
    for ([_]StopReason{ .cancelled, .removed }) |reason| {
        for (0..3) |phase| {
            var model: DmaModel = .{};
            var controller = Controller(*DmaModel){ .io = &model, .poll_limit = 4, .ready_poll_limit = 2, .rca = 1 << 16, .sectors = 8 };
            const control = Control{ .model = &model, .reason = reason, .phase = @intCast(phase) };
            const result = controller.writeSectorControlled(0, &bytes, control);
            if (reason == .cancelled) try std.testing.expectError(error.Cancelled, result) else try std.testing.expectError(error.Removed, result);
            try std.testing.expect(controller.quiescence.complete());
            if (phase == 0) {
                try std.testing.expectEqual(@as(u32, 0), model.write_prepared);
            } else {
                try std.testing.expect(controller.faulted);
                try std.testing.expect(model.write_command != 0);
                try std.testing.expectEqual(@as(u32, 1), model.releases);
                try std.testing.expectError(error.Controller, controller.writeSectorControlled(0, &bytes, Proceed{}));
            }
        }
    }
}
