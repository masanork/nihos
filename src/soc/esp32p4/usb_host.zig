//! One root port, one polled DWC2 scatter/gather DMA channel, boot CPU0 only.
//! Register and QTD layouts checked against ESP-IDF v5.4.4 Apache-2.0 LL.
//! No IDF host stack, RTOS, IRQ routing, heap, hub, or periodic scheduler.
const std = @import("std");
pub const base = 0x5000_0000;
pub const Error = error{ Timeout, Disconnected, Overcurrent, Unsupported, Stall, Transfer, Cache, InvalidTransfer, Poisoned };
pub const regs = struct {
    pub const ahb = 0x08;
    pub const usb = 0x0c;
    pub const reset = 0x10;
    pub const interrupts = 0x14;
    pub const mask = 0x18;
    pub const rx_fifo = 0x24;
    pub const tx_fifo = 0x28;
    pub const identity = 0x40;
    pub const hardware3 = 0x4c;
    pub const periodic_fifo = 0x100;
    pub const host = 0x400;
    pub const channels = 0x418;
    pub const port = 0x440;
    pub const channel = 0x500;
    pub const channel_irq = 0x508;
    pub const channel_mask = 0x50c;
    pub const size = 0x510;
    pub const dma = 0x514;
};
pub const Pipe = struct { address: u7, endpoint: u4 = 0, packet: u16 = 8, kind: u2 = 0, data1: bool = false };
pub fn setup(request_type: u8, request: u8, value: u16, index: u16, length: u16) [8]u8 {
    return .{ request_type, request, @truncate(value), @intCast(value >> 8), @truncate(index), @intCast(index >> 8), @truncate(length), @intCast(length >> 8) };
}
pub fn receiveSpan(length: usize, packet: u16) Error!usize {
    if (packet == 0 or packet > 512 or length > 512) return error.InvalidTransfer;
    const span = (length + packet - 1) / packet * packet;
    if (span > 512) return error.InvalidTransfer;
    return span;
}
pub fn descriptorStatus(word: u32, span: usize) Error!usize {
    if (word & 0xb000_0000 != 0 or word & 0x1ffff > span) return error.Transfer;
    return span - (word & 0x1ffff);
}

