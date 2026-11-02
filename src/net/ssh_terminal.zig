//! Interactive SSH channel I/O after Client startup. The single caller owns
//! the client, socket pump and transport; output is retained in the decoder
//! until consumed, so socket backpressure bounds memory and receive credit.
const std = @import("std");
const client = @import("ssh_client.zig");
const socket = @import("ssh_socket_pump.zig");
const transport = @import("ssh_transport.zig");

pub const Error = client.Error;
pub const Terminal = struct {
    output: []const u8 = "",
    offset: usize = 0,
    credit: u32 = 0,
    remote_eof: bool = false,
    remote_closed: bool = false,
    close_queued: bool = false,
    failed: bool = false,

    /// Advance at most one incoming packet and one outgoing packet. A remote
    /// close is acknowledged after buffered output is consumed. Returns true
    /// only after the close acknowledgement has been completely written.
    pub fn poll(self: *Terminal, c: *client.Client, wire: *transport.Transport, pump: *socket.Pump, io: socket.Io, epoch: u64, now_us: u64, random: *const [32]u8) Error!bool {
        return self.advance(c, wire, pump, io, epoch, now_us, random) catch |err| {
            self.failed = true;
            self.output = "";
            c.deinit(wire, pump);
            return err;
        };
    }
    fn advance(self: *Terminal, c: *client.Client, wire: *transport.Transport, pump: *socket.Pump, io: socket.Io, epoch: u64, now_us: u64, random: *const [32]u8) Error!bool {
        if (self.failed) return error.Failed;
        if (c.phase != .ready or !(try c.conn.poll(wire, pump, io, epoch, now_us, random))) return error.InvalidState;
        const s = if (c.session) |*v| v else return error.InvalidState;
        // Once channel close arrives, only flush its acknowledgement. The
        // peer may half-close TCP before that write has drained.
        if (self.remote_closed) pump.receive_paused = true;
        try pump.poll(io, epoch);
        if (wire.pending().len != 0) return false;
        if (self.close_queued) return true;
        var out: [512]u8 = undefined;
        if (self.remote_closed) {
            const response = try s.close(&out);
            try wire.prepare(response, random);
            self.close_queued = true;
            return false;
        }
        if (self.credit != 0) {
            const grant = try s.grant(&out, self.credit);
            try wire.prepare(grant, random);
            self.credit = 0;
            return false;
        }
        if (self.output.len != 0) return false;
        const packet = wire.rx.payload() orelse return false;
        if (packet.len > 0 and (packet[0] == 2 or packet[0] == 4)) {
            wire.rx.release();
            return false;
        }
        if (packet.len > 0 and packet[0] == 80) {
            if (packet.len < 6) return error.InvalidMessage;
            const name_len = std.mem.readInt(u32, packet[1..5], .big);
            if (name_len > packet.len - 6) return error.InvalidMessage;
            const reply = packet[5 + name_len];
            if (reply > 1) return error.InvalidMessage;
            wire.rx.release();
            if (reply == 1) {
                out[0] = 82;
                try wire.prepare(out[0..1], random);
            }
            return false;
        }
        const event = try s.receive(packet);
        switch (event) {
            .channel => |ev| switch (ev) {
                .data, .extended => |bytes| {
                    if (bytes.len != 0) {
                        self.output = bytes;
                        self.offset = 0;
                        return false;
                    }
                },
                .eof => self.remote_eof = true,
                .closed => self.remote_closed = true,
                .window, .ignored, .exit_status => {},
                else => return error.InvalidMessage,
            },
            else => return error.InvalidMessage,
        }
        wire.rx.release();
        return false;
    }
    /// Copy a partial output chunk. Credit is granted only after consumption.
    /// Call only with the same transport used by poll and before its next poll.
    pub fn read(self: *Terminal, c: *client.Client, wire: *transport.Transport, pump: *socket.Pump, io: socket.Io, epoch: u64, now_us: u64, random: *const [32]u8, dst: []u8) Error!usize {
        if (self.failed or wire.failed) return error.Failed;
        if (c.phase != .ready) return error.InvalidState;
        _ = c.conn.poll(wire, pump, io, epoch, now_us, random) catch |err| {
            self.failed = true;
            self.output = "";
            c.deinit(wire, pump);
            return err;
        };
        const n = @min(dst.len, self.output.len - self.offset);
        @memcpy(dst[0..n], self.output[self.offset..][0..n]);
        self.offset += n;
        self.credit += @intCast(n);
        if (self.output.len != 0 and self.offset == self.output.len) {
            self.output = "";
            self.offset = 0;
            wire.rx.release();
        }
        return n;
    }
    /// Enqueue one bounded input packet; zero means retry after polling.
    /// The returned count is accepted into transport, not yet delivered.
    pub fn write(self: *Terminal, c: *client.Client, wire: *transport.Transport, pump: *socket.Pump, io: socket.Io, epoch: u64, now_us: u64, bytes: []const u8, random: *const [32]u8) Error!usize {
        return self.writeInner(c, wire, pump, io, epoch, now_us, bytes, random) catch |err| {
            self.failed = true;
            self.output = "";
            c.deinit(wire, pump);
            return err;
        };
    }
    fn writeInner(self: *Terminal, c: *client.Client, wire: *transport.Transport, pump: *socket.Pump, io: socket.Io, epoch: u64, now_us: u64, bytes: []const u8, random: *const [32]u8) Error!usize {
        if (self.failed or wire.failed) return error.Failed;
        if (c.phase != .ready or self.remote_closed or self.close_queued) return error.InvalidState;
        _ = try c.conn.poll(wire, pump, io, epoch, now_us, random);
        if (wire.pending().len != 0 or bytes.len == 0) return 0;
        const s = if (c.session) |*v| v else return error.InvalidState;
        const n = @min(bytes.len, @min(@as(usize, s.terminal.remote_window), @min(@as(usize, s.terminal.remote_max), 503)));
        if (n == 0) return 0;
        var out: [512]u8 = undefined;
        const packet = try s.data(&out, bytes[0..n]);
        // Channel credit has changed, so an enqueue failure aborts the client.
        try wire.prepare(packet, random);
        return n;
    }
};

