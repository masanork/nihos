//! Derived from nihos commit 0b066228, experimental custom-C6 Network Split.
//! ESP-Hosted v2.13.1 Network Split address ownership boundary.
//!
//! The C6 owns DHCP.  The P4 adopts only a complete Event_DhcpDnsStatus
//! (RPC 777) snapshot and uses `generation` to revoke users of an old address.
//! This module does not configure hardware, start DHCP, or implement UDP.
const std = @import("std");
const hosted = @import("hosted.zig");
pub const Rpc = hosted.Rpc;

pub const event_id: u32 = 777;
pub const request_id: u32 = 353;
pub const response_id: u32 = 609;
pub const station_interface: u32 = 0;

pub const Address = struct {
    ip: u32,
    mask: u32,
    gateway: u32,
    dns: u32,
};

pub const Error = error{ Malformed, InvalidStatus, InvalidAddress };
pub const Outcome = enum { ignored, rejected, unchanged, changed };

pub const State = struct {
    generation: u64 = 0,
    address: ?Address = null,
    accepted: u32 = 0,
    rejected: u32 = 0,

    /// Consumes only RPC events with ID 777.  A rejected event never changes
    /// the current address or generation.
    pub fn receive(self: *State, message: Rpc) Outcome {
        if (message.kind != 3 or message.id != event_id) return .ignored;
        return self.apply(message.body);
    }

    /// Applies only the response correlated to a nonzero request UID.
    pub fn receiveResponse(self: *State, message: Rpc, expected_uid: u32) Outcome {
        if (expected_uid == 0 or message.kind != 2 or message.id != response_id or message.uid != expected_uid) return .ignored;
        return self.apply(message.body);
    }

    fn apply(self: *State, body: []const u8) Outcome {
        const next = decode(body) catch {
            self.rejected +|= 1;
            return .rejected;
        };
        if (std.meta.eql(self.address, next)) {
            self.accepted +|= 1;
            return .unchanged;
        }
        // Reusing a generation would make an old socket look current again.
        if (self.generation == std.math.maxInt(u64)) {
            self.rejected +|= 1;
            return .rejected;
        }
        self.accepted +|= 1;
        self.generation += 1;
        self.address = next;
        return .changed;
    }

    pub fn current(self: *const State, generation: u64) ?Address {
        if (generation != self.generation) return null;
        return self.address;
    }

    /// Revokes every handle derived from the current address even when the
    /// coprocessor reset/disconnect races the explicit all-down event.
    pub fn invalidate(self: *State) bool {
        if (self.generation == std.math.maxInt(u64)) {
            self.rejected +|= 1;
            self.address = null;
            return false;
        }
        self.generation += 1;
        self.address = null;
        return true;
    }
};

/// Builds GetDhcpDnsStatus for station interface. The zero-valued proto3
/// interface field is omitted from the body; the response is RPC 609.
pub fn statusRequest(out: []u8, uid: u32) hosted.Error![]const u8 {
    return hosted.request(out, request_id, uid, &.{});
}

const Status = struct {
    iface: u32 = 0,
    link_up: u32 = 0,
    dhcp_up: u32 = 0,
    ip: ?[]const u8 = null,
    mask: ?[]const u8 = null,
    gateway: ?[]const u8 = null,
    dns_up: u32 = 0,
    dns: ?[]const u8 = null,
    dns_type: u32 = 0,
    response: u32 = 0,
};

