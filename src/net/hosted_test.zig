const std = @import("std");
const station = @import("hosted_station.zig");
const wire = station.wire;
const dhcp = station.dhcp;
const mac = [_]u8{ 2, 3, 4, 5, 6, 7 };

test "settings provider owns credentials and validates updates before replacing" {
    var config: station.Configuration = .{};
    var name = [_]u8{ 't', 'e', 's', 't' };
    try config.set(.{ .network = .{ .ssid = &name, .password = "temporary" } });
    @memset(&name, 0);
    try std.testing.expectEqualStrings("test", config.get().network.ssid);
    try std.testing.expectError(error.InvalidArgument, config.set(.{ .network = .{ .ssid = "", .password = "" } }));
    try std.testing.expectEqualStrings("test", config.get().network.ssid);
    try config.set(.disabled);
    try std.testing.expectEqual(station.Join.disabled, config.get());
    try std.testing.expect(std.mem.allEqual(u8, &config.password, 0));
}

test "unconfigured Hosted transport never initializes or joins Wi-Fi, even on old version timeout" {
    var client: station.Client = .{};
    client.begin(.disabled, 0);
    client.keep_serving = true;
    try client.receive(.{ .interface = 5, .payload = &.{ 0x22, 6, 0x12, 1, 13, 0x11, 1, 1 } }, 1);
    _ = try client.tx(1);
    client.sent(1);
    _ = try client.tx(2);
    try std.testing.expectEqual(@as(u32, 350), client.active_id.?);
    client.sent(2);
    try std.testing.expectEqual(@as(usize, 0), (try client.tx(5_000_002)).len);
    try std.testing.expectEqual(station.Phase.done, client.phase);
    try std.testing.expect(client.dhcp_client == null);
    try std.testing.expectEqual(@as(u8, 1), client.peer_capabilities);
    try std.testing.expectEqual(@as(usize, 0), (try client.tx(100_000_000)).len);
}

test "Hosted HCI type participates in checksum and survives stream decoding" {
    var out: [32]u8 = undefined;
    const bytes = try wire.typedFrame(&out, 4, 1, 4, &.{ 14, 4, 1, 3, 12, 0 });
    var decoder: wire.Decoder = .{};
    for (bytes) |b| if (try decoder.push(b)) |frame| {
        try std.testing.expectEqual(@as(u8, 4), frame.packet_type);
        try std.testing.expectEqual(@as(u8, 4), frame.interface);
        try std.testing.expectEqualSlices(u8, &.{ 14, 4, 1, 3, 12, 0 }, frame.payload);
    };
    out[11] = 1;
    decoder = .{};
    for (bytes[0 .. bytes.len - 1]) |b| _ = try decoder.push(b);
    try std.testing.expectError(error.Checksum, decoder.push(bytes[bytes.len - 1]));
}

test "Bluetooth feature RPC is correlated and failures do not prevent Wi-Fi setup" {
    var client: station.Client = .{};
    client.begin(.disabled, 0);
    client.peer_capabilities = 4;
    client.phase = .bt_init;
    client.deadline = 5_000_000;
    _ = try client.tx(0);
    try std.testing.expectEqual(@as(u32, 387), client.active_id.?);
    client.sent(0);
    var bytes: [128]u8 = undefined;
    try client.receive(.{ .interface = 3, .payload = try reply(&bytes, 2, 643, client.uid, &.{ 16, 1, 24, 1 }) }, 1);
    try std.testing.expectEqual(station.Phase.bt_enable, client.phase);
    _ = try client.tx(2);
    client.sent(2);
    try client.receive(.{ .interface = 3, .payload = try reply(&bytes, 2, 643, client.uid - 1, &.{ 16, 1, 24, 3 }) }, 3);
    try std.testing.expect(!client.bluetooth_ready);
    try client.receive(.{ .interface = 3, .payload = try reply(&bytes, 2, 643, client.uid, &.{ 16, 1, 24, 3 }) }, 4);
    try std.testing.expect(client.bluetooth_ready);
    try std.testing.expectEqual(station.Phase.done, client.phase);

    client.begin(.saved, 0);
    client.phase = .bt_init;
    client.deadline = 5_000_000;
    _ = try client.tx(0);
    client.sent(0);
    try client.receive(.{ .interface = 3, .payload = try reply(&bytes, 2, 643, client.uid, &.{ 8, 1 }) }, 1);
    try std.testing.expectEqual(station.Phase.init_wifi, client.phase);
    try std.testing.expect(client.bluetooth_setup_done and !client.bluetooth_ready);
    try std.testing.expectEqual(@as(u32, 1), client.bluetooth_status);
}

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
    var template = dhcp.Client{ .mac = client.mac, .xid = client.xid };
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

