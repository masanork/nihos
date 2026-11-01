const std = @import("std");
const wire = @import("hosted.zig");
const time = @import("hosted_c6_time_exchange.zig");
const udp = @import("long_udp_probe.zig");
const probe = @import("hosted_split_udp_probe.zig");
const mod = @import("hosted_split_udp_owner.zig");
const local = [6]u8{ 2, 1, 2, 3, 4, 5 };
const peer = probe.Peer{ .ip = 0xc0a80127, .mac = .{ 2, 6, 7, 8, 9, 10 }, .port = 44444 };

fn exchange() time.Exchange {
    var e = time.Exchange{};
    e.phase = .ready;
    e.deadline = 100;
    e.station.phase = .done;
    e.station.connected = true;
    e.station.peer_chip = 13;
    e.station.version_known = true;
    e.station.version = .{ 3, 0, 10 };
    e.station.peer_rpc_version = 2;
    e.station.peer_sdio_buffer_blocks = .{ 7, 7 };
    e.station.peer_mode = 1;
    e.station.mac_address = local;
    e.addresses = .{ .generation = 7, .address = .{ .ip = 0xc0a80123, .mask = 0xffffff00, .gateway = 0xc0a80101, .dns = 0xc0a80101 } };
    e.clock.reset(7);
    return e;
}
const Fake = struct {
    input: []const u8 = &.{},
    pos: usize = 0,
    max_read: usize = 512,
    send_result: usize = 0,
    fail_send: bool = false,
    sends: u32 = 0,
    retired: bool = false,
    pub fn receive(self: *@This(), out: []u8) !usize {
        const n = @min(self.max_read, @min(out.len, self.input.len - self.pos));
        @memcpy(out[0..n], self.input[self.pos..][0..n]);
        self.pos += n;
        return n;
    }
    pub fn sendLong(self: *@This(), data: []const u8, padding: *[1536]u8) !usize {
        _ = padding;
        self.sends += 1;
        if (self.fail_send) return error.TransportFailure;
        return if (self.send_result == 1) data.len else self.send_result;
    }
    pub fn invalidate(self: *@This()) void {
        self.retired = true;
    }
};

test "requires ready connected C6 owner without host DHCP" {
    var e = exchange();
    var decoder = wire.Decoder{};
    // SAFETY: init is called before the owner is read.
    var o: mod.Owner = undefined;
    e.station.connected = false;
    try std.testing.expectError(error.WrongState, o.init(&e, &decoder, peer, 1, 1, 50));
    e.station.connected = true;
    e.station.dhcp_client = .{ .mac = local, .xid = 1 };
    try std.testing.expectError(error.WrongState, o.init(&e, &decoder, peer, 1, 1, 50));
    e.station.dhcp_client = null;
    e.station.peer_rpc_version = 1;
    try std.testing.expectError(error.UnsupportedPeer, o.init(&e, &decoder, peer, 1, 1, 50));
    e.station.peer_rpc_version = 2;
    decoder.used = 1;
    try std.testing.expectError(error.WrongState, o.init(&e, &decoder, peer, 1, 1, 50));
}

test "zero credit retries only the unsent packet and accepts matching echo" {
    var e = exchange();
    var decoder = wire.Decoder{};
    // SAFETY: init is called before the owner is read.
    var o: mod.Owner = undefined;
    try o.init(&e, &decoder, peer, 3, 1, 50);
    var s = Fake{};
    try o.step(&s, 2);
    try std.testing.expectEqual(mod.Phase.queued, o.phase);
    s.send_result = 1;
    try o.step(&s, 3);
    try std.testing.expectEqual(mod.Phase.waiting, o.phase);
    var packet: [udp.ethernet_bytes]u8 = undefined;
    const echo = udp.packetAttemptFrom(&packet, peer.mac, peer.ip, peer.port, local, e.addresses.address.?.ip, probe.local_port, 3);
    var encoded: [12 + udp.ethernet_bytes]u8 = undefined;
    s.input = try wire.frame(&encoded, wire.station_interface, 1, echo);
    for (4..10) |n| {
        if (o.phase == .complete) break;
        try o.step(&s, n);
    }
    try std.testing.expectEqual(mod.Phase.complete, o.phase);
    try std.testing.expectEqual(@as(u32, 1), o.sent_count);
    try std.testing.expect(!s.retired);
}