pub fn decode(body: []const u8) (hosted.Error || Error)!?Address {
    var status: Status = .{};
    var seen: u16 = 0;
    var reader = hosted.Reader{ .bytes = body };
    while (try reader.next()) |field| {
        if (field.number == 0 or field.number > 10) return error.Malformed;
        const bit = @as(u16, 1) << @as(u4, @intCast(field.number - 1));
        if (seen & bit != 0) return error.Malformed;
        seen |= bit;
        switch (field.number) {
            1, 2, 3, 7, 9, 10 => {
                if (field.kind != 0 or field.bytes != null or field.value > std.math.maxInt(u32)) return error.Malformed;
                const value: u32 = @intCast(field.value);
                switch (field.number) {
                    1 => status.iface = value,
                    2 => status.link_up = value,
                    3 => status.dhcp_up = value,
                    7 => status.dns_up = value,
                    9 => status.dns_type = value,
                    10 => status.response = value,
                    else => unreachable,
                }
            },
            4, 5, 6, 8 => {
                if (field.kind != 2) return error.Malformed;
                const value = field.bytes orelse return error.Malformed;
                switch (field.number) {
                    4 => status.ip = value,
                    5 => status.mask = value,
                    6 => status.gateway = value,
                    8 => status.dns = value,
                    else => unreachable,
                }
            },
            else => return error.Malformed,
        }
    }
    if (status.response != 0 or status.iface != station_interface or status.link_up > 1 or
        status.dhcp_up > 1 or status.dns_up > 1 or status.dns_type != 0)
        return error.InvalidStatus;

    if (status.link_up == 0 and status.dhcp_up == 0 and status.dns_up == 0) {
        // GetDhcpDnsStatus formats unset addresses as "0.0.0.0". DNS can
        // retain a prior server even after the interface drops; ignore it.
        if (try optionalAddress(status.ip) != 0 or try optionalAddress(status.mask) != 0 or
            try optionalAddress(status.gateway) != 0) return error.InvalidStatus;
        _ = try optionalAddress(status.dns);
        return null;
    }
    // The v2.13.1 sender publishes only a full snapshot or an all-down one.
    if (status.link_up != 1 or status.dhcp_up != 1 or status.dns_up != 1) return error.InvalidStatus;

    const address = Address{
        .ip = try ipv4(try text(status.ip)),
        .mask = try ipv4(try text(status.mask)),
        .gateway = try ipv4(try text(status.gateway)),
        .dns = try ipv4(try text(status.dns)),
    };
    // The netif can be marked up before DHCP and DNS are ready. Never adopt
    // or expose a partial address; wait for a later complete status event.
    if (address.ip == 0 or address.mask == 0 or address.gateway == 0 or address.dns == 0) return null;
    const host = ~address.mask;
    if (!unicast(address.ip) or !unicast(address.gateway) or !unicast(address.dns) or
        address.mask == 0 or host < 3 or host & (host +% 1) != 0 or
        address.ip & address.mask != address.gateway & address.mask or
        address.ip & host == 0 or address.ip & host == host or
        address.gateway & host == 0 or address.gateway & host == host)
        return error.InvalidAddress;
    return address;
}

fn text(value: ?[]const u8) Error![]const u8 {
    const bytes = value orelse return error.Malformed;
    if (bytes.len == 0 or bytes.len > 64) return error.Malformed;
    const end = std.mem.indexOfScalar(u8, bytes, 0) orelse bytes.len;
    if (end == 0 or !std.mem.allEqual(u8, bytes[end..], 0)) return error.Malformed;
    return bytes[0..end];
}

fn optionalAddress(value: ?[]const u8) Error!u32 {
    const bytes = value orelse return 0;
    if (bytes.len > 64) return error.Malformed;
    if (std.mem.allEqual(u8, bytes, 0)) return 0;
    return ipv4(try text(bytes));
}

fn ipv4(bytes: []const u8) Error!u32 {
    if (bytes.len < 7 or bytes.len > 15) return error.InvalidAddress;
    var parts = std.mem.splitScalar(u8, bytes, '.');
    var result: u32 = 0;
    for (0..4) |_| {
        const part = parts.next() orelse return error.InvalidAddress;
        if (part.len == 0 or part.len > 3) return error.InvalidAddress;
        for (part) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidAddress;
        const octet = std.fmt.parseInt(u8, part, 10) catch return error.InvalidAddress;
        result = (result << 8) | octet;
    }
    if (parts.next() != null) return error.InvalidAddress;
    return result;
}

fn unicast(address: u32) bool {
    const first = address >> 24;
    return first != 0 and first != 127 and first < 224 and address >> 16 != 0xa9fe;
}
