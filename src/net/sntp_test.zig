const std = @import("std");
const sntp = @import("sntp.zig");
const ip = @import("dhcp.zig");
const mac: [6]u8 = .{ 2, 3, 4, 5, 6, 7 };
const peer: [6]u8 = .{ 2, 8, 9, 10, 11, 12 };
const lease = ip.Lease{ .ip = 0xc0a80164, .mask = 0xffffff00, .gateway = 0xc0a80101, .dns = 0xc0a80101, .server = 0xc0a80101, .seconds = 3600 };
fn datagram(client: *const sntp.Client, payload: []const u8, out: []u8) []const u8 {
    const bytes = out[0 .. 42 + payload.len];
    @memset(bytes, 0);
    @memcpy(bytes[0..6], &mac);
    @memcpy(bytes[6..12], &peer);
    ip.put16(bytes[12..14], 0x0800);
    const header = bytes[14..34];
    header[0] = 0x45;
    header[8] = 64;
    header[9] = 17;
    ip.put16(header[2..4], @intCast(28 + payload.len));
    ip.put32(header[12..16], client.target);
    ip.put32(header[16..20], lease.ip);
    ip.put16(header[10..12], ip.checksum(header));
    ip.put16(bytes[34..36], if (client.phase == .dns) 53 else 123);
    ip.put16(bytes[36..38], client.port);
    ip.put16(bytes[38..40], @intCast(8 + payload.len));
    @memcpy(bytes[42..], payload);
    return bytes;
}
fn atDns() !sntp.Client {
    var client: sntp.Client = .{};
    client.bind(mac, lease, 0);
    const arp = client.tx(0);
    try std.testing.expectEqual(@as(u16, 0x0806), ip.get16(arp[12..14]));
    var reply: [42]u8 = arp[0..42].*;
    @memcpy(reply[0..6], &mac);
    @memcpy(reply[6..12], &peer);
    ip.put16(reply[20..22], 2);
    @memcpy(reply[22..28], &peer);
    ip.put32(reply[28..32], lease.gateway);
    @memcpy(reply[32..38], &mac);
    ip.put32(reply[38..42], lease.ip);
    client.sent(1);
    client.receive(&reply, 10);
    return client;
}
fn atNtp() !sntp.Client {
    var client = try atDns();
    const query = client.tx(10);
    try std.testing.expectEqual(@as(u16, 53), ip.get16(query[36..38]));
    var dns: [80]u8 = @splat(0);
    const query_payload = query[42..];
    @memcpy(dns[0..query_payload.len], query_payload);
    ip.put16(dns[2..4], 0x8180);
    ip.put16(dns[6..8], 1);
    const p = query_payload.len;
    dns[p] = 0xc0;
    dns[p + 1] = 12;
    ip.put16(dns[p + 2 ..][0..2], 1);
    ip.put16(dns[p + 4 ..][0..2], 1);
    ip.put32(dns[p + 6 ..][0..4], 3600);
    ip.put16(dns[p + 10 ..][0..2], 4);
    ip.put32(dns[p + 12 ..][0..4], 0x85f3eea3);
    var packet: [128]u8 = @splat(0);
    client.sent(20);
    client.receive(datagram(&client, dns[0 .. p + 16], &packet), 30);
    try std.testing.expectEqual(sntp.Phase.ntp, client.phase);
    try std.testing.expectEqual(@as(u16, 123), ip.get16(client.tx(30)[36..38]));
    client.sent(40);
    return client;
}
fn timePacket(client: *const sntp.Client, unix_us: u64) [48]u8 {
    var bytes: [48]u8 = @splat(0);
    bytes[0] = 0x24;
    bytes[1] = 1;
    std.mem.writeInt(u64, bytes[24..32], client.token, .big);
    for ([_]usize{ 32, 40 }, [_]u64{ unix_us, unix_us + 1000 }) |start, stamp| {
        const seconds: u32 = @truncate(stamp / 1_000_000 + 2_208_988_800);
        const fraction: u32 = @intCast(((stamp % 1_000_000) << 32) / 1_000_000);
        ip.put32(bytes[start..][0..4], seconds);
        ip.put32(bytes[start + 4 ..][0..4], fraction);
    }
    return bytes;
}
test "DNS and routed SNTP response yield bounded UTC sample and six-hour rate limit" {
    var client = try atNtp();
    var bytes: [128]u8 = @splat(0);
    const stamp = 1_800_000_000_000_000;
    const reply = timePacket(&client, stamp);
    client.receive(datagram(&client, &reply, &bytes), 40_040);
    const sample = client.take(41_000).?;
    try std.testing.expect(sample.unix_us >= stamp + 20_000 and sample.unix_us <= stamp + 21_000);
    try std.testing.expectEqual(@as(u32, 40_000), sample.rtt_us);
    try std.testing.expect(client.take(41_001) == null);
    client.disconnect();
    client.bind(mac, lease, 1_000_000);
    try std.testing.expectEqual(@as(usize, 0), client.tx(1_000_000).len);
    try std.testing.expectEqual(@as(u32, 1), client.attempts);
}
test "unsolicited wrong-token wrong-port fragmented bad-checksum and unsynchronized replies cannot set time" {
    for (0..8) |kind| {
        var client = try atNtp();
        var bytes: [128]u8 = @splat(0);
        var reply = timePacket(&client, 1_800_000_000_000_000);
        if (kind == 0) reply[24] ^= 1;
        if (kind == 1) reply[0] |= 0xc0;
        if (kind == 2) reply[1] = 16;
        if (kind == 3) reply[0] = 0x23;
        const packet = datagram(&client, &reply, &bytes);
        if (kind == 4) bytes[36] ^= 1;
        if (kind == 5) bytes[20] = 0x20;
        if (kind == 6) bytes[40] = 1;
        if (kind == 7) client.disconnect();
        client.receive(packet, 40_040);
        try std.testing.expect(client.take(40_041) == null);
        try std.testing.expectEqual(@as(u32, 0), client.replies);
    }
}
test "2036 era rollover works and stale samples or server processing beyond RTT are rejected" {
    var client = try atNtp();
    var bytes: [128]u8 = @splat(0);
    const reply = timePacket(&client, 2_085_978_497_000_000);
    client.receive(datagram(&client, &reply, &bytes), 40_040);
    try std.testing.expectEqual(@as(u64, 2_085_978_497), client.take(41_000).?.unix_us / 1_000_000);
    client = try atNtp();
    client.receive(datagram(&client, &reply, &bytes), 40_040);
    try std.testing.expect(client.take(6_000_000) == null);
    client = try atNtp();
    client.receive(datagram(&client, &reply, &bytes), 41);
    try std.testing.expect(client.take(42) == null);
}
test "timeout and KoD preserve poll limits across disconnect and DENY prevents retry" {
    var client = try atNtp();
    _ = client.tx(6_000_000);
    client.disconnect();
    client.bind(mac, lease, 6_000_001);
    try std.testing.expectEqual(@as(usize, 0), client.tx(10_000_000).len);
    var bytes: [128]u8 = @splat(0);
    client = try atNtp();
    var reply = timePacket(&client, 1_800_000_000_000_000);
    reply[1] = 0;
    reply[2] = 10;
    @memcpy(reply[12..16], "RATE");
    client.receive(datagram(&client, &reply, &bytes), 40_040);
    try std.testing.expect(client.next_allowed >= 1_024_000_000);
    client.disconnect();
    client.bind(mac, lease, 50_000);
    try std.testing.expectEqual(@as(usize, 0), client.tx(60_000_000).len);
    client = try atNtp();
    std.mem.writeInt(u64, reply[24..32], client.token, .big);
    @memcpy(reply[12..16], "DENY");
    client.receive(datagram(&client, &reply, &bytes), 40_040);
    client.disconnect();
    client.bind(mac, lease, 80_000);
    try std.testing.expectEqual(sntp.Phase.disabled, client.phase);
    try std.testing.expectEqual(@as(usize, 0), client.tx(10_000_000_000).len);
}
test "blocked packets remain byte-identical until accepted and no lease means no network traffic" {
    var client: sntp.Client = .{};
    try std.testing.expectEqual(@as(usize, 0), client.tx(0).len);
    client.bind(mac, lease, 0);
    const first: [42]u8 = client.tx(0)[0..42].*;
    try std.testing.expectEqualSlices(u8, &first, client.tx(1000));
    try std.testing.expectEqual(@as(u32, 0), client.attempts);
    client.disconnect();
    try std.testing.expectEqual(@as(usize, 0), client.tx(2000).len);
}