test "dual stack waits beyond IPv4 ACK and can also finish on IPv6-only networking" {
    const ip6 = station.ipv6;
    const peer_mac = [_]u8{ 2, 0xaa, 0xbb, 0xcc, 0xdd, 0xee };
    const router: ip6.Address = .{ 0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
    for ([_]bool{ true, false }) |use_ipv4| {
        var client: station.Client = .{};
        try boot(&client, .saved);
        client.ipv6_enabled = true;
        try connect(&client);
        _ = try client.tx(6);
        client.sent(6);
        if (use_ipv4) {
            var bytes: [342]u8 = undefined;
            try client.receive(.{ .interface = 1, .payload = try serverPacket(client.dhcp_client.?, 2, &bytes) }, 7);
            _ = try client.tx(8);
            client.sent(8);
            try client.receive(.{ .interface = 1, .payload = try serverPacket(client.dhcp_client.?, 5, &bytes) }, 9);
            try std.testing.expectEqual(station.Phase.lease, client.phase);
        }
        _ = try client.tx(1_000_000);
        client.sent(1_000_000); // MLD
        _ = try client.tx(1_000_000);
        client.sent(1_000_000); // DAD
        _ = try client.tx(2_000_000);
        client.sent(2_000_000); // RS
        try client.receive(.{ .interface = 1, .payload = @embedFile("fixtures/ipv6-ra.bin") }, 2_000_001);
        _ = try client.tx(2_000_002);
        client.sent(2_000_002); // SLAAC DAD
        const ping = try client.tx(3_000_002);
        try std.testing.expectEqual(@as(u8, 128), ping[12 + 54]);
        var message: [16]u8 = ping[12 + 54 ..][0..16].*;
        message[0] = 129;
        client.sent(3_000_002);
        var response: [128]u8 = undefined;
        try client.receive(.{ .interface = 1, .payload = try ip6.packet(&response, peer_mac, mac, router, client.ipv6_client.?.ll, 64, &message, false) }, 3_000_003);
        try std.testing.expectEqual(station.Phase.done, client.phase);
        try std.testing.expect(client.ipv6_client.?.complete());
        try std.testing.expectEqual(use_ipv4, client.dhcp_client.?.lease != null);
    }
}

test "integrated Hosted owner responds after acquisition and retains unsent reply" {
    const ip6 = station.ipv6;
    const peer_mac = [_]u8{ 2, 0xaa, 0xbb, 0xcc, 0xdd, 0xee };
    var client: station.Client = .{};
    client.beginDual(.saved, 0, true);
    client.keep_serving = true;
    client.phase = .done;
    client.ipv6_client = ip6.Client.init(mac, 0);
    client.ipv6_client.?.ll_valid = true;
    client.ipv6_client.?.stage = .no_router;
    var bytes: [128]u8 = undefined;
    const request = try ip6.packet(&bytes, peer_mac, mac, ip6.linkLocal(peer_mac), ip6.linkLocal(mac), 64, &.{ 128, 0, 0, 0, 0x12, 0x34, 0, 1 }, false);
    try client.receive(.{ .interface = 1, .payload = request }, 20_000_000);
    const packet = try client.tx(20_000_001);
    var retained: [512]u8 = undefined;
    @memcpy(retained[0..packet.len], packet);
    try std.testing.expectEqual(@as(u8, 129), packet[12 + 54]);
    try std.testing.expectEqualSlices(u8, retained[0..packet.len], try client.tx(20_000_002));
    client.sent(20_000_003);
    try std.testing.expectEqual(@as(usize, 0), (try client.tx(20_000_004)).len);
    try std.testing.expectEqual(@as(u32, 1), client.ipv6_client.?.echo_requests);
    // The original finite probe retains its stop-at-acquisition behavior.
    client.keep_serving = false;
    try client.receive(.{ .interface = 1, .payload = request }, 20_000_005);
    try std.testing.expectEqual(@as(u32, 1), client.ipv6_client.?.echo_requests);
    // A disconnect must revoke the integrated owner's addresses as well.
    var detail_buf: [32]u8 = undefined;
    var detail = wire.Writer{ .out = &detail_buf };
    try detail.uint(4, 201);
    var body_buf: [64]u8 = undefined;
    var body = wire.Writer{ .out = &body_buf };
    try body.data(2, detail.slice());
    var event: [128]u8 = undefined;
    try std.testing.expectError(error.Disconnected, client.receive(.{ .interface = 3, .payload = try reply(&event, 3, 776, 1, body.slice()) }, 20_000_006));
    try std.testing.expect(client.ipv6_client == null and client.dhcp_client == null);
    try std.testing.expectError(error.Rejected, client.tx(20_000_007));
}

fn dhcpNumber(packet: []u8, code: u8, value: u32) void {
    var pos: usize = 42 + 240;
    while (packet[pos] != 255) {
        if (packet[pos] == code) {
            dhcp.put32(packet[pos + 2 ..], value);
            return;
        }
        pos += 2 + packet[pos + 1];
    }
    packet[pos] = code;
    packet[pos + 1] = 4;
    dhcp.put32(packet[pos + 2 ..], value);
    packet[pos + 6] = 255;
}
fn shortLease() !dhcp.Client {
    var v4 = dhcp.Client{ .mac = mac, .xid = 0x1234 };
    var packet: [342]u8 = undefined;
    try v4.receiveAt(try serverPacket(v4, 2, &packet), 10);
    _ = try v4.packet(&packet);
    v4.sent(20);
    _ = try serverPacket(v4, 5, &packet);
    @memcpy(packet[6..12], &[_]u8{ 2, 0xaa, 0xbb, 0xcc, 0xdd, 0xee });
    dhcpNumber(&packet, 51, 12);
    dhcpNumber(&packet, 58, 3);
    dhcpNumber(&packet, 59, 9);
    try v4.receiveAt(&packet, 30);
    return v4;
}
fn hasDhcpOption(packet: []const u8, code: u8) bool {
    var pos: usize = 42 + 240;
    while (packet[pos] != 255) {
        if (packet[pos] == code) return true;
        pos += 2 + packet[pos + 1];
    }
    return false;
}
test "DHCP T1 unicast, T2 broadcast and ACK restart the lease clock with a new transaction" {
    var v4 = try shortLease();
    const old_xid = v4.xid;
    try std.testing.expectEqual(@as(u64, 3_000_020), v4.renew_at);
    try std.testing.expectEqual(@as(u64, 9_000_020), v4.rebind_at);
    try std.testing.expectEqual(@as(u64, 12_000_020), v4.expires_at);
    try v4.tick(v4.renew_at - 1);
    try std.testing.expectEqual(.bound, v4.phase);
    try v4.tick(v4.renew_at);
    try std.testing.expectEqual(.renewing, v4.phase);
    try std.testing.expect(v4.xid != old_xid);
    var packet: [342]u8 = undefined;
    const request = try v4.packet(&packet);
    try std.testing.expectEqualSlices(u8, &v4.server_mac, request[0..6]);
    try std.testing.expectEqual(v4.lease.?.ip, dhcp.get32(request[26..30]));
    try std.testing.expectEqual(v4.server, dhcp.get32(request[30..34]));
    try std.testing.expectEqual(v4.lease.?.ip, dhcp.get32(request[54..58]));
    try std.testing.expect(!hasDhcpOption(request, 50) and !hasDhcpOption(request, 54));
    try std.testing.expectEqual(@as(u16, 0), dhcp.checksum(request[14..34]));
    v4.sent(3_000_020);
    try std.testing.expect(!v4.due(3_000_021));
    _ = try serverPacket(v4, 5, &packet);
    dhcp.put32(packet[46..50], old_xid);
    try v4.receiveAt(&packet, 3_000_021);
    try std.testing.expectEqual(.renewing, v4.phase);
    try v4.tick(v4.rebind_at);
    const broadcast = try v4.packet(&packet);
    try std.testing.expectEqualSlices(u8, &@as([6]u8, @splat(255)), broadcast[0..6]);
    try std.testing.expectEqual(@as(u32, 0xffffffff), dhcp.get32(broadcast[30..34]));
    try std.testing.expect(!hasDhcpOption(broadcast, 50) and !hasDhcpOption(broadcast, 54));
    v4.sent(9_000_020);
    _ = try serverPacket(v4, 5, &packet);
    dhcpNumber(&packet, 54, 0xc0a80702); // Rebinding accepts a new server.
    try v4.receiveAt(&packet, 9_000_030);
    try std.testing.expectEqual(.bound, v4.phase);
    try std.testing.expectEqual(@as(u32, 1), v4.renewals);
    // Lifetime starts at the first REQUEST send, not delayed ACK reception.
    try std.testing.expectEqual(@as(u64, 3_603_000_020), v4.expires_at);
    try std.testing.expectEqual(@as(u32, 0xc0a80702), v4.server);
}
test "DHCP expiry and NAK revoke both families and discard a retained outgoing packet" {
    for ([_]bool{ false, true }) |nak| {
        var client: station.Client = .{};
        client.beginDual(.saved, 0, true);
        client.keep_serving = true;
        client.phase = .done;
        client.dhcp_client = try shortLease();
        client.ipv6_client = station.ipv6.Client.init(mac, 0);
        client.ipv6_client.?.ll_valid = true;
        client.ipv6_client.?.stage = .no_router;
        _ = try client.tx(3_000_020); // Queued renewal; not consumed yet.
        if (nak) {
            client.sent(3_000_020);
            var packet: [342]u8 = undefined;
            try std.testing.expectError(error.Rejected, client.receive(.{ .interface = 1, .payload = try serverPacket(client.dhcp_client.?, 6, &packet) }, 3_000_021));
        } else try std.testing.expectError(error.LeaseExpired, client.tx(12_000_020));
        try std.testing.expect(client.dhcp_client == null and client.ipv6_client == null);
        try std.testing.expectEqual(@as(usize, 0), client.output_len);
    }
}
test "leased IPv4 ARP response cannot acknowledge an unsent renewal or survive expiry" {
    var v4 = try shortLease();
    v4.requestRenewal(100);
    var packet: [342]u8 = undefined;
    _ = try v4.packet(&packet); // DHCP selected before ARP arrives.
    var arp: [42]u8 = @splat(0);
    @memset(arp[0..6], 255);
    @memcpy(arp[6..12], &[_]u8{ 2, 0xaa, 0xbb, 0xcc, 0xdd, 0xee });
    dhcp.put16(arp[12..14], 0x0806);
    dhcp.put16(arp[14..16], 1);
    dhcp.put16(arp[16..18], 0x0800);
    arp[18] = 6;
    arp[19] = 4;
    dhcp.put16(arp[20..22], 1);
    @memcpy(arp[22..28], arp[6..12]);
    dhcp.put32(arp[28..32], 0xc0a80701);
    dhcp.put32(arp[38..42], v4.lease.?.ip);
    try v4.receiveAt(&arp, 101);
    v4.sent(102); // This was DHCP, not the later ARP request.
    try std.testing.expectEqual(@as(?u64, 102), v4.last_sent);
    const response = try v4.packet(&packet);
    try std.testing.expectEqual(@as(usize, 42), response.len);
    try std.testing.expectEqual(@as(u16, 2), dhcp.get16(response[20..22]));
    try std.testing.expectEqual(v4.lease.?.ip, dhcp.get32(response[28..32]));
    v4.sent(103);
    try std.testing.expectEqual(@as(?u64, 102), v4.last_sent);
    try std.testing.expect(!v4.arp_pending);
    try v4.receiveAt(&arp, 104);
    try std.testing.expectError(error.LeaseExpired, v4.tick(v4.expires_at));
    try std.testing.expect(!v4.arp_pending and v4.lease == null);
}
test "invalid DHCP T1 T2 leave the previous lease and expiration unchanged" {
    var v4 = try shortLease();
    v4.requestRenewal(100);
    var packet: [342]u8 = undefined;
    _ = try v4.packet(&packet);
    v4.sent(101);
    _ = try serverPacket(v4, 5, &packet);
    dhcpNumber(&packet, 58, 9);
    dhcpNumber(&packet, 59, 3);
    const expiry = v4.expires_at;
    try std.testing.expectError(error.InvalidLease, v4.receiveAt(&packet, 102));
    try std.testing.expectEqual(expiry, v4.expires_at);
    try std.testing.expectEqual(.renewing, v4.phase);
}

test "a retained T1 unicast is replaced at T2 and only the selected server renews" {
    var client: station.Client = .{};
    client.begin(.saved, 0);
    client.keep_serving = true;
    client.phase = .done;
    client.dhcp_client = try shortLease();
    const unicast_request = try client.tx(3_000_020);
    try std.testing.expectEqual(@as(u32, 0xc0a80701), dhcp.get32(unicast_request[12 + 30 ..]));
    const broadcast_request = try client.tx(9_000_020); // No credit for the old packet.
    try std.testing.expectEqual(@as(u32, 0xffffffff), dhcp.get32(broadcast_request[12 + 30 ..]));
    var v4 = try shortLease();
    v4.requestRenewal(100);
    var packet: [342]u8 = undefined;
    _ = try v4.packet(&packet);
    v4.sent(101);
    _ = try serverPacket(v4, 5, &packet);
    dhcpNumber(&packet, 54, 0xc0a80702);
    try v4.receiveAt(&packet, 102);
    try std.testing.expectEqual(.renewing, v4.phase);
    dhcpNumber(&packet, 54, 0xc0a80701);
    try v4.receiveAt(&packet, 103);
    try std.testing.expectEqual(.bound, v4.phase);
    try std.testing.expectEqual(@as(u64, 3_600_000_101), v4.expires_at);
}
