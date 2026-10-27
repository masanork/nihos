//! Bounded boot-time station check. Call complete only for a successful AT
//! transaction; line data alone never commits a lease. No credentials or SSID
//! are retained here. This is not a DHCP implementation or packet capture.
const std = @import("std");
const commands = @import("at_commands.zig");

pub const Join = union(enum) {
    saved,
    network: struct { ssid: []const u8, password: []const u8 },
};
pub const Step = enum { enable_dhcp, check_dhcp, join, state, addresses, done };
pub const Error = error{ InvalidReply, MissingReply, DhcpDisabled, NotConnected, Disconnected, InvalidLease, Finished };

pub const Probe = struct {
    step: Step = .enable_dhcp,
    dhcp: ?u8 = null,
    state: ?u8 = null,
    ip: ?u32 = null,
    gateway: ?u32 = null,
    netmask: ?u32 = null,
    connected_events: u32 = 0,
    got_ip_events: u32 = 0,
    disconnected: bool = false,

    pub fn command(self: *const Probe, join: Join) Error!commands.Command {
        return switch (self.step) {
            .enable_dhcp => .wifi_dhcp_enable,
            .check_dhcp => .wifi_dhcp_query,
            .join => switch (join) {
                .saved => .wifi_join_saved,
                .network => |network| .{ .wifi_join = .{ .ssid = network.ssid, .password = network.password } },
            },
            .state => .wifi_state,
            .addresses => .wifi_addresses,
            .done => error.Finished,
        };
    }

    pub fn line(self: *Probe, bytes: []const u8) Error!void {
        if (std.mem.eql(u8, bytes, "WIFI DISCONNECT")) {
            self.disconnected = true;
            self.ip = null;
            self.gateway = null;
            self.netmask = null;
            if (self.step == .state or self.step == .addresses or self.step == .done) return error.Disconnected;
        } else if (std.mem.eql(u8, bytes, "WIFI CONNECTED")) {
            self.connected_events +|= 1;
            if (self.step == .join) self.disconnected = false;
        } else if (std.mem.eql(u8, bytes, "WIFI GOT IP")) {
            self.got_ip_events +|= 1;
        } else if (std.mem.startsWith(u8, bytes, "+CWDHCP:")) {
            if (self.step != .check_dhcp or self.dhcp != null) return error.InvalidReply;
            self.dhcp = std.fmt.parseInt(u8, bytes[8..], 10) catch return error.InvalidReply;
            if (self.dhcp.? > 7) return error.InvalidReply;
        } else if (std.mem.startsWith(u8, bytes, "+CWSTATE:")) {
            if (self.step != .state or self.state != null) return error.InvalidReply;
            // The rest is an escaped SSID. Do not print or retain it.
            if (bytes.len < 13 or bytes[10] != ',' or bytes[11] != '"' or bytes[bytes.len - 1] != '"' or
                bytes[9] < '0' or bytes[9] > '4') return error.InvalidReply;
            self.state = bytes[9] - '0';
        } else if (std.mem.startsWith(u8, bytes, "+CIPSTA:")) {
            if (self.step != .addresses) return error.InvalidReply;
            const field = bytes[8..];
            if (std.mem.startsWith(u8, field, "ip:")) {
                try address(&self.ip, field[3..]);
            } else if (std.mem.startsWith(u8, field, "gateway:")) {
                try address(&self.gateway, field[8..]);
            } else if (std.mem.startsWith(u8, field, "netmask:")) {
                try address(&self.netmask, field[8..]);
            } else if (!std.mem.startsWith(u8, field, "ip6ll:") and !std.mem.startsWith(u8, field, "ip6gl:")) return error.InvalidReply;
        }
    }

    pub fn complete(self: *Probe) Error!void {
        self.step = switch (self.step) {
            .enable_dhcp => .check_dhcp,
            .check_dhcp => blk: {
                if ((self.dhcp orelse return error.MissingReply) & 1 == 0) return error.DhcpDisabled;
                break :blk .join;
            },
            .join => .state,
            .state => blk: {
                if (self.disconnected) return error.Disconnected;
                if ((self.state orelse return error.MissingReply) != 2) return error.NotConnected;
                break :blk .addresses;
            },
            .addresses => blk: {
                if (self.disconnected) return error.Disconnected;
                const ip = self.ip orelse return error.MissingReply;
                const gateway = self.gateway orelse return error.MissingReply;
                const mask = self.netmask orelse return error.MissingReply;
                const host_mask = ~mask;
                if (!unicast(ip) or !unicast(gateway) or mask == 0 or host_mask < 3 or
                    host_mask & (host_mask +% 1) != 0 or ip & mask != gateway & mask or
                    ip & host_mask == 0 or ip & host_mask == host_mask or
                    gateway & host_mask == 0 or gateway & host_mask == host_mask) return error.InvalidLease;
                break :blk .done;
            },
            .done => return error.Finished,
        };
    }
};

fn unicast(ip: u32) bool {
    const first = ip >> 24;
    return first != 0 and first != 127 and first < 224 and ip >> 16 != 0xa9fe;
}

fn address(destination: *?u32, text: []const u8) Error!void {
    if (destination.* != null or text.len < 9 or text[0] != '"' or text[text.len - 1] != '"') return error.InvalidReply;
    var octets = std.mem.splitScalar(u8, text[1 .. text.len - 1], '.');
    var result: u32 = 0;
    for (0..4) |_| {
        const octet = octets.next() orelse return error.InvalidReply;
        if (octet.len == 0 or octet.len > 3) return error.InvalidReply;
        for (octet) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidReply;
        result = (result << 8) | (std.fmt.parseInt(u8, octet, 10) catch return error.InvalidReply);
    }
    if (octets.next() != null) return error.InvalidReply;
    destination.* = result;
}
