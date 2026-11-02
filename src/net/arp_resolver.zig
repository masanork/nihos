//! Single-owner IPv4 next-hop ARP resolution. No cache or socket table.
//! The adapter supplies a live lease epoch, a monotonic clock and full-frame
//! transmission. The resolved MAC is valid only for the current lease epoch.
const std = @import("std");
pub const Address = [4]u8;
pub const Mac = [6]u8;
pub const Lease = struct { ip: Address, mask: Address, gateway: Address, mac: Mac, epoch: u64 };
pub const Error = error{ InvalidArgument, InvalidState, Timeout, StaleLease };
pub const Result = struct { ip: Address, mac: Mac, epoch: u64 };

fn unicastMac(mac: Mac) bool {
    return mac[0] & 1 == 0 and !std.mem.allEqual(u8, &mac, 0);
}
fn usableIp(ip: Address) bool {
    return ip[0] != 0 and ip[0] < 224 and !std.mem.allEqual(u8, &ip, 255);
}
fn netNumber(ip: Address) u32 {
    return std.mem.readInt(u32, &ip, .big);
}

pub const Resolver = struct {
    const State = enum { idle, pending, waiting, resolved, failed };
    state: State = .idle,
    lease: Lease = .{ .ip = @splat(0), .mask = @splat(0), .gateway = @splat(0), .mac = @splat(0), .epoch = 0 },
    next_hop: Address = @splat(0),
    resolved_mac: Mac = @splat(0),
    frame: [42]u8 = @splat(0),
    deadline: u64 = 0,
    retry_at: u64 = 0,
    attempts: u8 = 0,

    /// Time is monotonic milliseconds; the IP lease owner supplies epoch.
    pub fn begin(self: *Resolver, lease: Lease, target: Address, now: u64, deadline: u64) Error!void {
        if (self.state != .idle) return error.InvalidState;
        const mask = netNumber(lease.mask);
        const host_mask = ~mask;
        if (deadline <= now or lease.epoch == 0 or !unicastMac(lease.mac) or !usableIp(lease.ip) or !usableIp(target) or !usableIp(lease.gateway) or mask == 0 or host_mask < 3 or host_mask & (host_mask +% 1) != 0) return error.InvalidArgument;
        if (netNumber(lease.ip) & mask != netNumber(lease.gateway) & mask) return error.InvalidArgument;
        const local_host = netNumber(lease.ip) & host_mask;
        const gateway_host = netNumber(lease.gateway) & host_mask;
        if (local_host == 0 or local_host == host_mask or gateway_host == 0 or gateway_host == host_mask) return error.InvalidArgument;
        if (netNumber(lease.ip) & mask == netNumber(target) & mask and (netNumber(target) & host_mask == 0 or netNumber(target) & host_mask == host_mask)) return error.InvalidArgument;
        self.lease = lease;
        self.next_hop = if (netNumber(lease.ip) & mask == netNumber(target) & mask) target else lease.gateway;
        if (std.mem.eql(u8, &self.next_hop, &lease.ip)) return error.InvalidArgument;
        self.deadline = deadline;
        self.frame = @splat(0);
        @memset(self.frame[0..6], 0xff);
        self.frame[6..12].* = lease.mac;
        std.mem.writeInt(u16, self.frame[12..14], 0x0806, .big);
        std.mem.writeInt(u16, self.frame[14..16], 1, .big);
        std.mem.writeInt(u16, self.frame[16..18], 0x0800, .big);
        self.frame[18] = 6;
        self.frame[19] = 4;
        std.mem.writeInt(u16, self.frame[20..22], 1, .big);
        self.frame[22..28].* = lease.mac;
        self.frame[28..32].* = lease.ip;
        self.frame[38..42].* = self.next_hop;
        self.state = .pending;
    }
    /// Borrowed full Ethernet frame remains stable until the next call.
    pub fn poll(self: *Resolver, epoch: u64, now: u64) Error!?[]const u8 {
        try self.check(epoch, now);
        if (self.state == .resolved) return null;
        if (self.state == .waiting and now >= self.retry_at) self.state = .pending;
        return if (self.state == .pending) &self.frame else null;
    }
    /// Record only a whole frame successfully handed to the network owner.
    pub fn sent(self: *Resolver, epoch: u64, now: u64) Error!void {
        try self.check(epoch, now);
        if (self.state != .pending) return error.InvalidState;
        self.retry_at = now +| (@as(u64, 1000) << @as(u6, @intCast(@min(self.attempts, 3))));
        self.attempts +|= 1;
        self.state = .waiting;
    }
    pub fn receive(self: *Resolver, epoch: u64, now: u64, frame: []const u8) Error!bool {
        try self.check(epoch, now);
        if (self.state != .waiting and !(self.state == .pending and self.attempts != 0)) return false;
        if (frame.len < 42 or std.mem.readInt(u16, frame[12..14], .big) != 0x0806 or std.mem.readInt(u16, frame[14..16], .big) != 1 or std.mem.readInt(u16, frame[16..18], .big) != 0x0800 or frame[18] != 6 or frame[19] != 4 or std.mem.readInt(u16, frame[20..22], .big) != 2) return false;
        const sender: Mac = frame[22..28].*;
        if (!unicastMac(sender) or !std.mem.eql(u8, frame[6..12], &sender) or !std.mem.eql(u8, frame[0..6], &self.lease.mac) or !std.mem.eql(u8, frame[28..32], &self.next_hop) or !std.mem.eql(u8, frame[32..38], &self.lease.mac) or !std.mem.eql(u8, frame[38..42], &self.lease.ip)) return false;
        self.resolved_mac = sender;
        self.state = .resolved;
        return true;
    }
    pub fn result(self: *Resolver, epoch: u64, now: u64) Error!?Result {
        try self.check(epoch, now);
        return if (self.state == .resolved) .{ .ip = self.next_hop, .mac = self.resolved_mac, .epoch = self.lease.epoch } else null;
    }
    pub fn invalidate(self: *Resolver) void {
        self.state = .failed;
        self.resolved_mac = @splat(0);
    }
    fn check(self: *Resolver, epoch: u64, now: u64) Error!void {
        if (self.state == .idle or self.state == .failed) return error.InvalidState;
        if (epoch != self.lease.epoch) {
            self.invalidate();
            return error.StaleLease;
        }
        if (self.state != .resolved and now >= self.deadline) {
            self.invalidate();
            return error.Timeout;
        }
    }
};

