//! Explicit TIME_WAIT owner after both FINs have been acknowledged.
//! The socket table must retain the tuple and drive the monotonic timer.
const std = @import("std");
const wire = @import("tcp_wire.zig");
const tcp = @import("tcp_stream.zig");
pub const Error = tcp.Error || error{Expired};
pub const TimeWait = struct {
    stream: *tcp.Stream,
    duration: u64,
    until: u64,
    expired: bool = false,

    /// duration is the platform's chosen 2*MSL in monotonic milliseconds.
    pub fn begin(stream: *tcp.Stream, now: u64, duration: u64) Error!TimeWait {
        if (!stream.closeHandshakeComplete()) return error.InvalidState;
        if (duration == 0 or now > std.math.maxInt(u64) - duration) return error.InvalidArgument;
        return .{ .stream = stream, .duration = duration, .until = now + duration };
    }
    /// A valid retransmission of the peer's FIN extends TIME_WAIT and requires
    /// another ACK. No data is delivered a second time.
    pub fn receive(self: *TimeWait, packet: []const u8, now: u64) Error!bool {
        if (self.expired or (now >= self.until and self.stream.closeHandshakeComplete())) {
            self.expired = true;
            return error.Expired;
        }
        const seg = wire.parse(packet) catch return false;
        const s = self.stream;
        if (!std.mem.eql(u8, &seg.src, &s.remote.address) or !std.mem.eql(u8, &seg.dst, &s.local.address) or seg.src_port != s.remote.port or seg.dst_port != s.local.port) return false;
        if ((seg.flags & (wire.Flags.fin | wire.Flags.ack | wire.Flags.syn | wire.Flags.rst)) != (wire.Flags.fin | wire.Flags.ack)) return false;
        if (seg.ack != s.send_unacked or seg.seq +% @as(u32, @intCast(seg.payload.len)) +% 1 != s.receive_next) return false;
        if (now > std.math.maxInt(u64) - self.duration) return error.InvalidArgument;
        _ = try s.receive(packet);
        self.until = now + self.duration;
        return true;
    }
    pub fn poll(self: *TimeWait, now: u64) Error!?[]const u8 {
        if (self.expired) return error.Expired;
        if (now >= self.until and self.stream.closeHandshakeComplete()) {
            self.expired = true;
            return error.Expired;
        }
        return self.stream.poll(now);
    }
    pub fn sent(self: *TimeWait, now: u64) Error!void {
        if (self.expired) return error.Expired;
        try self.stream.sent(now);
    }
};

test "TIME_WAIT retains tuple and extends for duplicate FIN" {
    const conn = @import("tcp_connect.zig");
    const local = conn.Endpoint{ .address = .{ 192, 0, 2, 1 }, .port = 50000 };
    const remote = conn.Endpoint{ .address = .{ 198, 51, 100, 2 }, .port = 22 };
    var s = tcp.Stream.init(.{ .local = local, .remote = remote, .send_next = 10, .receive_next = 20, .remote_window = 10, .remote_mss = 536 });
    try s.closeWrite(0, 10000);
    _ = try s.poll(0);
    try s.sent(0);
    var packet: [64]u8 = undefined;
    var peer = wire.Segment{ .src = remote.address, .dst = local.address, .src_port = 22, .dst_port = 50000, .seq = 20, .ack = 11, .flags = wire.Flags.ack | wire.Flags.fin, .window = 10, .options = "", .payload = "" };
    try std.testing.expect(try s.receive(try wire.encode(&packet, peer, 0)));
    _ = try s.poll(1);
    try s.sent(1);
    var tw = try TimeWait.begin(&s, 2, 100);
    peer.src_port = 23;
    try std.testing.expect(!try tw.receive(try wire.encode(&packet, peer, 0), 50));
    peer.src_port = 22;
    try std.testing.expect(try tw.receive(try wire.encode(&packet, peer, 0), 90));
    try std.testing.expectEqual(@as(u64, 190), tw.until);
    const ack = try wire.parse((try tw.poll(91)).?);
    try std.testing.expectEqual(@as(u32, 21), ack.ack);
    try tw.sent(91);
    try std.testing.expect((try tw.poll(189)) == null);
    try std.testing.expectError(error.Expired, tw.poll(190));
}
