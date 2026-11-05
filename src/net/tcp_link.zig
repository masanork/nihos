//! Single-owner Ethernet/ARP/IPv4 TCP integration for one experimental socket.
//! The network owner supplies the lease and serializes full-frame send/receive.
//! This is not yet wired to Hosted, DHCP, DMA, or an application socket table.
const std = @import("std");
const arp = @import("arp_resolver.zig");
const connect = @import("tcp_connect.zig");
const tcp = @import("tcp_stream.zig");
pub const Error = arp.Error || connect.Error || tcp.Error || error{ Busy, FrameTooLarge };
pub const Link = struct {
    const State = enum { idle, resolving, opening, active, failed };
    const Pending = enum { none, arp, open, stream };
    state: State = .idle,
    pending: Pending = .none,
    lease: arp.Lease = .{ .ip = @splat(0), .mask = @splat(0), .gateway = @splat(0), .mac = @splat(0), .epoch = 0 },
    target: connect.Endpoint = .{ .address = @splat(0), .port = 0 },
    local_port: u16 = 0,
    initial_seq: u32 = 0,
    deadline: u64 = 0,
    resolver: arp.Resolver = .{},
    opening: connect.Connect = .{},
    stream: ?tcp.Stream = null,
    frame: [1600]u8 = @splat(0),
    frame_len: usize = 0,

    /// Initialize in stable caller-owned storage without a large aggregate copy.
    pub fn initInPlace(self: *Link) void {
        self.state = .idle;
        self.pending = .none;
        self.lease = .{ .ip = @splat(0), .mask = @splat(0), .gateway = @splat(0), .mac = @splat(0), .epoch = 0 };
        self.target = .{ .address = @splat(0), .port = 0 };
        self.local_port = 0;
        self.initial_seq = 0;
        self.deadline = 0;
        self.resolver = .{};
        self.opening = .{};
        self.stream = null;
        @memset(&self.frame, 0);
        self.frame_len = 0;
    }

    pub fn begin(self: *Link, lease: arp.Lease, target: connect.Endpoint, local_port: u16, initial_seq: u32, now: u64, deadline: u64) Error!void {
        if (self.state != .idle) return error.InvalidState;
        if (local_port == 0 or target.port == 0) return error.InvalidArgument;
        try self.resolver.begin(lease, target.address, now, deadline);
        self.lease = lease;
        self.target = target;
        self.local_port = local_port;
        self.initial_seq = initial_seq;
        self.deadline = deadline;
        self.state = .resolving;
    }
    /// The returned full Ethernet frame belongs to this owner. Until sent(),
    /// the adapter must queue incoming frames rather than call receive().
    pub fn poll(self: *Link, epoch: u64, now: u64) Error!?[]const u8 {
        try self.check(epoch);
        if (self.pending != .none) {
            switch (self.pending) {
                .arp => _ = self.resolver.poll(epoch, now) catch |err| return self.fail(err),
                .open => _ = self.opening.poll(now) catch |err| return self.fail(err),
                .stream => if (self.stream) |*s| {
                    _ = s.poll(now) catch |err| return self.fail(err);
                } else return error.InvalidState,
                .none => unreachable,
            }
            return self.frame[0..self.frame_len];
        }
        if (self.state == .resolving) {
            const request = self.resolver.poll(epoch, now) catch |err| return self.fail(err);
            if (request) |bytes| {
                @memcpy(self.frame[0..bytes.len], bytes);
                self.frame_len = bytes.len;
                self.pending = .arp;
                return self.frame[0..self.frame_len];
            }
            return null;
        }
        const packet = if (self.state == .opening) self.opening.poll(now) catch |err| return self.fail(err) else if (self.stream) |*s| s.poll(now) catch |err| return self.fail(err) else return error.InvalidState;
        const bytes = packet orelse return null;
        const route = (self.resolver.result(epoch, now) catch |err| return self.fail(err)) orelse return error.InvalidState;
        if (bytes.len > self.frame.len - 14) return self.fail(error.FrameTooLarge);
        self.frame[0..6].* = route.mac;
        self.frame[6..12].* = self.lease.mac;
        self.frame[12] = 8;
        self.frame[13] = 0;
        @memcpy(self.frame[14..][0..bytes.len], bytes);
        self.frame_len = bytes.len + 14;
        self.pending = if (self.state == .opening) .open else .stream;
        return self.frame[0..self.frame_len];
    }
    /// Call only after successful whole-frame submission, never after an
    /// ambiguous partial write; such failures require invalidate().
    pub fn sent(self: *Link, epoch: u64, now: u64) Error!void {
        try self.check(epoch);
        switch (self.pending) {
            .none => return error.InvalidState,
            .arp => self.resolver.sent(epoch, now) catch |err| return self.fail(err),
            .open => {
                self.opening.sent(now) catch |err| return self.fail(err);
                if (self.opening.result()) |established| {
                    self.stream = tcp.Stream.init(established);
                    self.state = .active;
                }
            },
            .stream => if (self.stream) |*s| {
                s.sent(now) catch |err| return self.fail(err);
            } else return error.InvalidState,
        }
        self.pending = .none;
        self.frame_len = 0;
    }
    /// Returns false for unrelated frames; the network owner can route those
    /// to DHCP, ARP responders and other clients. Lease change fails closed.
    pub fn receive(self: *Link, epoch: u64, now: u64, frame: []const u8) Error!bool {
        try self.check(epoch);
        if (self.pending != .none) return error.Busy;
        if (self.state == .resolving) {
            const found = self.resolver.receive(epoch, now, frame) catch |err| return self.fail(err);
            if (!found) return false;
            self.opening.begin(.{ .address = self.lease.ip, .port = self.local_port }, self.target, self.initial_seq, now, self.deadline) catch |err| return self.fail(err);
            self.state = .opening;
            return true;
        }
        if (frame.len < 14 or frame[12] != 8 or frame[13] != 0 or !std.mem.eql(u8, frame[0..6], &self.lease.mac)) return false;
        const route = (self.resolver.result(epoch, now) catch |err| return self.fail(err)) orelse return error.InvalidState;
        if (!std.mem.eql(u8, frame[6..12], &route.mac)) return false;
        if (self.state == .opening) return self.opening.receive(frame[14..], now) catch |err| return self.fail(err);
        if (self.stream) |*s| return s.receive(frame[14..]) catch |err| return self.fail(err);
        return error.InvalidState;
    }
    pub fn ready(self: *const Link) bool {
        return self.state == .active;
    }
    pub fn write(self: *Link, epoch: u64, bytes: []const u8, now: u64, deadline: u64) Error!usize {
        try self.check(epoch);
        if (self.pending != .none) return error.Busy;
        if (self.stream) |*s| return s.write(bytes, now, deadline);
        return error.InvalidState;
    }
    pub fn read(self: *Link, epoch: u64, out: []u8) Error!usize {
        try self.check(epoch);
        if (self.pending != .none) return error.Busy;
        if (self.stream) |*s| return s.read(out);
        return error.InvalidState;
    }
    pub fn closeWrite(self: *Link, epoch: u64, now: u64, deadline: u64) Error!void {
        try self.check(epoch);
        if (self.pending != .none) return error.Busy;
        if (self.stream) |*s| return s.closeWrite(now, deadline);
        return error.InvalidState;
    }
    pub fn closeHandshakeComplete(self: *const Link) bool {
        if (self.state != .active or self.pending != .none) return false;
        if (self.stream) |*s| return s.closeHandshakeComplete();
        return false;
    }
    pub fn invalidate(self: *Link) void {
        self.state = .failed;
        self.pending = .none;
        self.frame_len = 0;
        self.resolver.invalidate();
        self.opening.transportFailed();
        std.crypto.secureZero(u8, &self.frame);
        if (self.stream) |*s| {
            std.crypto.secureZero(u8, &s.tx);
            std.crypto.secureZero(u8, &s.rx);
            s.failed = true;
        }
    }
    fn check(self: *Link, epoch: u64) Error!void {
        if (self.state == .idle or self.state == .failed) return error.InvalidState;
        if (epoch != self.lease.epoch) {
            self.invalidate();
            return error.StaleLease;
        }
    }
    fn fail(self: *Link, err: Error) Error {
        self.invalidate();
        return err;
    }
};

