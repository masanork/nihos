//! Exclusive single-attempt diagnostic on an already established C6-owned
//! Network Split connection. No DHCP, ARP, reconnect or generic socket API.
const wire = @import("hosted.zig");
const std = @import("std");
const time = @import("hosted_c6_time_exchange.zig");
const probe = @import("hosted_split_udp_probe.zig");
const udp = @import("long_udp_probe.zig");

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
                if (self.phase == .waiting and try self.session.echo(&self.exchange.addresses, frame.payload) == .long and frame.payload[50] == self.attempt) self.phase = .complete;
            } else if (frame.interface == 5) {
                // A new INIT denotes a peer restart; never reuse its old lease.
                return error.Stale;
            } else if (frame.interface >> 4 == 0) {
                try self.exchange.receive(frame, now);
                if (self.exchange.phase != .ready or !self.exchange.station.connected) return error.Stale;
                try self.session.check(&self.exchange.addresses);
            }
        };
        if (self.phase == .queued and n == 0 and self.decoder.used == 0) {
            try self.session.check(&self.exchange.addresses);
            const written = try stream.sendLong(&self.output, &self.padding);
            if (written != 0 and written != self.output.len) return error.PartialPacket;
            if (written == self.output.len) {
                self.sent_count = 1;
                self.phase = .waiting;
            }
        }
    }
};