pub fn Controller(comptime Io: type) type {
    return struct {
        io: Io,
        transfers: u32 = 0,
        last_irq: u32 = 0,
        last_descriptor: u32 = 0,
        poisoned: bool = false,
        speed: u32 = 0,
        const Self = @This();
        fn wait(self: *Self, offset: usize, mask: u32, wanted: u32, timeout: u32) Error!void {
            var elapsed: u32 = 0;
            while (elapsed < timeout) : (elapsed += 10) {
                if (self.io.read(offset) & mask == wanted) return;
                if (!self.io.delay(10)) return error.Timeout;
            }
            return error.Timeout;
        }
        fn portWrite(self: *Self, set: u32, clear: u32) void {
            // W1C includes port-enable; never echo it when changing power/reset.
            self.io.write(regs.port, (self.io.read(regs.port) & ~@as(u32, 0x2e) & ~clear) | set);
        }
        pub fn initialize(self: *Self) Error!void {
            const identity = self.io.read(regs.identity);
            if (identity != 0x4f54400a and identity != 0x4f54430a) return error.Unsupported;
            self.io.write(regs.ahb, (1 << 5) | 1);
            self.io.write(regs.usb, (self.io.read(regs.usb) & ~@as(u32, (1 << 8) | (1 << 9) | (1 << 6) | (1 << 4) | 7)) | (1 << 29) | (1 << 3) | 5);
            self.io.write(regs.mask, (1 << 24) | (1 << 25) | (1 << 29));
            self.io.write(regs.interrupts, 0xffff_ffff);
            if (!self.io.delay(100_000)) return error.Timeout;
            const depth = self.io.read(regs.hardware3) >> 16;
            if (depth < 512 or depth > 4096) return error.Unsupported;
            const tx = depth / 4;
            const periodic = depth / 8;
            const rx = depth - tx - periodic;
            self.io.write(regs.rx_fifo, rx);
            self.io.write(regs.tx_fifo, (tx << 16) | rx);
            self.io.write(regs.periodic_fifo, (periodic << 16) | (rx + tx));
            for ([_]u32{ 1 << 5, (1 << 5) | (1 << 6), 1 << 4 }) |flush| {
                self.io.write(regs.reset, flush);
                try self.wait(regs.reset, (1 << 5) | (1 << 4), 0, 10_000);
            }
            self.portWrite(1 << 12, 0);
            try self.wait(regs.port, 1, 1, 1_000_000);
            if (!self.io.delay(100_000)) return error.Timeout;
            self.portWrite(1 << 8, 0);
            if (!self.io.delay(60_000)) return error.Timeout;
            self.portWrite(0, 1 << 8);
            if (!self.io.delay(20_000)) return error.Timeout;
            try self.wait(regs.port, 4, 4, 100_000);
            const port = self.io.read(regs.port);
            if (port & 16 != 0) return error.Overcurrent;
            self.speed = (port >> 17) & 3;
            if (self.speed > 1) return error.Unsupported; // HS or FS, direct root only.
            self.io.write(regs.host, (self.io.read(regs.host) & ~@as(u32, 1 << 26)) | (1 << 23));
            self.io.write(regs.channels, 1);
            self.io.write(regs.channel_mask, (1 << 11) | 3);
        }
        fn halt(self: *Self) void {
            self.io.write(regs.channel, self.io.read(regs.channel) | (1 << 30));
            self.wait(regs.channel, 1 << 31, 0, 50_000) catch {
                self.poisoned = true;
            };
        }
        pub fn stage(self: *Self, pipe: *Pipe, input: bool, is_setup: bool, bytes: []u8) Error!usize {
            if (self.poisoned) return error.Poisoned;
            if (bytes.len > 512 or pipe.packet == 0 or pipe.packet > 512) return error.InvalidTransfer;
            const span = if (input) try receiveSpan(bytes.len, pipe.packet) else bytes.len;
            const descriptor = try self.io.prepare(bytes, span, input, is_setup);
            self.io.write(regs.channel_irq, 0xffff_ffff);
            const character = @as(u32, pipe.packet) | (@as(u32, pipe.endpoint) << 11) |
                (@as(u32, @intFromBool(input)) << 15) | (@as(u32, pipe.kind) << 18) | (@as(u32, pipe.address) << 22);
            self.io.write(regs.channel, character);
            self.io.write(regs.size, 0xff | (if (pipe.data1) @as(u32, 2 << 29) else 0));
            self.io.write(regs.dma, descriptor);
            self.io.write(regs.channel, character | (1 << 31));
            errdefer self.halt();
            var elapsed: u32 = 0;
            while (elapsed < 500_000) : (elapsed += 10) {
                const port = self.io.read(regs.port);
                if (port & 1 == 0) return error.Disconnected;
                if (port & 16 != 0) return error.Overcurrent;
                self.last_irq = self.io.read(regs.channel_irq);
                if (self.last_irq & (1 << 3) != 0) return error.Stall;
                if (self.last_irq & ((1 << 11) | (1 << 12) | (1 << 8) | 4) != 0) return error.Transfer;
                if (self.last_irq & 2 != 0) {
                    self.last_descriptor = try self.io.finish(bytes, span, input);
                    const actual = try descriptorStatus(self.last_descriptor, span);
                    if (self.last_irq & 1 == 0 or actual > bytes.len) return error.Transfer;
                    pipe.data1 = self.io.read(regs.size) & (2 << 29) != 0;
                    self.transfers += 1;
                    return actual;
                }
                if (!self.io.delay(10)) return error.Timeout;
            }
            return error.Timeout;
        }
        pub fn control(self: *Self, pipe: *Pipe, request: [8]u8, bytes: []u8) Error!usize {
            const length = @as(u16, request[6]) | (@as(u16, request[7]) << 8);
            if (length != bytes.len or pipe.endpoint != 0 or pipe.kind != 0) return error.InvalidTransfer;
            var command = request;
            pipe.data1 = false;
            if (try self.stage(pipe, false, true, &command) != 8) return error.Transfer;
            const input = request[0] & 0x80 != 0;
            var actual: usize = 0;
            if (length != 0) {
                pipe.data1 = true;
                actual = try self.stage(pipe, input, false, bytes);
            }
            pipe.data1 = true;
            if (try self.stage(pipe, !(length != 0 and input), false, &.{}) != 0) return error.Transfer;
            return actual;
        }
    };
}

