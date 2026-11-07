//! Single-owner Hosted/TCP adapter for one experimental connection. The native
//! network owner must serialize lease synchronization, RX, TX and completions.
//! This module is host-tested only; it is not wired into normal boot.
const std = @import("std");
const hosted = @import("hosted.zig");
const arp = @import("arp_resolver.zig");
const tcp = @import("tcp_link.zig");
const connect = @import("tcp_connect.zig");
pub const Error = hosted.Error || tcp.Error || error{ NoLease, StaleHandle, EpochExhausted, PartialFrame, PortAlreadyUsed, AttemptLimit };
pub const Handle = struct { generation: u64, id: u64 };
pub const Tx = struct { bytes: []const u8, newly_staged: bool };
// Normal C6 ProfileStream sends one complete Hosted frame, at most 512 bytes.
// Current TCP data packets use 12 Hosted + 14 Ethernet + 20 IPv4 + 20 TCP bytes.
pub const max_frame = 512;
pub const max_write = max_frame - 12 - 14 - 20 - 20;
/// Never reuse a local port within a lease generation, even after failure.
pub const max_attempts = 32;
pub const Service = struct {
    lease: ?arp.Lease = null,
    generation: u64 = 0,
    next_id: u64 = 0,
    current: ?Handle = null,
    used_ports: [max_attempts]u16 = @splat(0),
    attempts: usize = 0,
    exhausted: bool = false,
    // The service must stay at a stable address while a link is open.
    link_storage: [@sizeOf(tcp.Link)]u8 align(@alignOf(tcp.Link)) = @splat(0),
    link: ?*tcp.Link = null,
    frame: [1512]u8 = @splat(0),
    frame_len: usize = 0,

    /// Input is the authoritative live lease and the owner's reset epoch.
    /// A change invalidates outstanding handles, frames and connection state.
    pub fn sync(self: *Service, lease: ?arp.Lease) Error!void {
        if (self.exhausted) return error.EpochExhausted;
        if (std.meta.eql(self.lease, lease)) return;
        self.retire();
        if (self.generation == std.math.maxInt(u64)) {
            self.exhausted = true;
            return error.EpochExhausted;
        }
        self.generation += 1;
        self.lease = lease;
        self.used_ports = @splat(0);
        self.attempts = 0;
    }
    pub fn open(self: *Service, remote: connect.Endpoint, local_port: u16, initial_seq: u32, now: u64, deadline: u64) Error!Handle {
        if (self.exhausted) return error.EpochExhausted;
        if (self.current != null) return error.Busy;
        var lease = self.lease orelse return error.NoLease;
        if (lease.epoch == 0) return error.InvalidArgument;
        for (self.used_ports[0..self.attempts]) |port| {
            if (port == local_port) return error.PortAlreadyUsed;
        }
        if (self.attempts == max_attempts) return error.AttemptLimit;
        if (self.next_id == std.math.maxInt(u64)) {
            self.exhausted = true;
            return error.EpochExhausted;
        }
        lease.epoch = self.generation;
        const link: *tcp.Link = @ptrCast(&self.link_storage);
        link.initInPlace();
        self.link = link;
        link.begin(lease, remote, local_port, initial_seq, now, deadline) catch |err| {
            self.link = null;
            return err;
        };
        self.next_id += 1;
        const handle = Handle{ .generation = self.generation, .id = self.next_id };
        self.current = handle;
        self.used_ports[self.attempts] = local_port;
        self.attempts += 1;
        return handle;
    }
    /// Caller reserves sequence when newly_staged is true, even if the frame
    /// is later cancelled. This avoids colliding with other Hosted producers.
    pub fn tx(self: *Service, handle: Handle, sequence: u16, now: u64) Error!?Tx {
        const link = try self.get(handle);
        if (self.frame_len != 0) {
            _ = link.poll(handle.generation, now) catch |err| return self.fail(err);
            return .{ .bytes = self.frame[0..self.frame_len], .newly_staged = false };
        }
        const ethernet = (link.poll(handle.generation, now) catch |err| return self.fail(err)) orelse return null;
        const frame = hosted.frame(&self.frame, hosted.station_interface, sequence, ethernet) catch |err| return self.fail(err);
        if (frame.len > max_frame) return self.fail(error.FrameTooLarge);
        self.frame_len = frame.len;
        return .{ .bytes = self.frame[0..self.frame_len], .newly_staged = true };
    }
    /// 0 means backpressure. An ambiguous/partial frame invalidates the
    /// connection; the old byte stream must never be replayed on reconnect.
    pub fn sent(self: *Service, handle: Handle, count: usize, now: u64) Error!void {
        const link = try self.get(handle);
        if (self.frame_len == 0) return error.InvalidState;
        if (count == 0) return;
        if (count != self.frame_len) return self.fail(error.PartialFrame);
        link.sent(handle.generation, now) catch |err| return self.fail(err);
        std.crypto.secureZero(u8, self.frame[0..self.frame_len]);
        self.frame_len = 0;
    }
    /// Busy means the owner must retain the frame in a bounded RX queue until
    /// the staged TX completes; it must not silently discard it.
    pub fn receive(self: *Service, handle: Handle, frame: hosted.Frame, now: u64) Error!bool {
        const link = try self.get(handle);
        if (frame.interface != hosted.station_interface) return false;
        if (self.frame_len != 0) return error.Busy;
        return link.receive(handle.generation, now, frame.payload) catch |err| switch (err) {
            error.Busy => error.Busy,
            else => return self.fail(err),
        };
    }
    pub fn ready(self: *Service, handle: Handle) Error!bool {
        return (try self.get(handle)).ready();
    }
    pub fn write(self: *Service, handle: Handle, bytes: []const u8, now: u64, deadline: u64) Error!usize {
        return (try self.get(handle)).write(handle.generation, bytes[0..@min(bytes.len, max_write)], now, deadline);
    }
    pub fn read(self: *Service, handle: Handle, out: []u8) Error!usize {
        return (try self.get(handle)).read(handle.generation, out);
    }
    pub fn closeWrite(self: *Service, handle: Handle, now: u64, deadline: u64) Error!void {
        return (try self.get(handle)).closeWrite(handle.generation, now, deadline);
    }
    pub fn closeComplete(self: *Service, handle: Handle) Error!bool {
        return (try self.get(handle)).closeHandshakeComplete();
    }
    pub fn invalidate(self: *Service) void {
        self.retire();
    }
    fn get(self: *Service, handle: Handle) Error!*tcp.Link {
        if (self.current == null or !std.meta.eql(self.current.?, handle)) return error.StaleHandle;
        return self.link orelse error.StaleHandle;
    }
    fn retire(self: *Service) void {
        if (self.link) |link| link.invalidate();
        self.link = null;
        self.current = null;
        std.crypto.secureZero(u8, &self.frame);
        self.frame_len = 0;
    }
    fn fail(self: *Service, err: Error) Error {
        self.retire();
        return err;
    }
};

