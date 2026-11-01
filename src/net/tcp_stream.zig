//! Experimental one-segment-in-flight IPv4 TCP data plane. No routing, socket
//! table, congestion control, persist timer, local FIN or TIME_WAIT yet.
const std = @import("std");
const wire = @import("tcp_wire.zig");
const connect = @import("tcp_connect.zig");
pub const Error = wire.Error || error{ InvalidState, WouldBlock, Timeout, Reset, InvalidArgument };
pub const Stream = struct {
    const OutKind = enum { none, ack, data };
    local: connect.Endpoint,
    remote: connect.Endpoint,
    send_unacked: u32,
    receive_next: u32,
    remote_window: u16,
    remote_mss: u16,
    rx: [4096]u8 = undefined,
    rx_len: usize = 0,
    tx: [536]u8 = undefined,
    tx_len: usize = 0,
    tx_sent: bool = false,
    tx_deadline: u64 = 0,
    retry_at: u64 = 0,
    attempts: u8 = 0,
    ack_needed: bool = false,
    peer_fin: bool = false,
    failed: bool = false,
    packet: [576]u8 = undefined,
    packet_len: usize = 0,
    out_kind: OutKind = .none,
    out_ack: u32 = 0,
    out_window: u16 = 0,

    pub fn init(established: connect.Established) Stream {
        return .{ .local = established.local, .remote = established.remote, .send_unacked = established.send_next, .receive_next = established.receive_next, .remote_window = established.remote_window, .remote_mss = established.remote_mss };
    }
    /// Accepts one bounded send, copied until acknowledged. The caller must
    /// not treat this as peer acknowledgement or queue the remainder twice.
    pub fn write(self: *Stream, bytes: []const u8, now: u64, deadline: u64) Error!usize {
        if (self.failed) return error.InvalidState;
        if (bytes.len == 0 or deadline <= now) return error.InvalidArgument;
        if (self.tx_len != 0 or self.remote_window == 0) return error.WouldBlock;
        const n = @min(bytes.len, @min(self.tx.len, @min(self.remote_window, self.remote_mss)));
        if (n == 0) return error.WouldBlock;
        @memcpy(self.tx[0..n], bytes[0..n]);
        self.tx_len = n;
        self.tx_sent = false;
        self.tx_deadline = deadline;
        self.attempts = 0;
        return n;
    }
    /// Returns a borrowed full IP datagram, stable until the next mutating
    /// call. sent() is required after successful whole-datagram submission.
    pub fn poll(self: *Stream, now: u64) Error!?[]const u8 {
        if (self.failed) return error.InvalidState;
        if (self.tx_len != 0 and now >= self.tx_deadline) {
            self.failed = true;
            return error.Timeout;
        }
        if (self.out_kind != .none) return self.packet[0..self.packet_len];
        const kind: OutKind = if (self.ack_needed) .ack else if (self.tx_len != 0 and (!self.tx_sent or now >= self.retry_at)) .data else return null;
        const payload: []const u8 = if (kind == .data) self.tx[0..self.tx_len] else "";
        const sequence = self.send_unacked +% if (kind == .ack and self.tx_sent) @as(u32, @intCast(self.tx_len)) else @as(u32, 0);
        const packet = try wire.encode(&self.packet, .{ .src = self.local.address, .dst = self.remote.address, .src_port = self.local.port, .dst_port = self.remote.port, .seq = sequence, .ack = self.receive_next, .flags = wire.Flags.ack | if (kind == .data) wire.Flags.psh else @as(u8, 0), .window = self.window(), .options = "", .payload = payload }, 0);
        self.packet_len = packet.len;
        self.out_kind = kind;
        self.out_ack = self.receive_next;
        self.out_window = self.window();
        return self.packet[0..self.packet_len];
    }
    pub fn sent(self: *Stream, now: u64) Error!void {
        if (self.failed or self.out_kind == .none) return error.InvalidState;
        if (self.tx_len != 0 and now >= self.tx_deadline) {
            self.failed = true;
            return error.Timeout;
        }
        if (self.out_kind == .data) {
            const shift: u6 = @intCast(@min(self.attempts, 4));
            self.retry_at = now +| (@as(u64, 1000) << shift);
            self.attempts +|= 1;
            self.tx_sent = true;
        }
        if (self.out_ack == self.receive_next and self.out_window == self.window()) self.ack_needed = false;
        self.out_kind = .none;
        self.packet_len = 0;
    }
    pub fn receive(self: *Stream, packet: []const u8) Error!bool {
        if (self.failed) return error.InvalidState;
        const seg = wire.parse(packet) catch return false;
        if (!std.mem.eql(u8, &seg.src, &self.remote.address) or !std.mem.eql(u8, &seg.dst, &self.local.address) or seg.src_port != self.remote.port or seg.dst_port != self.local.port) return false;
        if (seg.seq != self.receive_next) {
            self.ack_needed = true;
            return false;
        }
        if ((seg.flags & wire.Flags.rst) != 0) {
            self.failed = true;
            return error.Reset;
        }
        if ((seg.flags & wire.Flags.syn) != 0 or (seg.flags & wire.Flags.ack) == 0) return false;
        const acknowledged = seg.ack -% self.send_unacked;
        if (acknowledged > self.tx_len or (acknowledged != 0 and !self.tx_sent)) return false;
        if (acknowledged > 0) {
            const n: usize = acknowledged;
            std.mem.copyForwards(u8, self.tx[0 .. self.tx_len - n], self.tx[n..self.tx_len]);
            self.tx_len -= n;
            self.send_unacked +%= acknowledged;
            if (self.out_kind == .data) {
                self.out_kind = .none;
                self.packet_len = 0;
            }
            if (self.tx_len == 0) {
                self.tx_sent = false;
                self.attempts = 0;
            }
        }
        self.remote_window = seg.window;
        if (self.peer_fin and (seg.payload.len != 0 or (seg.flags & wire.Flags.fin) != 0)) {
            self.ack_needed = true;
            return false;
        }
        if (seg.payload.len > self.rx.len - self.rx_len) {
            self.ack_needed = true;
            return false;
        }
        if (seg.payload.len != 0) {
            @memcpy(self.rx[self.rx_len..][0..seg.payload.len], seg.payload);
            self.rx_len += seg.payload.len;
            self.receive_next +%= @intCast(seg.payload.len);
            self.ack_needed = true;
        }
        if ((seg.flags & wire.Flags.fin) != 0) {
            self.peer_fin = true;
            self.receive_next +%= 1;
            self.ack_needed = true;
        }
        return true;
    }
    pub fn read(self: *Stream, out: []u8) Error!usize {
        if (self.failed) return error.InvalidState;
        if (out.len == 0) return error.InvalidArgument;
        if (self.rx_len == 0) return if (self.peer_fin) 0 else error.WouldBlock;
        const n = @min(out.len, self.rx_len);
        @memcpy(out[0..n], self.rx[0..n]);
        std.mem.copyForwards(u8, self.rx[0 .. self.rx_len - n], self.rx[n..self.rx_len]);
        self.rx_len -= n;
        self.ack_needed = true;
        return n;
    }
    fn window(self: *const Stream) u16 {
        return @intCast(self.rx.len - self.rx_len);
    }
};

