const std = @import("std");
const sender = @import("hosted_long_sender.zig");
const sd = @import("../soc/esp32p4/sdio.zig");

const Io = struct {
    regs: [64]u32 = @splat(0),
    transfers: usize = 0,
    timeout: bool = false,
    fail_prepare: bool = false,
    fail_finish: bool = false,
    tx: [1536]u8 = @splat(0),
    pub fn read(self: *@This(), address: usize) u32 {
        return switch (address) {
            sd.regs.ctrl, sd.regs.command, sd.regs.dma_mode, sd.regs.dma_status => 0,
            sd.regs.interrupts => (1 << 2) | (if (self.timeout) @as(u32, 0) else 1 << 3),
            else => self.regs[address / 4],
        };
    }
    pub fn write(self: *@This(), address: usize, value: u32) void {
        self.regs[address / 4] = value;
        if (address == sd.regs.command and value & 63 == 53) self.transfers += 1;
    }
    pub fn delay(_: *@This(), _: u32) void {}
    pub fn prepareDma(self: *@This(), writing: bool, source: []const u8, length: usize) ?u32 {
        if (self.fail_prepare or !writing or length > self.tx.len) return null;
        @memcpy(self.tx[0..length], source);
        return 0x4ff10000;
    }
    pub fn finishDma(self: *@This(), _: bool, _: []u8) bool {
        return !self.fail_finish;
    }
};

const Host = struct {
    pub const TransportError = sd.Error || error{CreditRead};
    controller: sd.Controller(*Io),
    total: u32 = 0,
    fail_credit: bool = false,
    credit_reads: usize = 0,
    pub fn readWord(self: *@This(), _: u32) TransportError!u32 {
        self.credit_reads += 1;
        if (self.fail_credit) return error.CreditRead;
        return self.total << 16;
    }
    pub fn writeBlocks(self: *@This(), address: u32, bytes: []const u8) TransportError!void {
        try self.controller.writeBlocks(address, bytes);
    }
    pub fn writeBytes(self: *@This(), address: u32, bytes: []const u8) TransportError!void {
        try self.controller.writeBytes(address, bytes);
    }
};

fn setup(io: *Io) Host {
    return .{ .controller = .{ .io = io, .prepared = true, .selected = true, .four_bit = true, .poll_limit = 2 } };
}

test "invalid length and explicit reset never read credit or touch FIFO" {
    var io: Io = .{};
    var host = setup(&io);
    var stream = sender.ProfileStream(Host, 64){ .host = &host };
    var tx = sender.Sender(Host, 64){ .stream = &stream };
    const too_short: [512]u8 = @splat(0);
    try std.testing.expectError(error.InvalidLength, tx.send(&too_short));
    try std.testing.expectEqual(@as(usize, 0), host.credit_reads);
    try std.testing.expectEqual(@as(usize, 0), io.transfers);
    tx.retire(); // Caller invalidates the sender when the peer resets.
    const packet: [1254]u8 = @splat(0);
    try std.testing.expectError(error.Retired, tx.send(&packet));
    try std.testing.expectEqual(@as(usize, 0), host.credit_reads);
    try std.testing.expectEqual(@as(usize, 0), io.transfers);
}

test "credit gates a single complete Hosted transaction and preserves padding" {
    var io: Io = .{};
    var host = setup(&io);
    var stream = sender.ProfileStream(Host, 64){ .host = &host, .sent_buffers = 0xfff };
    var tx = sender.Sender(Host, 64){ .stream = &stream };
    const packet: [1254]u8 = @splat(0x5a);
    host.total = 0xfff;
    try std.testing.expectEqual(@as(usize, 0), try tx.send(&packet));
    try std.testing.expectEqual(@as(usize, 0), io.transfers);
    host.total = 0; // wrap: one credit available
    try std.testing.expectEqual(@as(usize, 1254), try tx.send(&packet));
    try std.testing.expectEqual(@as(usize, 1), io.transfers);
    try std.testing.expectEqual(@as(u32, 0), stream.sent_buffers);
    try std.testing.expectEqual(@as(u32, 1536), io.regs[sd.regs.bytes / 4]);
    try std.testing.expectEqual(@as(u32, 3), io.regs[sd.regs.argument / 4] & 511);
    try std.testing.expectEqual(@as(u32, 0x1f800 - 1254), (io.regs[sd.regs.argument / 4] >> 9) & 0x1ffff);
    try std.testing.expectEqualSlices(u8, &packet, io.tx[0..packet.len]);
    try std.testing.expect(std.mem.allEqual(u8, io.tx[packet.len..], 0));
}

test "credit and DMA provider errors retire the sender without replay" {
    const packet: [1254]u8 = @splat(0x5a);
    for (0..5) |failure| {
        var io: Io = .{ .fail_prepare = failure == 1, .timeout = failure == 2, .fail_finish = failure == 3 };
        var host = setup(&io);
        host.total = if (failure == 4) 65 else 1;
        host.fail_credit = failure == 0;
        var stream = sender.ProfileStream(Host, 64){ .host = &host };
        var tx = sender.Sender(Host, 64){ .stream = &stream };
        const expected: anyerror = switch (failure) {
            0 => error.CreditRead,
            1 => error.Dma,
            2 => error.Timeout,
            3 => error.Dma,
            else => error.CounterDiscontinuity,
        };
        try std.testing.expectError(expected, tx.send(&packet));
        try std.testing.expectEqual(@as(u32, 0), stream.sent_buffers);
        try std.testing.expectError(error.Retired, stream.send("short"));
        const calls = io.transfers;
        try std.testing.expectError(error.Retired, tx.send(&packet));
        try std.testing.expectEqual(calls, io.transfers);
    }
}

test "short and long sends share credits and a short failure retires long send" {
    var io: Io = .{};
    var host = setup(&io);
    host.total = 3;
    var stream = sender.ProfileStream(Host, 64){ .host = &host };
    var tx = sender.Sender(Host, 64){ .stream = &stream };
    const packet: [1254]u8 = @splat(0x5a);
    try std.testing.expectEqual(@as(usize, 3), try stream.send("abc"));
    try std.testing.expectEqual(@as(usize, 1254), try tx.send(&packet));
    try std.testing.expectEqual(@as(u32, 2), stream.sent_buffers);
    io.timeout = true;
    try std.testing.expectError(error.Timeout, stream.send("abc"));
    try std.testing.expectEqual(@as(u32, 2), stream.sent_buffers);
    const transfers = io.transfers;
    try std.testing.expectError(error.Retired, tx.send(&packet));
    try std.testing.expectEqual(transfers, io.transfers);
}
