const std = @import("std");
const sd = @import("sdio.zig");
const r = sd.regs;

const Model = struct {
    registers: [64]u32 = @splat(0),
    cccr: [512]u8 = @splat(0),
    trace: [256]u32 = @splat(0),
    trace_len: usize = 0,
    touches: usize = 0,
    irq_error: u32 = 0,
    r5_error: u32 = 0,
    self_clear: bool = false,
    dma_error: u32 = 0,
    no_data: bool = false,
    fail_prepare: bool = false,
    owned: bool = false,
    stall_stop: bool = false,
    stopped: u32 = 0,
    prepared: usize = 0,
    tx: [512]u8 = @splat(0),
    tx_len: usize = 0,
    pins: bool = false,

    pub fn read(self: *@This(), offset: usize) u32 {
        self.touches += 1;
        return switch (offset) {
            r.ctrl => if (self.stall_stop and self.stopped > 0) 4 else 0,
            r.command => 0,
            r.dma_mode => 0,
            r.interrupts => (1 << 2) | (if (self.no_data) @as(u32, 0) else 1 << 3) | self.irq_error,
            r.dma_status => self.dma_error,
            else => self.registers[offset / 4],
        };
    }
    pub fn write(self: *@This(), offset: usize, value: u32) void {
        self.touches += 1;
        self.registers[offset / 4] = value;
        if (offset == r.dma_mode and value == 0) self.stopped += 1;
        if (offset != r.command or value & (1 << 21) != 0) return;
        self.trace[self.trace_len] = value;
        self.trace_len += 1;
        const argument = self.registers[r.argument / 4];
        self.registers[r.response / 4] = switch (value & 63) {
            5 => 0x90ff8000,
            3 => 0x12340000,
            7 => 0x900,
            52 => blk: {
                const address = (argument >> 9) & 0x1ffff;
                if (address >= self.cccr.len) break :blk self.r5_error;
                if (argument & (1 << 31) != 0) self.cccr[address] = @truncate(argument);
                if (self.self_clear and address == 0x8c) self.cccr[address] = 0;
                break :blk self.cccr[address] | self.r5_error;
            },
            53 => self.r5_error,
            else => 0,
        };
    }
    pub fn delay(_: *@This(), _: u32) void {}
    pub fn fourBitPins(self: *@This()) void {
        self.pins = true;
    }
    pub fn prepareDma(self: *@This(), writing: bool, source: []const u8, length: usize) ?u32 {
        self.prepared = length;
        if (self.fail_prepare) return null;
        if (writing) {
            @memcpy(self.tx[0..length], source);
            self.tx_len = length;
        }
        return 0x4ff10000;
    }
    pub fn finishDma(self: *@This(), writing: bool, destination: []u8) bool {
        if (self.owned) return false;
        if (!writing) for (destination, 0..) |*byte, i| {
            byte.* = @truncate(i);
        };
        return true;
    }
};

fn setup(model: *Model) !sd.Controller(*Model) {
    var host = sd.Controller(*Model){ .io = model, .poll_limit = 3 };
    try host.prepare(true);
    try host.identify();
    model.cccr[3] = 2;
    try host.enableFunction();
    return host;
}

test "slot 1 enumeration selects its own clock divider and SDIO command responses" {
    var model: Model = .{};
    var host = try setup(&model);
    try std.testing.expectEqual(@as(u32, 50 << 8), model.registers[r.divider / 4]);
    try std.testing.expectEqual(@as(u32, 4), model.registers[r.source / 4]);
    try std.testing.expectEqual(@as(u32, 2), model.registers[r.clock / 4]);
    try std.testing.expectEqual(@as(u32, 2), model.registers[r.width / 4]);
    try std.testing.expect(model.pins and host.four_bit and host.selected);
    try std.testing.expectEqual(@as(u32, 0x12340000), host.rca);
    for (model.trace[0..model.trace_len]) |command| {
        try std.testing.expect(command & (1 << 16) != 0);
        if (command & 63 == 5) try std.testing.expect(command & (1 << 8) == 0);
        if (command & 63 == 52) try std.testing.expect(command & (1 << 8) != 0);
    }
    try std.testing.expectEqual(@as(u8, 2), try host.readByte(0, 0x111));
}

