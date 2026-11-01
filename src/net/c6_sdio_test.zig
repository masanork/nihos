const std = @import("std");
const sdio = @import("c6_sdio.zig");

const LongHost = struct {
    pub const TransportError = error{Io};
    total: u32 = 0,
    reads: u32 = 0,
    writes: u32 = 0,
    pub fn readWord(self: *@This(), _: u32) TransportError!u32 {
        self.reads += 1;
        return self.total << 16;
    }
    pub fn writeBlocks(self: *@This(), _: u32, _: []const u8) TransportError!void {
        self.writes += 1;
    }
};
const CreditObserver = struct {
    calls: u32 = 0,
    total: u32 = 0,
    credit: u32 = 0,
    counter: u32 = 0,
    pub fn record(self: *@This(), total: u32, credit: u32, counter: u32) void {
        self.* = .{ .calls = self.calls + 1, .total = total, .credit = credit, .counter = counter };
    }
};

test "long send observer records the existing credit read without extra I/O" {
    var host: LongHost = .{};
    var stream = sdio.ProfileStream(LongHost, 64){ .host = &host };
    var observer: CreditObserver = .{};
    var padding: [1536]u8 = undefined;
    const packet: [1254]u8 = @splat(0x41);
    try std.testing.expectEqual(@as(usize, 0), try stream.sendLongObserved(&packet, &padding, &observer));
    try std.testing.expectEqual(@as(u32, 1), host.reads);
    try std.testing.expectEqual(@as(u32, 0), host.writes);
    try std.testing.expectEqual(@as(u32, 0), observer.credit);
    host.total = 2;
    try std.testing.expectEqual(@as(usize, packet.len), try stream.sendLongObserved(&packet, &padding, &observer));
    try std.testing.expectEqual(@as(u32, 2), host.reads);
    try std.testing.expectEqual(@as(u32, 1), host.writes);
    try std.testing.expectEqual(@as(u32, 2), observer.calls);
    try std.testing.expectEqual(@as(u32, 2), observer.total);
    try std.testing.expectEqual(@as(u32, 2), observer.credit);
    try std.testing.expectEqual(@as(u32, 0), observer.counter);
    try std.testing.expectEqual(@as(u32, 1), stream.sent_buffers);
}

const Host = struct {
    pub const TransportError = error{Io};
    total: u32 = 0,
    credits: u32 = 10,
    fifo_calls: usize = 0,
    last_address: u32 = 0,
    last_length: usize = 0,
    fail_transfer: bool = false,
    fail_clear: bool = false,
    tx: [512]u8 = @splat(0),
    pub fn readWord(self: *@This(), address: u32) TransportError!u32 {
        return if (address == sdio.length_register) self.total else self.credits << 16;
    }
    pub fn writeWord(self: *@This(), _: u32, _: u32) TransportError!void {
        if (self.fail_clear) return error.Io;
    }
    pub fn readBytes(self: *@This(), address: u32, destination: []u8) TransportError!void {
        self.fifo_calls += 1;
        if (self.fail_transfer) return error.Io;
        self.last_address = address;
        self.last_length = destination.len;
        for (destination, 0..) |*byte, i| byte.* = @truncate(i + 1);
    }
    pub fn writeBytes(self: *@This(), address: u32, source: []const u8) TransportError!void {
        self.fifo_calls += 1;
        if (self.fail_transfer) return error.Io;
        self.last_address = address;
        self.last_length = source.len;
        @memcpy(self.tx[0..source.len], source);
    }
};

test "logical FIFO address is independent of padded DMA count" {
    for ([_]usize{ 1, 2, 3, 4, 509, 510, 511, 512 }) |length| {
        const plan = try sdio.plan(length);
        try std.testing.expectEqual(@as(u32, @intCast(0x1f800 - length)), plan.address);
        try std.testing.expect(plan.wire >= length and plan.wire <= 512 and plan.wire % 4 == 0);
    }
    try std.testing.expectError(error.InvalidBuffer, sdio.plan(0));
    try std.testing.expectError(error.InvalidBuffer, sdio.plan(513));
}

test "one-byte RX never writes DMA padding into caller memory" {
    var host = Host{ .total = 3 };
    var stream = sdio.Stream(Host){ .host = &host };
    var bytes = [_]u8{ 9, 9, 9, 9 };
    try std.testing.expectEqual(@as(usize, 1), try stream.receive(bytes[0..1]));
    try std.testing.expectEqualSlices(u8, &.{ 1, 9, 9, 9 }, &bytes);
    try std.testing.expectEqual(@as(usize, 4), host.last_length);
    try std.testing.expectEqual(@as(u32, 0x1f7ff), host.last_address);
}

test "RX and TX cumulative counters wrap at their own protocol widths" {
    var host = Host{ .total = 2, .credits = 1 };
    var stream = sdio.Stream(Host){ .host = &host, .received = 0xffffe, .sent_buffers = 0xfff };
    var bytes: [512]u8 = @splat(0);
    try std.testing.expectEqual(@as(usize, 4), try stream.receive(&bytes));
    try std.testing.expectEqual(@as(u32, 2), stream.received);
    try std.testing.expectEqual(@as(usize, 3), try stream.send("abc"));
    try std.testing.expectEqual(@as(u32, 0), stream.sent_buffers);
    try std.testing.expectEqualSlices(u8, "abc\x00", host.tx[0..4]);
}

test "credit exhaustion leaves TX and counters unchanged without blocking" {
    var host = Host{ .credits = 0 };
    var stream = sdio.Stream(Host){ .host = &host };
    try std.testing.expectEqual(@as(usize, 0), try stream.send("abc"));
    try std.testing.expectEqual(@as(usize, 0), host.fifo_calls);
    try std.testing.expectEqual(@as(u32, 0), stream.sent_buffers);
    host.credits = 2;
    const bytes: [1024]u8 = @splat(3);
    try std.testing.expectError(error.InvalidBuffer, stream.send(&bytes));
    try std.testing.expectEqual(@as(usize, 0), host.fifo_calls);
    try std.testing.expectEqual(@as(u32, 0), stream.sent_buffers);
    try std.testing.expect(!stream.faulted);
    try std.testing.expectEqual(@as(usize, 512), try stream.send(bytes[0..512]));
    try std.testing.expectEqual(@as(usize, 512), try stream.send(bytes[512..]));
    try std.testing.expectEqual(@as(usize, 0), try stream.send("abc"));
}

test "counter discontinuity, ambiguous FIFO failure and clear failure require reset" {
    for (0..4) |failure| {
        var host = Host{ .total = if (failure == 0) sdio.backlog_limit + 1 else 3, .credits = if (failure == 1) 4095 else 10, .fail_transfer = failure == 2, .fail_clear = failure == 3 };
        var stream = sdio.Stream(Host){ .host = &host };
        var bytes: [4]u8 = @splat(9);
        if (failure == 1) {
            try std.testing.expectError(error.CounterDiscontinuity, stream.send("abc"));
        } else try std.testing.expectError(if (failure == 0) error.CounterDiscontinuity else error.Io, stream.receive(&bytes));
        try std.testing.expectEqualSlices(u8, &.{ 9, 9, 9, 9 }, &bytes);
        try std.testing.expect(stream.faulted);
        try std.testing.expectError(error.Retired, stream.send("abc"));
        try std.testing.expectError(error.Retired, stream.receive(&bytes));
    }
}
