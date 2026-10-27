const std = @import("std");
const station = @import("hosted_station.zig");
const wire = station.wire;
const dhcp = station.dhcp;
const mac = [_]u8{ 2, 3, 4, 5, 6, 7 };

fn reply(out: []u8, kind: u8, id: u32, uid: u32, body: []const u8) ![]const u8 {
    const result = try wire.request(out, id, uid, body);
    // Same envelope encoding, but the peer sends a response/event.
    out[13] = kind;
    if (kind == 3) @memcpy(out[3..9], "RPCEvt");
    return result;
}
fn boot(client: *station.Client, join: station.Join) !void {
    client.begin(join, 0);
    try client.receive(.{ .interface = 5, .payload = &.{ 0x22, 3, 0x12, 1, 13 } }, 1);
    const cap = try client.tx(1);
    try std.testing.expectEqual(@as(u8, 5), cap[0]);
    client.sent(1);
    const ids = [_]u32{ 350, 278, 313, 260, 280, 270, 257 };
    for (ids) |id| {
        const request = try client.tx(2);
        try std.testing.expect(request.len <= 512);
        try std.testing.expectEqual(id, client.active_id.?);
        // Decode the request body without the response-only outer validator.
        var reader = wire.Reader{ .bytes = request[24..] };
        while (try reader.next()) |field| if (field.number == id and id == 313) {
            try std.testing.expectEqual(@as(u32, 1), try wire.integer(field.bytes.?, 1));
        };
        client.sent(2);
        var body_buffer: [32]u8 = undefined;
        var body = wire.Writer{ .out = &body_buffer };
        if (id == 257) try body.data(1, &mac);
        if (id == 350) {
            try body.uint(2, 1);
            try body.uint(3, 4);
            try body.uint(4, 1);
        }
        var payload: [128]u8 = undefined;
        try client.receive(.{ .interface = 3, .payload = try reply(&payload, 2, id + 256, client.uid, body.slice()) }, 3);
    }
}
fn connect(client: *station.Client) !void {
    _ = try client.tx(4);
    try std.testing.expectEqual(@as(u32, 282), client.active_id.?);
    client.sent(4);
    var payload: [128]u8 = undefined;
    // The association event may precede its RPC response.
    try client.receive(.{ .interface = 3, .payload = try reply(&payload, 3, 775, 77, &.{}) }, 5);
    try client.receive(.{ .interface = 3, .payload = try reply(&payload, 2, 538, client.uid, &.{}) }, 5);
}
fn serverPacket(client: dhcp.Client, kind: u8, out: []u8) ![]const u8 {
    const template = dhcp.Client{ .mac = client.mac, .xid = client.xid };
    _ = try template.packet(out);
    @memcpy(out[0..6], &client.mac);
    dhcp.put32(out[26..30], 0xc0a80701);
    dhcp.put16(out[24..26], 0);
    dhcp.put16(out[24..26], dhcp.checksum(out[14..34]));
    dhcp.put16(out[34..36], 67);
    dhcp.put16(out[36..38], 68);
    const bp = out[42..342];
    bp[0] = 2;
    dhcp.put32(bp[16..20], 0xc0a8070c);
    @memset(bp[240..], 0);
    var pos: usize = 240;
    bp[pos] = 53;
    bp[pos + 1] = 1;
    bp[pos + 2] = kind;
    pos += 3;
    for ([_]u8{ 54, 1, 3, 51 }, [_]u32{ 0xc0a80701, 0xffffff00, 0xc0a80701, 3600 }) |code, value| {
        bp[pos] = code;
        bp[pos + 1] = 4;
        dhcp.put32(bp[pos + 2 ..], value);
        pos += 6;
    }
    bp[pos] = 255;
    return out[0..342];
}