test "gateway resolution retries and rejects unrelated replies and stale leases" {
    const lease = Lease{ .ip = .{ 10, 0, 2, 15 }, .mask = .{ 255, 255, 255, 0 }, .gateway = .{ 10, 0, 2, 2 }, .mac = .{ 0x52, 0x54, 0, 0x12, 0x34, 0x56 }, .epoch = 7 };
    var r: Resolver = .{};
    try r.begin(lease, .{ 203, 0, 113, 8 }, 0, 5000);
    const req = (try r.poll(7, 0)).?;
    try std.testing.expectEqualSlices(u8, &lease.gateway, req[38..42]);
    try r.sent(7, 0);
    try std.testing.expect((try r.poll(7, 999)) == null);
    try std.testing.expect((try r.poll(7, 1000)) != null);
    const gateway_mac: Mac = .{ 0x52, 0x55, 10, 0, 2, 2 };
    var reply = r.frame;
    reply[0..6].* = lease.mac;
    reply[6..12].* = gateway_mac;
    std.mem.writeInt(u16, reply[20..22], 2, .big);
    reply[22..28].* = gateway_mac;
    reply[28..32].* = lease.gateway;
    reply[32..38].* = lease.mac;
    reply[38..42].* = lease.ip;
    reply[28] = 11;
    try std.testing.expect(!try r.receive(7, 1001, &reply));
    reply[28] = 10;
    try std.testing.expect(try r.receive(7, 1002, &reply));
    try std.testing.expectEqualSlices(u8, &gateway_mac, &(try r.result(7, 1003)).?.mac);
    try std.testing.expectError(error.StaleLease, r.result(8, 1004));
    try std.testing.expectError(error.InvalidState, r.poll(7, 1005));
}

test "on-link targets, unsolicited replies, deadline and invalid leases" {
    const lease = Lease{ .ip = .{ 10, 0, 2, 15 }, .mask = .{ 255, 255, 255, 0 }, .gateway = .{ 10, 0, 2, 2 }, .mac = .{ 0x52, 0x54, 0, 0x12, 0x34, 0x56 }, .epoch = 4 };
    var r: Resolver = .{};
    try r.begin(lease, .{ 10, 0, 2, 77 }, 10, 100);
    const request = (try r.poll(4, 10)).?;
    try std.testing.expectEqualSlices(u8, &.{ 10, 0, 2, 77 }, request[38..42]);
    try std.testing.expect(!try r.receive(4, 10, request));
    try r.sent(4, 10);
    try std.testing.expectError(error.Timeout, r.poll(4, 100));
    try std.testing.expectError(error.InvalidState, r.poll(4, 101));
    var invalid: Resolver = .{};
    try std.testing.expectError(error.InvalidArgument, invalid.begin(lease, .{ 10, 0, 2, 255 }, 0, 10));
    var bad_mask = lease;
    bad_mask.mask = .{ 255, 0, 255, 0 };
    try std.testing.expectError(error.InvalidArgument, invalid.begin(bad_mask, .{ 10, 0, 2, 77 }, 0, 10));
}