test "DNS rejects truncation, wrong question/id/owner, compression cycles and non-unicast answers" {
    for (0..10) |kind| {
        var client = try atDns();
        const query = client.tx(10)[42..];
        var reply: [80]u8 = @splat(0);
        @memcpy(reply[0..query.len], query);
        ip.put16(reply[2..4], 0x8180);
        ip.put16(reply[6..8], 1);
        const p = query.len;
        reply[p] = 0xc0;
        reply[p + 1] = 12;
        ip.put16(reply[p + 2 ..][0..2], 1);
        ip.put16(reply[p + 4 ..][0..2], 1);
        ip.put16(reply[p + 10 ..][0..2], 4);
        ip.put32(reply[p + 12 ..][0..4], 0x85f3eea3);
        switch (kind) {
            0 => reply[0] ^= 1,
            1 => reply[2] |= 2,
            2 => reply[13] ^= 1,
            3 => reply[p + 1] = 0,
            4 => reply[p + 11] = 5,
            5 => reply[p + 5] = 2,
            6 => reply[p + 12] = 224,
            7 => reply[7] = 17,
            8 => reply[p + 1] = @intCast(p),
            9 => {},
            else => unreachable,
        }
        var packet: [128]u8 = @splat(0);
        client.sent(20);
        client.receive(datagram(&client, reply[0 .. p + 16 - @as(usize, @intFromBool(kind == 9))], &packet), 30);
        try std.testing.expectEqual(sntp.Phase.dns, client.phase);
        try std.testing.expectEqual(@as(u32, 0), client.server);
    }
}

test "a timeout invalidates a cached neighbor before retry" {
    var client = try atNtp();
    try std.testing.expect(client.peer[0] != 0);
    _ = client.tx(6_000_000);
    try std.testing.expectEqual(@as(u32, 0), client.neighbor);
    try std.testing.expect(std.mem.allEqual(u8, &client.peer, 0));
    const next = client.next_allowed;
    const packet = client.tx(next);
    try std.testing.expectEqual(@as(u16, 0x0806), ip.get16(packet[12..14]));
}
