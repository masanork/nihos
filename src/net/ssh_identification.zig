//! Bounded nonblocking SSH identification exchange. The socket remains owned
//! by the caller, which must enforce an overall monotonic deadline.
const std = @import("std");
const io_mod = @import("ssh_socket_pump.zig");
const handshake = @import("ssh_handshake.zig");
const client_line = handshake.client_banner ++ "\r\n";
pub const Error = io_mod.SocketError || error{ InvalidBanner, InvalidIo, PeerClosed, StaleConnection, Failed };
pub const Exchange = struct {
    epoch: u64,
    sent: usize = 0,
    line: [253]u8 = @splat(0),
    line_len: usize = 0,
    total: usize = 0,
    cr: bool = false,
    identified: bool = false,
    failed: bool = false,

    /// At most one bounded write and one one-byte read per call. The latter
    /// guarantees no SSH packet bytes are consumed beyond the identification.
    pub fn poll(self: *Exchange, io: io_mod.Io, epoch: u64) Error!bool {
        return self.advance(io, epoch) catch |err| {
            self.failed = true;
            return err;
        };
    }
    fn advance(self: *Exchange, io: io_mod.Io, epoch: u64) Error!bool {
        if (self.failed) return error.Failed;
        if (epoch != self.epoch) return error.StaleConnection;
        if (self.sent < client_line.len) {
            const remaining = client_line[self.sent..];
            const result = io.write(io.context, remaining) catch return error.SocketFailed;
            switch (result) {
                .progress => |n| {
                    if (n == 0 or n > remaining.len) return error.InvalidIo;
                    self.sent += n;
                },
                .would_block => {},
                .eof => return error.PeerClosed,
            }
        }
        if (!self.identified) {
            var one: [1]u8 = undefined;
            const result = io.read(io.context, &one) catch return error.SocketFailed;
            switch (result) {
                .progress => |n| {
                    if (n != 1) return error.InvalidIo;
                    try self.consume(one[0]);
                },
                .would_block => {},
                .eof => return error.PeerClosed,
            }
        }
        return self.identified and self.sent == client_line.len;
    }
    fn consume(self: *Exchange, byte: u8) Error!void {
        self.total += 1;
        if (self.total > 1024) return error.InvalidBanner;
        if (self.cr) {
            if (byte != '\n') return error.InvalidBanner;
            self.cr = false;
            const line = self.line[0..self.line_len];
            if (std.mem.startsWith(u8, line, "SSH-")) {
                if (line.len < 9 or !std.mem.startsWith(u8, line, "SSH-2.0-")) return error.InvalidBanner;
                self.identified = true;
            } else {
                self.line_len = 0;
            }
            return;
        }
        if (byte == '\r') {
            self.cr = true;
            return;
        }
        if (byte < 32 or byte > 126 or self.line_len == self.line.len) return error.InvalidBanner;
        self.line[self.line_len] = byte;
        self.line_len += 1;
    }
    pub fn banner(self: *const Exchange) ?[]const u8 {
        return if (self.identified and self.sent == client_line.len and !self.failed) self.line[0..self.line_len] else null;
    }
};

test "fragmented identification preserves the following packet" {
    const Mock = struct {
        source: []const u8 = "welcome\r\nSSH-2.0-test\r\n\x14packet",
        read_at: usize = 0,
        written: [64]u8 = @splat(0),
        write_at: usize = 0,
        fn read(ctx: ?*anyopaque, dst: []u8) io_mod.SocketError!io_mod.Result {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            if (self.read_at == self.source.len) return .would_block;
            dst[0] = self.source[self.read_at];
            self.read_at += 1;
            return .{ .progress = 1 };
        }
        fn write(ctx: ?*anyopaque, src: []const u8) io_mod.SocketError!io_mod.Result {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            const n = @min(src.len, 3);
            @memcpy(self.written[self.write_at..][0..n], src[0..n]);
            self.write_at += n;
            return .{ .progress = n };
        }
    };
    var mock: Mock = .{};
    const io = io_mod.Io{ .context = &mock, .read = Mock.read, .write = Mock.write };
    var exchange = Exchange{ .epoch = 4 };
    for (0..128) |_| if (try exchange.poll(io, 4)) break else {};
    try std.testing.expectEqualStrings("SSH-2.0-test", exchange.banner().?);
    try std.testing.expectEqualStrings(client_line, mock.written[0..mock.write_at]);
    try std.testing.expectEqual(@as(u8, 20), mock.source[mock.read_at]);
    try std.testing.expectError(error.StaleConnection, exchange.poll(io, 5));
    try std.testing.expectError(error.Failed, exchange.poll(io, 4));
}

test "identification rejects unsupported versions and malformed input" {
    var wrong = Exchange{ .epoch = 1 };
    for ("SSH-1.5-old\r") |byte| try wrong.consume(byte);
    try std.testing.expectError(error.InvalidBanner, wrong.consume('\n'));
    var invalid = Exchange{ .epoch = 1 };
    try std.testing.expectError(error.InvalidBanner, invalid.consume('\n'));
    var oversized = Exchange{ .epoch = 1 };
    for (0..253) |_| try oversized.consume('a');
    try std.testing.expectError(error.InvalidBanner, oversized.consume('b'));
    var preamble = Exchange{ .epoch = 1 };
    for (0..512) |_| {
        try preamble.consume('\r');
        try preamble.consume('\n');
    }
    try std.testing.expectError(error.InvalidBanner, preamble.consume('x'));
}

test "backpressure is retryable and invalid progress fails closed" {
    const Mock = struct {
        invalid: bool = false,
        fn read(_: ?*anyopaque, _: []u8) io_mod.SocketError!io_mod.Result {
            return .would_block;
        }
        fn write(ctx: ?*anyopaque, _: []const u8) io_mod.SocketError!io_mod.Result {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            return if (self.invalid) .{ .progress = 0 } else .would_block;
        }
    };
    var mock: Mock = .{};
    const io = io_mod.Io{ .context = &mock, .read = Mock.read, .write = Mock.write };
    var exchange = Exchange{ .epoch = 1 };
    try std.testing.expect(!(try exchange.poll(io, 1)));
    try std.testing.expectEqual(@as(usize, 0), exchange.sent);
    mock.invalid = true;
    try std.testing.expectError(error.InvalidIo, exchange.poll(io, 1));
    try std.testing.expectError(error.Failed, exchange.poll(io, 1));
}