test "factory Hosted sequence and full DHCP exchange require matching ACK" {
    var client: station.Client = .{};
    try boot(&client, .saved);
    try connect(&client);
    const discover = try client.tx(6);
    try std.testing.expectEqual(@as(u8, 1), discover[0]);
    try std.testing.expectEqual(station.Phase.lease, client.phase);
    try std.testing.expectEqual(@as(u8, 1), discover[12 + 42 + 242]);
    client.sent(6);
    var bytes: [342]u8 = undefined;
    try client.receive(.{ .interface = 1, .payload = try serverPacket(client.dhcp_client.?, 2, &bytes) }, 7);
    try std.testing.expect(client.dhcp_client.?.lease == null);
    const request = try client.tx(8);
    try std.testing.expectEqual(@as(u8, 3), request[12 + 42 + 242]);
    client.sent(8);
    try client.receive(.{ .interface = 1, .payload = try serverPacket(client.dhcp_client.?, 5, &bytes) }, 9);
    try std.testing.expectEqual(station.Phase.done, client.phase);
    try std.testing.expectEqual(@as(u32, 0xc0a8070c), client.dhcp_client.?.lease.?.ip);
    try std.testing.expectEqual(@as(u32, 3600), client.dhcp_client.?.lease.?.seconds);
}

test "Hosted stream handles every byte boundary and rejects corruption and fragmentation" {
    var buffer: [128]u8 = undefined;
    const encoded = try wire.frame(&buffer, 5, 3, &wire.capabilities);
    var decoder: wire.Decoder = .{};
    for (0..3) |_| {
        for (encoded, 0..) |byte, i| {
            const item = try decoder.push(byte);
            if (i + 1 == encoded.len) try std.testing.expectEqualSlices(u8, &wire.capabilities, item.?.payload) else try std.testing.expect(item == null);
        }
    }
    buffer[encoded.len - 1] ^= 1;
    for (buffer[0 .. encoded.len - 1]) |byte| _ = try decoder.push(byte);
    try std.testing.expectError(error.Checksum, decoder.push(buffer[encoded.len - 1]));
    try std.testing.expectError(error.Malformed, decoder.push(0));
    decoder = .{};
    buffer[1] = 1;
    for (buffer[0..11]) |byte| _ = try decoder.push(byte);
    try std.testing.expectError(error.Fragmented, decoder.push(buffer[11]));
}

test "RPC rejects malformed TLV lengths and correlates UID and message ID" {
    var client: station.Client = .{};
    try boot(&client, .saved);
    _ = try client.tx(4);
    client.sent(4);
    var buffer: [128]u8 = undefined;
    const stale = try reply(&buffer, 2, 538, client.uid - 1, &.{});
    try client.receive(.{ .interface = 3, .payload = stale }, 5);
    try std.testing.expectEqual(station.Phase.connect, client.phase);
    try std.testing.expectEqual(@as(u32, 1), client.ignored_rpcs);
    const malformed = try reply(&buffer, 2, 538, client.uid, &.{});
    buffer[10] += 1;
    try std.testing.expectError(error.Malformed, wire.rpc(malformed));
    var reader = wire.Reader{ .bytes = &.{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 2 } };
    try std.testing.expectError(error.Malformed, reader.next());
    const rejected = try reply(&buffer, 2, 538, client.uid, &.{ 8, 1 });
    try std.testing.expectError(error.Rejected, client.receive(.{ .interface = 3, .payload = rejected }, 5));
    try std.testing.expectEqual(station.Phase.failed, client.phase);
}

test "explicit AP configuration is escaped by protobuf and stays in RAM storage" {
    var client: station.Client = .{};
    const ssid = "教室,\"\\";
    try boot(&client, .{ .network = .{ .ssid = ssid, .password = "test-secret" } });
    const request = try client.tx(4);
    try std.testing.expectEqual(@as(u32, 284), client.active_id.?);
    var reader = wire.Reader{ .bytes = request[24..] };
    var body: ?[]const u8 = null;
    while (try reader.next()) |field| if (field.number == 284) {
        body = field.bytes;
    };
    const cfg = (try wire.data(body.?, 2)).?;
    const sta = (try wire.data(cfg, 2)).?;
    try std.testing.expectEqualStrings(ssid, (try wire.data(sta, 1)).?);
    try std.testing.expect(try wire.data(sta, 9) != null);
    try std.testing.expect(try wire.data(sta, 10) != null);
    const count = request.len;
    client.sent(4);
    try std.testing.expect(std.mem.allEqual(u8, client.output[0..count], 0));
}

