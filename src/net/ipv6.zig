//! Bounded IPv6 boot probe: one link-local address, one SLAAC /64, one router.
//! RFC 4861/4862/4443. No sockets, forwarding, DHCPv6, fragmentation or NUD cache.
const std = @import("std");
pub const Address = [16]u8;
pub const zero: Address = @splat(0);
pub const all_nodes: Address = .{ 0xff, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
pub const all_routers: Address = .{ 0xff, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2 };
pub const Stage = enum { join, dad_link, wait_link, discover, dad_slaac, wait_slaac, resolve, ping, done, no_router, timeout, duplicate };
pub const Error = error{ Capacity, Malformed, Checksum, Duplicate, Clock };
pub fn equal(a: Address, b: Address) bool {
    return std.mem.eql(u8, &a, &b);
}
pub fn linkLocal(mac: [6]u8) Address {
    return .{ 0xfe, 0x80, 0, 0, 0, 0, 0, 0, mac[0] ^ 2, mac[1], mac[2], 0xff, 0xfe, mac[3], mac[4], mac[5] };
}
pub fn solicited(target: Address) Address {
    return .{ 0xff, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0xff, target[13], target[14], target[15] };
}
fn multicast(a: Address) bool {
    return a[0] == 0xff;
}
fn linklocal(a: Address) bool {
    return a[0] == 0xfe and a[1] & 0xc0 == 0x80;
}
fn usable(a: Address) bool {
    return !multicast(a) and !equal(a, zero) and !equal(a, .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 });
}
fn macValid(mac: []const u8) bool {
    return mac.len == 6 and mac[0] & 1 == 0 and !std.mem.allEqual(u8, mac, 0);
}
pub fn multicastMac(a: Address) [6]u8 {
    return .{ 0x33, 0x33, a[12], a[13], a[14], a[15] };
}

