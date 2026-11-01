//! Experimental one-shot Hosted 2.13.1 station -> C6-owned DHCP -> SNTP query.
//! Exclusive owner of station/stream until completion; no factory-path changes.
const std = @import("std");
fn timeSection() []const u8 {
    const root = @import("root");
    if (@hasDecl(root, "C6TimeFlash") and root.C6TimeFlash) return ".flash.text.time";
    return if (@import("builtin").object_format == .macho) "__TEXT,__text" else ".text";
}
const station = @import("hosted_station.zig");
const wire = @import("hosted.zig");
const split = @import("hosted_network_split.zig");
const clock = @import("hosted_c6_time.zig");

pub const Phase = enum { station, address, ready, queued, waiting, done, failed };
pub const Error = station.Error || error{ Busy, Deadline, WrongState, InvalidArgument, PartialPacket, UnsupportedPeer };
pub const Exchange = struct {
    station: station.Client = .{},
    addresses: split.State = .{},
    clock: clock.Session = .{},
    phase: Phase = .station,
    deadline: u64 = 0,
    last_now: u64 = 0,
    uid: u32 = 0,
    last_rpc_id: u32 = 0,
    last_rpc_kind: u32 = 0,
    status_body: [320]u8 = @splat(0),
    status_body_len: usize = 0,
    status_body_truncated: bool = false,
    address_uid: u32 = 0,
    address_queried: bool = false,
    address_pending: bool = false,
    address_event_seen: bool = false,
    acknowledged: bool = false,
    got_result: bool = false,
    sample: ?clock.Sample = null,
    service_output: [128]u8 = @splat(0),
    pending_len: usize = 0,
    owner: enum { none, station, address, service } = .none,

    /// generation_base must exceed every generation previously used on this
    /// stream, including generations invalidated on reset or reconnect.
    pub noinline fn begin(self: *Exchange, join: station.Join, generation_base: u64, now: u64, deadline: u64) linksection(timeSection()) Error!void {
        if (join == .disabled or generation_base == 0 or generation_base == std.math.maxInt(u64) or deadline <= now)
            return error.InvalidArgument;
        self.* = .{ .deadline = deadline, .last_now = now };
        self.addresses.generation = generation_base;
        self.station.begin(join, now);
    }
    noinline fn tick(self: *Exchange, now: u64) linksection(timeSection()) Error!void {
        if (self.phase == .done or self.phase == .failed) return error.WrongState;
        if (now < self.last_now or now >= self.deadline) return error.Deadline;
        self.last_now = now;
    }
    noinline fn checkPeer(self: *const Exchange) linksection(timeSection()) Error!void {
        if (self.station.phase != .handshake and self.station.phase != .version and
            (self.station.peer_chip != 13 or !self.station.version_known or
                !std.mem.eql(u32, &self.station.version, &.{ 2, 13, 1 }))) return error.UnsupportedPeer;
    }
    noinline fn adopt(self: *Exchange) linksection(timeSection()) void {
        if (self.phase != .station and self.phase != .address) return;
        if (self.station.phase != .link or !self.station.connected) return;
        if (self.address_pending or self.owner == .address) return;
        if (self.addresses.address == null) {
            self.phase = .address;
            return;
        }
        // Do not call station.tx at link-up: that starts P4 DHCP.
        self.station.phase = .done;
        self.clock.reset(self.addresses.generation);
        self.phase = .ready;
    }
    pub noinline fn receive(self: *Exchange, frame: wire.Frame, now: u64) linksection(timeSection()) Error!void {
        errdefer self.invalidate();
        try self.tick(now);
        if (frame.interface >> 4 == 0 and frame.interface & 15 == 3) {
            const rpc = try wire.rpc(frame.payload);
            self.last_rpc_id = rpc.id;
            self.last_rpc_kind = rpc.kind;
            if (rpc.kind == 3 and rpc.id == split.event_id) {
                const before = self.addresses.generation;
                if (self.addresses.receive(rpc) == .rejected) return error.Malformed;
                if (self.address_pending or self.owner == .address) self.address_event_seen = true;
                if (before != self.addresses.generation and
                    (self.phase == .ready or self.phase == .queued or self.phase == .waiting)) return error.Stale;
            } else if (rpc.kind == 2 and rpc.id == split.response_id) {
                self.status_body_len = @min(rpc.body.len, self.status_body.len);
                self.status_body_truncated = rpc.body.len > self.status_body.len;
                @memcpy(self.status_body[0..self.status_body_len], rpc.body[0..self.status_body_len]);
                if (!self.address_pending or rpc.uid != self.address_uid) return error.Stale;
                // A newer asynchronous event supersedes this potentially old
                // snapshot; never resurrect an address after link-down.
                if (!self.address_event_seen) {
                    const outcome = self.addresses.receiveResponse(rpc, self.address_uid);
                    if (outcome == .rejected or outcome == .ignored) return error.Malformed;
                }
                self.address_pending = false;
                self.adopt();
                return;
            } else if (rpc.kind == 2 and rpc.id == 644) {
                if (self.phase != .waiting or self.acknowledged) return error.Stale;
                try clock.acceptAck(rpc, self.uid);
                self.acknowledged = true;
                self.finish();
                return;
            } else if (rpc.kind == 3 and rpc.id == 788) {
                if (self.phase != .waiting or self.got_result) return error.Stale;
                self.sample = try self.clock.receive(rpc, now);
                self.got_result = true;
                self.finish();
                return;
            }
        }
        try self.station.receive(frame, now);
        try self.checkPeer();
        self.adopt();
    }
    /// Begin another one-shot query on the same live address after both the
    /// acknowledgement and prior result completed. Never reuse request IDs.
    pub noinline fn nextSnapshot(self: *Exchange, now: u64) linksection(timeSection()) Error!void {
        if (self.phase != .done) return error.WrongState;
        if (now < self.last_now or now >= self.deadline) {
            self.invalidate();
            return error.Deadline;
        }
        if (self.addresses.current(self.clock.generation) == null) {
            self.invalidate();
            return error.Stale;
        }
        self.last_now = now;
        self.acknowledged = false;
        self.got_result = false;
        self.sample = null;
        self.phase = .ready;
    }
    /// Returned frame is owned by this object until sent() or invalidation.
    pub noinline fn tx(self: *Exchange, now: u64) linksection(timeSection()) Error![]const u8 {
        errdefer self.invalidate();
        try self.tick(now);
        try self.checkPeer();
        self.adopt();
        if (self.owner == .station) return self.station.output[0..self.pending_len];
        if (self.owner == .service or self.owner == .address) return self.service_output[0..self.pending_len];
        if (self.phase == .station) {
            const frame = try self.station.tx(now);
            if (frame.len > 0) {
                self.owner = .station;
                self.pending_len = frame.len;
            }
            return frame;
        }
        if (self.phase == .address and !self.address_queried) {
            if (self.station.uid == std.math.maxInt(u32)) return error.Stale;
            self.station.uid += 1;
            self.address_uid = self.station.uid;
            var payload: [64]u8 = undefined;
            const request = try split.statusRequest(&payload, self.address_uid);
            const frame = try wire.frame(&self.service_output, 3, self.station.sequence, request);
            self.station.sequence +%= 1;
            self.pending_len = frame.len;
            self.owner = .address;
            return frame;
        }
        if (self.phase == .ready) {
            if (self.station.uid == std.math.maxInt(u32)) return error.Stale;
            self.station.uid += 1;
            self.uid = self.station.uid;
            var payload: [96]u8 = undefined;
            const request = try self.clock.start(&payload, self.uid, now, self.deadline);
            const frame = try wire.frame(&self.service_output, 3, self.station.sequence, request);
            self.station.sequence +%= 1;
            self.pending_len = frame.len;
            self.owner = .service;
            self.phase = .queued;
            return frame;
        }
        return &.{};
    }
    /// Zero means no credit/no write. A partial frame is uncertain: fail closed.
    pub noinline fn sent(self: *Exchange, count: usize, now: u64) linksection(timeSection()) Error!void {
        errdefer self.invalidate();
        try self.tick(now);
        if (self.owner == .none or self.pending_len == 0) return error.WrongState;
        if (count == 0) return;
        if (count != self.pending_len) return error.PartialPacket;
        switch (self.owner) {
            .station => self.station.sent(now),
            .address => {
                self.address_pending = true;
                self.address_queried = true;
            },
            .service => self.phase = .waiting,
            .none => unreachable,
        }
        self.owner = .none;
        self.pending_len = 0;
    }
    pub noinline fn invalidate(self: *Exchange) linksection(timeSection()) void {
        _ = self.addresses.invalidate();
        self.clock.reset(self.addresses.generation);
        self.sample = null;
        self.phase = .failed;
        self.pending_len = 0;
        self.owner = .none;
    }
    noinline fn finish(self: *Exchange) linksection(timeSection()) void {
        if (self.acknowledged and self.got_result) self.phase = .done;
    }
};
