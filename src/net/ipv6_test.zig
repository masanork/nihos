const std = @import("std");
const ip6 = @import("ipv6.zig");
const mac = [_]u8{ 2, 3, 4, 5, 6, 7 };
const peer_mac = [_]u8{ 2, 0xaa, 0xbb, 0xcc, 0xdd, 0xee };
const router: ip6.Address = .{ 0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
const ra = @embedFile("fixtures/ipv6-ra.bin");
fn linkReady(client: *ip6.Client) !void {
    _ = try client.tx(1_000_000);
    client.sent(1_000_000); // MLD join
    _ = try client.tx(1_000_000);
    client.sent(1_000_000); // DAD
    try std.testing.expect(!client.ll_valid);
    _ = try client.tx(1_500_000);
    try std.testing.expect(!client.ll_valid);
    const rs = try client.tx(2_000_000);
    try std.testing.expect(client.ll_valid);
    try std.testing.expectEqual(@as(u8, 133), rs[54]);
    client.sent(2_000_000);
}

test "IPv6 EUI64, MLD and DAD match independently generated Scapy packets" {
    var client = ip6.Client.init(mac, 0);
    try std.testing.expectEqualSlices(u8, @embedFile("fixtures/ipv6-mld.bin"), try client.tx(1_000_000));
    // Repeated reads with no transport progress must retain the same packet.
    try std.testing.expectEqualSlices(u8, @embedFile("fixtures/ipv6-mld.bin"), try client.tx(1_100_000));
    client.sent(1_100_000);
    try std.testing.expectEqualSlices(u8, @embedFile("fixtures/ipv6-dad.bin"), try client.tx(1_100_000));
    client.sent(1_100_000);
    _ = try client.tx(2_099_999);
    try std.testing.expect(!client.ll_valid);
    _ = try client.tx(2_100_000);
    try std.testing.expect(client.ll_valid);
}

test "valid RA, SLAAC DAD and exact Echo Reply complete the IPv6 probe" {
    var client = ip6.Client.init(mac, 0);
    try linkReady(&client);
    try client.receive(ra, 2_000_001);
    try std.testing.expectEqual(@as(u32, 1), client.ras);
    try std.testing.expect(!client.slaac_valid);
    const dad = try client.tx(2_000_002);
    try std.testing.expectEqual(@as(u8, 135), dad[54]);
    try std.testing.expectEqualSlices(u8, &ip6.zero, dad[22..38]);
    client.sent(2_000_002);
    const ping = try client.tx(3_000_002);
    try std.testing.expect(client.slaac_valid and client.ping_replies == 0);
    try std.testing.expectEqual(@as(u8, 128), ping[54]);
    var message: [16]u8 = ping[54..70].*;
    message[0] = 129;
    client.sent(3_000_002);
    var response: [128]u8 = undefined;
    message[15] ^= 1;
    try client.receive(try ip6.packet(&response, peer_mac, mac, router, client.ll, 64, &message, false), 3_000_003);
    try std.testing.expect(!client.complete());
    message[15] ^= 1;
    try client.receive(try ip6.packet(&response, peer_mac, mac, router, client.ll, 64, &message, false), 3_000_004);
    try std.testing.expect(client.complete());
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x20, 1, 0x0d, 0xb8, 0, 1, 0, 0 }, client.address[0..8]);
}

test "DAD rejects a real duplicate and ignores the reflected local DAD frame" {
    var client = ip6.Client.init(mac, 0);
    _ = try client.tx(1_000_000);
    client.sent(1_000_000);
    const own = try client.tx(1_000_000);
    try client.receive(own, 1_000_001);
    try std.testing.expectEqual(ip6.Stage.dad_link, client.stage);
    client.sent(1_000_001);
    try std.testing.expectError(error.Duplicate, client.receive(@embedFile("fixtures/ipv6-duplicate.bin"), 1_000_002));
    try std.testing.expect(!client.ll_valid and client.stage == .duplicate);
}