pub const Client = struct {
    mac: [6]u8,
    ll: Address,
    address: Address = zero,
    router: Address = zero,
    router_mac: ?[6]u8 = null,
    stage: Stage = .join,
    ll_valid: bool = false,
    slaac_valid: bool = false,
    started: u64,
    deadline: u64,
    next_send: u64,
    sends: u8 = 0,
    router_until: u64 = 0,
    valid_until: u64 = 0,
    preferred_until: u64 = 0,
    ras: u32 = 0,
    ns_received: u32 = 0,
    na_received: u32 = 0,
    ping_replies: u32 = 0,
    echo_requests: u32 = 0,
    dropped: u32 = 0,
    received: u32 = 0,
    solicitations: u32 = 0,
    cookie: u64,
    ping_sent: bool = false,
    output: [256]u8 = @splat(0),
    output_len: usize = 0,
    response: [256]u8 = @splat(0),
    response_len: usize = 0,
    response_tx: bool = false,
    pending_stage: Stage = .join,
    pub fn init(mac: [6]u8, now: u64) Client {
        return .{ .mac = mac, .ll = linkLocal(mac), .started = now, .deadline = now + 35_000_000, .next_send = now + (now ^ @as(u64, mac[5]) * 7193) % 1_000_000, .cookie = now ^ (@as(u64, mac[4]) << 40) ^ (@as(u64, mac[5]) << 32) ^ 0x4e49484f535636 };
    }
    pub fn finished(self: *const Client) bool {
        return self.stage == .done or self.stage == .no_router or self.stage == .timeout or self.stage == .duplicate;
    }
    pub fn complete(self: *const Client) bool {
        return self.ll_valid and self.slaac_valid and self.ping_replies != 0 and self.stage == .done;
    }
    pub fn tick(self: *Client, now: u64) Error!void {
        if (now < self.started) return error.Clock;
        if (self.stage == .duplicate) return error.Duplicate;
        if (self.finished()) return;
        if (self.router_until != 0 and now >= self.router_until) {
            self.router = zero;
            self.router_mac = null;
            self.stage = .timeout;
            return;
        }
        if (self.valid_until != 0 and (now >= self.valid_until or now >= self.preferred_until)) {
            self.slaac_valid = false;
            self.stage = .timeout;
            return;
        }
        if (self.stage == .wait_link and now >= self.next_send) {
            self.ll_valid = true;
            self.stage = .discover;
            self.sends = 0;
            self.next_send = now;
            self.deadline = now + 15_000_000;
        }
        if (self.stage == .wait_slaac and now >= self.next_send) {
            self.slaac_valid = true;
            self.stage = if (self.router_mac != null) .ping else .resolve;
            self.sends = 0;
            self.next_send = now;
            self.deadline = now + 5_000_000;
        }
        if (self.stage == .discover and usable(self.router) and usable(self.address)) {
            self.stage = .dad_slaac;
            self.next_send = now;
            self.sends = 0;
            self.deadline = now + 5_000_000;
        }
        if (now >= self.deadline) {
            if (self.stage == .discover and usable(self.router)) {
                self.stage = if (self.router_mac != null) .ping else .resolve;
                self.sends = 0;
                self.next_send = now;
                self.deadline = now + 5_000_000;
            } else self.stage = if (self.stage == .discover) .no_router else .timeout;
        }
    }
    /// Retains an entire Ethernet packet until sent(). Zero transport credits
    /// never advance DAD, retry counters or the ping acknowledgement window.
    pub fn tx(self: *Client, now: u64) Error![]const u8 {
        try self.tick(now);
        if (self.output_len != 0) return self.output[0..self.output_len];
        if (self.response_len != 0) {
            @memcpy(self.output[0..self.response_len], self.response[0..self.response_len]);
            self.output_len = self.response_len;
            self.response_len = 0;
            self.response_tx = true;
            return self.output[0..self.output_len];
        }
        if (self.finished() or now < self.next_send) return &.{};
        var message: [64]u8 = @splat(0);
        var source = self.ll;
        var destination = all_routers;
        var length: usize = 0;
        var hop: u8 = 255;
        var destination_mac: [6]u8 = undefined;
        var hbh = false;
        switch (self.stage) {
            .join => {
                source = zero;
                destination = .{ 0xff, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x16 };
                message[0] = 143;
                put16(message[6..8], 1);
                message[8] = 4;
                @memcpy(message[12..28], &solicited(self.ll));
                length = 28;
                hop = 1;
                hbh = true;
            },
            .dad_link, .dad_slaac => {
                const target = if (self.stage == .dad_link) self.ll else self.address;
                source = zero;
                destination = solicited(target);
                message[0] = 135;
                @memcpy(message[8..24], &target);
                length = 24;
            },
            .discover => {
                if (self.sends >= 3) return &.{};
                message[0] = 133;
                message[8] = 1;
                message[9] = 1;
                @memcpy(message[10..16], &self.mac);
                length = 16;
            },
            .resolve => {
                if (self.sends >= 3) return &.{};
                destination = solicited(self.router);
                message[0] = 135;
                @memcpy(message[8..24], &self.router);
                message[24] = 1;
                message[25] = 1;
                @memcpy(message[26..32], &self.mac);
                length = 32;
            },
            .ping => {
                if (self.sends >= 3) return &.{};
                destination = self.router;
                hop = 64;
                message[0] = 128;
                put16(message[4..6], 0x4e49);
                put16(message[6..8], 1);
                std.mem.writeInt(u64, message[8..16], self.cookie, .big);
                length = 16;
            },
            else => return &.{},
        }
        destination_mac = if (multicast(destination)) multicastMac(destination) else self.router_mac orelse return error.Malformed;
        self.output_len = (try packet(&self.output, self.mac, destination_mac, source, destination, hop, message[0..length], hbh)).len;
        self.response_tx = false;
        self.pending_stage = self.stage;
        return self.output[0..self.output_len];
    }
    pub fn sent(self: *Client, now: u64) void {
        self.output_len = 0;
        if (self.response_tx) {
            self.response_tx = false;
            return;
        }
        switch (self.pending_stage) {
            .join => {
                self.stage = .dad_link;
                self.next_send = now;
            },
            .dad_link => {
                self.stage = .wait_link;
                self.next_send = now + 1_000_000;
            },
            .dad_slaac => {
                self.stage = .wait_slaac;
                self.next_send = now + 1_000_000;
            },
            .discover => {
                self.sends += 1;
                self.solicitations += 1;
                self.next_send = now + 4_000_000;
            },
            .resolve, .ping => {
                self.sends += 1;
                self.next_send = now + 1_000_000;
                if (self.pending_stage == .ping) self.ping_sent = true;
            },
            else => {},
        }
    }
    pub fn receive(self: *Client, frame: []const u8, now: u64) Error!void {
        if (frame.len < 54 or get16(frame[12..14]) != 0x86dd) return;
        self.received +|= 1;
        if (std.mem.eql(u8, frame[6..12], &self.mac)) return; // reflected own multicast
        if (!macValid(frame[6..12])) return error.Malformed;
        const ip = frame[14..];
        if (ip[0] >> 4 != 6) return error.Malformed;
        const length: usize = get16(ip[4..6]);
        if (length > ip.len - 40 or length < 4) return error.Malformed;
        const source: Address = ip[8..24].*;
        const destination: Address = ip[24..40].*;
        if (equal(destination, zero)) return error.Malformed;
        const expected_mac = if (multicast(destination)) multicastMac(destination) else self.mac;
        if (!std.mem.eql(u8, frame[0..6], &expected_mac)) return;
        if (!equal(destination, self.ll) and !equal(destination, self.address) and !equal(destination, all_nodes) and !equal(destination, solicited(self.ll))) return;
        var next = ip[6];
        var payload = ip[40..][0..length];
        if (next == 0) {
            if (payload.len < 8 or payload[1] != 0) return error.Malformed;
            next = payload[0];
            payload = payload[8..];
        }
        if (next != 58) return;
        if (payload.len < 4) return error.Malformed;
        if (icmpChecksum(source, destination, payload) != 0) return error.Checksum;
        if (payload[1] != 0) return error.Malformed;
        if (payload[0] >= 133 and payload[0] <= 137 and ip[7] != 255) return error.Malformed;
        if (payload[0] == 134) try self.routerAdvertisement(source, payload, frame[6..12], now) else if (payload[0] == 135 or payload[0] == 136) try self.neighbor(source, destination, payload, frame[6..12], now) else if (payload[0] == 129 and self.ping_sent and equal(source, self.router) and equal(destination, self.ll) and payload.len == 16) {
            if (get16(payload[4..6]) == 0x4e49 and get16(payload[6..8]) == 1 and std.mem.readInt(u64, payload[8..16], .big) == self.cookie) {
                self.ping_replies +|= 1;
                self.stage = .done;
            }
        } else if (payload[0] == 128 and self.owns(destination) and usable(source) and payload.len >= 8 and payload.len <= 128) {
            var message: [128]u8 = undefined;
            @memcpy(message[0..payload.len], payload);
            message[0] = 129;
            message[2] = 0;
            message[3] = 0;
            try self.queue(frame[6..12].*, destination, source, 64, message[0..payload.len]);
            self.echo_requests +|= 1;
        }
    }
    fn owns(self: *const Client, a: Address) bool {
        return (self.ll_valid and equal(a, self.ll)) or (self.slaac_valid and equal(a, self.address));
    }
    fn routerAdvertisement(self: *Client, source: Address, message: []const u8, ethernet_mac: []const u8, now: u64) Error!void {
        if (!self.ll_valid or !linklocal(source) or message.len < 16) return error.Malformed;
        var options = Options{ .bytes = message[16..] };
        var mac: ?[6]u8 = null;
        var prefix: ?Address = null;
        var valid: u32 = 0;
        var preferred: u32 = 0;
        while (try options.next()) |option| switch (option[0]) {
            1 => {
                if (option.len != 8 or mac != null or !macValid(option[2..8]) or !std.mem.eql(u8, option[2..8], ethernet_mac)) return error.Malformed;
                mac = option[2..8].*;
            },
            3 => {
                if (option.len != 32) return error.Malformed;
                const p: Address = option[16..32].*;
                const v = get32(option[4..8]);
                const preferred_time = get32(option[8..12]);
                if (prefix == null and option[2] == 64 and option[3] & 0x40 != 0 and !linklocal(p) and usable(p) and v != 0 and preferred_time != 0 and preferred_time <= v) {
                    prefix = p;
                    valid = v;
                    preferred = preferred_time;
                }
            },
            else => {},
        };
        self.ras +|= 1;
        if (get16(message[6..8]) == 0) {
            if (equal(source, self.router)) {
                self.router = zero;
                self.router_mac = null;
                self.router_until = 0;
            }
            return;
        }
        if (usable(self.router) and !equal(source, self.router)) return;
        self.router = source;
        self.router_until = now + @as(u64, get16(message[6..8])) * 1_000_000;
        if (mac) |value| self.router_mac = value;
        if (prefix) |p| if (equal(self.address, zero)) {
            self.address = p;
            @memcpy(self.address[8..], self.ll[8..]);
            self.valid_until = now + @as(u64, valid) * 1_000_000;
            self.preferred_until = now + @as(u64, preferred) * 1_000_000;
        };
    }
    fn neighbor(self: *Client, source: Address, destination: Address, message: []const u8, ethernet_mac: []const u8, now: u64) Error!void {
        if (message.len < 24) return error.Malformed;
        const target: Address = message[8..24].*;
        if (!usable(target)) return error.Malformed;
        var options = Options{ .bytes = message[24..] };
        var link_mac: ?[6]u8 = null;
        while (try options.next()) |option| if (option[0] == (if (message[0] == 135) @as(u8, 1) else 2)) {
            if (option.len != 8 or link_mac != null or !macValid(option[2..8]) or !std.mem.eql(u8, option[2..8], ethernet_mac)) return error.Malformed;
            link_mac = option[2..8].*;
        };
        if (message[0] == 135 and equal(source, zero) and (!equal(destination, solicited(target)) or link_mac != null)) return error.Malformed;
        if (message[0] == 136 and (!usable(source) or (multicast(destination) and message[4] & 0x40 != 0))) return error.Malformed;
        const tentative = ((!self.ll_valid and equal(target, self.ll)) or (!self.slaac_valid and !equal(self.address, zero) and equal(target, self.address)));
        if (tentative and (message[0] == 136 or equal(source, zero))) {
            if (equal(target, self.ll)) self.ll_valid = false;
            if (equal(target, self.address)) self.slaac_valid = false;
            self.stage = .duplicate;
            return error.Duplicate;
        }
        if (message[0] == 136) {
            self.na_received +|= 1;
            if (self.stage == .resolve and equal(target, self.router) and equal(source, self.router) and message[4] & 0x40 != 0 and link_mac != null) {
                self.router_mac = link_mac;
                self.stage = .ping;
                self.sends = 0;
                self.next_send = now;
                self.deadline = now + 5_000_000;
            }
        } else {
            self.ns_received +|= 1;
            if (!self.owns(target) or (!equal(source, zero) and !usable(source))) return;
            var reply: [32]u8 = @splat(0);
            reply[0] = 136;
            reply[4] = if (equal(source, zero)) 0x20 else 0x60;
            @memcpy(reply[8..24], &target);
            reply[24] = 2;
            reply[25] = 1;
            @memcpy(reply[26..32], &self.mac);
            const dst = if (equal(source, zero)) all_nodes else source;
            try self.queue(if (multicast(dst)) multicastMac(dst) else ethernet_mac[0..6].*, target, dst, 255, &reply);
        }
    }
    fn queue(self: *Client, destination_mac: [6]u8, source: Address, destination: Address, hop: u8, message: []const u8) Error!void {
        if (self.response_len != 0) {
            self.dropped +|= 1;
            return;
        }
        self.response_len = (try packet(&self.response, self.mac, destination_mac, source, destination, hop, message, false)).len;
    }
};
const Options = struct {
    bytes: []const u8,
    pos: usize = 0,
    fn next(self: *Options) Error!?[]const u8 {
        if (self.pos == self.bytes.len) return null;
        if (self.bytes.len - self.pos < 2) return error.Malformed;
        const length = @as(usize, self.bytes[self.pos + 1]) * 8;
        if (length == 0 or length > self.bytes.len - self.pos) return error.Malformed;
        const result = self.bytes[self.pos..][0..length];
        self.pos += length;
        return result;
    }
};
pub fn packet(out: []u8, source_mac: [6]u8, destination_mac: [6]u8, source: Address, destination: Address, hop: u8, message: []const u8, hbh: bool) Error![]const u8 {
    const extra: usize = if (hbh) 8 else 0;
    if (message.len < 4 or message.len + extra > 65535 or out.len < 54 + extra + message.len) return error.Capacity;
    const result = out[0 .. 54 + extra + message.len];
    @memset(result, 0);
    @memcpy(result[0..6], &destination_mac);
    @memcpy(result[6..12], &source_mac);
    put16(result[12..14], 0x86dd);
    const ip = result[14..54];
    ip[0] = 0x60;
    put16(ip[4..6], @intCast(message.len + extra));
    ip[6] = if (hbh) 0 else 58;
    ip[7] = hop;
    @memcpy(ip[8..24], &source);
    @memcpy(ip[24..40], &destination);
    if (hbh) @memcpy(result[54..62], &[_]u8{ 58, 0, 5, 2, 0, 0, 1, 0 });
    const payload = result[54 + extra ..];
    @memcpy(payload, message);
    payload[2] = 0;
    payload[3] = 0;
    put16(payload[2..4], icmpChecksum(source, destination, payload));
    return result;
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
fn sum16(bytes: []const u8) u32 {
    var sum: u32 = 0;
    var i: usize = 0;
    while (i + 1 < bytes.len) : (i += 2) sum += get16(bytes[i..]);
    if (i != bytes.len) sum += @as(u32, bytes[i]) << 8;
    return sum;
}
pub fn icmpChecksum(source: Address, destination: Address, message: []const u8) u16 {
    var sum = sum16(&source) + sum16(&destination) + @as(u32, @intCast(message.len)) + 58 + sum16(message);
    while (sum > 65535) sum = (sum & 65535) + (sum >> 16);
    return ~@as(u16, @truncate(sum));
}
