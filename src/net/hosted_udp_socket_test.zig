const std = @import("std");
const t = std.testing;
const split = @import("hosted_network_split.zig");
const hosted = @import("hosted.zig");
const packet = @import("hosted_udp_frame.zig");
const udp = @import("udp_ipv4.zig");
const socket = @import("hosted_udp_socket.zig");
const local = [6]u8{ 2, 0, 0, 0, 0, 1 };
const peer = udp.Endpoint{ .mac = .{ 2, 0, 0, 0, 0, 2 }, .ip = .{ 192, 0, 2, 2 }, .port = 44444 };
const range = @import("hosted_udp_lease.zig").PortRange{ .first = 49152, .last = 61439 };
fn ready() split.State {
    return .{ .generation = 7, .address = .{ .ip = 0xc0000201, .mask = 0xffffff00, .gateway = 0xc00002fe, .dns = 0xc00002fe } };
}
const Fake = struct {
    mode: enum { blocked, full, partial } = .blocked,
    writes: usize = 0,
    retired: bool = false,
    data: [1512]u8 = @splat(0),
    len: usize = 0,
    pub fn send(self: *@This(), bytes: []const u8) !usize {
        self.writes += 1;
        if (self.mode == .blocked) return 0;
        if (self.mode == .partial) return 1;
        self.len = bytes.len;
        @memcpy(self.data[0..bytes.len], bytes);
        return bytes.len;
    }
    pub fn sendLong(self: *@This(), bytes: []const u8, _: *[1536]u8) !usize {
        return self.send(bytes);
    }
    pub fn invalidate(self: *@This()) void {
        self.retired = true;
    }
};
fn decoded(storage: *[1512]u8, decoder: *hosted.Decoder, source: udp.Endpoint, destination: udp.Endpoint, payload: []const u8) !hosted.Frame {
    const bytes = try packet.prepare(storage, source, destination, payload, 10);
    decoder.* = .{};
    var value: ?hosted.Frame = null;
    for (bytes) |b| if (try decoder.push(b)) |f| {
        value = f;
    };
    return value.?;
}

test "bound socket sends copied datagrams with bounded backpressure" {
    var state = ready();
    var s: socket.Socket = .{};
    const h = try s.bind(&state, local, 49152, range);
    try t.expectError(error.Busy, s.bind(&state, local, 49153, range));
    var payload = [_]u8{ 1, 2, 3 };
    try s.sendTo(h, peer, &payload, 5, 1, 100);
    payload[0] = 9;
    try t.expectError(error.Busy, s.sendTo(h, peer, "other", 6, 1, 100));
    var transport: Fake = .{};
    const decoder: hosted.Decoder = .{};
    try t.expectEqual(@import("hosted_udp_sender.zig").Outcome.pending, try s.pollSend(h, &transport, 2, &decoder, false));
    try t.expectEqual(@as(usize, 0), transport.writes);
    try t.expectEqual(@import("hosted_udp_sender.zig").Outcome.pending, try s.pollSend(h, &transport, 3, &decoder, true));
    transport.mode = .full;
    try t.expectEqual(@import("hosted_udp_sender.zig").Outcome.sent, try s.pollSend(h, &transport, 4, &decoder, true));
    const datagram = try udp.decode(transport.data[12..transport.len]);
    try t.expectEqualSlices(u8, &.{ 1, 2, 3 }, datagram.payload);
    try t.expectError(error.Busy, s.pollSend(h, &transport, 5, &decoder, true));
    try s.sendTo(h, peer, "again", 7, 6, 100);
    try s.close(h);
    try t.expectError(error.StaleHandle, s.sendTo(h, peer, "x", 8, 7, 100));
    const replacement = try s.bind(&state, local, 49152, range);
    try t.expect(!std.meta.eql(h, replacement));
}

test "receive queue retains datagrams, source and empty payload" {
    var state = ready();
    var s: socket.Socket = .{};
    const h = try s.bind(&state, local, 49152, range);
    const dst = s.sender.?.binding.local;
    var storage: [1512]u8 = undefined;
    var decoder: hosted.Decoder = .{};
    const incoming = try decoded(&storage, &decoder, peer, dst, "hello");
    try t.expect(try s.receive(h, incoming));
    try t.expectError(error.ReceiveFull, s.receive(h, incoming));
    var short: [2]u8 = undefined;
    try t.expectError(error.BufferTooSmall, s.read(h, &short));
    var out: [10]u8 = undefined;
    const got = (try s.read(h, &out)).?;
    try t.expectEqualDeep(peer, got.source);
    try t.expectEqualStrings("hello", out[0..got.bytes]);
    try t.expect((try s.read(h, &out)) == null);
    const empty = try decoded(&storage, &decoder, peer, dst, "");
    try t.expect(try s.receive(h, empty));
    try t.expectEqual(@as(usize, 0), (try s.read(h, &out)).?.bytes);
}