test "DHCP ignores wrong xid MAC and server, rejects truncated options, NAK revokes acquisition" {
    var client = dhcp.Client{ .mac = mac, .xid = 0x12345678 };
    var packet: [342]u8 = undefined;
    _ = try serverPacket(client, 2, &packet);
    packet[46] ^= 1;
    try client.receive(&packet);
    try std.testing.expectEqual(.discover, client.phase);
    _ = try serverPacket(client, 2, &packet);
    packet[70] ^= 1;
    try client.receive(&packet);
    try std.testing.expectEqual(.discover, client.phase);
    _ = try serverPacket(client, 2, &packet);
    packet[42 + 244] = 250;
    try std.testing.expectError(error.Malformed, client.receive(&packet));
    try client.receive(try serverPacket(client, 2, &packet));
    _ = try serverPacket(client, 5, &packet);
    dhcp.put32(packet[42 + 245 ..], 0xc0a80702);
    try client.receive(&packet);
    try std.testing.expect(client.lease == null);
    try std.testing.expectError(error.Rejected, client.receive(try serverPacket(client, 6, &packet)));
    try std.testing.expectEqual(.failed, client.phase);
}

test "disconnect after lease revokes success, and bounded deadlines stop a silent peer" {
    var client: station.Client = .{};
    try boot(&client, .saved);
    try connect(&client);
    _ = try client.tx(6);
    client.sent(6);
    var packet: [342]u8 = undefined;
    try client.receive(.{ .interface = 1, .payload = try serverPacket(client.dhcp_client.?, 2, &packet) }, 7);
    _ = try client.tx(8);
    client.sent(8);
    try client.receive(.{ .interface = 1, .payload = try serverPacket(client.dhcp_client.?, 5, &packet) }, 9);
    var payload: [128]u8 = undefined;
    const event = try reply(&payload, 3, 776, 55, &.{ 18, 3, 32, 201, 1 });
    try std.testing.expectError(error.Disconnected, client.receive(.{ .interface = 3, .payload = event }, 10));
    try std.testing.expect(client.dhcp_client == null);
    try std.testing.expectEqual(@as(u32, 201), client.disconnect_reason);
    client.begin(.saved, 0);
    try std.testing.expectError(error.Timeout, client.tx(5_000_001));
}

test "independent Scapy fixtures validate UDP checksums and actual Offer ACK framing" {
    var client = dhcp.Client{ .mac = mac, .xid = 0x12345678 };
    try client.receive(@embedFile("fixtures/dhcp-offer.bin"));
    try std.testing.expectEqual(.request, client.phase);
    const ack = @embedFile("fixtures/dhcp-ack.bin");
    var corrupt: [ack.len]u8 = ack.*;
    corrupt[corrupt.len - 2] ^= 1;
    try std.testing.expectError(error.Malformed, client.receive(&corrupt));
    try std.testing.expect(client.lease == null);
    try client.receive(ack);
    try std.testing.expectEqual(@as(u32, 0xc000020c), client.lease.?.ip);
    try std.testing.expectEqual(@as(u32, 0xc0000201), client.lease.?.gateway);
    try std.testing.expectEqual(@as(u32, 3600), client.lease.?.seconds);
}

test "INIT identity and SDIO mode are checked before any RPC" {
    var client: station.Client = .{};
    client.begin(.saved, 0);
    try std.testing.expectError(error.Malformed, client.receive(.{ .interface = 5, .payload = &.{ 0x22, 3, 0x12, 1, 2 } }, 1));
    client.begin(.saved, 0);
    try std.testing.expectError(error.Malformed, client.receive(.{ .interface = 5, .payload = &.{ 0x22, 6, 0x12, 1, 13, 0x18, 1, 0 } }, 1));
    client.begin(.saved, 0);
    try client.receive(.{ .interface = 5, .payload = &.{ 0x22, 6, 0x12, 1, 13, 0x18, 1, 1 } }, 1);
    try std.testing.expectEqual(@as(u32, 13), client.peer_chip);
    try std.testing.expectEqual(@as(u32, 1), client.peer_mode);
    try std.testing.expect(client.active_id == null);
}