test "terminal applies bounded output credit and input backpressure" {
    const Mock = struct {
        fn read(_: ?*anyopaque, _: []u8) socket.SocketError!socket.Result {
            return .would_block;
        }
        fn write(_: ?*anyopaque, src: []const u8) socket.SocketError!socket.Result {
            return .{ .progress = src.len };
        }
    };
    const io = socket.Io{ .context = null, .read = Mock.read, .write = Mock.write };
    const random: [32]u8 = @splat(1);
    var c = client.Client.init(1, 0, 100, @splat(1), @splat(2), @splat(3), 80, 24);
    c.conn.phase = .ready;
    c.phase = .ready;
    c.session = .{ .session_id = @splat(4) };
    const s = if (c.session) |*value| value else unreachable;
    s.state = .authenticated;
    s.terminal.state = .running;
    s.terminal.remote = 7;
    s.terminal.remote_window = 3;
    s.terminal.remote_max = 10;
    var wire: transport.Transport = .{};
    var pump = socket.Pump{ .wire = &wire, .epoch = 1 };
    var term: Terminal = .{};
    var peer: transport.Transport = .{};
    try peer.prepare(&.{ 94, 0, 0, 0, 0, 0, 0, 0, 5, 'h', 'e', 'l', 'l', 'o' }, &random);
    _ = try wire.feed(peer.pending());
    try std.testing.expect(!(try term.poll(&c, &wire, &pump, io, 1, 1, &random)));
    var out: [8]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 2), try term.read(&c, &wire, &pump, io, 1, 2, &random, out[0..2]));
    try std.testing.expectEqualStrings("he", out[0..2]);
    try std.testing.expect(wire.rx.pending);
    try std.testing.expectEqual(@as(u32, 2), term.credit);
    try std.testing.expect(!(try term.poll(&c, &wire, &pump, io, 1, 3, &random)));
    try std.testing.expectEqual(@as(u32, 0), term.credit);
    try std.testing.expectEqual(@as(usize, 3), try term.read(&c, &wire, &pump, io, 1, 4, &random, &out));
    try std.testing.expectEqualStrings("llo", out[0..3]);
    try std.testing.expect(!wire.rx.pending);
    try std.testing.expectEqual(@as(usize, 0), try term.write(&c, &wire, &pump, io, 1, 5, "input", &random));
    try std.testing.expect(!(try term.poll(&c, &wire, &pump, io, 1, 6, &random)));
    try std.testing.expect(!(try term.poll(&c, &wire, &pump, io, 1, 7, &random)));
    try std.testing.expectEqual(@as(usize, 3), try term.write(&c, &wire, &pump, io, 1, 8, "input", &random));
    try std.testing.expectEqual(@as(usize, 0), try term.write(&c, &wire, &pump, io, 1, 9, "ut", &random));
    try std.testing.expect(!(try term.poll(&c, &wire, &pump, io, 1, 10, &random)));
    try std.testing.expectEqual(@as(usize, 0), try term.write(&c, &wire, &pump, io, 1, 11, "ut", &random));
    try std.testing.expectError(error.StaleConnection, term.poll(&c, &wire, &pump, io, 2, 12, &random));
    try std.testing.expect(wire.failed and pump.dead and c.session == null);
}

test "remote close acknowledgement drains after peer half closes" {
    const Mock = struct {
        fn read(_: ?*anyopaque, _: []u8) socket.SocketError!socket.Result {
            return .eof;
        }
        fn write(_: ?*anyopaque, src: []const u8) socket.SocketError!socket.Result {
            return .{ .progress = @min(3, src.len) };
        }
    };
    const io = socket.Io{ .context = null, .read = Mock.read, .write = Mock.write };
    const random: [32]u8 = @splat(1);
    var c = client.Client.init(1, 0, 100, @splat(1), @splat(2), @splat(3), 80, 24);
    c.conn.phase = .ready;
    c.phase = .ready;
    c.session = .{ .session_id = @splat(4) };
    const s = if (c.session) |*value| value else unreachable;
    s.state = .authenticated;
    s.terminal.state = .running;
    s.terminal.remote = 7;
    var wire: transport.Transport = .{};
    var pump = socket.Pump{ .wire = &wire, .epoch = 1 };
    var peer: transport.Transport = .{};
    try peer.prepare(&.{ 97, 0, 0, 0, 0 }, &random);
    _ = try wire.feed(peer.pending());
    var term: Terminal = .{};
    try std.testing.expect(!(try term.poll(&c, &wire, &pump, io, 1, 1, &random)));
    var complete = false;
    for (2..30) |now| {
        if (try term.poll(&c, &wire, &pump, io, 1, now, &random)) {
            complete = true;
            break;
        }
    }
    try std.testing.expect(complete and term.remote_closed and pump.receive_paused);
    try std.testing.expectEqual(@as(usize, 0), wire.pending().len);
}
