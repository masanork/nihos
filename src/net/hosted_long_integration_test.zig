const std = @import("std");
const dma = @import("hosted_long_dma.zig");
const guard = @import("hosted_long_dma_guard.zig");
const sender = @import("hosted_long_sender.zig");
const sd = @import("../soc/esp32p4/sdio.zig");

const Failure = enum { none, data_cache, desc_cache, timeout, stop_timeout, invalidate, owned, desc_error };
const Backend = struct {
    failure: Failure = .none,
    writebacks: usize = 0,
    invalidations: usize = 0,
    pub fn address(_: *@This(), ptr: anytype) ?u32 {
        if (@intFromPtr(ptr) % 64 != 0) return null;
        return 0x4ff10000;
    }
    pub fn writeback(self: *@This(), _: usize, _: usize) bool {
        self.writebacks += 1;
        return !((self.failure == .data_cache and self.writebacks == 1) or
            (self.failure == .desc_cache and self.writebacks == 2));
    }
    pub fn invalidate(self: *@This(), _: usize, _: usize) bool {
        self.invalidations += 1;
        return self.failure != .invalidate;
    }
    pub fn fence(_: *@This()) void {}
};

const Io = struct {
    regs: [64]u32 = @splat(0),
    buffer: dma.Buffer = .{},
    backend: Backend = .{},
    stops: usize = 0,
    transfers: usize = 0,
    finishes: usize = 0,
    pub fn read(self: *@This(), address: usize) u32 {
        return switch (address) {
            sd.regs.ctrl => if (self.backend.failure == .stop_timeout and self.stops > 0) 4 else 0,
            sd.regs.command, sd.regs.dma_mode, sd.regs.dma_status => 0,
            sd.regs.interrupts => (1 << 2) | (if (self.backend.failure == .timeout or self.backend.failure == .stop_timeout) @as(u32, 0) else 1 << 3),
            else => self.regs[address / 4],
        };
    }
    pub fn write(self: *@This(), address: usize, value: u32) void {
        self.regs[address / 4] = value;
        if (address == sd.regs.command and value & 63 == 53) self.transfers += 1;
        if (address == sd.regs.dma_mode and value == 0) self.stops += 1;
    }
    pub fn delay(_: *@This(), _: u32) void {}
    pub fn prepareDma(self: *@This(), writing: bool, source: []const u8, length: usize) ?u32 {
        if (!writing or source.len != length) return null;
        return self.buffer.prepare(source, &self.backend);
    }
    pub fn finishDma(self: *@This(), writing: bool, destination: []u8) bool {
        self.finishes += 1;
        if (!writing or destination.len != 0 or self.stops == 0) return false;
        if (self.backend.failure != .owned) self.buffer.descriptor[0] &= ~(@as(u32, 1) << 31);
        if (self.backend.failure == .desc_error) self.buffer.descriptor[0] |= @as(u32, 1) << 30;
        return self.buffer.finish(&self.backend);
    }
};
const Host = struct {
    pub const TransportError = sd.Error;
    controller: sd.Controller(*Io),
    credits: u32 = 1,
    pub fn readWord(self: *@This(), _: u32) TransportError!u32 {
        return self.credits << 16;
    }
    pub fn writeBlocks(self: *@This(), address: u32, bytes: []const u8) TransportError!void {
        try self.controller.writeBlocks(address, bytes);
    }
};

test "sender controller and DMA buffer complete one padded transaction" {
    var io: Io = .{};
    var host: Host = .{ .controller = .{ .io = &io, .prepared = true, .selected = true, .four_bit = true, .poll_limit = 2 } };
    var guarded: guard.Guard(Host) = .{ .host = &host, .buffer = &io.buffer };
    var stream = sender.ProfileStream(@TypeOf(guarded), 64){ .host = &guarded };
    var tx = sender.Sender(@TypeOf(guarded), 64){ .stream = &stream };
    const packet: [1254]u8 = @splat(0x5a);
    try std.testing.expectEqual(@as(usize, packet.len), try tx.send(&packet));
    try std.testing.expectEqual(@as(u32, 1), stream.sent_buffers);
    try std.testing.expectEqual(@as(usize, 1), io.transfers);
    try std.testing.expectEqual(@as(usize, 1), io.finishes);
    try std.testing.expectEqual(@as(usize, 1), io.stops);
    try std.testing.expectEqual(dma.State.idle, io.buffer.state);
    try std.testing.expectEqual(@as(u32, 1536), io.buffer.descriptor[1]);
    try std.testing.expectEqualSlices(u8, &packet, io.buffer.data[0..packet.len]);
    try std.testing.expect(std.mem.allEqual(u8, io.buffer.data[packet.len..], 0));
    try std.testing.expectEqual(@as(usize, 2), io.backend.writebacks);
    try std.testing.expectEqual(@as(usize, 1), io.backend.invalidations);
    host.credits = 2;
    const shorter: [513]u8 = @splat(0x37);
    try std.testing.expectEqual(@as(usize, shorter.len), try tx.send(&shorter));
    try std.testing.expectEqual(@as(u32, 2), stream.sent_buffers);
    try std.testing.expectEqual(@as(u32, 1024), io.buffer.descriptor[1]);
    try std.testing.expectEqualSlices(u8, &shorter, io.buffer.data[0..shorter.len]);
    try std.testing.expect(std.mem.allEqual(u8, io.buffer.data[shorter.len..], 0));
    try std.testing.expectEqual(dma.State.idle, io.buffer.state);
}

test "controller failures quarantine actual buffer and prevent credit consumption or replay" {
    const failures = [_]Failure{ .data_cache, .desc_cache, .timeout, .stop_timeout, .invalidate, .owned, .desc_error };
    for (failures) |failure| {
        var io: Io = .{ .backend = .{ .failure = failure } };
        var host: Host = .{ .controller = .{ .io = &io, .prepared = true, .selected = true, .four_bit = true, .poll_limit = 2 } };
        var guarded: guard.Guard(Host) = .{ .host = &host, .buffer = &io.buffer };
        var stream = sender.ProfileStream(@TypeOf(guarded), 64){ .host = &guarded };
        var tx = sender.Sender(@TypeOf(guarded), 64){ .stream = &stream };
        const packet: [1254]u8 = @splat(0x5a);
        const expected: anyerror = if (failure == .timeout or failure == .stop_timeout) error.Timeout else error.Dma;
        try std.testing.expectError(expected, tx.send(&packet));
        try std.testing.expectEqual(dma.State.retired, io.buffer.state);
        try std.testing.expect(host.controller.faulted and stream.faulted);
        try std.testing.expectEqual(failure == .stop_timeout, host.controller.cleanup_failed);
        try std.testing.expectEqual(@as(u32, 0), stream.sent_buffers);
        if (failure == .timeout or failure == .stop_timeout) try std.testing.expectEqual(@as(usize, 0), io.finishes);
        if (failure == .timeout or failure == .stop_timeout) try std.testing.expectEqual(@as(usize, 0), io.backend.invalidations);
        const transfers = io.transfers;
        try std.testing.expectError(error.Retired, tx.send(&packet));
        try std.testing.expectEqual(transfers, io.transfers);
        try std.testing.expectEqual(@as(?u32, null), io.buffer.prepare(tx.buffer[0..1536], &io.backend));
    }
}