test "partial write retires transport and revokes address" {
    var e = exchange();
    var decoder = wire.Decoder{};
    // SAFETY: init is called before the owner is read.
    var o: mod.Owner = undefined;
    try o.init(&e, &decoder, peer, 1, 1, 50);
    var s = Fake{ .send_result = 17 };
    try std.testing.expectError(error.PartialPacket, o.step(&s, 2));
    try std.testing.expectEqual(mod.Phase.failed, o.phase);
    try std.testing.expect(s.retired and e.addresses.address == null);
    try std.testing.expectError(error.WrongState, o.step(&s, 3));
}

test "transport error cannot be retried" {
    var e = exchange();
    var decoder = wire.Decoder{};
    // SAFETY: init is called before the owner is read.
    var o: mod.Owner = undefined;
    try o.init(&e, &decoder, peer, 1, 1, 50);
    var s = Fake{ .fail_send = true };
    try std.testing.expectError(error.TransportFailure, o.step(&s, 2));
    try std.testing.expect(s.retired and e.addresses.address == null);
    try std.testing.expectError(error.WrongState, o.step(&s, 3));
    try std.testing.expectEqual(@as(u32, 1), s.sends);
}

test "link-down event is processed before any queued send" {
    var e = exchange();
    var decoder = wire.Decoder{};
    // SAFETY: init is called before the owner is read.
    var o: mod.Owner = undefined;
    try o.init(&e, &decoder, peer, 1, 1, 50);
    var body: [64]u8 = undefined;
    const rpc = try wire.request(&body, 777, 1, &.{});
    body[13] = 3;
    @memcpy(body[3..9], "RPCEvt");
    var encoded: [100]u8 = undefined;
    var s = Fake{ .input = try wire.frame(&encoded, 3, 1, rpc), .send_result = 1 };
    try std.testing.expectError(error.Stale, o.step(&s, 2));
    try std.testing.expectEqual(@as(u32, 0), s.sends);
    try std.testing.expect(s.retired and e.addresses.address == null);
}

test "fragmented control event blocks the queued send until decoded" {
    var e = exchange();
    var decoder = wire.Decoder{};
    // SAFETY: init is called before the owner is read.
    var o: mod.Owner = undefined;
    try o.init(&e, &decoder, peer, 1, 1, 50);
    var body: [64]u8 = undefined;
    const rpc = try wire.request(&body, 777, 1, &.{});
    body[13] = 3;
    @memcpy(body[3..9], "RPCEvt");
    var encoded: [100]u8 = undefined;
    var s = Fake{ .input = try wire.frame(&encoded, 3, 1, rpc), .send_result = 1, .max_read = 4 };
    var now: u64 = 2;
    while (s.pos < s.input.len) : (now += 1) {
        o.step(&s, now) catch |err| {
            try std.testing.expectEqual(error.Stale, err);
            break;
        };
        try std.testing.expectEqual(@as(u32, 0), s.sends);
    }
    try std.testing.expect(s.retired and e.addresses.address == null);
    try std.testing.expectEqual(@as(u32, 0), s.sends);
}

test "deadline revokes owner without touching transport" {
    var e = exchange();
    var decoder = wire.Decoder{};
    // SAFETY: init is called before the owner is read.
    var o: mod.Owner = undefined;
    try o.init(&e, &decoder, peer, 1, 1, 50);
    var s = Fake{ .send_result = 1 };
    try std.testing.expectError(error.Deadline, o.step(&s, 50));
    try std.testing.expectEqual(@as(u32, 0), s.sends);
    try std.testing.expect(s.retired and e.addresses.address == null);
}

test "new C6 initialization retires old connection before sending" {
    var e = exchange();
    var decoder = wire.Decoder{};
    // SAFETY: init is called before the owner is read.
    var o: mod.Owner = undefined;
    try o.init(&e, &decoder, peer, 1, 1, 50);
    var encoded: [64]u8 = undefined;
    var s = Fake{ .input = try wire.frame(&encoded, 5, 1, &.{ 0x22, 0 }), .send_result = 1 };
    try std.testing.expectError(error.Stale, o.step(&s, 2));
    try std.testing.expectEqual(@as(u32, 0), s.sends);
    try std.testing.expect(s.retired and e.addresses.address == null);
}