test "large writes fit the normal short Hosted transport" {
    var service: Service = .{};
    const lease = arp.Lease{ .ip = .{ 10, 0, 2, 15 }, .mask = .{ 255, 255, 255, 0 }, .gateway = .{ 10, 0, 2, 2 }, .mac = .{ 0x52, 0x54, 0, 0x12, 0x34, 0x56 }, .epoch = 7 };
    try service.sync(lease);
    const handle = try service.open(.{ .address = lease.gateway, .port = 22 }, 50001, 123, 0, 5000);
    const link = service.link.?;
    link.resolver.state = .resolved;
    link.resolver.resolved_mac = .{ 0x52, 0x54, 0, 0, 0, 2 };
    link.state = .active;
    link.stream = @import("tcp_stream.zig").Stream.init(.{ .local = .{ .address = lease.ip, .port = 50001 }, .remote = .{ .address = lease.gateway, .port = 22 }, .send_next = 1, .receive_next = 1, .remote_window = 4096, .remote_mss = 1460 });
    const input: [600]u8 = @splat(0x5a);
    try std.testing.expectEqual(@as(usize, max_write), try service.write(handle, &input, 1, 5000));
    const frame = (try service.tx(handle, 1, 1)).?;
    try std.testing.expectEqual(@as(usize, max_frame), frame.bytes.len);
}

