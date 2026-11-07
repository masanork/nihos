//! Single-owner adapter between a packet transport and an asynchronous KEM.
//! It does not schedule work, deliver cancellation, or manage worker backing.
const std = @import("std");
const kem = @import("ssh_kem_handoff.zig");
const replies = @import("ssh_hybrid_reply_buffer.zig");
const transport = @import("ssh_transport.zig");
pub const Error = kem.Error || replies.Error;
pub const Exchange = struct {
    handoff: kem.Handoff = .{},
    reply: replies.Buffer = .{},

    /// A successful capture releases the transport packet; all later users
    /// borrow our copy until verification returns or the exchange aborts.
    pub fn captureReply(self: *Exchange, wire: *transport.Transport, token: kem.Token, now: u64) Error!void {
        try self.handoff.tick(token, now);
        if (self.handoff.phase != .waiting_reply) return error.InvalidState;
        self.reply.capture(wire) catch |err| {
            if (err == error.NoPacket) return err;
            self.abort();
            return err;
        };
        const parsed = self.reply.get() catch |err| {
            self.abort();
            return err;
        };
        self.handoff.submitReply(token, now, parsed.ciphertext()) catch |err| {
            self.abort();
            return err;
        };
    }
    /// Caller drives this even during a silent network or worker.
    pub fn tick(self: *Exchange, token: kem.Token, now: u64) Error!void {
        self.handoff.tick(token, now) catch |err| {
            if (err != error.Stale and (self.handoff.phase == .cancel_pending or self.handoff.phase == .failed)) self.reply.clear();
            return err;
        };
    }
    pub fn abort(self: *Exchange) void {
        self.handoff.abort();
        self.reply.clear();
    }
    /// The caller must perform pinned host verification before reporting true.
    /// Callback and reply borrow are synchronous and non-reentrant.
    pub const Verifier = *const fn (?*anyopaque, []const u8, *const [32]u8) bool;
    pub fn authenticate(self: *Exchange, token: kem.Token, now: u64, context: ?*anyopaque, verifier: Verifier) Error!bool {
        const Adapter = struct {
            exchange: *Exchange,
            context: ?*anyopaque,
            verifier: Verifier,
            fn call(raw: ?*anyopaque, secret: *const [32]u8) bool {
                const ctx: *@This() = @ptrCast(@alignCast(raw.?));
                return ctx.verifier(ctx.context, ctx.exchange.reply.bytes[0..ctx.exchange.reply.len], secret);
            }
        };
        var adapter: Adapter = .{ .exchange = self, .context = context, .verifier = verifier };
        const accepted = self.handoff.authenticate(token, now, &adapter, &Adapter.call) catch |err| {
            if (err != error.Stale and (self.handoff.phase == .cancel_pending or self.handoff.phase == .failed)) self.reply.clear();
            return err;
        };
        self.reply.clear();
        return accepted;
    }
};

test "capture and timeout retain worker ownership but erase reply" {
    const token: kem.Token = .{ .epoch = 1, .request = 2 };
    var x: Exchange = .{};
    try x.handoff.start(token, 0, 10);
    try x.handoff.publicComplete(token, 1, &@as([1184]u8, @splat(1)));
    var pk: [1184]u8 = undefined;
    try x.handoff.takePublic(token, 2, &pk);
    const hybrid = @import("ssh_hybrid_transcript.zig");
    var packet: [1 + 4 + 4 + hybrid.server_len + 4]u8 = @splat(0);
    packet[0] = 31;
    std.mem.writeInt(u32, packet[5..9], hybrid.server_len, .big);
    packet[9] = 42;
    var sender: transport.Transport = .{};
    var wire: transport.Transport = .{};
    try std.testing.expectError(error.NoPacket, x.captureReply(&wire, token, 3));
    try std.testing.expectEqual(kem.Phase.waiting_reply, x.handoff.phase);
    try sender.prepare(&packet, &@as([32]u8, @splat(3)));
    _ = try wire.feed(sender.pending());
    try std.testing.expectError(error.Stale, x.captureReply(&wire, .{ .epoch = 1, .request = 3 }, 3));
    try std.testing.expect(wire.rx.payload() != null);
    try x.captureReply(&wire, token, 3);
    try std.testing.expect(wire.rx.payload() == null);
    var ct: [1088]u8 = undefined;
    try x.handoff.takeCiphertext(token, 4, &ct);
    try std.testing.expectEqual(@as(u8, 42), ct[0]);
    try std.testing.expectError(error.TimedOut, x.tick(token, 10));
    try std.testing.expectEqual(@as(usize, 0), x.reply.len);
    try std.testing.expect(!x.handoff.reclaimable());
    try x.handoff.cancelAcknowledged(token);
    try std.testing.expect(x.handoff.reclaimable());
}

test "authentication callback is bounded by deadline and clears retained data" {
    const token: kem.Token = .{ .epoch = 2, .request = 3 };
    const Verify = struct {
        fn accept(_: ?*anyopaque, bytes: []const u8, secret: *const [32]u8) bool {
            return std.mem.eql(u8, bytes, "reply") and std.mem.allEqual(u8, secret, 7);
        }
    };
    var x: Exchange = .{};
    try x.handoff.start(token, 0, 20);
    x.handoff.phase = .authenticating;
    x.handoff.worker_owned = false;
    x.handoff.secret = @splat(7);
    @memcpy(x.reply.bytes[0..5], "reply");
    x.reply.len = 5;
    try std.testing.expectError(error.Stale, x.authenticate(.{ .epoch = 1, .request = 3 }, 1, null, &Verify.accept));
    try std.testing.expectEqual(@as(usize, 5), x.reply.len);
    try std.testing.expect(try x.authenticate(token, 2, null, &Verify.accept));
    try std.testing.expectEqual(@as(usize, 0), x.reply.len);
    try std.testing.expect(x.handoff.reclaimable());
    var late: Exchange = .{};
    try late.handoff.start(token, 0, 20);
    late.handoff.phase = .authenticating;
    late.handoff.worker_owned = false;
    late.handoff.secret = @splat(7);
    @memcpy(late.reply.bytes[0..5], "reply");
    late.reply.len = 5;
    try std.testing.expectError(error.TimedOut, late.authenticate(token, 20, null, &Verify.accept));
    try std.testing.expectEqual(@as(usize, 0), late.reply.len);
    try std.testing.expect(std.mem.allEqual(u8, &late.handoff.secret, 0));
    try std.testing.expect(late.handoff.reclaimable());
}
