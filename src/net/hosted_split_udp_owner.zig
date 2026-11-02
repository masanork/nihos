//! Exclusive bounded UDP diagnostic on an already established C6-owned
//! Network Split connection. No DHCP, ARP, reconnect or generic socket API.
const wire = @import("hosted.zig");
const std = @import("std");
const time = @import("hosted_c6_time_exchange.zig");
const probe = @import("hosted_split_udp_probe.zig");
const udp = @import("long_udp_probe.zig");
pub const Peer = probe.Peer;

pub const Acquisition = enum { pump, drain, ready };
/// Once the address owner is ready, never call its tx() again: that would
/// enqueue the unrelated C6 time service. Drain an incomplete frame first.
pub fn acquisition(exchange: *const time.Exchange, decoder: *const wire.Decoder) error{WrongState}!Acquisition {
    if (decoder.poisoned) return error.WrongState;
    return switch (exchange.phase) {
        .station, .address => .pump,
        .ready => if (decoder.used == 0) .ready else .drain,
        else => error.WrongState,
    };
}

pub const Phase = enum { queued, waiting, complete, failed };
pub const Owner = struct {
    exchange: *time.Exchange,
    session: probe.Session,
    phase: Phase = .queued,
    decoder: *wire.Decoder,
    output: [12 + udp.ethernet_bytes]u8 = @splat(0),
    padding: [1536]u8 = @splat(0),
    rx: [512]u8 = @splat(0),
    deadline: u64,
    last_now: u64,
    attempt: u8,
    sent_count: u32 = 0,
    sent_mask: u32 = 0,
    echo_mask: u32 = 0,
    duplicate_echoes: u32 = 0,
    burst_limit: u8 = 1,
    interval_us: u64 = 0,
    settle_us: u64 = 0,
    next_send: u64 = 0,
    last_send: u64 = 0,

    /// Caller must transfer exclusive exchange and transport ownership until
    /// completion or failure. Starting a time request concurrently is invalid.
    pub fn init(self: *Owner, exchange: *time.Exchange, decoder: *wire.Decoder, peer: probe.Peer, attempt: u8, now: u64, deadline: u64) !void {
        if (deadline <= now or deadline > exchange.deadline or now < exchange.last_now) return error.Deadline;
        if (decoder.used != 0 or decoder.poisoned) return error.WrongState;
        if (exchange.phase != .ready or !exchange.station.connected or exchange.station.phase != .done or exchange.station.dhcp_client != null or exchange.address_pending) return error.WrongState;
        if (exchange.station.peer_chip != 13 or !exchange.station.version_known or
            !std.mem.eql(u32, &exchange.station.version, &.{ 3, 0, 10 }) or
            exchange.station.peer_rpc_version != 2 or exchange.station.peer_mode != 1 or
            exchange.station.peer_sdio_buffer_blocks == null) return error.UnsupportedPeer;
        const session = try probe.Session.open(&exchange.addresses, exchange.station.mac_address, peer);
        self.* = .{ .exchange = exchange, .decoder = decoder, .session = session, .deadline = deadline, .last_now = now, .attempt = attempt };
        const data: *[udp.ethernet_bytes]u8 = self.output[12..][0..udp.ethernet_bytes];
        _ = try session.prepare(&exchange.addresses, data, attempt);
        _ = try wire.frameInPlace(&self.output, wire.station_interface, 0x7000, udp.ethernet_bytes);
    }

    /// A burst uses unique attempt IDs and never retransmits a completed send.
    /// Completion after the bounded settling interval may contain missing echoes.
    pub fn initBurst(self: *Owner, exchange: *time.Exchange, decoder: *wire.Decoder, peer: probe.Peer, count: u8, interval_us: u64, settle_us: u64, now: u64, deadline: u64) !void {
        if (count < 2 or count > 32 or interval_us == 0 or settle_us == 0) return error.InvalidArgument;
        const minimum = (@as(u64, count - 1) *| interval_us) +| settle_us;
        if (deadline <= now or minimum >= deadline - now) return error.Deadline;
        try self.init(exchange, decoder, peer, 1, now, deadline);
        self.burst_limit = count;
        self.interval_us = interval_us;
        self.settle_us = settle_us;
    }

    /// `receive`, `sendLong` and `invalidate` are exclusively owned here.
    /// Receive is drained before sending; zero send means no transfer started.
    /// Any nonzero partial write or transport error retires the connection.
    pub fn step(self: *Owner, stream: anytype, now: u64) !void {
        if (self.phase == .complete or self.phase == .failed) return error.WrongState;
        errdefer {
            self.phase = .failed;
            self.exchange.invalidate();
            stream.invalidate();
        }
        if (now < self.last_now or now >= self.deadline) return error.Deadline;
        self.last_now = now;
        if (self.exchange.phase != .ready or !self.exchange.station.connected or self.exchange.station.phase != .done) return error.Stale;
        try self.session.check(&self.exchange.addresses);
        const n = try stream.receive(&self.rx);
        if (n > self.rx.len) return error.InvalidBuffer;
        for (self.rx[0..n]) |b| if (try self.decoder.push(b)) |frame| {
            if (frame.interface == wire.station_interface) {
                if (try self.session.echo(&self.exchange.addresses, frame.payload) == .long) {
                    const id = frame.payload[50];
                    if (id >= 1 and id <= 32) {
                        const bit = @as(u32, 1) << @as(u5, @intCast(id - 1));
                        if (self.sent_mask & bit != 0) {
                            if (self.echo_mask & bit != 0) self.duplicate_echoes +|= 1;
                            self.echo_mask |= bit;
                            if (self.burst_limit == 1) self.phase = .complete;
                        }
                    }
                }
            } else if (frame.interface == 5) {
                // A new INIT denotes a peer restart; never reuse its old lease.
                return error.Stale;
            } else if (frame.interface >> 4 == 0) {
                try self.exchange.receive(frame, now);
                if (self.exchange.phase != .ready or !self.exchange.station.connected) return error.Stale;
                try self.session.check(&self.exchange.addresses);
            }
        };
        if (n == 0 and self.decoder.used == 0 and self.phase == .waiting and self.burst_limit > 1) {
            if (self.sent_count == self.burst_limit and now - self.last_send >= self.settle_us) {
                self.phase = .complete;
            } else if (self.sent_count < self.burst_limit and now >= self.next_send) {
                self.attempt = @intCast(self.sent_count + 1);
                const data: *[udp.ethernet_bytes]u8 = self.output[12..][0..udp.ethernet_bytes];
                _ = try self.session.prepare(&self.exchange.addresses, data, self.attempt);
                _ = try wire.frameInPlace(&self.output, wire.station_interface, 0x7000 + @as(u16, self.attempt) - 1, udp.ethernet_bytes);
                self.phase = .queued;
            }
        }
        if (self.phase == .queued and n == 0 and self.decoder.used == 0) {
            try self.session.check(&self.exchange.addresses);
            const written = try stream.sendLong(&self.output, &self.padding);
            if (written != 0 and written != self.output.len) return error.PartialPacket;
            if (written == self.output.len) {
                self.sent_count += 1;
                self.sent_mask |= @as(u32, 1) << @as(u5, @intCast(self.attempt - 1));
                self.last_send = now;
                self.next_send = now +| self.interval_us;
                self.phase = .waiting;
            }
        }
    }
};