test "lease change and ambiguous transmit invalidate handles and frames" {
    var service: Service = .{};
    const lease = arp.Lease{ .ip = .{ 10, 0, 2, 15 }, .mask = .{ 255, 255, 255, 0 }, .gateway = .{ 10, 0, 2, 2 }, .mac = .{ 0x52, 0x54, 0, 0x12, 0x34, 0x56 }, .epoch = 7 };
    try service.sync(lease);
    const handle = try service.open(.{ .address = lease.gateway, .port = 22 }, 50001, 123, 0, 5000);
    const first = (try service.tx(handle, 17, 0)).?;
    try std.testing.expect(first.newly_staged);
    var decoder: hosted.Decoder = .{};
    var decoded: ?hosted.Frame = null;
    for (first.bytes) |b| if (try decoder.push(b)) |frame| {
        decoded = frame;
    };
    try std.testing.expectEqual(@as(u8, 1), decoded.?.interface);
    try std.testing.expectEqual(@as(u16, 0x0806), std.mem.readInt(u16, decoded.?.payload[12..14], .big));
    const again = (try service.tx(handle, 99, 1)).?;
    try std.testing.expect(!again.newly_staged);
    try std.testing.expectEqual(@as(u16, 17), std.mem.readInt(u16, again.bytes[8..10], .little));
    try std.testing.expectError(error.Busy, service.receive(handle, decoded.?, 1));
    try service.sent(handle, 0, 1);
    try std.testing.expectError(error.PartialFrame, service.sent(handle, 1, 2));
    try std.testing.expectError(error.StaleHandle, service.ready(handle));
    try std.testing.expectError(error.PortAlreadyUsed, service.open(.{ .address = lease.gateway, .port = 22 }, 50001, 123, 3, 5000));
    try service.sync(null);
    try service.sync(lease);
    const replacement = try service.open(.{ .address = lease.gateway, .port = 22 }, 50001, 124, 4, 5000);
    try std.testing.expect(!std.meta.eql(handle, replacement));
    try std.testing.expectError(error.StaleHandle, service.ready(handle));
}

test "owner reset revokes a staged frame even when address is unchanged" {
    var service: Service = .{};
    const lease = arp.Lease{ .ip = .{ 10, 0, 2, 15 }, .mask = .{ 255, 255, 255, 0 }, .gateway = .{ 10, 0, 2, 2 }, .mac = .{ 0x52, 0x54, 0, 0x12, 0x34, 0x56 }, .epoch = 7 };
    try service.sync(lease);
    const old = try service.open(.{ .address = lease.gateway, .port = 22 }, 50001, 123, 0, 5000);
    const staged = (try service.tx(old, 1, 0)).?;
    const length = staged.bytes.len;
    try service.sync(lease);
    try std.testing.expectEqual(@as(usize, length), service.frame_len);
    var replacement_lease = lease;
    replacement_lease.epoch += 1;
    try service.sync(replacement_lease);
    try std.testing.expectEqual(@as(usize, 0), service.frame_len);
    try std.testing.expectError(error.StaleHandle, service.sent(old, length, 1));
    const replacement = try service.open(.{ .address = lease.gateway, .port = 22 }, 50001, 124, 2, 5000);
    try std.testing.expect(!std.meta.eql(old, replacement));
    try std.testing.expect(!(try service.ready(replacement)));
}

test "sequential attempts use distinct ports and remain bounded" {
    var service: Service = .{};
    const lease = arp.Lease{ .ip = .{ 10, 0, 2, 15 }, .mask = .{ 255, 255, 255, 0 }, .gateway = .{ 10, 0, 2, 2 }, .mac = .{ 0x52, 0x54, 0, 0x12, 0x34, 0x56 }, .epoch = 7 };
    const remote = connect.Endpoint{ .address = lease.gateway, .port = 22 };
    try service.sync(lease);
    var first: Handle = undefined;
    for (0..max_attempts) |i| {
        const port: u16 = @intCast(50000 + i);
        const handle = try service.open(remote, port, 123, 0, 5000);
        if (i == 0) first = handle else try std.testing.expectError(error.StaleHandle, service.ready(first));
        try std.testing.expectError(error.Busy, service.open(remote, port + 100, 124, 0, 5000));
        service.invalidate();
        try std.testing.expectError(error.PortAlreadyUsed, service.open(remote, port, 124, 0, 5000));
    }
    try std.testing.expectError(error.AttemptLimit, service.open(remote, 51000, 124, 0, 5000));
    try service.sync(null);
    try service.sync(lease);
    _ = try service.open(remote, 50000, 125, 0, 5000);
}
