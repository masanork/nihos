//! Host model of the native C6 time/UDP ordering. No SDIO or device execution.
const std = @import("std");
const t = std.testing;
const hosted = @import("hosted.zig");
const time = @import("hosted_c6_time_exchange.zig");
const packet = @import("hosted_udp_frame.zig");
const udp = @import("udp_ipv4.zig");
const shared = @import("hosted_udp_shared.zig");
const local = [6]u8{ 2, 0, 0, 0, 0, 1 };
const peer = udp.Endpoint{ .mac = .{ 2, 0, 0, 0, 0, 2 }, .ip = .{ 192, 0, 2, 2 }, .port = 44444 };
const range = @import("hosted_udp_lease.zig").PortRange{ .first = 49152, .last = 61439 };
fn ready() time.Exchange {
    var e: time.Exchange = .{};
    e.phase = .ready;
    e.deadline = 1000;
    e.station.phase = .done;
    e.station.connected = true;
    e.station.peer_chip = 13;
    e.station.version_known = true;
    e.station.version = .{ 3, 0, 10 };
    e.station.peer_rpc_version = 2;
    e.station.peer_sdio_buffer_blocks = .{ 7, 7 };
    e.station.peer_mode = 1;
    e.station.mac_address = local;
    e.addresses = .{ .generation = 7, .address = .{ .ip = 0xc0000201, .mask = 0xffffff00, .gateway = 0xc00002fe, .dns = 0xc00002fe } };
    e.clock.reset(7);
    return e;
}
const Stream = struct {
    writes: usize = 0,
    retired: bool = false,
    pub fn send(self: *@This(), data: []const u8) !usize {
        self.writes += 1;
        return data.len;
    }
    pub fn sendLong(_: *@This(), _: []const u8, _: *[1536]u8) !usize {
        return error.LongDisabled;
    }
    pub fn invalidate(self: *@This()) void {
        self.retired = true;
    }
};

test "time RPC keeps priority over a queued short UDP datagram" {
    var e = ready();
    var owner: shared.Shared = .{};
    const h = try owner.bind(&e.addresses, local, 49152, range);
    try owner.socket.sendTo(h, peer, "hello", e.station.sequence, 1, 100);
    e.station.sequence +%= 1;
    const request = try e.tx(2);
    try t.expect(request.len != 0);
    var stream: Stream = .{};
    const decoder: hosted.Decoder = .{};
    try t.expectEqual(shared.Send.pending, try owner.poll(h, &stream, &decoder, 2, true, true, true));
    try t.expectEqual(@as(usize, 0), stream.writes);
    const n = try stream.send(request);
    try e.sent(n, 3);
    try t.expectEqual(shared.Send.sent, try owner.poll(h, &stream, &decoder, 4, true, false, false));
    try t.expectEqual(@as(usize, 2), stream.writes);
}

test "time exchange processes UDP receive before socket copies it" {
    var e = ready();
    var owner: shared.Shared = .{};
    const h = try owner.bind(&e.addresses, local, 49152, range);
    const destination = owner.socket.sender.?.binding.local;
    var storage: [1512]u8 = undefined;
    const bytes = try packet.prepare(&storage, peer, destination, "reply", 1);
    var decoder: hosted.Decoder = .{};
    var decoded: ?hosted.Frame = null;
    for (bytes) |b| if (try decoder.push(b)) |f| {
        decoded = f;
    };
    try e.receive(decoded.?, 2);
    try t.expectEqual(shared.Receive.accepted, try owner.receiveProcessed(h, decoded.?));
    var out: [8]u8 = undefined;
    const result = (try owner.socket.read(h, &out)).?;
    try t.expectEqualStrings("reply", out[0..result.bytes]);
}

test "changed C6 address invalidates the queued UDP before send" {
    var e = ready();
    var owner: shared.Shared = .{};
    const h = try owner.bind(&e.addresses, local, 49152, range);
    try owner.socket.sendTo(h, peer, "hello", 1, 1, 100);
    var body_storage: [128]u8 = undefined;
    var body = hosted.Writer{ .out = &body_storage };
    try body.uint(2, 1);
    try body.uint(3, 1);
    try body.data(4, "192.0.2.3");
    try body.data(5, "255.255.255.0");
    try body.data(6, "192.0.2.254");
    try body.uint(7, 1);
    try body.data(8, "8.8.8.8");
    var rpc_storage: [400]u8 = undefined;
    const rpc = try hosted.request(&rpc_storage, 777, 1, body.slice());
    rpc_storage[13] = 3;
    @memcpy(rpc_storage[3..9], "RPCEvt");
    try t.expectError(error.Stale, e.receive(.{ .interface = 3, .payload = rpc }, 2));
    var stream: Stream = .{};
    const decoder: hosted.Decoder = .{};
    try t.expectError(error.StaleHandle, owner.poll(h, &stream, &decoder, 3, true, false, false));
    try t.expectEqual(@as(usize, 0), stream.writes);
    try t.expect(stream.retired);
}