test "maximum Hosted UDP payload stays bounded in both directions" {
    var state = ready();
    var s: socket.Socket = .{};
    const h = try s.bind(&state, local, 49152, range);
    const dst = s.sender.?.binding.local;
    const payload: [packet.max_payload]u8 = @splat(0x5a);
    const oversized: [packet.max_payload + 1]u8 = @splat(0x5a);
    try t.expectError(error.TooLarge, s.sendTo(h, peer, &oversized, 1, 1, 100));
    try s.sendTo(h, peer, &payload, 1, 1, 100);
    var transport: Fake = .{ .mode = .full };
    var decoder: hosted.Decoder = .{};
    _ = try s.pollSend(h, &transport, 2, &decoder, true);
    try t.expectEqualSlices(u8, &payload, (try udp.decode(transport.data[12..transport.len])).payload);
    var storage: [1512]u8 = undefined;
    const incoming = try decoded(&storage, &decoder, peer, dst, &payload);
    try t.expect(try s.receive(h, incoming));
    var out: [packet.max_payload]u8 = undefined;
    const got = (try s.read(h, &out)).?;
    try t.expectEqualSlices(u8, &payload, out[0..got.bytes]);
}

test "unrelated traffic, stale leases and partial transmission fail safely" {
    var state = ready();
    var s: socket.Socket = .{};
    const h = try s.bind(&state, local, 49152, range);
    const dst = s.sender.?.binding.local;
    var storage: [1512]u8 = undefined;
    var decoder: hosted.Decoder = .{};
    var wrong = dst;
    wrong.port += 1;
    const incoming = try decoded(&storage, &decoder, peer, wrong, "x");
    try t.expect(!try s.receive(h, incoming));
    try s.sendTo(h, peer, "x", 1, 1, 100);
    var transport: Fake = .{ .mode = .partial };
    decoder = .{};
    try t.expectError(error.PartialPacket, s.pollSend(h, &transport, 2, &decoder, true));
    try t.expect(transport.retired);
    try t.expectError(error.StaleHandle, s.read(h, &storage));
    state = ready();
    const next = try s.bind(&state, local, 49152, range);
    state.address.?.dns = 0x08080808;
    try t.expectError(error.StaleHandle, s.sendTo(next, peer, "x", 2, 3, 100));
    try t.expectError(error.StaleHandle, s.close(next));
}

test "stale active send retires its stream but an old handle cannot retire a new one" {
    var state = ready();
    var s: socket.Socket = .{};
    const first = try s.bind(&state, local, 49152, range);
    try s.sendTo(first, peer, "x", 1, 1, 100);
    var transport: Fake = .{};
    const decoder: hosted.Decoder = .{};
    _ = state.invalidate();
    try t.expectError(error.StaleHandle, s.pollSend(first, &transport, 2, &decoder, true));
    try t.expect(transport.retired);
    state = ready();
    const next = try s.bind(&state, local, 49152, range);
    transport = .{};
    try s.sendTo(next, peer, "y", 2, 3, 100);
    try t.expectError(error.StaleHandle, s.pollSend(first, &transport, 4, &decoder, true));
    try t.expect(!transport.retired);
    transport.mode = .full;
    try t.expectEqual(@import("hosted_udp_sender.zig").Outcome.sent, try s.pollSend(next, &transport, 5, &decoder, true));
}

test "ARP route result feeds a bound socket without changing destination" {
    var state = ready();
    var s: socket.Socket = .{};
    const h = try s.bind(&state, local, 49152, range);
    var route: @import("hosted_udp_route.zig").Route = .{};
    try route.begin(&state, s.sender.?.binding, peer.ip, peer.port, 0, 1000);
    const request = (try route.poll(&state, 1, 1)).?;
    var response: [42]u8 = request[12..54].*;
    response[0..6].* = local;
    response[6..12].* = peer.mac;
    std.mem.writeInt(u16, response[20..22], 2, .big);
    response[22..28].* = peer.mac;
    response[28..32].* = peer.ip;
    response[32..38].* = local;
    response[38..42].* = .{ 192, 0, 2, 1 };
    try route.sent(&state, 2);
    try t.expect(try route.receive(&state, 3, .{ .interface = hosted.station_interface, .payload = &response }));
    const resolved = (try route.result(&state, 4)).?;
    try s.sendTo(h, resolved, "from socket", 2, 5, 100);
    var transport: Fake = .{ .mode = .full };
    const decoder: hosted.Decoder = .{};
    _ = try s.pollSend(h, &transport, 6, &decoder, true);
    const datagram = try udp.decode(transport.data[12..transport.len]);
    try t.expectEqualDeep(peer, datagram.destination);
    try t.expectEqualStrings("from socket", datagram.payload);
}