test "data transfer handles loss, duplicate input, partial ACK and EOF" {
    const local = connect.Endpoint{ .address = .{ 192, 0, 2, 1 }, .port = 50000 };
    const remote = connect.Endpoint{ .address = .{ 198, 51, 100, 2 }, .port = 22 };
    var s = Stream.init(.{ .local = local, .remote = remote, .send_next = 0xfffffffe, .receive_next = 100, .remote_window = 100, .remote_mss = 536 });
    try std.testing.expectEqual(@as(usize, 4), try s.write("ping", 0, 6000));
    const first = try wire.parse((try s.poll(0)).?);
    try std.testing.expectEqualStrings("ping", first.payload);
    try s.sent(0);
    try std.testing.expect((try s.poll(999)) == null);
    try std.testing.expectEqualStrings("ping", (try wire.parse((try s.poll(1000)).?)).payload);
    try s.sent(1000);
    var peer_buf: [128]u8 = undefined;
    var peer = wire.Segment{ .src = remote.address, .dst = local.address, .src_port = 22, .dst_port = 50000, .seq = 100, .ack = 0, .flags = wire.Flags.ack, .window = 100, .options = "", .payload = "pong" };
    try std.testing.expect(try s.receive(try wire.encode(&peer_buf, peer, 0)));
    try std.testing.expectEqual(@as(usize, 2), s.tx_len);
    try std.testing.expect(!try s.receive(try wire.encode(&peer_buf, peer, 0)));
    var out: [8]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 4), try s.read(&out));
    try std.testing.expectEqualStrings("pong", out[0..4]);
    try std.testing.expectEqual(@as(u32, 2), (try wire.parse((try s.poll(1001)).?)).seq);
    try s.sent(1001); // ACK the data and window update.
    peer.seq = 104;
    peer.ack = 2;
    peer.payload = "";
    peer.flags = wire.Flags.ack | wire.Flags.fin;
    try std.testing.expect(try s.receive(try wire.encode(&peer_buf, peer, 0)));
    try std.testing.expectEqual(@as(usize, 0), s.tx_len);
    try std.testing.expectEqual(@as(usize, 0), try s.read(&out));
    const final_ack = try wire.parse((try s.poll(1002)).?);
    try std.testing.expectEqual(@as(u32, 105), final_ack.ack);
}

test "flow control, invalid ACK and send deadline fail safely" {
    const local = connect.Endpoint{ .address = .{ 192, 0, 2, 1 }, .port = 50000 };
    const remote = connect.Endpoint{ .address = .{ 198, 51, 100, 2 }, .port = 22 };
    var s = Stream.init(.{ .local = local, .remote = remote, .send_next = 10, .receive_next = 20, .remote_window = 0, .remote_mss = 536 });
    try std.testing.expectError(error.WouldBlock, s.write("x", 0, 3000));
    var packet: [64]u8 = undefined;
    var peer = wire.Segment{ .src = remote.address, .dst = local.address, .src_port = 22, .dst_port = 50000, .seq = 20, .ack = 10, .flags = wire.Flags.ack, .window = 2, .options = "", .payload = "" };
    try std.testing.expect(try s.receive(try wire.encode(&packet, peer, 0)));
    try std.testing.expectEqual(@as(usize, 2), try s.write("long", 1, 3000));
    peer.ack = 12;
    try std.testing.expect(!try s.receive(try wire.encode(&packet, peer, 0))); // Cannot acknowledge unsent bytes.
    _ = try s.poll(1);
    try s.sent(1);
    peer.ack = 13;
    try std.testing.expect(!try s.receive(try wire.encode(&packet, peer, 0))); // Beyond the transmitted range.
    try std.testing.expectEqual(@as(usize, 2), s.tx_len);
    try std.testing.expectError(error.Timeout, s.poll(3000));
    try std.testing.expectError(error.InvalidState, s.write("x", 3001, 4000));
}
