const std = @import("std");
const split = @import("hosted_network_split.zig");
const probe = @import("hosted_split_udp_probe.zig");
const udp = @import("long_udp_probe.zig");

const local = [6]u8{ 2, 1, 2, 3, 4, 5 };
const peer = probe.Peer{ .ip = 0xc0a80127, .mac = .{ 2, 6, 7, 8, 9, 10 }, .port = 44444 };
fn ready() split.State {
    return .{ .generation = 7, .address = .{ .ip = 0xc0a80123, .mask = 0xffffff00, .gateway = 0xc0a80101, .dns = 0xc0a80101 } };
}

test "no usable address or local unicast peer is rejected" {
    var state = split.State{};
    try std.testing.expectError(error.NoAddress, probe.Session.open(&state, local, peer));
    state = ready();
    state.generation = 0;
    try std.testing.expectError(error.NoAddress, probe.Session.open(&state, local, peer));
    state = ready();
    const invalid = [_]probe.Peer{
        .{ .ip = 0xc0a80227, .mac = peer.mac, .port = peer.port },
        .{ .ip = 0xc0a801ff, .mac = peer.mac, .port = peer.port },
        .{ .ip = 0xc0a80100, .mac = peer.mac, .port = peer.port },
        .{ .ip = 0xc0a80123, .mac = peer.mac, .port = peer.port },
        .{ .ip = peer.ip, .mac = .{ 1, 0, 0, 0, 0, 0 }, .port = peer.port },
        .{ .ip = peer.ip, .mac = peer.mac, .port = 0 },
        .{ .ip = peer.ip, .mac = local, .port = peer.port },
    };
    for (invalid) |p| try std.testing.expectError(error.InvalidPeer, probe.Session.open(&state, local, p));
}

test "generation changes revoke prepared sends and received echoes" {
    var state = ready();
    const s = try probe.Session.open(&state, local, peer);
    var frame: [udp.ethernet_bytes]u8 = undefined;
    const packet = try s.prepare(&state, &frame, 1);
    try std.testing.expectEqual(udp.ethernet_bytes, packet.len);
    try std.testing.expectEqual(@as(u32, peer.ip), std.mem.readInt(u32, packet[30..34], .big));
    try std.testing.expectError(error.InvalidAttempt, s.prepare(&state, &frame, 0));
    try std.testing.expect(state.invalidate());
    try std.testing.expectError(error.Stale, s.check(&state));
    try std.testing.expectError(error.Stale, s.prepare(&state, &frame, 1));
    try std.testing.expectError(error.Stale, s.echo(&state, packet));
    state.address = ready().address;
    try std.testing.expectError(error.Stale, s.check(&state));
}

test "changed snapshot under same generation fails closed" {
    var state = ready();
    const s = try probe.Session.open(&state, local, peer);
    state.address.?.dns = 0x08080808;
    try std.testing.expectError(error.Stale, s.check(&state));
}

test "only current lease accepts the configured peer's echo" {
    var state = ready();
    const session = try probe.Session.open(&state, local, peer);
    var bytes: [udp.ethernet_bytes]u8 = undefined;
    const packet = udp.packetAttempt(&bytes, peer.mac, peer.ip, local, session.address.ip, 44444, 3);
    try std.testing.expectEqual(udp.Echo.long, try session.echo(&state, packet));
    bytes[51] ^= 1;
    try std.testing.expectEqual(udp.Echo.none, try session.echo(&state, packet));
    try std.testing.expect(state.invalidate());
    try std.testing.expectError(error.Stale, session.echo(&state, packet));
}
