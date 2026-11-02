//! Experimental address-generation guard around Hosted UDP frame handling.
//! This owns no socket, port allocation, transport, routing, ARP or I/O.
const std = @import("std");
const hosted = @import("hosted.zig");
const split = @import("hosted_network_split.zig");
const wire = @import("udp_ipv4.zig");
const udp = @import("hosted_udp_frame.zig");

pub const Error = udp.Error || error{ NoAddress, InvalidBinding, Stale };
/// An externally established inclusive C6-to-P4 port range; no firmware
/// profile is discovered or verified by this module.
pub const PortRange = struct { first: u16, last: u16 };

/// Exclusive owner must recheck immediately before submitting a send or
/// consuming a receive, and retire the binding on disconnect/reset. A check
/// cannot cancel a transport operation already submitted to hardware.
pub const Lease = struct {
    generation: u64,
    address: split.Address,
    local: wire.Endpoint,

    pub fn open(state: *const split.State, mac: [6]u8, port: u16, routed: PortRange) Error!Lease {
        const address = state.address orelse return error.NoAddress;
        if (state.generation == 0) return error.NoAddress;
        if (routed.first == 0 or routed.first > routed.last or port < routed.first or port > routed.last or
            mac[0] & 1 != 0 or std.mem.allEqual(u8, &mac, 0)) return error.InvalidBinding;
        var local_ip: [4]u8 = undefined;
        std.mem.writeInt(u32, &local_ip, address.ip, .big);
        return .{ .generation = state.generation, .address = address, .local = .{ .mac = mac, .ip = local_ip, .port = port } };
    }

    pub fn check(self: *const Lease, state: *const split.State) Error!void {
        const current = state.current(self.generation) orelse return error.Stale;
        if (!std.meta.eql(current, self.address)) return error.Stale;
    }

    pub fn prepare(self: *const Lease, state: *const split.State, out: []u8, peer: wire.Endpoint, payload: []const u8, sequence: u16) Error![]const u8 {
        try self.check(state);
        return udp.prepare(out, self.local, peer, payload, sequence);
    }

    /// Returned datagram borrows frame data; consuming it requires a current
    /// lease and exclusive ownership of that storage. Source is unauthenticated.
    pub fn receive(self: *const Lease, state: *const split.State, frame: hosted.Frame) Error!?wire.Datagram {
        try self.check(state);
        return udp.receive(frame, self.local);
    }
};
