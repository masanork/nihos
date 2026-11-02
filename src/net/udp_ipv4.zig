//! Bounded Ethernet/IPv4/UDP wire codec. No socket, routing, ARP or device I/O.
//! IPv4 options, fragmentation, VLANs and packets larger than the given MTU
//! are intentionally unsupported. Caller owns both input and output buffers.
const std = @import("std");

pub const mtu: usize = 1500;
pub const max_payload: usize = mtu - 20 - 8;
pub const frame_header: usize = 14 + 20 + 8;
pub const Error = error{ Truncated, Malformed, Unsupported, Checksum, TooLarge, NoSpace, InvalidPort };
pub const Endpoint = struct { mac: [6]u8, ip: [4]u8, port: u16 };
pub const Datagram = struct { source: Endpoint, destination: Endpoint, payload: []const u8 };

fn sumWords(bytes: []const u8, seed: u32) u32 {
    var sum = seed;
    var i: usize = 0;
    while (i + 1 < bytes.len) : (i += 2) sum += std.mem.readInt(u16, bytes[i..][0..2], .big);
    if (i < bytes.len) sum += @as(u32, bytes[i]) << 8;
    return sum;
}
fn checksum(bytes: []const u8, seed: u32) u16 {
    var sum = sumWords(bytes, seed);
    while (sum >> 16 != 0) sum = (sum & 0xffff) + (sum >> 16);
    return ~@as(u16, @intCast(sum));
}
fn pseudo(ip: []const u8, len: usize) u32 {
    return sumWords(ip[12..20], 0) + 17 + @as(u32, @intCast(len));
}

/// Produces one nonfragmented IPv4 datagram. `out` must not overlap payload.
pub fn encode(out: []u8, source: Endpoint, destination: Endpoint, payload: []const u8) Error![]const u8 {
    if (source.port == 0 or destination.port == 0) return error.InvalidPort;
    if (payload.len > max_payload) return error.TooLarge;
    const size = frame_header + payload.len;
    if (out.len < size) return error.NoSpace;
    const frame = out[0..size];
    @memset(frame[0..frame_header], 0);
    @memcpy(frame[0..6], &destination.mac);
    @memcpy(frame[6..12], &source.mac);
    std.mem.writeInt(u16, frame[12..14], 0x0800, .big);
    const ip = frame[14..34];
    ip[0] = 0x45;
    std.mem.writeInt(u16, ip[2..4], @intCast(28 + payload.len), .big);
    std.mem.writeInt(u16, ip[6..8], 0x4000, .big); // Do not fragment.
    ip[8] = 64;
    ip[9] = 17;
    @memcpy(ip[12..16], &source.ip);
    @memcpy(ip[16..20], &destination.ip);
    std.mem.writeInt(u16, ip[10..12], checksum(ip, 0), .big);
    const udp = frame[34..];
    std.mem.writeInt(u16, udp[0..2], source.port, .big);
    std.mem.writeInt(u16, udp[2..4], destination.port, .big);
    std.mem.writeInt(u16, udp[4..6], @intCast(udp.len), .big);
    @memcpy(udp[8..], payload);
    const value = checksum(udp, pseudo(ip, udp.len));
    std.mem.writeInt(u16, udp[6..8], if (value == 0) 0xffff else value, .big);
    return frame;
}

/// Returns a borrowed payload; the caller must retain the frame unchanged.
/// Ethernet padding is ignored; the IPv4 and UDP lengths must agree exactly.
pub fn decode(frame: []const u8) Error!Datagram {
    if (frame.len < frame_header) return error.Truncated;
    if (std.mem.readInt(u16, frame[12..14], .big) != 0x0800) return error.Unsupported;
    const ip = frame[14..];
    if (ip[0] != 0x45 or ip[9] != 17) return error.Unsupported;
    const total = std.mem.readInt(u16, ip[2..4], .big);
    if (total < 28) return error.Malformed;
    if (total > mtu) return error.TooLarge;
    if (total > ip.len) return error.Truncated;
    if (std.mem.readInt(u16, ip[6..8], .big) & 0xbfff != 0) return error.Unsupported;
    if (checksum(ip[0..20], 0) != 0) return error.Checksum;
    const udp = ip[20..total];
    if (std.mem.readInt(u16, udp[4..6], .big) != udp.len) return error.Malformed;
    const src_port = std.mem.readInt(u16, udp[0..2], .big);
    const dst_port = std.mem.readInt(u16, udp[2..4], .big);
    if (src_port == 0 or dst_port == 0) return error.InvalidPort;
    if (std.mem.readInt(u16, udp[6..8], .big) != 0 and checksum(udp, pseudo(ip, udp.len)) != 0) return error.Checksum;
    return .{
        .source = .{ .mac = frame[6..12].*, .ip = ip[12..16].*, .port = src_port },
        .destination = .{ .mac = frame[0..6].*, .ip = ip[16..20].*, .port = dst_port },
        .payload = udp[8..],
    };
}
