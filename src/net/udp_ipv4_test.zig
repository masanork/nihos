const std = @import("std");
const wire = @import("udp_ipv4.zig");
const probe = @import("long_udp_probe.zig");
const hosted = @import("hosted.zig");
const tx_plan = @import("hosted_tx_plan.zig");
const hosted_udp = @import("hosted_udp_frame.zig");
const testing = std.testing;
const src = wire.Endpoint{ .mac = .{ 2, 0, 0, 0, 0, 1 }, .ip = .{ 192, 0, 2, 1 }, .port = 49152 };
const dst = wire.Endpoint{ .mac = .{ 2, 0, 0, 0, 0, 2 }, .ip = .{ 198, 51, 100, 2 }, .port = 443 };
const golden = [_]u8{ 0x02, 0, 0, 0, 0, 0x02, 0x02, 0, 0, 0, 0, 0x01, 0x08, 0x00, 0x45, 0, 0, 0x21, 0, 0, 0x40, 0, 0x40, 0x11, 0x4e, 0x95, 0xc0, 0x00, 0x02, 0x01, 0xc6, 0x33, 0x64, 0x02, 0xc0, 0x00, 0x01, 0xbb, 0x00, 0x0d, 0x0e, 0x0f, 0x68, 0x65, 0x6c, 0x6c, 0x6f };

test "golden odd-length datagram and ethernet padding" {
    var storage: [100]u8 = @splat(0);
    const frame = try wire.encode(&storage, src, dst, "hello");
    try testing.expectEqualSlices(u8, &golden, frame);
    const received = try wire.decode(&storage);
    try testing.expectEqualDeep(src, received.source);
    try testing.expectEqualDeep(dst, received.destination);
    try testing.expectEqualStrings("hello", received.payload);
}

test "size bounds and empty payload" {
    var frame: [wire.frame_header + wire.max_payload]u8 = undefined;
    var payload: [wire.max_payload + 1]u8 = @splat(0x5a);
    const largest = try wire.encode(&frame, src, dst, payload[0..wire.max_payload]);
    try testing.expectEqualSlices(u8, payload[0..wire.max_payload], (try wire.decode(largest)).payload);
    try testing.expectEqual(@as(usize, 0), (try wire.decode(try wire.encode(&frame, src, dst, ""))).payload.len);
    try testing.expectError(error.TooLarge, wire.encode(&frame, src, dst, &payload));
    try testing.expectError(error.NoSpace, wire.encode(frame[0..41], src, dst, ""));
    var invalid = src;
    invalid.port = 0;
    try testing.expectError(error.InvalidPort, wire.encode(&frame, invalid, dst, ""));
}

test "corruption, truncation, fragments and inconsistent lengths fail closed" {
    for (0..golden.len) |length| try testing.expectError(error.Truncated, wire.decode(golden[0..length]));
    var copy = golden;
    copy[46] ^= 1;
    try testing.expectError(error.Checksum, wire.decode(&copy));
    copy = golden;
    copy[22] ^= 1;
    try testing.expectError(error.Checksum, wire.decode(&copy));
    copy = golden;
    copy[20] |= 0x20; // More fragments.
    try testing.expectError(error.Unsupported, wire.decode(&copy));
    copy = golden;
    copy[21] = 1; // Nonzero fragment offset.
    try testing.expectError(error.Unsupported, wire.decode(&copy));
    copy = golden;
    copy[39] -= 1;
    try testing.expectError(error.Malformed, wire.decode(&copy));
    copy = golden;
    copy[14] = 0x46; // IPv4 options are outside this codec's scope.
    try testing.expectError(error.Unsupported, wire.decode(&copy));
}

test "IPv4 zero UDP checksum is accepted, nonzero bad checksum rejected" {
    var copy = golden;
    copy[40] = 0;
    copy[41] = 0;
    try testing.expectEqualStrings("hello", (try wire.decode(&copy)).payload);
    copy[41] = 1;
    try testing.expectError(error.Checksum, wire.decode(&copy));
}

test "a computed zero UDP checksum is transmitted as all ones" {
    var storage: [64]u8 = undefined;
    const frame = try wire.encode(&storage, src, dst, &.{ 0x51, 0xe7 });
    try testing.expectEqual(@as(u8, 0xff), frame[40]);
    try testing.expectEqual(@as(u8, 0xff), frame[41]);
    try testing.expectEqualSlices(u8, &.{ 0x51, 0xe7 }, (try wire.decode(frame)).payload);
}

