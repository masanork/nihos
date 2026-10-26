//! Synthetic C6 peer at the FIFO/register boundary, not a hardware emulator.
const std = @import("std");
const control = @import("at_controller.zig");
const sdio = @import("c6_sdio.zig");

const Peer = struct {
    pub const TransportError = error{Io};
    fifo: [4096]u8 = @splat(0),
    queued: usize = 0,
    consumed: usize = 0,
    tokens: u32 = 10,
    header: [512]u8 = @splat(0),
    header_len: usize = 0,
    profile_index: usize = 0,
    body: [7]u8 = @splat(0),
    body_len: usize = 0,
    body_pending: bool = false,

    fn queue(self: *@This(), bytes: []const u8) TransportError!void {
        if (bytes.len > self.fifo.len - self.queued) return error.Io;
        @memcpy(self.fifo[self.queued..][0..bytes.len], bytes);
        self.queued += bytes.len;
    }
    pub fn readWord(self: *@This(), address: u32) TransportError!u32 {
        return switch (address) {
            sdio.length_register => @intCast(self.queued),
            sdio.token_register => self.tokens << 16,
            else => error.Io,
        };
    }
    pub fn writeWord(_: *@This(), address: u32, value: u32) TransportError!void {
        if (address != sdio.interrupt_clear or value != 0xffffffff) return error.Io;
    }
    pub fn readBytes(self: *@This(), address: u32, bytes: []u8) TransportError!void {
        if (address >= sdio.fifo_end) return error.Io;
        const logical: usize = sdio.fifo_end - address;
        if (logical > bytes.len or logical > self.queued - self.consumed) return error.Io;
        @memset(bytes, 0);
        @memcpy(bytes[0..logical], self.fifo[self.consumed..][0..logical]);
        self.consumed += logical;
    }
    pub fn writeBytes(self: *@This(), address: u32, bytes: []const u8) TransportError!void {
        if (address >= sdio.fifo_end) return error.Io;
        const logical: usize = sdio.fifo_end - address;
        if (logical == 0 or logical > bytes.len or bytes.len % 4 != 0) return error.Io;
        for (bytes[logical..]) |byte| if (byte != 0) return error.Io;
        for (bytes[0..logical]) |byte| {
            if (self.body_pending) {
                self.body[self.body_len] = byte;
                self.body_len += 1;
                if (self.body_len == self.body.len) {
                    self.body_pending = false;
                    try self.queue("+NOTIFY:0,3,6,3,x\x00>\r\nSEND OK\r\n+IPD,0,7\r\n");
                }
            } else {
                if (self.header_len == self.header.len) return error.Io;
                self.header[self.header_len] = byte;
                self.header_len += 1;
                if (byte == '\n') {
                    try self.command();
                    self.header_len = 0;
                }
            }
        }
        self.tokens = (self.tokens + 1) & sdio.credit_mask;
    }
    fn command(self: *@This()) TransportError!void {
        const text = self.header[0..self.header_len];
        if (self.profile_index < control.profile.len) {
            if (!std.mem.eql(u8, text, control.profile[self.profile_index])) return error.Io;
            if (std.mem.eql(u8, text, "AT+GMR\r\n")) try self.queue("AT version:synthetic\r\n");
            self.profile_index += 1;
            return self.queue("OK\r\n");
        }
        if (std.mem.eql(u8, text, "AT+CIPSEND=0,7\r\n")) {
            self.body_pending = true;
            return self.queue("OK\r\n> ");
        }
        if (std.mem.eql(u8, text, "AT+CIPRECVDATA=0,8\r\n")) {
            return self.queue("+CIPRECVDATA:7,\x00\r\nOK>>\r\n+NOTIFY:0,3,6,3,x\x00>\r\nOK\r\n");
        }
        return error.Io;
    }
};

fn step(owner: *control.Controller, stream: *sdio.Stream(Peer), chunk: usize, tick: u64, notifications: *u32) !void {
    const tx = try owner.tx(tick);
    if (tx.len != 0) try owner.consumeTx(try stream.send(tx[0..@min(tx.len, chunk)]), tick);
    var bytes: [512]u8 = @splat(0);
    const count = try stream.receive(bytes[0..chunk]);
    for (bytes[0..count]) |byte| {
        if (try owner.push(byte, tick)) |notice| switch (notice) {
            .data => |data| {
                try std.testing.expectEqualSlices(u8, "x\x00>", data.bytes);
                notifications.* += 1;
            },
            else => {},
        };
    }
}

test "AT profile and binary TCP/BLE exchange survive arbitrary FIFO chunk boundaries" {
    for ([_]usize{ 1, 3, 17, 512 }) |chunk| {
        var peer: Peer = .{};
        var stream = sdio.Stream(Peer){ .host = &peer };
        var owner: control.Controller = .{};
        var notifications: u32 = 0;
        var tick: u64 = 0;
        try owner.recover(tick, 10_000);
        while (!owner.ready() and tick < 2000) : (tick += 1) try step(&owner, &stream, chunk, tick, &notifications);
        try std.testing.expect(owner.ready());
        try std.testing.expectEqual(control.profile.len, peer.profile_index);
        _ = try owner.submit(.{ .socket_send = .{ .link = 0, .bytes = "a\x00\r\nOK>" } }, tick, tick + 2000);
        while (owner.completion == null and tick < 4000) : (tick += 1) try step(&owner, &stream, chunk, tick, &notifications);
        try std.testing.expect(owner.takeCompletion().?.failure == null);
        try std.testing.expectEqualSlices(u8, "a\x00\r\nOK>", &peer.body);
        // Drain a trailing availability announcement before starting a new command.
        while (peer.consumed < peer.queued and tick < 5000) : (tick += 1) try step(&owner, &stream, chunk, tick, &notifications);
        _ = try owner.submit(.{ .socket_read = .{ .link = 0, .limit = 8 } }, tick, tick + 2000);
        while (owner.completion == null and tick < 7000) : (tick += 1) try step(&owner, &stream, chunk, tick, &notifications);
        const result = owner.takeCompletion().?;
        try std.testing.expect(result.failure == null);
        try std.testing.expectEqualSlices(u8, "\x00\r\nOK>>", result.bytes);
        try std.testing.expectEqual(@as(u32, 2), notifications);
    }
}
