const std = @import("std");
const wire = @import("hosted.zig");
const service = @import("hosted_c6_time_exchange.zig");
fn deliver(exchange: *service.Exchange, iface: u8, payload: []const u8, now: u64) !void {
    var frame_bytes: [512]u8 = undefined;
    const frame = try wire.frame(&frame_bytes, iface, 0, payload);
    var decoder = wire.Decoder{};
    var found = false;
    for (frame) |byte| if (try decoder.push(byte)) |decoded| {
        try exchange.receive(decoded, now);
        found = true;
    };
    try std.testing.expect(found);
}
fn rpc(exchange: *service.Exchange, kind: u8, id: u32, uid: u32, body: []const u8, now: u64) !void {
    var bytes: [400]u8 = undefined;
    const packet = try wire.request(&bytes, id, uid, body);
    bytes[13] = kind;
    if (kind == 3) @memcpy(bytes[3..9], "RPCEvt");
    try deliver(exchange, 3, packet, now);
}
fn outgoing(frame: []const u8) !struct { id: u32, uid: u32 } {
    var r = wire.Reader{ .bytes = frame[24..] };
    var id: u32 = 0;
    var uid: u32 = 0;
    while (try r.next()) |field| {
        if (field.number == 2) id = @intCast(field.value);
        if (field.number == 3) uid = @intCast(field.value);
    }
    return .{ .id = id, .uid = uid };
}
fn address(exchange: *service.Exchange, now: u64) !void {
    var buf: [128]u8 = undefined;
    var w = wire.Writer{ .out = &buf };
    try w.uint(2, 1);
    try w.uint(3, 1);
    try w.data(4, "192.168.1.2");
    try w.data(5, "255.255.255.0");
    try w.data(6, "192.168.1.1");
    try w.uint(7, 1);
    try w.data(8, "8.8.8.8");
    try rpc(exchange, 3, 777, 1, w.slice(), now);
}
fn connect(exchange: *service.Exchange, version_major: u32) !void {
    try exchange.begin(.saved, 100, 0, 200);
    try deliver(exchange, 5, &.{ 0x22, 3, 0x12, 1, 13 }, 1);
    const caps = try exchange.tx(2);
    try std.testing.expectEqual(@as(u8, 5), caps[0] & 15);
    try exchange.sent(caps.len, 2);
    var now: u64 = 3;
    while (exchange.station.phase != .link and now < 50) : (now += 1) {
        const frame = try exchange.tx(now);
        try std.testing.expect(frame.len > 0);
        try std.testing.expectEqual(@as(u8, 3), frame[0] & 15); // no P4 DHCP
        const req = try outgoing(frame);
        try exchange.sent(frame.len, now);
        var body_bytes: [100]u8 = undefined;
        var body = wire.Writer{ .out = &body_bytes };
        if (req.id == 350) {
            try body.uint(2, version_major);
            try body.uint(3, 13);
            try body.uint(4, 1);
        } else if (req.id == 257) try body.data(1, &.{ 2, 3, 4, 5, 6, 7 });
        try rpc(exchange, 2, req.id + 256, req.uid, body.slice(), now);
    }
    try std.testing.expectEqual(@import("hosted_station.zig").Phase.link, exchange.station.phase);
    try rpc(exchange, 3, 775, 1, &.{}, now);
    try std.testing.expectEqual(service.Phase.address, exchange.phase);
    try std.testing.expect(exchange.station.dhcp_client == null);
    try address(exchange, now);
    try std.testing.expectEqual(service.Phase.ready, exchange.phase);
}
fn queueTime(exchange: *service.Exchange) !void {
    const frame = try exchange.tx(60);
    try std.testing.expectEqual(@as(u8, 3), frame[0] & 15);
    const req = try outgoing(frame);
    try std.testing.expectEqual(@as(u32, 388), req.id);
    try exchange.sent(0, 60);
    try std.testing.expectEqual(service.Phase.queued, exchange.phase);
    try exchange.sent(frame.len, 60);
}
fn event(exchange: *service.Exchange, known: bool, now: u64) !void {
    var result: [32]u8 = @splat(0);
    result[0] = 1;
    result[1] = @intFromBool(known);
    std.mem.writeInt(u32, result[4..8], 1, .little);
    std.mem.writeInt(u64, result[8..16], 101, .little);
    if (known) {
        std.mem.writeInt(u64, result[16..24], 1760000000, .little);
        std.mem.writeInt(u32, result[24..28], 17, .little);
    }
    var body_bytes: [100]u8 = undefined;
    var body = wire.Writer{ .out = &body_bytes };
    try body.uint(2, 0x4e545152);
    try body.data(3, &result);
    try rpc(exchange, 3, 788, 1, body.slice(), now);
}
test "station and split snapshot precede C6 time; event can precede ack" {
    var e = service.Exchange{};
    try connect(&e, 2);
    try queueTime(&e);
    try event(&e, true, 61);
    try std.testing.expectEqual(service.Phase.waiting, e.phase);
    try rpc(&e, 2, 644, e.uid, &.{}, 62);
    try std.testing.expectEqual(service.Phase.done, e.phase);
    try std.testing.expectEqual(@as(u64, 1760000000), e.sample.?.seconds);
    try std.testing.expectEqual(@as(u32, 17), e.sample.?.age_seconds);
}
test "ack first and unsynchronized result are distinguishable" {
    var e = service.Exchange{};
    try connect(&e, 2);
    try queueTime(&e);
    try rpc(&e, 2, 644, e.uid, &.{}, 61);
    try event(&e, false, 62);
    try std.testing.expectEqual(service.Phase.done, e.phase);
    try std.testing.expect(e.got_result and e.sample == null);
}
test "disconnect, partial transmission and timeout invalidate requests" {
    var e = service.Exchange{};
    try connect(&e, 2);
    try queueTime(&e);
    try std.testing.expectError(error.Stale, rpc(&e, 3, 777, 1, &.{}, 61)); // all-down invalidates generation
    try std.testing.expectEqual(service.Phase.failed, e.phase);
}
test "partial transmission fails closed" {
    var e = service.Exchange{};
    try connect(&e, 2);
    const frame = try e.tx(60);
    try std.testing.expectError(error.PartialPacket, e.sent(frame.len - 1, 60));
    try std.testing.expectEqual(service.Phase.failed, e.phase);
}
test "unrecognized firmware fails before Wi-Fi setup" {
    var e = service.Exchange{};
    try e.begin(.saved, 100, 0, 200);
    try deliver(&e, 5, &.{ 0x22, 3, 0x12, 1, 13 }, 1);
    const caps = try e.tx(2);
    try e.sent(caps.len, 2);
    const frame = try e.tx(3);
    const req = try outgoing(frame);
    try e.sent(frame.len, 3);
    var b: [32]u8 = undefined;
    var w = wire.Writer{ .out = &b };
    try w.uint(2, 1);
    try w.uint(3, 4);
    try w.uint(4, 1);
    try std.testing.expectError(error.UnsupportedPeer, rpc(&e, 2, 606, req.uid, w.slice(), 4));
    try std.testing.expectEqual(service.Phase.failed, e.phase);
}
test "deadline retires an unanswered request" {
    var e = service.Exchange{};
    try connect(&e, 2);
    try queueTime(&e);
    try std.testing.expectError(error.Deadline, e.tx(200));
    try std.testing.expectEqual(service.Phase.failed, e.phase);
}
test "event lost: correlated status query adopts the C6 address" {
    var e = service.Exchange{};
    try e.begin(.saved, 100, 0, 200);
    // Start from the link phase to exercise the previously tested station's
    // status-query handoff independently of its handshake fixture.
    e.station.phase = .link;
    e.station.connected = true;
    e.station.peer_chip = 13;
    e.station.version_known = true;
    e.station.version = .{ 2, 13, 1 };
    const query = try e.tx(10);
    const req = try outgoing(query);
    try std.testing.expectEqual(@as(u32, 353), req.id);
    try e.sent(query.len, 10);
    try address(&e, 11); // event cannot race ahead of the correlated response
    try std.testing.expectEqual(service.Phase.address, e.phase);
    try rpc(&e, 2, 609, req.uid, &.{}, 12); // older down snapshot must not replace later event
    try std.testing.expectEqual(service.Phase.ready, e.phase);
    try std.testing.expect(e.station.dhcp_client == null);
}
test "status reply supplies address when no event arrives" {
    var e = service.Exchange{};
    try e.begin(.saved, 100, 0, 200);
    e.station.phase = .link;
    e.station.connected = true;
    e.station.peer_chip = 13;
    e.station.version_known = true;
    e.station.version = .{ 2, 13, 1 };
    const query = try e.tx(10);
    const req = try outgoing(query);
    try e.sent(query.len, 10);
    var buf: [128]u8 = undefined;
    var w = wire.Writer{ .out = &buf };
    try w.uint(2, 1);
    try w.uint(3, 1);
    try w.data(4, "192.168.1.2");
    try w.data(5, "255.255.255.0");
    try w.data(6, "192.168.1.1");
    try w.uint(7, 1);
    try w.data(8, "8.8.8.8");
    try rpc(&e, 2, 609, req.uid, w.slice(), 11);
    try std.testing.expectEqual(service.Phase.ready, e.phase);
    try std.testing.expect(e.station.dhcp_client == null);
}
test "later down event wins over an earlier up status reply" {
    var e = service.Exchange{};
    try e.begin(.saved, 100, 0, 200);
    e.station.phase = .link;
    e.station.connected = true;
    e.station.peer_chip = 13;
    e.station.version_known = true;
    e.station.version = .{ 2, 13, 1 };
    const query = try e.tx(10);
    const req = try outgoing(query);
    try e.sent(query.len, 10);
    try rpc(&e, 3, 777, 1, &.{}, 11);
    var buf: [128]u8 = undefined;
    var w = wire.Writer{ .out = &buf };
    try w.uint(2, 1);
    try w.uint(3, 1);
    try w.data(4, "192.168.1.2");
    try w.data(5, "255.255.255.0");
    try w.data(6, "192.168.1.1");
    try w.uint(7, 1);
    try w.data(8, "8.8.8.8");
    try rpc(&e, 2, 609, req.uid, w.slice(), 12);
    try std.testing.expectEqual(service.Phase.address, e.phase);
    try std.testing.expect(e.addresses.address == null);
}
test "unsynchronized result can be polled again with a new request ID" {
    var e = service.Exchange{};
    try connect(&e, 2);
    try queueTime(&e);
    try rpc(&e, 2, 644, e.uid, &.{}, 61);
    try event(&e, false, 62);
    try e.nextSnapshot(63);
    const frame = try e.tx(64);
    try std.testing.expectEqual(@as(u32, 2), e.clock.outstanding.?);
    try std.testing.expectEqual(@as(u32, 388), (try outgoing(frame)).id);
    try e.sent(frame.len, 64);
    // A delayed event for request 1 cannot satisfy request 2.
    try std.testing.expectError(error.Stale, event(&e, true, 65));
    try std.testing.expectEqual(service.Phase.failed, e.phase);
}
test "rejected acknowledgement discards a previously received sample" {
    var e = service.Exchange{};
    try connect(&e, 2);
    try queueTime(&e);
    try event(&e, true, 61);
    try std.testing.expect(e.sample != null);
    try std.testing.expectError(error.Rejected, rpc(&e, 2, 644, e.uid, &.{ 8, 1 }, 62));
    try std.testing.expectEqual(service.Phase.failed, e.phase);
    try std.testing.expect(e.sample == null);
}
test "a reply with the wrong request UID cannot satisfy the status query" {
    var e = service.Exchange{};
    try e.begin(.saved, 100, 0, 200);
    e.station.phase = .link;
    e.station.connected = true;
    e.station.peer_chip = 13;
    e.station.version_known = true;
    e.station.version = .{ 2, 13, 1 };
    const query = try e.tx(10);
    const req = try outgoing(query);
    try e.sent(query.len, 10);
    try std.testing.expectError(error.Stale, rpc(&e, 2, 609, req.uid + 1, &.{}, 11));
    try std.testing.expectEqual(service.Phase.failed, e.phase);
}
