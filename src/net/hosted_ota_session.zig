//! Explicit exclusive Hosted handshake followed by a single OTA transaction.
//! Callers perform device setup/reset and must keep image memory immutable.
//! No transport acquisition, device reset or physical write is done here.
const std = @import("std");
const station = @import("hosted_station.zig");
const ota = @import("hosted_ota.zig");
const pump = @import("hosted_ota_pump.zig");
const wire = @import("hosted.zig");

pub const State = enum { handshake, transfer, complete, failed };
pub const Session = struct {
    state: State = .handshake,
    client: station.Client = .{},
    decoder: wire.Decoder = .{},
    ota_client: ota.Client,
    transfer: ?pump.Pump = null,
    deadline: u64,
    last_now: u64,
    allow_213: bool = false,
    required_peer: ?[3]u32 = null,
    rx: [512]u8 = @splat(0),

    /// Hash and header are checked before any interaction with the device.
    pub fn init(image: []const u8, digest: [32]u8, now: u64, deadline: u64) !Session {
        // SAFETY: initInPlace initializes result before it can be returned.
        var result: Session = undefined;
        try result.initInPlace(image, digest, now, deadline);
        return result;
    }
    /// Large session objects must be initialized directly in their final
    /// storage on small embedded stacks; do not construct a stack temporary.
    pub fn initInPlace(self: *Session, image: []const u8, digest: [32]u8, now: u64, deadline: u64) !void {
        if (deadline <= now) return error.InvalidDeadline;
        const client = try ota.Client.init(image, digest, 0, 0);
        self.state = .handshake;
        self.client.begin(.disabled, now);
        self.decoder.reset();
        self.ota_client = client;
        self.transfer = null;
        self.deadline = deadline;
        self.last_now = now;
        self.allow_213 = false;
        self.required_peer = null;
    }
    pub fn step(self: *Session, stream: anytype, now: u64) !void {
        if (self.state == .failed or self.state == .complete) return error.WrongState;
        errdefer {
            self.state = .failed;
            if (self.transfer) |*p| {
                p.state = .failed;
                p.client.fail();
            }
        }
        if (now < self.last_now or now >= self.deadline) return error.Timeout;
        self.last_now = now;
        if (self.state == .handshake) {
            const count = try stream.receive(&self.rx);
            if (count > self.rx.len) return error.InvalidBuffer;
            for (self.rx[0..count]) |byte| if (try self.decoder.push(byte)) |frame| try self.client.receive(frame, now);
            if (self.client.phase == .done and self.decoder.used == 0) {
                if (self.client.peer_chip != 13 or !self.client.version_known) return error.UnsupportedPeer;
                if (self.required_peer) |version| {
                    if (!std.mem.eql(u32, &self.client.version, &version)) return error.UnsupportedPeer;
                }
                if (std.mem.eql(u32, &self.client.version, &.{ 1, 4, 1 })) {
                    self.ota_client.activation = .legacy_automatic;
                } else if (self.allow_213 and std.mem.eql(u32, &self.client.version, &.{ 2, 13, 1 })) {
                    self.ota_client.activation = .explicit_rpc;
                } else return error.UnsupportedPeer;
                self.ota_client.uid = self.client.uid;
                self.ota_client.sequence = self.client.sequence;
                self.transfer = try pump.Pump.init(self.ota_client, now, self.deadline);
                self.state = .transfer;
                return; // The next step sends OTA Begin.
            }
            const frame = try self.client.tx(now);
            if (frame.len > 0) {
                const sent = try stream.send(frame);
                if (sent != 0 and sent != frame.len) return error.PartialPacket;
                if (sent == frame.len) self.client.sent(now);
            }
            return;
        }
        if (self.transfer) |*driver| {
            try driver.step(stream, now);
            if (driver.state == .complete) self.state = .complete;
        } else return error.WrongState;
    }
};