test "decodes the existing 1200-byte Network Split diagnostic frame" {
    var storage: [probe.ethernet_bytes]u8 = undefined;
    const frame = probe.packetAttemptFrom(&storage, src.mac, 0xc0000201, src.port, dst.mac, 0xc6336402, dst.port, 3);
    const datagram = try wire.decode(frame);
    try testing.expectEqualDeep(src, datagram.source);
    try testing.expectEqualDeep(dst, datagram.destination);
    try testing.expectEqual(@as(usize, 1200), datagram.payload.len);
    try testing.expectEqualStrings("NIHOSUDP", datagram.payload[0..8]);
    try testing.expectEqual(@as(u8, 3), datagram.payload[8]);
}

test "Hosted framing limits UDP payload to 1458 bytes" {
    var packet: [1536]u8 = undefined;
    const payload: [wire.max_payload]u8 = @splat(0x5a);
    const limit = 1500 - wire.frame_header;
    const ethernet = try wire.encode(packet[12..], src, dst, payload[0..limit]);
    try testing.expectEqual(@as(usize, 1500), ethernet.len);
    const framed = try hosted.frameInPlace(&packet, hosted.station_interface, 1, ethernet.len);
    try testing.expectEqual(@as(usize, 1512), framed.len);
    const plan = try tx_plan.longPacket(framed.len);
    try testing.expectEqual(@as(usize, 1536), plan.wire);
    try testing.expectEqualSlices(u8, payload[0..limit], (try wire.decode(framed[12..])).payload);
    const too_long = try wire.encode(packet[12..], src, dst, payload[0 .. limit + 1]);
    try testing.expectError(error.Capacity, hosted.frameInPlace(&packet, hosted.station_interface, 1, too_long.len));
}

test "Hosted UDP preparation returns one complete frame and rejects oversize before writing" {
    var output: [1536]u8 = @splat(0xa5);
    const data: [hosted_udp.max_payload + 1]u8 = @splat(0x5a);
    const frame = try hosted_udp.prepare(&output, src, dst, data[0..hosted_udp.max_payload], 17);
    try testing.expectEqual(@as(usize, 1512), frame.len);
    try testing.expectEqual(@as(u16, 17), std.mem.readInt(u16, frame[8..10], .little));
    var decoder: hosted.Decoder = .{};
    var received: ?hosted.Frame = null;
    for (frame) |byte| if (try decoder.push(byte)) |f| {
        received = f;
    };
    const decoded = try wire.decode((received orelse return error.TestUnexpectedResult).payload);
    try testing.expectEqualSlices(u8, data[0..hosted_udp.max_payload], decoded.payload);
    @memset(&output, 0xa5);
    try testing.expectError(error.TooLarge, hosted_udp.prepare(&output, src, dst, &data, 17));
    try testing.expect(std.mem.allEqual(u8, &output, 0xa5));
    try testing.expectError(error.NoSpace, hosted_udp.prepare(output[0..53], src, dst, "", 17));
    try testing.expect(std.mem.allEqual(u8, &output, 0xa5));
}

test "Hosted receive filters destination but leaves source unauthenticated" {
    var buffer: [1536]u8 = undefined;
    const framed = try hosted_udp.prepare(&buffer, src, dst, "hello", 17);
    var decoder: hosted.Decoder = .{};
    var received: ?hosted.Frame = null;
    for (framed) |byte| if (try decoder.push(byte)) |f| {
        received = f;
    };
    const frame = received orelse return error.TestUnexpectedResult;
    const accepted = (try hosted_udp.receive(frame, dst)) orelse return error.TestUnexpectedResult;
    try testing.expectEqualDeep(src, accepted.source);
    try testing.expectEqualStrings("hello", accepted.payload);
    var wrong = dst;
    wrong.port += 1;
    try testing.expect((try hosted_udp.receive(frame, wrong)) == null);
    wrong = dst;
    wrong.ip[3] ^= 1;
    try testing.expect((try hosted_udp.receive(frame, wrong)) == null);
    wrong = dst;
    wrong.mac[5] ^= 1;
    try testing.expect((try hosted_udp.receive(frame, wrong)) == null);
    try testing.expect((try hosted_udp.receive(.{ .interface = 2, .payload = frame.payload }, dst)) == null);
    var corrupt = golden;
    corrupt[46] ^= 1;
    try testing.expectError(error.Checksum, hosted_udp.receive(.{ .interface = hosted.station_interface, .payload = &corrupt }, dst));
}