test "malformed RA checksum, hop limit, options and truncation cannot create an address" {
    for (0..ra.len) |length| {
        var client = ip6.Client.init(mac, 0);
        try linkReady(&client);
        client.receive(ra[0..length], 2_000_001) catch {};
        try std.testing.expect(ip6.equal(client.address, ip6.zero) and client.ras == 0);
    }
    var client = ip6.Client.init(mac, 0);
    try linkReady(&client);
    var corrupt: [ra.len]u8 = ra.*;
    corrupt[corrupt.len - 1] ^= 1;
    try std.testing.expectError(error.Checksum, client.receive(&corrupt, 2_000_001));
    corrupt = ra.*;
    corrupt[21] = 64;
    try std.testing.expectError(error.Malformed, client.receive(&corrupt, 2_000_001));
    var options: [56]u8 = ra[54..110].*;
    options[17] = 0;
    var frame: [128]u8 = undefined;
    try std.testing.expectError(error.Malformed, client.receive(try ip6.packet(&frame, peer_mac, ip6.multicastMac(ip6.all_nodes), router, ip6.all_nodes, 255, &options, false), 2_000_001));
    try std.testing.expect(ip6.equal(client.address, ip6.zero));
}

test "no router stays a distinct link-local-only result" {
    var client = ip6.Client.init(mac, 0);
    try linkReady(&client);
    _ = try client.tx(6_000_000);
    client.sent(6_000_000);
    _ = try client.tx(10_000_000);
    client.sent(10_000_000);
    _ = try client.tx(17_000_000);
    try std.testing.expect(client.finished() and client.stage == .no_router and client.ll_valid and !client.complete());
}

test "NS resolution and NA validation learn the router before ping" {
    var client = ip6.Client.init(mac, 0);
    try linkReady(&client);
    var message: [48]u8 = undefined;
    @memcpy(message[0..16], ra[54..70]);
    @memcpy(message[16..48], ra[78..110]); // RA without SLLA
    var frame: [128]u8 = undefined;
    try client.receive(try ip6.packet(&frame, peer_mac, ip6.multicastMac(ip6.all_nodes), router, ip6.all_nodes, 255, &message, false), 2_000_001);
    _ = try client.tx(2_000_002);
    client.sent(2_000_002);
    const ns = try client.tx(3_000_002);
    try std.testing.expectEqual(@as(u8, 135), ns[54]);
    client.sent(3_000_002);
    var na: [32]u8 = @splat(0);
    na[0] = 136;
    na[4] = 0x60;
    @memcpy(na[8..24], &router);
    na[24] = 2;
    na[25] = 1;
    @memcpy(na[26..32], &peer_mac);
    try std.testing.expectError(error.Malformed, client.receive(try ip6.packet(&frame, peer_mac, ip6.multicastMac(ip6.all_nodes), router, ip6.all_nodes, 255, &na, false), 3_000_003));
    try client.receive(try ip6.packet(&frame, peer_mac, mac, router, client.ll, 255, &na, false), 3_000_004);
    try std.testing.expectEqual(ip6.Stage.ping, client.stage);
    try std.testing.expectEqualSlices(u8, &peer_mac, &(client.router_mac.?));
}

test "preferred address answers DAD NS and Echo, tentative addresses never answer Echo" {
    var client = ip6.Client.init(mac, 0);
    try linkReady(&client);
    var ns: [24]u8 = @splat(0);
    ns[0] = 135;
    @memcpy(ns[8..24], &client.ll);
    var frame: [256]u8 = undefined;
    const dst = ip6.solicited(client.ll);
    try client.receive(try ip6.packet(&frame, peer_mac, ip6.multicastMac(dst), ip6.zero, dst, 255, &ns, false), 2_000_001);
    const na = try client.tx(2_000_002);
    try std.testing.expectEqual(@as(u8, 136), na[54]);
    try std.testing.expectEqual(@as(u8, 0x20), na[58]);
    client.sent(2_000_002);
    var echo: [16]u8 = @splat(0);
    echo[0] = 128;
    echo[8] = 0x5a;
    try client.receive(try ip6.packet(&frame, peer_mac, mac, router, client.ll, 64, &echo, false), 2_000_003);
    const reply = try client.tx(2_000_004);
    try std.testing.expectEqual(@as(u8, 129), reply[54]);
    try std.testing.expectEqual(@as(u8, 0x5a), reply[62]);
}

test "short Echo and unspecified destinations cannot produce a response" {
    var client = ip6.Client.init(mac, 0);
    try linkReady(&client);
    var frame: [128]u8 = undefined;
    try client.receive(try ip6.packet(&frame, peer_mac, mac, router, client.ll, 64, &.{ 128, 0, 0, 0 }, false), 2_000_001);
    try std.testing.expectEqual(@as(usize, 0), client.response_len);
    try std.testing.expectError(error.Malformed, client.receive(try ip6.packet(&frame, peer_mac, mac, router, ip6.zero, 64, &.{ 128, 0, 0, 0, 0, 0, 0, 0 }, false), 2_000_002));
    try std.testing.expectEqual(@as(usize, 0), client.response_len);
}
