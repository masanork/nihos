//! Bounded IPv4/DNS/SNTP client for a wall clock. Not an authenticated time source.
//! One pending packet, no allocator, no IP fragments or DNS TCP/CNAME chasing.
const std = @import("std");
const ip = @import("dhcp.zig");
const builtin = @import("builtin");
pub const server_name = "ntp.nict.jp";
pub const retry_min: u64 = 64_000_000;
pub const resync: u64 = 6 * 60 * 60 * 1_000_000;
pub const Phase = enum(u32) { offline, waiting, arp, dns, ntp, disabled };
pub const Sample = struct { unix_us: u64, received: u64, stratum: u8, rtt_us: u32 };
pub const Report = extern struct { phase: u32, attempts: u32, replies: u32, rejected: u32, failures: u32, server: u32, stratum: u32, rtt_us: u32, unix_high: u32, unix_low: u32 };
fn defaultSection() []const u8 {
    return if (builtin.object_format == .macho) "__TEXT,__text" else ".text";
}
pub const Client = Engine(null);
pub fn Engine(comptime section: ?[]const u8) type {
    return struct {
        const Self = @This();
        phase: Phase = .offline,
        lease: ?ip.Lease = null,
        mac: [6]u8 = @splat(0),
        peer: [6]u8 = @splat(0),
        neighbor: u32 = 0,
        target: u32 = 0,
        server: u32 = 0,
        port: u16 = 49152,
        id: u16 = 0,
        token: u64 = 0,
        sequence: u32 = 0,
        next_allowed: u64 = 0,
        deadline: u64 = 0,
        sent_at: ?u64 = null,
        backoff: u64 = retry_min,
        pending: [128]u8 = @splat(0),
        pending_len: usize = 0,
        arp_for_ntp: bool = false,
        sample: ?Sample = null,
        attempts: u32 = 0,
        replies: u32 = 0,
        rejected: u32 = 0,
        failures: u32 = 0,
        stratum: u32 = 0,
        rtt_us: u32 = 0,
        unix_seconds: u64 = 0,

        /// Revokes outstanding replies/output but preserves rate limits and KoD.
        pub noinline fn disconnect(self: *Self) linksection(section orelse defaultSection()) void {
            self.lease = null;
            self.pending_len = 0;
            self.sent_at = null;
            self.sample = null;
            self.peer = @splat(0);
            self.neighbor = 0;
            if (self.phase != .disabled) self.phase = .offline;
        }
        pub noinline fn bind(self: *Self, mac: [6]u8, lease: ip.Lease, now: u64) linksection(section orelse defaultSection()) void {
            if (self.lease) |old| if (std.meta.eql(old, lease) and std.mem.eql(u8, &mac, &self.mac)) return;
            self.disconnect();
            self.mac = mac;
            self.lease = lease;
            if (self.phase == .disabled) return;
            self.phase = .waiting;
            self.deadline = now;
        }
        noinline fn fail(self: *Self, now: u64) linksection(section orelse defaultSection()) void {
            self.failures +|= 1;
            self.phase = .waiting;
            // A router may change its MAC without changing the DHCP address.
            // Retry must resolve the route again instead of pinning stale ARP.
            self.peer = @splat(0);
            self.neighbor = 0;
            self.pending_len = 0;
            self.sent_at = null;
            self.next_allowed = @max(self.next_allowed, now +| self.backoff);
            self.backoff = @min(self.backoff * 2, 131_072_000_000);
        }
        pub noinline fn tx(self: *Self, now: u64) linksection(section orelse defaultSection()) []const u8 {
            const lease = self.lease orelse return &.{};
            if (self.phase == .disabled) return &.{};
            if (self.pending_len != 0) {
                if (now >= self.deadline) {
                    self.fail(now);
                    return &.{};
                }
                return self.pending[0..self.pending_len];
            }
            if (self.phase == .waiting) {
                if (now < self.next_allowed or !unicast(lease.dns)) return &.{};
                self.sequence +%= 1;
                self.id = @truncate(self.sequence ^ @as(u32, @truncate(now)) ^ ip.get32(self.mac[2..6]));
                self.port = 49152 + (self.id & 0x3fff);
                self.target = lease.dns;
                self.server = 0;
                self.arp_for_ntp = false;
                self.route(now);
            } else if (now >= self.deadline) self.fail(now);
            return self.pending[0..self.pending_len];
        }
        noinline fn route(self: *Self, now: u64) linksection(section orelse defaultSection()) void {
            const lease = self.lease.?;
            const neighbor = if (self.target & lease.mask == lease.ip & lease.mask) self.target else lease.gateway;
            if (neighbor == self.neighbor and validMac(&self.peer)) {
                self.query(now);
                return;
            }
            self.neighbor = neighbor;
            self.peer = @splat(0);
            self.phase = .arp;
            self.deadline = now +| 3_000_000;
            const out = self.pending[0..42];
            @memset(out, 0);
            @memset(out[0..6], 255);
            @memcpy(out[6..12], &self.mac);
            ip.put16(out[12..14], 0x0806);
            ip.put16(out[14..16], 1);
            ip.put16(out[16..18], 0x0800);
            out[18] = 6;
            out[19] = 4;
            ip.put16(out[20..22], 1);
            @memcpy(out[22..28], &self.mac);
            ip.put32(out[28..32], lease.ip);
            ip.put32(out[38..42], neighbor);
            self.pending_len = out.len;
        }
        noinline fn query(self: *Self, now: u64) linksection(section orelse defaultSection()) void {
            var payload: [48]u8 = @splat(0);
            var length: usize = 0;
            if (self.arp_for_ntp) {
                self.phase = .ntp;
                payload[0] = 0x23; // LI=0, version 4, client mode.
                payload[2] = 6;
                // An unsynchronized monotonic-origin timestamp also correlates
                // replies. It is not an entropy source or authentication.
                self.token = ((@as(u64, self.id) << 32) ^ now ^ (@as(u64, self.sequence) << 48)) | 1;
                std.mem.writeInt(u64, payload[40..48], self.token, .big);
                length = 48;
            } else {
                self.phase = .dns;
                ip.put16(payload[0..2], self.id);
                ip.put16(payload[2..4], 0x0100);
                ip.put16(payload[4..6], 1);
                const name = "\x03ntp\x04nict\x02jp\x00";
                @memcpy(payload[12..][0..name.len], name);
                length = 12 + name.len;
                ip.put16(payload[length..][0..2], 1);
                ip.put16(payload[length + 2 ..][0..2], 1);
                length += 4;
            }
            self.udp(payload[0..length], if (self.arp_for_ntp) 123 else 53);
            self.sent_at = null;
            self.deadline = now +| 5_000_000;
        }
        noinline fn udp(self: *Self, payload: []const u8, port: u16) linksection(section orelse defaultSection()) void {
            const out = self.pending[0 .. 42 + payload.len];
            @memset(out, 0);
            @memcpy(out[0..6], &self.peer);
            @memcpy(out[6..12], &self.mac);
            ip.put16(out[12..14], 0x0800);
            const header = out[14..34];
            header[0] = 0x45;
            header[8] = 64;
            header[9] = 17;
            ip.put16(header[2..4], @intCast(28 + payload.len));
            ip.put32(header[12..16], self.lease.?.ip);
            ip.put32(header[16..20], self.target);
            ip.put16(header[10..12], ip.checksum(header));
            const udp_bytes = out[34..];
            ip.put16(udp_bytes[0..2], self.port);
            ip.put16(udp_bytes[2..4], port);
            ip.put16(udp_bytes[4..6], @intCast(udp_bytes.len));
            @memcpy(udp_bytes[8..], payload);
            var sum = sum16(header[12..20]) + 17 + @as(u32, @intCast(udp_bytes.len)) + sum16(udp_bytes);
            while (sum > 65535) sum = (sum & 65535) + (sum >> 16);
            const checksum: u16 = ~@as(u16, @intCast(sum));
            ip.put16(udp_bytes[6..8], if (checksum == 0) 65535 else checksum);
            self.pending_len = out.len;
        }
        /// Caller invokes this only when the complete Ethernet packet was
        /// accepted; a blocked transport retains identical bytes and token.
        pub noinline fn sent(self: *Self, now: u64) linksection(section orelse defaultSection()) void {
            if (self.pending_len == 0) return;
            self.pending_len = 0;
            self.sent_at = now;
            self.deadline = now +| (if (self.phase == .arp) @as(u64, 3_000_000) else 5_000_000);
            if (self.phase == .ntp) {
                self.attempts +|= 1;
                self.next_allowed = @max(self.next_allowed, now +| self.backoff);
            }
        }
        pub noinline fn receive(self: *Self, frame: []const u8, now: u64) linksection(section orelse defaultSection()) void {
            if (self.lease == null or self.phase == .disabled or self.phase == .waiting or self.phase == .offline or self.sent_at == null) return;
            if (now < self.sent_at.? or now >= self.deadline) {
                self.fail(now);
                return;
            }
            if (self.phase == .arp) {
                if (frame.len < 42 or ip.get16(frame[12..14]) != 0x0806 or ip.get16(frame[14..16]) != 1 or
                    ip.get16(frame[16..18]) != 0x0800 or frame[18] != 6 or frame[19] != 4 or ip.get16(frame[20..22]) != 2 or
                    !std.mem.eql(u8, frame[0..6], &self.mac) or !std.mem.eql(u8, frame[32..38], &self.mac) or
                    !std.mem.eql(u8, frame[6..12], frame[22..28]) or !validMac(frame[6..12]) or
                    ip.get32(frame[28..32]) != self.neighbor or ip.get32(frame[38..42]) != self.lease.?.ip) return;
                self.peer = frame[6..12].*;
                self.query(now);
                return;
            }
            const payload = self.datagram(frame) orelse return;
            if (self.phase == .dns) {
                const address = dnsAnswer(payload, self.id) orelse {
                    self.rejected +|= 1;
                    return;
                };
                self.server = address;
                self.target = address;
                self.arp_for_ntp = true;
                self.sent_at = null;
                self.route(now);
            } else if (self.phase == .ntp) self.acceptTime(payload, now);
        }
        noinline fn datagram(self: *Self, frame: []const u8) linksection(section orelse defaultSection()) ?[]const u8 {
            if (frame.len < 42 or ip.get16(frame[12..14]) != 0x0800 or !std.mem.eql(u8, frame[0..6], &self.mac) or
                !std.mem.eql(u8, frame[6..12], &self.peer)) return null;
            const header = frame[14..];
            if (header[0] != 0x45 or header[9] != 17 or ip.get16(header[6..8]) & 0x3fff != 0 or ip.checksum(header[0..20]) != 0 or
                ip.get32(header[12..16]) != self.target or ip.get32(header[16..20]) != self.lease.?.ip) return null;
            const length = ip.get16(header[2..4]);
            if (length < 28 or length > header.len) return null;
            const udp_bytes = header[20..length];
            if (ip.get16(udp_bytes[0..2]) != @as(u16, if (self.phase == .dns) 53 else 123) or
                ip.get16(udp_bytes[2..4]) != self.port or ip.get16(udp_bytes[4..6]) != udp_bytes.len) return null;
            if (ip.get16(udp_bytes[6..8]) != 0) {
                var sum = sum16(header[12..20]) + 17 + @as(u32, @intCast(udp_bytes.len)) + sum16(udp_bytes);
                while (sum > 65535) sum = (sum & 65535) + (sum >> 16);
                if (sum != 65535) return null;
            }
            return udp_bytes[8..];
        }
        noinline fn acceptTime(self: *Self, bytes: []const u8, now: u64) linksection(section orelse defaultSection()) void {
            if (bytes.len != 48 or bytes[0] & 7 != 4 or (bytes[0] >> 3) & 7 < 3 or (bytes[0] >> 3) & 7 > 4 or
                std.mem.readInt(u64, bytes[24..32], .big) != self.token)
            {
                self.rejected +|= 1;
                return;
            }
            if (bytes[1] == 0) {
                self.pending_len = 0;
                self.sent_at = null;
                if (std.mem.eql(u8, bytes[12..16], "RATE")) {
                    self.backoff = @min(@max(self.backoff * 2, @as(u64, 1_000_000) << @as(u6, @intCast(@min(bytes[2], 17)))), 131_072_000_000);
                    self.next_allowed = now +| self.backoff;
                    self.phase = .waiting;
                } else self.phase = .disabled;
                self.failures +|= 1;
                return;
            }
            if (bytes[0] >> 6 == 3 or bytes[1] > 15 or ip.get32(bytes[8..12]) > 16 * 65536) {
                self.rejected +|= 1;
                return;
            }
            const received = timestamp(bytes[32..40]) orelse {
                self.rejected +|= 1;
                return;
            };
            const transmitted = timestamp(bytes[40..48]) orelse {
                self.rejected +|= 1;
                return;
            };
            const rtt = now - self.sent_at.?;
            if (transmitted < received or transmitted - received > rtt or rtt > 2_000_000) {
                self.rejected +|= 1;
                return;
            }
            const estimated = transmitted + (rtt - (transmitted - received)) / 2;
            self.sample = .{ .unix_us = estimated, .received = now, .stratum = bytes[1], .rtt_us = @intCast(rtt) };
            self.stratum = bytes[1];
            self.rtt_us = @intCast(rtt);
            self.unix_seconds = estimated / 1_000_000;
            self.replies +|= 1;
            self.phase = .waiting;
            self.sent_at = null;
            self.backoff = retry_min;
            self.next_allowed = now +| resync;
        }
        pub noinline fn take(self: *Self, now: u64) linksection(section orelse defaultSection()) ?Sample {
            const value = self.sample orelse return null;
            self.sample = null;
            if (self.lease == null or now < value.received or now - value.received > 5_000_000) return null;
            return value;
        }
        pub noinline fn snapshot(self: *const Self) linksection(section orelse defaultSection()) Report {
            return .{ .phase = @backingInt(self.phase), .attempts = self.attempts, .replies = self.replies, .rejected = self.rejected, .failures = self.failures, .server = self.server, .stratum = self.stratum, .rtt_us = self.rtt_us, .unix_high = @truncate(self.unix_seconds >> 32), .unix_low = @truncate(self.unix_seconds) };
        }
        noinline fn timestamp(bytes: *const [8]u8) linksection(section orelse defaultSection()) ?u64 {
            const raw = std.mem.readInt(u64, bytes, .big);
            if (raw == 0) return null;
            const seconds = raw >> 32;
            const unix = seconds + (if (seconds < 3_155_673_600) @as(u64, 1) << 32 else 0) - 2_208_988_800;
            if (unix < 946_684_800 or unix >= 4_102_444_800) return null;
            return unix * 1_000_000 + ((raw & 0xffffffff) * 1_000_000 >> 32);
        }
        noinline fn skipName(bytes: []const u8, start: usize) linksection(section orelse defaultSection()) ?usize {
            var pos = start;
            for (0..128) |_| {
                if (pos >= bytes.len) return null;
                const size = bytes[pos];
                pos += 1;
                if (size == 0) return pos;
                if (size & 0xc0 == 0xc0) {
                    if (pos >= bytes.len or ((@as(usize, size & 0x3f) << 8) | bytes[pos]) >= bytes.len) return null;
                    return pos + 1;
                }
                if (size > 63 or size > bytes.len - pos) return null;
                pos += size;
            }
            return null;
        }
        noinline fn dnsAnswer(bytes: []const u8, id: u16) linksection(section orelse defaultSection()) ?u32 {
            const question = "\x03ntp\x04nict\x02jp\x00\x00\x01\x00\x01";
            if (bytes.len < 12 + question.len or ip.get16(bytes[0..2]) != id or ip.get16(bytes[2..4]) & 0xfa0f != 0x8000 or
                ip.get16(bytes[4..6]) != 1 or !std.mem.eql(u8, bytes[12..][0..question.len], question)) return null;
            const answers = ip.get16(bytes[6..8]);
            if (answers == 0 or answers > 16) return null;
            var pos: usize = 12 + question.len;
            for (0..answers) |_| {
                const name = pos;
                pos = skipName(bytes, pos) orelse return null;
                if (bytes.len - pos < 10) return null;
                const kind = ip.get16(bytes[pos..][0..2]);
                const class = ip.get16(bytes[pos + 2 ..][0..2]);
                const length = ip.get16(bytes[pos + 8 ..][0..2]);
                pos += 10;
                if (length > bytes.len - pos) return null;
                // Only an A record for the exact queried name, not an unrelated
                // additional record or an unchecked compressed-name chain.
                const matching = (bytes[name] == 0xc0 and name + 1 < bytes.len and bytes[name + 1] == 12) or
                    (pos - 10 - name == question.len - 4 and std.mem.eql(u8, bytes[name .. pos - 10], question[0 .. question.len - 4]));
                if (matching and kind == 1 and class == 1 and length == 4) {
                    const address = ip.get32(bytes[pos..][0..4]);
                    return if (unicast(address)) address else null;
                }
                pos += length;
            }
            return null;
        }
        noinline fn validMac(mac: []const u8) linksection(section orelse defaultSection()) bool {
            return mac[0] & 1 == 0 and !std.mem.allEqual(u8, mac, 0);
        }
        noinline fn unicast(address: u32) linksection(section orelse defaultSection()) bool {
            const first = address >> 24;
            return first != 0 and first != 127 and first < 224;
        }
        noinline fn sum16(bytes: []const u8) linksection(section orelse defaultSection()) u32 {
            var sum: u32 = 0;
            var pos: usize = 0;
            while (pos + 1 < bytes.len) : (pos += 2) sum += ip.get16(bytes[pos..][0..2]);
            if (pos < bytes.len) sum += @as(u32, bytes[pos]) << 8;
            return sum;
        }
    };
}