test "DMA sizes and completion reject overrun, inactive and error descriptors" {
    try std.testing.expectEqual(@as(usize, 128), try receiveSpan(116, 64));
    try std.testing.expectError(error.InvalidTransfer, receiveSpan(513, 64));
    try std.testing.expectError(error.InvalidTransfer, receiveSpan(1, 0));
    try std.testing.expectEqual(@as(usize, 116), try descriptorStatus(12, 128));
    for ([_]u32{ 0x80000000, 0x10000000, 0x20000000, 129 }) |word|
        try std.testing.expectError(error.Transfer, descriptorStatus(word, 128));
}

const Model = struct {
    outcome: enum { complete, stalled, timeout, disconnected } = .complete,
    halt_stuck: bool = false,
    active: bool = false,
    prepared: u32 = 0,
    finishes: u32 = 0,
    delays: u32 = 0,
    size: u32 = 0,
    pub fn read(self: *@This(), offset: usize) u32 {
        return switch (offset) {
            regs.port => if (self.outcome == .disconnected) 0 else 5,
            regs.channel_irq => switch (self.outcome) {
                .complete => 3,
                .stalled => 10,
                else => 0,
            },
            regs.channel => if (self.active) 1 << 31 else 0,
            regs.size => self.size,
            else => 0,
        };
    }
    pub fn write(self: *@This(), offset: usize, value: u32) void {
        if (offset == regs.channel) {
            if (value & (1 << 30) != 0) {
                if (!self.halt_stuck) self.active = false;
            } else self.active = value & (1 << 31) != 0;
        }
        if (offset == regs.size) self.size = value;
    }
    pub fn delay(self: *@This(), _: u32) bool {
        self.delays += 1;
        return true;
    }
    pub fn prepare(self: *@This(), _: []u8, _: usize, _: bool, _: bool) Error!u32 {
        self.prepared += 1;
        return 0x4ff10000;
    }
    pub fn finish(self: *@This(), _: []u8, _: usize, _: bool) Error!u32 {
        self.finishes += 1;
        self.active = false;
        return 0;
    }
};

test "stalled and disconnected channels halt before returning buffer ownership" {
    for ([_]Model{ .{ .outcome = .stalled }, .{ .outcome = .disconnected } }) |initial| {
        var model = initial;
        var controller = Controller(*Model){ .io = &model };
        var pipe = Pipe{ .address = 1, .packet = 64 };
        var data: [64]u8 = @splat(0);
        const expected = if (model.outcome == .stalled) error.Stall else error.Disconnected;
        try std.testing.expectError(expected, controller.stage(&pipe, true, false, &data));
        try std.testing.expect(!model.active);
        try std.testing.expectEqual(@as(u32, 0), model.finishes);
    }
}

test "timeout with stuck DMA poisons controller and prevents buffer reuse" {
    var model = Model{ .outcome = .timeout, .halt_stuck = true };
    var controller = Controller(*Model){ .io = &model };
    var pipe = Pipe{ .address = 1, .packet = 64 };
    var data: [64]u8 = @splat(0);
    try std.testing.expectError(error.Timeout, controller.stage(&pipe, true, false, &data));
    try std.testing.expect(controller.poisoned);
    try std.testing.expectEqual(@as(u32, 55_000), model.delays);
    try std.testing.expectError(error.Poisoned, controller.stage(&pipe, true, false, &data));
    try std.testing.expectEqual(@as(u32, 1), model.prepared);
    try std.testing.expectEqual(@as(u32, 0), model.finishes);
}

test "invalid control length never reaches DMA" {
    var model = Model{};
    var controller = Controller(*Model){ .io = &model };
    var pipe = Pipe{ .address = 0 };
    var data: [8]u8 = @splat(0);
    try std.testing.expectError(error.InvalidTransfer, controller.control(&pipe, setup(0x80, 6, 0x0100, 0, 18), &data));
    try std.testing.expectEqual(@as(u32, 0), model.prepared);
}