test "in-place initialization resets reused link storage" {
    // SAFETY: initInPlace initializes every live field before use.
    var link: Link = undefined;
    @memset(std.mem.asBytes(&link), 0xa5);
    link.initInPlace();
    try std.testing.expectEqualDeep(Link{}, link);
}

test "link owns outgoing frame and invalidates on lease change" {
    var link: Link = .{};
    const lease = arp.Lease{ .ip = .{ 10, 0, 2, 15 }, .mask = .{ 255, 255, 255, 0 }, .gateway = .{ 10, 0, 2, 2 }, .mac = .{ 0x52, 0x54, 0, 0x12, 0x34, 0x56 }, .epoch = 7 };
    try link.begin(lease, .{ .address = .{ 10, 0, 2, 2 }, .port = 22 }, 50001, 123, 0, 5000);
    const pending = (try link.poll(7, 0)).?;
    try std.testing.expectEqual(@as(usize, 42), pending.len);
    try std.testing.expectError(error.Busy, link.receive(7, 0, pending));
    try std.testing.expectError(error.StaleLease, link.poll(8, 1));
    try std.testing.expectError(error.InvalidState, link.poll(7, 2));
    var timed: Link = .{};
    try timed.begin(lease, .{ .address = .{ 10, 0, 2, 2 }, .port = 22 }, 50001, 123, 0, 10);
    _ = try timed.poll(7, 0);
    try std.testing.expectError(error.Timeout, timed.poll(7, 10));
    try std.testing.expectError(error.InvalidState, timed.sent(7, 11));
}

