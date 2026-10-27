//! One-shot DHCPv4 acquisition for the boot fixture (RFC 2131/2132).
//! No persistent lease, renewal, address conflict detection or general IP stack.
const std = @import("std");
pub const Error = error{ Capacity, Malformed, Rejected, InvalidLease };
pub const Lease = struct { ip: u32, mask: u32, gateway: u32, server: u32, seconds: u32 };
pub const Client = struct {
    mac: [6]u8,
    xid: u32,
    phase: enum { discover, request, bound, failed } = .discover,
    offered: u32 = 0,
    server: u32 = 0,
    lease: ?Lease = null,
    attempts: u8 = 0,
    last_sent: ?u64 = null,

    /// Caller acknowledges a packet only after all bytes were accepted by SDIO.
    pub fn sent(self: *Client, now: u64) void {
        self.last_sent = now;
        self.attempts += 1;
    }
    pub fn due(self: *const Client, now: u64) bool {
        if (self.phase == .bound or self.phase == .failed or self.attempts >= 4) return false;
        const previous = self.last_sent orelse return true;
        return now >= previous and now - previous >= (@as(u64, 1_000_000) << @as(u6, @intCast(self.attempts)));
    }
    pub fn packet(self: *const Client, out: []u8) Error![]const u8 {
        if (out.len < 342 or (self.phase != .discover and self.phase != .request)) return error.Capacity;
        const result = out[0..342];
        @memset(result, 0);
        @memset(result[0..6], 255);
        @memcpy(result[6..12], &self.mac);
        put16(result[12..14], 0x0800);
        const ip = result[14..34];
        ip[0] = 0x45;
        put16(ip[2..4], 328);
        ip[8] = 64;
        ip[9] = 17;
        @memset(ip[16..20], 255);
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
        put16(bootp[10..12], 0x8000);
        @memcpy(bootp[28..34], &self.mac);
        put32(bootp[236..240], 0x63825363);
        var pos: usize = 240;
        const kind: u8 = if (self.phase == .discover) 1 else 3;
        try option(bootp, &pos, 53, &.{kind});
        var client_id: [7]u8 = undefined;
        client_id[0] = 1;
        @memcpy(client_id[1..], &self.mac);
        try option(bootp, &pos, 61, &client_id);
        try option(bootp, &pos, 55, &.{ 1, 3, 6, 51, 54 });
        if (kind == 3) {
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
        if (self.phase == .bound or self.phase == .failed) return;
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
                52 => return error.Malformed, // Option overload is outside this bounded fixture.
                else => {},
            }
        }
        if (!ended) return error.Malformed;
        const selected = server orelse return error.Malformed;
        if (self.phase == .request and selected != self.server) return;
        if (kind == 6 and self.phase == .request) {
            self.phase = .failed;
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
        } else if (self.phase == .request and kind == 5) {
            if (address != self.offered) return error.InvalidLease;
            const lease = Lease{ .ip = address, .mask = mask orelse return error.InvalidLease, .gateway = gateway orelse return error.InvalidLease, .server = selected, .seconds = seconds orelse return error.InvalidLease };
            const host = ~lease.mask;
            if (lease.mask == 0 or host < 3 or host & (host +% 1) != 0 or lease.seconds == 0 or !unicast(lease.gateway) or
                address & lease.mask != lease.gateway & lease.mask or address & host == 0 or address & host == host or
                lease.gateway & host == 0 or lease.gateway & host == host) return error.InvalidLease;
            self.lease = lease;
            self.phase = .bound;
        }
    }
};
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
