//! One bounded Hosted UDP next-hop lookup, without sockets or transport I/O.
//! The exclusive stream owner supplies time, complete writes and control events.
const std = @import("std");
const arp = @import("arp_resolver.zig");
const hosted = @import("hosted.zig");
const split = @import("hosted_network_split.zig");
const binding = @import("hosted_udp_lease.zig");
const wire = @import("udp_ipv4.zig");

pub const Error = arp.Error || hosted.Error || binding.Error || error{ Busy, Deadline };

/// One resolution, tied to the complete captured C6 address snapshot. No MAC
/// cache is retained after the caller's deadline. A result is not peer identity.
pub const Route = struct {
    const Phase = enum { idle, resolving, resolved, failed };
    phase: Phase = .idle,
    lease: binding.Lease = .{
        .generation = 0,
        .address = .{ .ip = 0, .mask = 0, .gateway = 0, .dns = 0 },
        .local = .{ .mac = @splat(0), .ip = @splat(0), .port = 0 },
    },
    resolver: arp.Resolver = .{},
    target: [4]u8 = @splat(0),
    port: u16 = 0,
    deadline: u64 = 0,
    last_now: u64 = 0,
    pending: bool = false,
    frame: [54]u8 = @splat(0),
    frame_len: usize = 0,

    pub fn begin(self: *Route, state: *const split.State, bound: binding.Lease, target: [4]u8, port: u16, now: u64, deadline: u64) Error!void {
        if (self.phase != .idle) return error.InvalidState;
        try bound.check(state);
        if (port == 0 or deadline <= now) return error.InvalidArgument;
        var mask: [4]u8 = undefined;
        var gateway: [4]u8 = undefined;
        std.mem.writeInt(u32, &mask, bound.address.mask, .big);
        std.mem.writeInt(u32, &gateway, bound.address.gateway, .big);
        try self.resolver.begin(.{ .ip = bound.local.ip, .mask = mask, .gateway = gateway, .mac = bound.local.mac, .epoch = bound.generation }, target, now, deadline);
        self.lease = bound;
        self.target = target;
        self.port = port;
        self.deadline = deadline;
        self.last_now = now;
        self.phase = .resolving;
    }

    /// The returned Hosted frame remains borrowed until sent or invalidate.
    /// Retrying after a zero-byte write is safe; partial or ambiguous writes
    /// require invalidation and transport recovery, never sent().
    pub fn poll(self: *Route, state: *const split.State, now: u64, sequence: u16) Error!?[]const u8 {
        try self.check(state, now);
        if (self.pending) return self.frame[0..self.frame_len];
        if (self.phase == .resolved) return null;
        const request = self.resolver.poll(self.lease.generation, now) catch |err| return self.fail(err);
        if (request) |payload| {
            const frame = hosted.frame(&self.frame, hosted.station_interface, sequence, payload) catch |err| return self.fail(err);
            self.frame_len = frame.len;
            self.pending = true;
            return self.frame[0..self.frame_len];
        }
        return null;
    }

    pub fn sent(self: *Route, state: *const split.State, now: u64) Error!void {
        try self.check(state, now);
        if (!self.pending) return error.InvalidState;
        self.resolver.sent(self.lease.generation, now) catch |err| return self.fail(err);
        self.pending = false;
        self.frame_len = 0;
    }

    /// False leaves unrelated frames available to the exclusive owner. The
    /// owner must queue receive frames while a borrowed TX is pending.
    pub fn receive(self: *Route, state: *const split.State, now: u64, frame: hosted.Frame) Error!bool {
        try self.check(state, now);
        if (self.pending) return error.Busy;
        if (self.phase == .resolved or frame.interface != hosted.station_interface) return false;
        const matched = self.resolver.receive(self.lease.generation, now, frame.payload) catch |err| return self.fail(err);
        if (matched) self.phase = .resolved;
        return matched;
    }

    /// IP remains the final destination even when the MAC belongs to gateway.
    pub fn result(self: *Route, state: *const split.State, now: u64) Error!?wire.Endpoint {
        try self.check(state, now);
        const hop = self.resolver.result(self.lease.generation, now) catch |err| return self.fail(err);
        return if (hop) |h| .{ .ip = self.target, .port = self.port, .mac = h.mac } else null;
    }

    pub fn invalidate(self: *Route) void {
        self.phase = .failed;
        self.pending = false;
        self.frame_len = 0;
        self.resolver.invalidate();
    }
    fn check(self: *Route, state: *const split.State, now: u64) Error!void {
        if (self.phase == .idle or self.phase == .failed) return error.InvalidState;
        self.lease.check(state) catch |err| return self.fail(err);
        if (now < self.last_now or now >= self.deadline) return self.fail(error.Deadline);
        self.last_now = now;
    }
    fn fail(self: *Route, err: Error) Error {
        self.invalidate();
        return err;
    }
};
