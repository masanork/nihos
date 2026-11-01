//! One deterministic 1200-byte UDP payload for an explicit LAN test peer.
const std = @import("std");
pub const payload_bytes = 1200;
pub const ethernet_bytes = 14 + 20 + 8 + payload_bytes;
/// Compare the host-visible DMA staging bytes and zero padding after a write.
/// This does not observe SDIO wire data or the C6's copy.
pub fn stagingMatches(expected: []const u8, staging: []const u8) bool {
    if (expected.len == 0 or expected.len > staging.len) return false;
    if (!std.mem.eql(u8, expected, staging[0..expected.len])) return false;
    for (staging[expected.len..]) |byte| if (byte != 0) return false;
    return true;
}
pub fn sum(bytes: []const u8, seed: u32) u16 {
    var value = seed;
    var i: usize = 0;
    while (i + 1 < bytes.len) : (i += 2) value += std.mem.readInt(u16, bytes[i..][0..2], .big);
    if (i < bytes.len) value += @as(u32, bytes[i]) << 8;
    while (value >> 16 != 0) value = (value & 65535) + (value >> 16);
    return ~@as(u16, @intCast(value));
}
pub fn packet(out: *[ethernet_bytes]u8, mac: [6]u8, ip: u32, peer_mac: [6]u8, peer_ip: u32, port: u16) []const u8 {
    return sizedPacket(out, mac, ip, peer_mac, peer_ip, port, payload_bytes);
}
/// The ninth payload byte identifies a long-datagram attempt (1 through 32).
pub fn packetAttempt(out: *[ethernet_bytes]u8, mac: [6]u8, ip: u32, peer_mac: [6]u8, peer_ip: u32, port: u16, attempt: u8) []const u8 {
    std.debug.assert(attempt >= 1 and attempt <= 32);
    _ = packet(out, mac, ip, peer_mac, peer_ip, port);
    out[50] = attempt;
    out[40] = 0;
    out[41] = 0;
    const pseudo: u32 = @as(u32, @intCast(~sum(out[26..34], 0))) + 17 + 8 + payload_bytes;
    const checksum = sum(out[34..], pseudo);
    std.mem.writeInt(u16, out[40..42], if (checksum == 0) 0xffff else checksum, .big);
    return out;
}
pub fn sizedPacket(storage: *[ethernet_bytes]u8, mac: [6]u8, ip: u32, peer_mac: [6]u8, peer_ip: u32, port: u16, length: usize) []const u8 {
    std.debug.assert(length >= 8 and length <= payload_bytes);
    const out = storage[0 .. 42 + length];
    @memset(out, 0);
    @memcpy(out[0..6], &peer_mac);
    @memcpy(out[6..12], &mac);
    out[12] = 8;
    out[14] = 0x45;
    std.mem.writeInt(u16, out[16..18], @intCast(20 + 8 + length), .big);
    out[20] = 0x40; // DF: this diagnostic must fit one IPv4 packet.
    out[22] = 64;
    out[23] = 17;
    std.mem.writeInt(u32, out[26..30], ip, .big);
    std.mem.writeInt(u32, out[30..34], peer_ip, .big);
    std.mem.writeInt(u16, out[24..26], sum(out[14..34], 0), .big);
    std.mem.writeInt(u16, out[34..36], 44444, .big);
    std.mem.writeInt(u16, out[36..38], port, .big);
    std.mem.writeInt(u16, out[38..40], @intCast(8 + length), .big);
    for (out[42..], 0..) |*byte, i| byte.* = @truncate(i);
    @memcpy(out[42..50], "NIHOSUDP");
    const pseudo: u32 = @as(u32, @intCast(~sum(out[26..34], 0))) + 17 + 8 + @as(u32, @intCast(length));
    const checksum = sum(out[34..], pseudo);
    std.mem.writeInt(u16, out[40..42], if (checksum == 0) 0xffff else checksum, .big);
    return out;
}
pub fn hash(bytes: []const u8) u32 {
    var result: u32 = 2166136261;
    for (bytes) |byte| result = (result ^ byte) *% 16777619;
    return result;
}

pub const Echo = enum { none, short, long };
/// Validate an unfragmented Ethernet/IPv4 UDP echo from the configured peer.
pub fn matchEcho(frame: []const u8, mac: [6]u8, ip: u32, peer_mac: [6]u8, peer_ip: u32, peer_port: u16) Echo {
    if (frame.len < 42 or !std.mem.eql(u8, frame[0..6], &mac) or !std.mem.eql(u8, frame[6..12], &peer_mac) or
        std.mem.readInt(u16, frame[12..14], .big) != 0x0800 or frame[14] != 0x45 or frame[23] != 17) return .none;
    const total = std.mem.readInt(u16, frame[16..18], .big);
    if (total < 28 or @as(usize, total) + 14 > frame.len or std.mem.readInt(u16, frame[20..22], .big) & 0x3fff != 0 or
        sum(frame[14..34], 0) != 0 or std.mem.readInt(u32, frame[26..30], .big) != peer_ip or
        std.mem.readInt(u32, frame[30..34], .big) != ip) return .none;
    const length = std.mem.readInt(u16, frame[38..40], .big);
    if (length != total - 20 or std.mem.readInt(u16, frame[34..36], .big) != peer_port or
        std.mem.readInt(u16, frame[36..38], .big) != 44444) return .none;
    const udp = frame[34 .. 14 + total];
    if (std.mem.readInt(u16, frame[40..42], .big) != 0) {
        const pseudo: u32 = @as(u32, @intCast(~sum(frame[26..34], 0))) + 17 + length;
        if (sum(udp, pseudo) != 0) return .none;
    }
    const body = udp[8..];
    if (body.len != 64 and body.len != payload_bytes) return .none;
    if (!std.mem.eql(u8, body[0..8], "NIHOSUDP")) return .none;
    for (body[8..], 8..) |byte, i| {
        if (body.len == payload_bytes and i == 8) continue;
        if (byte != @as(u8, @truncate(i))) return .none;
    }
    return if (body.len == 64) .short else .long;
}
