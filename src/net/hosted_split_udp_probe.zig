//! Host-testable ownership boundary for the experimental Network Split UDP probe.
//! No transport, DHCP client, ARP, or device execution is provided here.
const std = @import("std");
const split = @import("hosted_network_split.zig");
const udp = @import("long_udp_probe.zig");

pub const Error = error{ NoAddress, InvalidPeer, Stale, InvalidAttempt };
pub const Peer = struct { ip: u32, mac: [6]u8, port: u16 };
/// Pinned Hosted 3 C6 build forwards this UDP destination range to P4.
pub const local_port: u16 = 49152;

fn validMac(mac: [6]u8) bool {
    return mac[0] & 1 == 0 and !std.mem.allEqual(u8, &mac, 0);
}

/// An address lease is captured once; every send and receive must recheck it
/// immediately before use under the same exclusive stream owner.
pub const Session = struct {
    generation: u64,
    address: split.Address,
    local_mac: [6]u8,
    peer: Peer,

    pub fn open(state: *const split.State, local_mac: [6]u8, peer: Peer) Error!Session {
        const address = state.address orelse return error.NoAddress;
        if (state.generation == 0) return error.NoAddress;
        const host = ~address.mask;
        if (!validMac(local_mac) or !validMac(peer.mac) or peer.port == 0 or
            std.mem.eql(u8, &local_mac, &peer.mac) or
            peer.ip & address.mask != address.ip & address.mask or peer.ip == address.ip or
            peer.ip & host == 0 or peer.ip & host == host or peer.ip >> 24 == 0 or
            peer.ip >> 24 == 127 or peer.ip >> 24 >= 224 or peer.ip >> 16 == 0xa9fe)
            return error.InvalidPeer;
        return .{ .generation = state.generation, .address = address, .local_mac = local_mac, .peer = peer };
    }

    pub fn check(self: *const Session, state: *const split.State) Error!void {
        const address = state.current(self.generation) orelse return error.Stale;
        if (!std.meta.eql(address, self.address)) return error.Stale;
    }

    /// Caller owns storage and must recheck immediately before transport send.
    pub fn prepare(self: *const Session, state: *const split.State, out: *[udp.ethernet_bytes]u8, attempt: u8) Error![]const u8 {
        try self.check(state);
        if (attempt < 1 or attempt > 32) return error.InvalidAttempt;
        return udp.packetAttemptFrom(out, self.local_mac, self.address.ip, local_port, self.peer.mac, self.peer.ip, self.peer.port, attempt);
    }

    pub fn echo(self: *const Session, state: *const split.State, packet: []const u8) Error!udp.Echo {
        try self.check(state);
        return udp.matchEchoTo(packet, self.local_mac, self.address.ip, local_port, self.peer.mac, self.peer.ip, self.peer.port);
    }
};
