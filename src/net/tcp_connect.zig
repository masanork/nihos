//! Bounded IPv4 TCP active-open state. Not a connected socket implementation.
//! Caller owns IP routing, frame transmission, clock, entropy and cancellation.
const std = @import("std");
const wire = @import("tcp_wire.zig");
pub const Error = wire.Error || error{ InvalidState, InvalidArgument, Timeout, Refused, TransportFailed };
pub const Endpoint = struct { address: [4]u8, port: u16 };
pub const Established = struct { local: Endpoint, remote: Endpoint, send_next: u32, receive_next: u32, remote_window: u16, remote_mss: u16 };
pub const Connect = struct {
    const State = enum { idle, syn_pending, syn_wait, ack_pending, established, failed };
    state: State = .idle,
    local: Endpoint = undefined,
    remote: Endpoint = undefined,
    initial_seq: u32 = 0,
    peer_seq: u32 = 0,
    remote_window: u16 = 0,
    remote_mss: u16 = 536,
    deadline: u64 = 0,
    retry_at: u64 = 0,
    retries: u8 = 0,
    packet: [40]u8 = undefined,
    packet_len: usize = 0,

    /// now/deadline use caller's monotonic milliseconds. initial_seq and the
    /// ephemeral local port must be chosen by a secure platform provider.
    pub fn begin(self: *Connect, local: Endpoint, remote: Endpoint, initial_seq: u32, now: u64, deadline: u64) Error!void {
        if (self.state != .idle) return error.InvalidState;
        if (local.port == 0 or remote.port == 0 or deadline <= now) return error.InvalidArgument;
        self.local = local;
        self.remote = remote;
        self.initial_seq = initial_seq;
        self.deadline = deadline;
        self.state = .syn_pending;
        try self.makePacket(wire.Flags.syn, initial_seq, 0);
    }
    /// The packet remains stable until sent or failed. The adapter must not
    /// mark a packet sent until it has handed off the entire IP datagram.
    pub fn poll(self: *Connect, now: u64) Error!?[]const u8 {
        if (self.state == .idle or self.state == .failed) return error.InvalidState;
        if (self.state == .established) return null;
        if (now >= self.deadline) {
            self.state = .failed;
            return error.Timeout;
        }
        if (self.state == .syn_wait and now >= self.retry_at) {
            self.state = .syn_pending;
            try self.makePacket(wire.Flags.syn, self.initial_seq, 0);
        }
        return if (self.state == .syn_pending or self.state == .ack_pending) self.packet[0..self.packet_len] else null;
    }
    pub fn sent(self: *Connect, now: u64) Error!void {
        if (self.state != .syn_pending and self.state != .ack_pending) return error.InvalidState;
        if (now >= self.deadline) {
            self.state = .failed;
            return error.Timeout;
        }
        switch (self.state) {
            .syn_pending => {
                const shift: u6 = @intCast(@min(self.retries, 4));
                const delay = @as(u64, 1000) << shift;
                self.retry_at = now +| delay;
                self.retries +|= 1;
                self.state = .syn_wait;
            },
            .ack_pending => self.state = .established,
            else => return error.InvalidState,
        }
    }
    /// Ignores malformed, unrelated, and invalidly acknowledged packets.
    /// The caller should still route them to other connections where applicable.
    pub fn receive(self: *Connect, packet: []const u8, now: u64) Error!bool {
        if (self.state != .syn_wait and !(self.state == .syn_pending and self.retries > 0)) return error.InvalidState;
        if (now >= self.deadline) {
            self.state = .failed;
            return error.Timeout;
        }
        const segment = wire.parse(packet) catch return false;
        if (!std.mem.eql(u8, &segment.src, &self.remote.address) or !std.mem.eql(u8, &segment.dst, &self.local.address) or segment.src_port != self.remote.port or segment.dst_port != self.local.port) return false;
        if ((segment.flags & wire.Flags.ack) == 0 or segment.ack != self.initial_seq +% 1) return false;
        if ((segment.flags & wire.Flags.rst) != 0) {
            self.state = .failed;
            return error.Refused;
        }
        if ((segment.flags & (wire.Flags.syn | wire.Flags.fin | wire.Flags.ack)) != (wire.Flags.syn | wire.Flags.ack) or segment.payload.len != 0) return false;
        const mss = parseMss(segment.options) orelse return false;
        self.peer_seq = segment.seq;
        self.remote_window = segment.window;
        self.remote_mss = mss;
        try self.makePacket(wire.Flags.ack, self.initial_seq +% 1, self.peer_seq +% 1);
        self.state = .ack_pending;
        return true;
    }
    pub fn result(self: *const Connect) ?Established {
        if (self.state != .established) return null;
        return .{ .local = self.local, .remote = self.remote, .send_next = self.initial_seq +% 1, .receive_next = self.peer_seq +% 1, .remote_window = self.remote_window, .remote_mss = self.remote_mss };
    }
    pub fn transportFailed(self: *Connect) void {
        self.state = .failed;
    }
    fn makePacket(self: *Connect, flags: u8, seq: u32, ack: u32) Error!void {
        const packet = try wire.encode(&self.packet, .{ .src = self.local.address, .dst = self.remote.address, .src_port = self.local.port, .dst_port = self.remote.port, .seq = seq, .ack = ack, .flags = flags, .window = 4096, .options = "", .payload = "" }, 0);
        self.packet_len = packet.len;
    }
};