test "link resolves ARP then accepts only matching Ethernet and TCP handshake" {
    const wire = @import("tcp_wire.zig");
    var link: Link = .{};
    const lease = arp.Lease{ .ip = .{ 10, 0, 2, 15 }, .mask = .{ 255, 255, 255, 0 }, .gateway = .{ 10, 0, 2, 2 }, .mac = .{ 0x52, 0x54, 0, 0x12, 0x34, 0x56 }, .epoch = 7 };
    const remote_mac: arp.Mac = .{ 0x52, 0x55, 10, 0, 2, 2 };
    try link.begin(lease, .{ .address = lease.gateway, .port = 22 }, 50001, 123, 0, 5000);
    const request = (try link.poll(7, 0)).?;
    var arp_reply: [42]u8 = request[0..42].*;
    try link.sent(7, 0);
    arp_reply[0..6].* = lease.mac;
    arp_reply[6..12].* = remote_mac;
    std.mem.writeInt(u16, arp_reply[20..22], 2, .big);
    arp_reply[22..28].* = remote_mac;
    arp_reply[28..32].* = lease.gateway;
    arp_reply[32..38].* = lease.mac;
    arp_reply[38..42].* = lease.ip;
    try std.testing.expect(try link.receive(7, 1, &arp_reply));
    const syn = (try link.poll(7, 1)).?;
    try std.testing.expectEqualSlices(u8, &remote_mac, syn[0..6]);
    try std.testing.expectEqual(wire.Flags.syn, (try wire.parse(syn[14..])).flags);
    try link.sent(7, 1);
    var reply: [64]u8 = @splat(0);
    reply[0..6].* = lease.mac;
    reply[6..12].* = remote_mac;
    reply[12] = 8;
    const segment = wire.Segment{ .src = lease.gateway, .dst = lease.ip, .src_port = 22, .dst_port = 50001, .seq = 10, .ack = 124, .flags = wire.Flags.syn | wire.Flags.ack, .window = 1024, .options = "", .payload = "" };
    const ip = try wire.encode(reply[14..], segment, 0);
    const frame_len = 14 + ip.len;
    reply[0] ^= 1;
    try std.testing.expect(!try link.receive(7, 2, reply[0..frame_len]));
    reply[0] ^= 1;
    try std.testing.expect(try link.receive(7, 2, reply[0..frame_len]));
    try std.testing.expect(!link.ready());
    const ack = (try link.poll(7, 2)).?;
    try std.testing.expectEqual(wire.Flags.ack, (try wire.parse(ack[14..])).flags);
    try link.sent(7, 2);
    try std.testing.expect(link.ready());
    try std.testing.expectError(error.StaleLease, link.write(8, "x", 3, 100));
    try std.testing.expect(!link.ready());
}
