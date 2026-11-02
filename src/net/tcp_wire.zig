//! Bounded IPv4/TCP wire codec. No connection or retransmission state.
//! Input begins at the IPv4 header; fragmented IPv4 datagrams are rejected.
const std = @import("std");
pub const Error = error{ Malformed, Fragmented, Checksum, Unsupported, BufferTooSmall };
pub const Flags = struct {
    pub const fin: u8 = 0x01;
    pub const syn: u8 = 0x02;
    pub const rst: u8 = 0x04;
    pub const psh: u8 = 0x08;
    pub const ack: u8 = 0x10;
};
pub const Segment = struct {
    src: [4]u8,
    dst: [4]u8,
    src_port: u16,
    dst_port: u16,
    seq: u32,
    ack: u32,
    flags: u8,
    window: u16,
    options: []const u8,
    payload: []const u8,
};

const Sum = struct {
    total: u64 = 0,
    odd: ?u8 = null,
    fn add(self: *Sum, bytes: []const u8) void {
        var i: usize = 0;
        if (self.odd) |previous| {
            if (bytes.len == 0) return;
            self.total += (@as(u16, previous) << 8) | bytes[0];
            self.odd = null;
            i = 1;
        }
        while (i + 1 < bytes.len) : (i += 2) self.total += (@as(u16, bytes[i]) << 8) | bytes[i + 1];
        if (i < bytes.len) self.odd = bytes[i];
    }
    fn finish(self: Sum) u16 {
        var value = self.total + if (self.odd) |b| @as(u64, b) << 8 else @as(u64, 0);
        while (value >> 16 != 0) value = (value & 0xffff) + (value >> 16);
        return ~@as(u16, @truncate(value));
    }
};
fn ipChecksum(bytes: []const u8) u16 {
    var sum = Sum{};
    sum.add(bytes);
    return sum.finish();
}
fn tcpChecksum(src: [4]u8, dst: [4]u8, bytes: []const u8) u16 {
    var sum = Sum{};
    sum.add(&src);
    sum.add(&dst);
    const length: u16 = @intCast(bytes.len);
    const trailer = [4]u8{ 0, 6, @truncate(length >> 8), @truncate(length) };
    sum.add(&trailer);
    sum.add(bytes);
    return sum.finish();
}

/// Input may include link padding beyond IPv4 total length; returned slices
/// borrow the input and never include that padding.
pub fn parse(packet: []const u8) Error!Segment {
    if (packet.len < 40 or packet[0] >> 4 != 4) return error.Malformed;
    const ip_len = @as(usize, packet[0] & 15) * 4;
    if (ip_len < 20 or ip_len > packet.len) return error.Malformed;
    const total = std.mem.readInt(u16, packet[2..4], .big);
    if (total < ip_len + 20 or total > packet.len) return error.Malformed;
    if (ipChecksum(packet[0..ip_len]) != 0) return error.Checksum;
    const fragment = std.mem.readInt(u16, packet[6..8], .big);
    if ((fragment & 0x3fff) != 0) return error.Fragmented;
    if (packet[9] != 6) return error.Unsupported;
    const src = packet[12..16].*;
    const dst = packet[16..20].*;
    const tcp = packet[ip_len..total];
    const header_len = @as(usize, tcp[12] >> 4) * 4;
    if (header_len < 20 or header_len > tcp.len or (tcp[12] & 0x0f) != 0) return error.Malformed;
    if (tcpChecksum(src, dst, tcp) != 0) return error.Checksum;
    return .{ .src = src, .dst = dst, .src_port = std.mem.readInt(u16, tcp[0..2], .big), .dst_port = std.mem.readInt(u16, tcp[2..4], .big), .seq = std.mem.readInt(u32, tcp[4..8], .big), .ack = std.mem.readInt(u32, tcp[8..12], .big), .flags = tcp[13], .window = std.mem.readInt(u16, tcp[14..16], .big), .options = tcp[20..header_len], .payload = tcp[header_len..] };
}

