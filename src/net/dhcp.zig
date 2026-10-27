//! Bounded DHCPv4 acquisition/renewal (RFC 2131/2132), minimal leased-IP ARP.
//! No persistent storage, address conflict detection or general IPv4 stack.
const std = @import("std");
pub const Error = error{ Capacity, Malformed, Rejected, InvalidLease, LeaseExpired, Clock };
pub const Lease = struct { ip: u32, mask: u32, gateway: u32, server: u32, seconds: u32 };
pub const Client = struct {
    mac: [6]u8,
    xid: u32,
    phase: enum { discover, request, bound, failed, renewing, rebinding } = .discover,
    offered: u32 = 0,
    server: u32 = 0,
    lease: ?Lease = null,
    attempts: u8 = 0,
    last_sent: ?u64 = null,
    request_started: ?u64 = null,
    bound_at: u64 = 0,
    renew_at: u64 = 0,
    rebind_at: u64 = 0,
    expires_at: u64 = 0,
    next_retry: u64 = 0,
    server_mac: [6]u8 = @splat(0),
    renewals: u32 = 0,
    arp: [42]u8 = @splat(0),
    arp_pending: bool = false,
    sending_arp: bool = false,

    pub fn maintaining(self: *const Client) bool {
        return self.phase == .renewing or self.phase == .rebinding;
    }
    pub fn tick(self: *Client, now: u64) Error!void {
        if (self.lease == null) return;
        if (now < self.bound_at) return error.Clock;
        if (now >= self.expires_at) {
            self.revoke();
            return error.LeaseExpired;
        }
        if (now >= self.rebind_at and self.phase != .rebinding) {
            if (self.phase == .bound) self.newTransaction();
            self.phase = .rebinding;
            self.last_sent = null;
            self.next_retry = now;
        } else if (self.phase == .bound and now >= self.renew_at) self.requestRenewal(now);
    }
    /// A diagnostic/application may request renewal early, without changing
    /// the server's lease duration or expiration clock.
    pub fn requestRenewal(self: *Client, now: u64) void {
        if (self.phase != .bound or self.lease == null or now >= self.expires_at) return;
        self.newTransaction();
        self.phase = .renewing;
        self.next_retry = now;
    }
    fn newTransaction(self: *Client) void {
        self.xid +%= 0x9e3779b9;
        if (self.xid == 0) self.xid = 1;
        self.attempts = 0;
        self.last_sent = null;
        self.request_started = null;
    }
    fn revoke(self: *Client) void {
        self.lease = null;
        self.phase = .failed;
        self.arp_pending = false;
        self.arp = @splat(0);
    }

    /// Caller acknowledges a packet only after all bytes were accepted by SDIO.
    pub fn sent(self: *Client, now: u64) void {
        if (self.sending_arp) {
            self.sending_arp = false;
            self.arp_pending = false;
            return;
        }
        self.last_sent = now;
        if (self.request_started == null and self.phase != .discover) self.request_started = now;
        self.attempts +|= 1;
        if (self.maintaining()) {
            const until = if (self.phase == .renewing) self.rebind_at else self.expires_at;
            self.next_retry = now +| @max(@as(u64, 60_000_000), (until -| now) / 2);
        }
    }
    pub fn due(self: *const Client, now: u64) bool {
        if (self.phase == .failed) return false;
        if (self.arp_pending) return true;
        if (self.maintaining()) return now >= self.next_retry;
        if (self.phase == .bound or self.attempts >= 4) return false;
        const previous = self.last_sent orelse return true;
        return now >= previous and now - previous >= (@as(u64, 1_000_000) << @as(u6, @intCast(self.attempts)));
    }
    pub fn packet(self: *Client, out: []u8) Error![]const u8 {
        if (self.arp_pending) {
            self.sending_arp = true;
            if (out.len < 42) return error.Capacity;
            @memcpy(out[0..42], &self.arp);
            return out[0..42];
        }
        if (out.len < 342 or (self.phase != .discover and self.phase != .request and !self.maintaining())) return error.Capacity;
        self.sending_arp = false;
        const result = out[0..342];
        @memset(result, 0);
        if (self.phase == .renewing) @memcpy(result[0..6], &self.server_mac) else @memset(result[0..6], 255);
        @memcpy(result[6..12], &self.mac);
        put16(result[12..14], 0x0800);
        const ip = result[14..34];
        ip[0] = 0x45;
        put16(ip[2..4], 328);
        ip[8] = 64;
        ip[9] = 17;
        if (self.maintaining()) put32(ip[12..16], self.lease.?.ip);
        if (self.phase == .renewing) put32(ip[16..20], self.server) else @memset(ip[16..20], 255);
        put16(ip[10..12], checksum(ip));
        const udp = result[34..42];
        put16(udp[0..2], 68);
        put16(udp[2..4], 67);
        put16(udp[4..6], 308);
        const bootp = result[42..];
        bootp[0] = 1;
        bootp[1] = 1;
        bootp[2] = 6;
        put32(bootp[4..8], self.xid);
        if (self.maintaining()) put32(bootp[12..16], self.lease.?.ip) else put16(bootp[10..12], 0x8000);
        @memcpy(bootp[28..34], &self.mac);
        put32(bootp[236..240], 0x63825363);
        var pos: usize = 240;
        const kind: u8 = if (self.phase == .discover) 1 else 3;
        try option(bootp, &pos, 53, &.{kind});
        var client_id: [7]u8 = undefined;
        client_id[0] = 1;
        @memcpy(client_id[1..], &self.mac);
        try option(bootp, &pos, 61, &client_id);
        try option(bootp, &pos, 55, &.{ 1, 3, 6, 51, 54, 58, 59 });
        if (self.phase == .request) {
            var number: [4]u8 = undefined;
            put32(&number, self.offered);
            try option(bootp, &pos, 50, &number);
            put32(&number, self.server);
            try option(bootp, &pos, 54, &number);
        }
        bootp[pos] = 255;
        return result;
    }
    /// Unrelated traffic is ignored. Malformed DHCP never changes lease state.
    pub fn receive(self: *Client, frame: []const u8) Error!void {
        return self.receiveAt(frame, self.request_started orelse self.bound_at);
    }
    pub fn receiveAt(self: *Client, frame: []const u8, now: u64) Error!void {
        try self.tick(now);
        if (self.phase == .failed) return;
        if (self.lease != null and frame.len >= 42 and get16(frame[12..14]) == 0x0806) {
            self.receiveArp(frame);
            return;
        }
        if (self.phase == .bound) return;
        if (frame.len < 42 or get16(frame[12..14]) != 0x0800) return;
        const broadcast: [6]u8 = @splat(255);
        if (!std.mem.eql(u8, frame[0..6], &self.mac) and !std.mem.eql(u8, frame[0..6], &broadcast)) return;
        const ip = frame[14..];
        if (ip[0] >> 4 != 4 or ip[9] != 17) return;
        const header: usize = @as(usize, ip[0] & 15) * 4;
        const total = get16(ip[2..4]);
        if (header < 20 or total > ip.len or total < header + 8 or get16(ip[6..8]) & 0x3fff != 0) return error.Malformed;
        if (checksum(ip[0..header]) != 0) return error.Malformed;
        const udp = ip[header..total];
        if (get16(udp[0..2]) != 67 or get16(udp[2..4]) != 68) return;
        const length = get16(udp[4..6]);
        if (length != udp.len or length < 248) return error.Malformed;
        if (get16(udp[6..8]) != 0) {
            var sum = sum16(ip[12..20]) + @as(u32, 17) + @as(u32, length) + sum16(udp);
            while (sum > 65535) sum = (sum & 65535) + (sum >> 16);
            if (sum != 65535) return error.Malformed;
        }
        const bootp = udp[8..];
        if (get32(bootp[4..8]) != self.xid or !std.mem.eql(u8, bootp[28..34], &self.mac)) return;
        if (bootp[0] != 2 or bootp[1] != 1 or bootp[2] != 6 or get32(bootp[236..240]) != 0x63825363) return error.Malformed;
        var kind: ?u8 = null;
        var server: ?u32 = null;
        var mask: ?u32 = null;
        var gateway: ?u32 = null;
        var seconds: ?u32 = null;
        var renewal: ?u32 = null;
        var rebind: ?u32 = null;
        var pos: usize = 240;
        var ended = false;
        while (pos < bootp.len) {
            const code = bootp[pos];
            pos += 1;
            if (code == 255) {
                ended = true;
                break;
            }
            if (code == 0) continue;
            if (pos == bootp.len) return error.Malformed;
            const count = bootp[pos];
            pos += 1;
            if (count > bootp.len - pos) return error.Malformed;
            const value = bootp[pos..][0..count];
            pos += count;
            switch (code) {
                53 => {
                    if (kind != null or count != 1) return error.Malformed;
                    kind = value[0];
                },
                54 => {
                    if (server != null or count != 4) return error.Malformed;
                    server = get32(value);
                },
                1 => {
                    if (mask != null or count != 4) return error.Malformed;
                    mask = get32(value);
                },
                3 => {
                    if (gateway != null or count < 4 or count % 4 != 0) return error.Malformed;
                    gateway = get32(value[0..4]);
                },
                51 => {
                    if (seconds != null or count != 4) return error.Malformed;
                    seconds = get32(value);
                },
                58, 59 => {
                    const dest = if (code == 58) &renewal else &rebind;
                    if (dest.* != null or count != 4) return error.Malformed;
                    dest.* = get32(value);
                },
                52 => return error.Malformed, // Option overload is outside this bounded fixture.
                else => {},
            }
        }
        if (!ended) return error.Malformed;
        const selected = server orelse return error.Malformed;
        if (!unicast(selected)) return error.InvalidLease;
        if ((self.phase == .request or self.phase == .renewing) and selected != self.server) return;
        if (kind == 6 and (self.phase == .request or self.maintaining())) {
            self.revoke();
            return error.Rejected;
        }
        const address = get32(bootp[16..20]);
        if (!unicast(address) or !unicast(selected)) return error.InvalidLease;
        if (self.phase == .discover and kind == 2) {
            self.offered = address;
            self.server = selected;
            self.phase = .request;
            self.last_sent = null;
            self.attempts = 0;
            self.request_started = null;
        } else if ((self.phase == .request or self.maintaining()) and kind == 5) {
            if (address != self.offered) return error.InvalidLease;
            const lease = Lease{ .ip = address, .mask = mask orelse if (self.lease) |old| old.mask else return error.InvalidLease, .gateway = gateway orelse if (self.lease) |old| old.gateway else return error.InvalidLease, .server = selected, .seconds = seconds orelse return error.InvalidLease };
            const host = ~lease.mask;
            if (lease.mask == 0 or host < 3 or host & (host +% 1) != 0 or lease.seconds == 0 or !unicast(lease.gateway) or
                address & lease.mask != lease.gateway & lease.mask or address & host == 0 or address & host == host or
                lease.gateway & host == 0 or lease.gateway & host == host) return error.InvalidLease;
            const span = @as(u64, lease.seconds) * 1_000_000;
            const t1 = if (renewal) |v| @as(u64, v) * 1_000_000 else span / 2;
            const t2 = if (rebind) |v| @as(u64, v) * 1_000_000 else span * 7 / 8;
            if (t1 == 0 or t1 >= t2 or t2 >= span) return error.InvalidLease;
            const base = self.request_started orelse now;
            if (now < base) return error.Clock;
            const expiry = std.math.add(u64, base, span) catch return error.Clock;
            if (expiry <= now) return error.InvalidLease;
            if (!macValid(frame[6..12])) return error.Malformed;
            if (self.maintaining()) self.renewals +|= 1;
            self.bound_at = base;
            self.renew_at = base + t1;
            self.rebind_at = base + t2;
            self.expires_at = expiry;
            self.server_mac = frame[6..12].*;
            self.server = selected;
            self.lease = lease;
            self.phase = .bound;
        }
    }
    fn receiveArp(self: *Client, frame: []const u8) void {
        if (self.arp_pending or !macValid(frame[6..12]) or
            get16(frame[14..16]) != 1 or get16(frame[16..18]) != 0x0800 or
            frame[18] != 6 or frame[19] != 4 or get16(frame[20..22]) != 1 or
            !std.mem.eql(u8, frame[6..12], frame[22..28]) or
            get32(frame[38..42]) != self.lease.?.ip) return;
        const broadcast: [6]u8 = @splat(255);
        if (!std.mem.eql(u8, frame[0..6], &self.mac) and !std.mem.eql(u8, frame[0..6], &broadcast)) return;
        @memcpy(&self.arp, frame[0..42]);
        @memcpy(self.arp[0..6], frame[6..12]);
        @memcpy(self.arp[6..12], &self.mac);
        put16(self.arp[20..22], 2);
        @memcpy(self.arp[22..28], &self.mac);
        put32(self.arp[28..32], self.lease.?.ip);
        @memcpy(self.arp[32..38], frame[22..28]);
        @memcpy(self.arp[38..42], frame[28..32]);
        self.arp_pending = true;
    }
};
fn macValid(mac: []const u8) bool {
    return mac[0] & 1 == 0 and !std.mem.allEqual(u8, mac, 0);
}
fn unicast(ip: u32) bool {
    const first = ip >> 24;
    return first != 0 and first != 127 and first < 224 and ip >> 16 != 0xa9fe;
}
fn option(out: []u8, pos: *usize, code: u8, value: []const u8) Error!void {
    if (value.len > 255 or value.len + 3 > out.len - pos.*) return error.Capacity;
    out[pos.*] = code;
    out[pos.* + 1] = @intCast(value.len);
    @memcpy(out[pos.* + 2 ..][0..value.len], value);
    pos.* += 2 + value.len;
}
pub fn get16(bytes: []const u8) u16 {
    return std.mem.readInt(u16, bytes[0..2], .big);
}
pub fn get32(bytes: []const u8) u32 {
    return std.mem.readInt(u32, bytes[0..4], .big);
}
pub fn put16(bytes: []u8, value: u16) void {
    std.mem.writeInt(u16, bytes[0..2], value, .big);
}
pub fn put32(bytes: []u8, value: u32) void {
    std.mem.writeInt(u32, bytes[0..4], value, .big);
}
fn sum16(bytes: []const u8) u32 {
    var sum: u32 = 0;
    var i: usize = 0;
    while (i + 1 < bytes.len) : (i += 2) sum += get16(bytes[i..]);
    if (i != bytes.len) sum += @as(u32, bytes[i]) << 8;
    return sum;
}
pub fn checksum(bytes: []const u8) u16 {
    var sum = sum16(bytes);
    while (sum > 65535) sum = (sum & 65535) + (sum >> 16);
    return ~@as(u16, @truncate(sum));
}