fn parseMss(options: []const u8) ?u16 {
    var pos: usize = 0;
    var mss: u16 = 536;
    var seen = false;
    while (pos < options.len) {
        const kind = options[pos];
        if (kind == 0) break;
        if (kind == 1) {
            pos += 1;
            continue;
        }
        if (options.len - pos < 2) return null;
        const len: usize = options[pos + 1];
        if (len < 2 or len > options.len - pos) return null;
        if (kind == 2) {
            if (len != 4 or seen) return null;
            mss = std.mem.readInt(u16, options[pos + 2 ..][0..2], .big);
            if (mss == 0) return null;
            seen = true;
        }
        pos += len;
    }
    return mss;
}

test "active open retries SYN and accepts only matching SYN ACK" {
    const local = Endpoint{ .address = .{ 192, 0, 2, 1 }, .port = 50000 };
    const remote = Endpoint{ .address = .{ 198, 51, 100, 2 }, .port = 22 };
    var c: Connect = .{};
    try c.begin(local, remote, 0xffffffff, 0, 5000);
    const syn = (try c.poll(0)).?;
    try std.testing.expectEqual(wire.Flags.syn, (try wire.parse(syn)).flags);
    try c.sent(0);
    try std.testing.expect((try c.poll(999)) == null);
    try std.testing.expect((try c.poll(1000)) != null);
    try c.sent(1000);
    var peer: [64]u8 = undefined;
    var segment = wire.Segment{ .src = remote.address, .dst = local.address, .src_port = 22, .dst_port = 50000, .seq = 41, .ack = 1, .flags = wire.Flags.syn | wire.Flags.ack, .window = 3000, .options = "", .payload = "" };
    try std.testing.expect(!try c.receive(try wire.encode(&peer, segment, 1), 1001));
    segment.ack = 0;
    try std.testing.expect(try c.receive(try wire.encode(&peer, segment, 1), 1002));
    try std.testing.expect(c.result() == null);
    const ack = try wire.parse((try c.poll(1002)).?);
    try std.testing.expectEqual(@as(u32, 42), ack.ack);
    try c.sent(1002);
    try std.testing.expectEqual(@as(u32, 0), c.result().?.send_next);
    try std.testing.expectEqual(@as(u16, 536), c.result().?.remote_mss);
}

test "active open times out and validates TCP option lengths" {
    try std.testing.expectEqual(@as(?u16, 1460), parseMss(&.{ 2, 4, 5, 180 }));
    try std.testing.expectEqual(@as(?u16, null), parseMss(&.{ 2, 1, 0, 0 }));
    const local = Endpoint{ .address = .{ 192, 0, 2, 1 }, .port = 50000 };
    const remote = Endpoint{ .address = .{ 198, 51, 100, 2 }, .port = 22 };
    var c: Connect = .{};
    try c.begin(local, remote, 1, 0, 10);
    try c.sent(0);
    try std.testing.expectError(error.Timeout, c.poll(10));
    try std.testing.expectError(error.InvalidState, c.poll(11));
}

test "late SYN ACK is accepted while retransmit is queued; valid reset fails" {
    const local = Endpoint{ .address = .{ 192, 0, 2, 1 }, .port = 50000 };
    const remote = Endpoint{ .address = .{ 198, 51, 100, 2 }, .port = 22 };
    var packet: [64]u8 = undefined;
    var peer = wire.Segment{ .src = remote.address, .dst = local.address, .src_port = 22, .dst_port = 50000, .seq = 4, .ack = 2, .flags = wire.Flags.syn | wire.Flags.ack, .window = 100, .options = "", .payload = "" };
    var c: Connect = .{};
    try c.begin(local, remote, 1, 0, 5000);
    try c.sent(0);
    _ = try c.poll(1000);
    try std.testing.expect(try c.receive(try wire.encode(&packet, peer, 0), 1001));
    var refused: Connect = .{};
    try refused.begin(local, remote, 1, 0, 5000);
    try refused.sent(0);
    peer.flags = wire.Flags.rst | wire.Flags.ack;
    peer.ack = 3;
    try std.testing.expect(!try refused.receive(try wire.encode(&packet, peer, 0), 1));
    peer.ack = 2;
    try std.testing.expectError(error.Refused, refused.receive(try wire.encode(&packet, peer, 0), 2));
}