test "ownership and forbidden memory-card commands are rejected before MMIO" {
    var model: Model = .{};
    var host = sd.Controller(*Model){ .io = &model };
    try std.testing.expectError(error.NoOwnership, host.prepare(false));
    for ([_]u6{ 17, 24, 25, 32, 33, 38 }) |index| try std.testing.expectError(error.InvalidArgument, host.command(index, 0, null));
    try std.testing.expectError(error.InvalidArgument, host.command(53, 0, null));
    try std.testing.expectEqual(@as(usize, 0), model.touches);
}

test "CMD52 and CMD53 encoding reject function, address and DMA count mistakes" {
    try std.testing.expectEqual(@as(u32, 0x180004ab | 0x80000000), try sd.argument52(1, 2, 0xab));
    try std.testing.expectError(error.InvalidArgument, sd.argument52(2, 0, null));
    try std.testing.expectError(error.InvalidArgument, sd.argument52(0, 0x20000, null));
    for ([_]usize{ 0, 1, 3, 513, 1024 }) |length| try std.testing.expectError(error.InvalidArgument, sd.argument53(0, length, false));
    const block = try sd.argument53(0x1f600, 512, true);
    try std.testing.expect(block & (1 << 31) != 0 and block & (1 << 27) != 0);
    try std.testing.expectEqual(@as(u32, 1), block & 511);
    try std.testing.expectEqual(@as(u32, 4), (try sd.argument53(0x60, 4, false)) & 511);
}

test "R5 failure poisons the host and no subsequent transaction reaches hardware" {
    var model: Model = .{};
    var host = try setup(&model);
    model.r5_error = 0x100;
    try std.testing.expectError(error.Response, host.readByte(0, 0));
    const touches = model.touches;
    try std.testing.expectError(error.Retired, host.readByte(0, 0));
    try std.testing.expectEqual(touches, model.touches);
}

test "self-clearing doorbell accepts a cleared byte but preserves R5 validation" {
    var model: Model = .{};
    var host = try setup(&model);
    model.self_clear = true;
    model.r5_error = 0x1000; // IO current state is not an R5 error bit.
    try host.writeDoorbell(1, 0x8c, 1);
    try std.testing.expect(!host.faulted);
    try std.testing.expectEqual(@as(u8, 0), try host.readByte(1, 0x8c));
    model.r5_error = 0x100;
    try std.testing.expectError(error.Response, host.writeDoorbell(1, 0x8c, 1));
    try std.testing.expect(host.faulted);
}

test "DMA transfers preserve byte counts, direction and descriptor address" {
    var model: Model = .{};
    var host = try setup(&model);
    var bytes: [512]u8 = @splat(0);
    try host.readBytes(0x1f600, &bytes);
    for (bytes, 0..) |byte, i| try std.testing.expectEqual(@as(u8, @truncate(i)), byte);
    try std.testing.expectEqual(@as(usize, 512), model.prepared);
    try std.testing.expectEqual(@as(u32, 0x4ff10000), model.registers[r.descriptor / 4]);
    try host.writeBytes(0x1f7fd, "abc\x00");
    try std.testing.expectEqualSlices(u8, "abc\x00", model.tx[0..model.tx_len]);
    try std.testing.expect(model.trace[model.trace_len - 1] & (1 << 10) != 0);
    try std.testing.expectEqual(@as(u32, 4), model.registers[r.bytes / 4]);
}

test "DMA errors, timeout, retained ownership and failed cleanup retire the controller" {
    for (0..5) |failure| {
        var model: Model = .{};
        var host = try setup(&model);
        model.no_data = failure == 0 or failure == 4;
        model.dma_error = if (failure == 1) 4 else 0;
        model.owned = failure == 2;
        model.fail_prepare = failure == 3;
        model.stall_stop = failure == 4;
        var bytes: [4]u8 = @splat(0);
        try std.testing.expectError(if (failure == 0 or failure == 4) error.Timeout else error.Dma, host.readBytes(0x60, &bytes));
        try std.testing.expect(host.faulted);
        try std.testing.expectEqual(failure == 4, host.cleanup_failed);
        const touches = model.touches;
        try std.testing.expectError(error.Retired, host.readBytes(0x60, &bytes));
        try std.testing.expectEqual(touches, model.touches);
    }
}
