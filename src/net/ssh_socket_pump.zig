//! Bounded, nonblocking bridge between an SSH transport and a socket owner.
//! The adapter supplies an epoch and owns connection establishment, deadlines,
//! readiness notifications and close. Never retry after an ambiguous write.
const std = @import("std");
const transport = @import("ssh_transport.zig");
pub const Result = union(enum) { progress: usize, would_block, eof };
pub const SocketError = error{SocketFailed};
pub const Io = struct {
    context: ?*anyopaque,
    read: *const fn (?*anyopaque, []u8) SocketError!Result,
    write: *const fn (?*anyopaque, []const u8) SocketError!Result,
};
pub const Error = transport.Error || SocketError || error{ StaleConnection, InvalidIo, PeerClosed };
pub const Pump = struct {
    wire: *transport.Transport,
    epoch: u64,
    input: [1024]u8 = undefined,
    input_start: usize = 0,
    input_end: usize = 0,
    dead: bool = false,
    receive_paused: bool = false,

    /// One nonblocking write and one read at most per call. A complete packet
    /// remains borrowed from wire.rx until the consumer releases it. Unconsumed
    /// bytes after that packet stay in this pump, never in the socket adapter.
    pub fn poll(self: *Pump, io: Io, epoch: u64) Error!void {
        if (self.dead) return error.Failed;
        if (epoch != self.epoch) return self.fail(error.StaleConnection);
        const pending = self.wire.pending();
        if (pending.len != 0) {
            const sent = io.write(io.context, pending) catch return self.fail(error.SocketFailed);
            switch (sent) {
                .progress => |n| {
                    if (n == 0 or n > pending.len) return self.fail(error.InvalidIo);
                    self.wire.consume(n) catch |err| return self.fail(err);
                },
                .would_block => {},
                .eof => return self.fail(error.PeerClosed),
            }
        }
        if (self.receive_paused or self.wire.rx.pending) return;
        if (self.input_start == self.input_end) {
            self.input_start = 0;
            self.input_end = 0;
            const result = io.read(io.context, &self.input) catch return self.fail(error.SocketFailed);
            switch (result) {
                .progress => |n| {
                    if (n == 0 or n > self.input.len) return self.fail(error.InvalidIo);
                    self.input_end = n;
                },
                .would_block => return,
                .eof => return self.fail(error.PeerClosed),
            }
        }
        const count = self.wire.feed(self.input[self.input_start..self.input_end]) catch |err| return self.fail(err);
        self.input_start += count;
    }
    pub fn abort(self: *Pump) void {
        self.dead = true;
        std.crypto.secureZero(u8, &self.input);
        self.input_start = 0;
        self.input_end = 0;
        self.wire.abort();
    }
    fn fail(self: *Pump, err: Error) Error {
        self.abort();
        return err;
    }
};

test "pump preserves partial I/O, packet boundaries and fails on epoch reset" {
    const ssh = @import("ssh.zig");
    const Mock = struct {
        source: []const u8,
        at: usize = 0,
        sent: usize = 0,
        fn read(context: ?*anyopaque, dst: []u8) SocketError!Result {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (self.at == self.source.len) return .would_block;
            const n = @min(dst.len, self.source.len - self.at);
            @memcpy(dst[0..n], self.source[self.at..][0..n]);
            self.at += n;
            return .{ .progress = n };
        }
        fn write(context: ?*anyopaque, src: []const u8) SocketError!Result {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            const n = @min(src.len, 3);
            self.sent += n;
            return .{ .progress = n };
        }
    };
    var input: [128]u8 = undefined;
    const a = try ssh.packPacket("one", 0, false, null, null, &@as([32]u8, @splat(1)), &input);
    const b = try ssh.packPacket("two", 1, false, null, null, &@as([32]u8, @splat(1)), input[a..]);
    var mock = Mock{ .source = input[0 .. a + b] };
    const io = Io{ .context = &mock, .read = Mock.read, .write = Mock.write };
    var wire: transport.Transport = .{};
    var pump = Pump{ .wire = &wire, .epoch = 9 };
    try wire.prepare("out", &@as([32]u8, @splat(2)));
    const total = wire.pending().len;
    try pump.poll(io, 9);
    try std.testing.expectEqualStrings("one", wire.rx.payload().?);
    try std.testing.expectEqual(@as(usize, 3), mock.sent);
    pump.receive_paused = true;
    wire.rx.release();
    try pump.poll(io, 9);
    try std.testing.expect(wire.rx.payload() == null);
    pump.receive_paused = false;
    try pump.poll(io, 9);
    try std.testing.expectEqualStrings("two", wire.rx.payload().?);
    wire.rx.release();
    while (wire.pending().len > 0) try pump.poll(io, 9);
    try std.testing.expectEqual(total, mock.sent);
    try std.testing.expectError(error.StaleConnection, pump.poll(io, 10));
    try std.testing.expectError(error.Failed, pump.poll(io, 9));
}
