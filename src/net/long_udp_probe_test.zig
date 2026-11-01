const std = @import("std");
const udp = @import("long_udp_probe.zig");
const hosted = @import("hosted.zig");
const station = @import("hosted_station.zig");

test "staging audit catches corruption in payload and padding" {
    const packet = [_]u8{ 1, 2, 3 };
    var staging = [_]u8{ 1, 2, 3, 0, 0 };
    try std.testing.expect(udp.stagingMatches(&packet, &staging));
    staging[1] ^= 1;
    try std.testing.expect(!udp.stagingMatches(&packet, &staging));
    staging[1] ^= 1;
    staging[4] = 1;
    try std.testing.expect(!udp.stagingMatches(&packet, &staging));
    try std.testing.expect(!udp.stagingMatches(&packet, staging[0..2]));
}

test "diagnostic Ethernet uses the same Hosted interface as actual DHCP" {
    var client: station.Client = .{ .phase = .lease, .deadline = 1000, .dhcp_client = .{ .mac = .{ 2, 0, 0, 0, 0, 1 }, .xid = 1 } };
    const dhcp = try client.tx(0);
    try std.testing.expect(dhcp.len > 12);
    try std.testing.expectEqual(@as(u8, 1), dhcp[0]);
    var ethernet: [udp.ethernet_bytes]u8 = undefined;
    var encoded: [1254]u8 = undefined;
    for ([_]usize{ 64, 1200 }) |length| {
        const frame = udp.sizedPacket(&ethernet, .{ 2, 0, 0, 0, 0, 1 }, 0xc0000201, .{ 2, 0, 0, 0, 0, 2 }, 0xc0000202, 44444, length);
        const diagnostic = try hosted.frame(&encoded, hosted.station_interface, 0x7000, frame);
        try std.testing.expectEqual(dhcp[0], diagnostic[0]);
    }
}
test "1200 byte UDP fixture matches independent checksum oracle and Hosted framing" {
    var ethernet: [udp.ethernet_bytes]u8 = undefined;
    const bytes = udp.packet(&ethernet, .{ 2, 0, 0, 0, 0, 1 }, 0xc0000201, .{ 2, 0, 0, 0, 0, 2 }, 0xc0000202, 44444);
    // Values independently calculated with Python struct/network-order sums.
    try std.testing.expectEqual(@as(u16, 0xb21d), std.mem.readInt(u16, bytes[24..26], .big));
    try std.testing.expectEqual(@as(u16, 0xedb5), std.mem.readInt(u16, bytes[40..42], .big));
    try std.testing.expectEqual(@as(u32, 0x21b7f448), udp.hash(bytes));
    try std.testing.expectEqual(@as(usize, 1200), bytes[42..].len);
    try std.testing.expectEqualSlices(u8, "NIHOSUDP", bytes[42..50]);
    var out: [1254]u8 = undefined;
    const encoded = try hosted.frame(&out, 0, 0x7000, bytes);
    try std.testing.expectEqual(@as(usize, 1254), encoded.len);
    var decoder: hosted.Decoder = .{};
    var frames: usize = 0;
    for (encoded) |byte| if (try decoder.push(byte)) |frame| {
        frames += 1;
        try std.testing.expectEqualSlices(u8, bytes, frame.payload);
    };
    try std.testing.expectEqual(@as(usize, 1), frames);
}

test "64 byte control uses matching IP and UDP checksum" {
    var ethernet: [udp.ethernet_bytes]u8 = undefined;
    const bytes = udp.sizedPacket(&ethernet, .{ 2, 0, 0, 0, 0, 1 }, 0xc0000201, .{ 2, 0, 0, 0, 0, 2 }, 0xc0000202, 44444, 64);
    try std.testing.expectEqual(@as(usize, 106), bytes.len);
    try std.testing.expectEqual(@as(u16, 0xb68d), std.mem.readInt(u16, bytes[24..26], .big));
    try std.testing.expectEqual(@as(u16, 0x19ef), std.mem.readInt(u16, bytes[40..42], .big));
    try std.testing.expectEqualSlices(u8, "NIHOSUDP", bytes[42..50]);
}

test "echo validation accepts short and long peers and rejects corruption or wrong identity" {
    const local = [6]u8{ 2, 0, 0, 0, 0, 1 };
    const peer = [6]u8{ 2, 0, 0, 0, 0, 2 };
    var packet_buffer: [udp.ethernet_bytes]u8 = undefined;
    for ([_]usize{ 64, 1200 }) |length| {
        const packet = udp.sizedPacket(&packet_buffer, peer, 0xc0000202, local, 0xc0000201, 44444, length);
        try std.testing.expectEqual(if (length == 64) udp.Echo.short else .long, udp.matchEcho(packet, local, 0xc0000201, peer, 0xc0000202, 44444));
        try std.testing.expectEqual(udp.Echo.none, udp.matchEcho(packet[0 .. packet.len - 1], local, 0xc0000201, peer, 0xc0000202, 44444));
        try std.testing.expectEqual(udp.Echo.none, udp.matchEcho(packet, local, 0xc0000201, peer, 0xc0000203, 44444));
        packet_buffer[50] ^= 1;
        try std.testing.expectEqual(udp.Echo.none, udp.matchEcho(packet, local, 0xc0000201, peer, 0xc0000202, 44444));
    }
}

test "long attempt identifier changes only the tag and UDP checksum" {
    const local = [6]u8{ 2, 0, 0, 0, 0, 1 };
    const peer = [6]u8{ 2, 0, 0, 0, 0, 2 };
    var data: [udp.ethernet_bytes]u8 = undefined;
    for (1..33) |number| {
        const bytes = udp.packetAttempt(&data, peer, 0xc0000202, local, 0xc0000201, 44444, @intCast(number));
        try std.testing.expectEqual(@as(u8, @intCast(number)), bytes[50]);
        try std.testing.expectEqual(udp.Echo.long, udp.matchEcho(bytes, local, 0xc0000201, peer, 0xc0000202, 44444));
        try std.testing.expectEqual(@as(u16, 0), udp.sum(bytes[34..], @as(u32, @intCast(~udp.sum(bytes[26..34], 0))) + 17 + 1208));
    }
}