/// Generates an IPv4 packet without IP or TCP options; caller supplies IP ID,
/// ports, sequence numbers and payload from a connection state machine.
pub fn encode(out: []u8, segment: Segment, id: u16) Error![]const u8 {
    if (segment.options.len != 0 or segment.src_port == 0 or segment.dst_port == 0) return error.Unsupported;
    if (segment.payload.len > 65535 - 40 or out.len < 40 + segment.payload.len) return error.BufferTooSmall;
    const bytes = out[0 .. 40 + segment.payload.len];
    @memset(bytes, 0);
    bytes[0] = 0x45;
    std.mem.writeInt(u16, bytes[2..4], @intCast(bytes.len), .big);
    std.mem.writeInt(u16, bytes[4..6], id, .big);
    std.mem.writeInt(u16, bytes[6..8], 0x4000, .big); // do not fragment
    bytes[8] = 64;
    bytes[9] = 6;
    bytes[12..16].* = segment.src;
    bytes[16..20].* = segment.dst;
    std.mem.writeInt(u16, bytes[10..12], ipChecksum(bytes[0..20]), .big);
    const tcp = bytes[20..];
    std.mem.writeInt(u16, tcp[0..2], segment.src_port, .big);
    std.mem.writeInt(u16, tcp[2..4], segment.dst_port, .big);
    std.mem.writeInt(u32, tcp[4..8], segment.seq, .big);
    std.mem.writeInt(u32, tcp[8..12], segment.ack, .big);
    tcp[12] = 0x50;
    tcp[13] = segment.flags;
    std.mem.writeInt(u16, tcp[14..16], segment.window, .big);
    @memcpy(tcp[20..], segment.payload);
    std.mem.writeInt(u16, tcp[16..18], tcpChecksum(segment.src, segment.dst, tcp), .big);
    return bytes;
}

test "IPv4 TCP codec validates checksums, lengths and fragmentation" {
    var storage: [128]u8 = undefined;
    const original = Segment{ .src = .{ 192, 0, 2, 1 }, .dst = .{ 198, 51, 100, 2 }, .src_port = 49152, .dst_port = 22, .seq = 123, .ack = 456, .flags = Flags.ack | Flags.psh, .window = 4096, .options = "", .payload = "abc" };
    const bytes = try encode(&storage, original, 7);
    // Independently generated from the IPv4 and TCP pseudo-header checksum.
    const expected = [_]u8{ 0x45, 0x00, 0x00, 0x2b, 0x00, 0x07, 0x40, 0x00, 0x40, 0x06, 0x4e, 0x8f, 0xc0, 0x00, 0x02, 0x01, 0xc6, 0x33, 0x64, 0x02, 0xc0, 0x00, 0x00, 0x16, 0x00, 0x00, 0x00, 0x7b, 0x00, 0x00, 0x01, 0xc8, 0x50, 0x18, 0x10, 0x00, 0x2c, 0xd6, 0x00, 0x00, 0x61, 0x62, 0x63 };
    try std.testing.expectEqualSlices(u8, &expected, bytes);
    const parsed = try parse(bytes);
    try std.testing.expectEqual(original.seq, parsed.seq);
    try std.testing.expectEqualStrings(original.payload, parsed.payload);
    storage[bytes.len - 1] ^= 1;
    try std.testing.expectError(error.Checksum, parse(bytes));
    storage[bytes.len - 1] ^= 1;
    std.mem.writeInt(u16, storage[6..8], 0x2000, .big);
    storage[10] = 0;
    storage[11] = 0;
    std.mem.writeInt(u16, storage[10..12], ipChecksum(storage[0..20]), .big);
    try std.testing.expectError(error.Fragmented, parse(bytes));
    try std.testing.expectError(error.Malformed, parse(bytes[0..39]));
}
