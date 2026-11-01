//! Exclusive Hosted handshake and one read-only C6 OTA-info query.
//! No retry after an uncertain send, and no OTA write or activate RPC.
const std = @import("std");
const station = @import("hosted_station.zig");
const wire = @import("hosted.zig");
const info = @import("hosted_c6_ota_info.zig");

pub const State = enum { handshake, queued, waiting, complete, failed };

/// Defense in depth for the diagnostic's physical stream: only handshake,
/// Bluetooth controller setup and the read-only OTA-info CustomRpc may leave.
pub fn ReadOnlyStream(comptime Stream: type) type {
    return struct {
        inner: *Stream,
        const Self = @This();
        pub fn receive(self: *Self, out: []u8) !usize {
            return self.inner.receive(out);
        }
        pub fn send(self: *Self, bytes: []const u8) !usize {
            var decoder: wire.Decoder = .{};
            var seen = false;
            for (bytes, 0..) |b, i| if (try decoder.push(b)) |frame| {
                if (seen or i + 1 != bytes.len) return error.Malformed;
                seen = true;
                if (frame.interface == 5) {
                    if (!std.mem.eql(u8, frame.payload, &wire.capabilities)) {
                        var expected: [wire.capabilities.len + 3]u8 = undefined;
                        @memcpy(expected[0..wire.capabilities.len], &wire.capabilities);
                        expected[1] += 3;
                        expected[wire.capabilities.len..][0..3].* = .{ 0x1a, 1, 2 };
                        if (!std.mem.eql(u8, frame.payload, &expected)) return error.Forbidden;
                    }
                    continue;
                }
                if (frame.interface != 3 or frame.payload.len < 12 or !std.mem.eql(u8, frame.payload[0..10], &.{ 1, 6, 0, 'R', 'P', 'C', 'R', 's', 'p', 2 }) or
                    std.mem.readInt(u16, frame.payload[10..12], .little) != frame.payload.len - 12) return error.Malformed;
                var r: wire.Reader = .{ .bytes = frame.payload[12..] };
                var id: ?u32 = null;
                var kind: ?u32 = null;
                var uid: ?u32 = null;
                var body_id: ?u32 = null;
                var body: ?[]const u8 = null;
                while (try r.next()) |f| {
                    if (f.number >= 1 and f.number <= 3) {
                        if (f.kind != 0 or f.value > std.math.maxInt(u32)) return error.Malformed;
                        const dest = if (f.number == 1) &kind else if (f.number == 2) &id else &uid;
                        if (dest.* != null) return error.Malformed;
                        dest.* = @intCast(f.value);
                    } else if (f.number >= 256) {
                        if (body != null or f.kind != 2 or f.number > std.math.maxInt(u32)) return error.Malformed;
                        body_id = @intCast(f.number);
                        body = f.bytes orelse return error.Malformed;
                    } else return error.Malformed;
                }
                if (kind != 1 or uid == null or uid == 0 or id == null or body_id != id) return error.Malformed;
                const value = body orelse return error.Malformed;
                switch (id.?) {
                    350 => if (value.len != 0) return error.Malformed,
                    387 => {
                        const feature = try wire.integer(value, 1);
                        const action = try wire.integer(value, 2);
                        if (feature != 1 or (action != 1 and action != 3)) return error.Forbidden;
                    },
                    388 => {
                        if (try wire.integer(value, 1) != info.request_id) return error.Forbidden;
                        const raw = (try wire.data(value, 2)) orelse return error.Malformed;
                        if (raw.len != 8 or raw[0] != 1 or raw[1] != 0 or raw[2] != 0 or raw[3] != 0 or std.mem.readInt(u32, raw[4..8], .little) == 0) return error.Malformed;
                    },
                    else => return error.Forbidden,
                }
            };
            if (!seen or decoder.used != 0) return error.Malformed;
            return self.inner.send(bytes);
        }
    };
}
pub const Exchange = struct {
    state: State = .handshake,
    client: station.Client = .{},
    query: info.Session = .{},
    decoder: wire.Decoder = .{},
    rx: [512]u8 = @splat(0),
    output: [128]u8 = @splat(0),
    output_len: usize = 0,
    nonce: u32,
    deadline: u64,
    last_now: u64,
    ack_status: ?u32 = null,

    pub fn init(nonce: u32, now: u64, deadline: u64) error{InvalidArgument}!Exchange {
        if (nonce == 0 or deadline <= now) return error.InvalidArgument;
        var self: Exchange = .{ .nonce = nonce, .deadline = deadline, .last_now = now };
        self.client.begin(.disabled, now);
        return self;
    }
    /// Stream has receive/send; zero send means no bytes were transferred.
    pub fn step(self: *Exchange, stream: anytype, now: u64) !void {
        if (self.state == .complete or self.state == .failed) return error.WrongState;
        errdefer {
            self.state = .failed;
            self.query.fail();
        }
        if (now < self.last_now or now >= self.deadline) return error.Timeout;
        self.last_now = now;
        const count = try stream.receive(&self.rx);
        if (count > self.rx.len) return error.InvalidBuffer;
        for (self.rx[0..count]) |byte| if (try self.decoder.push(byte)) |frame| {
            if (self.state == .handshake) {
                try self.client.receive(frame, now);
            } else if (self.state == .waiting and frame.interface == 3) {
                const rpc = try wire.rpc(frame.payload);
                if (rpc.kind == 2 and rpc.id == 644 and rpc.uid == self.query.uid) {
                    self.ack_status = try wire.integer(rpc.body, 1);
                    try self.query.receive(rpc, now);
                } else if (rpc.kind == 3 and rpc.id == 788 and try wire.integer(rpc.body, 2) == info.result_id) {
                    try self.query.receive(rpc, now);
                }
            }
        };
        if (self.state == .waiting and self.query.phase == .complete and self.decoder.used == 0) {
            self.state = .complete;
            return;
        }
        if (self.state == .handshake and self.client.phase == .done and self.decoder.used == 0) {
            if (self.client.peer_chip != 13 or !self.client.version_known) return error.UnsupportedPeer;
            const old = std.mem.eql(u32, &self.client.version, &.{ 2, 13, 1 });
            const current = std.mem.eql(u32, &self.client.version, &.{ 3, 0, 10 }) and
                self.client.peer_rpc_version == 2 and self.client.peer_mode == 1 and self.client.peer_sdio_buffer_blocks != null;
            if (!old and !current) return error.UnsupportedPeer;
            if (self.client.uid == std.math.maxInt(u32)) return error.UidExhausted;
            var payload: [100]u8 = undefined;
            const request = try self.query.start(&payload, self.client.uid + 1, self.nonce, now, self.deadline);
            const frame = try wire.frame(&self.output, 3, self.client.sequence, request);
            self.output_len = frame.len;
            self.state = .queued;
        }
        if (self.state == .handshake) {
            const frame = try self.client.tx(now);
            if (frame.len != 0) {
                const sent = try stream.send(frame);
                if (sent != 0 and sent != frame.len) return error.PartialPacket;
                if (sent != 0) self.client.sent(now);
            }
        } else if (self.state == .queued) {
            const sent = try stream.send(self.output[0..self.output_len]);
            if (sent != 0 and sent != self.output_len) return error.PartialPacket;
            if (sent != 0) self.state = .waiting;
        }
    }
};
