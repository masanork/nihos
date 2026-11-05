//! Experimental single-owner hybrid KEX driver. Worker callbacks must copy
//! inputs before return and must not reenter this driver. Before completion,
//! the worker must stop using and erase its own key and result copies.
//! Verification currently runs on the caller's stack; P4 needs a suitable
//! worker stack before this driver can be used by the native service.
const std = @import("std");
const handshake = @import("ssh_hybrid_handshake.zig");
const exchange = @import("ssh_hybrid_exchange.zig");
const kem = @import("ssh_kem_handoff.zig");
const transport = @import("ssh_transport.zig");
const kex = @import("ssh_kex.zig");
const ssh = @import("ssh.zig");
pub const Submit = *const fn (?*anyopaque, kem.Token, *const [1088]u8) bool;
pub const Driver = struct {
    const State = enum { send_init, server_init, server_reply, waiting_worker, send_newkeys, peer_newkeys, done, failed };
    state: State = .send_init,
    protocol: handshake.Handshake,
    exchange: exchange.Exchange = .{},
    token: kem.Token,
    cookie: [16]u8,
    deadline: u64,
    last_time: u64,
    keys: ?kex.Keys = null,
    session_id: ?[32]u8 = null,

    /// Worker key generation has completed and its secret remains worker-owned.
    /// On init failure, the owner must cancel and reclaim that worker.
    pub fn init(protocol: handshake.Handshake, cookie: [16]u8, token: kem.Token, now: u64, deadline: u64) !Driver {
        var self: Driver = undefined;
        self.protocol = protocol;
        try self.initInPlace(cookie, token, now, deadline);
        return self;
    }
    /// Protocol must already be initialized in this exclusively owned storage.
    /// All prior workers must have stopped and been reclaimed before reuse.
    /// On failure, the owner must cancel and reclaim the new worker.
    pub fn initInPlace(self: *Driver, cookie: [16]u8, token: kem.Token, now: u64, deadline: u64) !void {
        self.state = .send_init;
        self.exchange = .{};
        self.token = token;
        self.cookie = cookie;
        self.deadline = deadline;
        self.last_time = now;
        self.keys = null;
        self.session_id = null;
        errdefer {
            self.exchange.abort();
            self.protocol.deinit();
            std.crypto.secureZero(u8, &self.cookie);
        }
        try self.exchange.handoff.start(token, now, deadline);
        try self.exchange.handoff.publicComplete(token, now, self.protocol.client[0..1184]);
        var public: [1184]u8 = undefined;
        try self.exchange.handoff.takePublic(token, now, &public);
    }
    /// One transition per call. The owner must pump the transport and call
    /// step even while the worker or network is silent so deadlines advance.
    pub fn step(self: *Driver, wire: *transport.Transport, now: u64, padding: *const [32]u8, context: ?*anyopaque, submit: Submit) !bool {
        return self.advance(wire, now, padding, context, submit) catch |err| {
            self.abort(wire);
            return err;
        };
    }
    fn advance(self: *Driver, wire: *transport.Transport, now: u64, padding: *const [32]u8, context: ?*anyopaque, submit: Submit) !bool {
        if (self.state == .failed) return error.InvalidState;
        if (wire.failed) return error.Failed;
        if (self.state == .done) return true;
        try self.checkTime(now);
        if (self.state != .send_newkeys and self.state != .peer_newkeys) try self.exchange.tick(self.token, now);
        if (wire.pending().len != 0) return false;
        var out: [1300]u8 = undefined;
        switch (self.state) {
            .send_init => {
                const packet = try self.protocol.start(self.cookie, &out);
                try wire.prepare(packet, padding);
                std.crypto.secureZero(u8, &self.cookie);
                self.state = .server_init;
            },
            .server_init => {
                const packet = wire.rx.payload() orelse return false;
                const client = try self.protocol.serverInit(packet, &out);
                wire.rx.release();
                try wire.prepare(client, padding);
                self.state = .server_reply;
            },
            .server_reply => {
                _ = try self.dispatchReply(wire, now, context, submit);
            },
            .waiting_worker => {},
            .send_newkeys => {
                try wire.prepare(&.{ssh.SSH_MSG_NEWKEYS}, padding);
                self.state = .peer_newkeys;
            },
            .peer_newkeys => {
                const packet = wire.rx.payload() orelse return false;
                if (!std.mem.eql(u8, packet, &.{ssh.SSH_MSG_NEWKEYS})) return error.Malformed;
                wire.rx.release();
                const keys = if (self.keys) |*v| v else return error.InvalidState;
                try wire.enableEncryption(keys);
                self.session_id = keys.exchange_hash;
                std.crypto.secureZero(u8, std.mem.asBytes(keys));
                self.keys = null;
                self.state = .done;
                return true;
            },
            else => unreachable,
        }
        return false;
    }
    /// Dispatch a fully decoded server reply, or return false if none is ready.
    /// This may be called directly by a transport adapter at the packet boundary.
    pub fn dispatchReply(self: *Driver, wire: *transport.Transport, now: u64, context: ?*anyopaque, submit: Submit) !bool {
        return self.dispatch(wire, now, context, submit) catch |err| {
            self.abort(wire);
            return err;
        };
    }
    fn dispatch(self: *Driver, wire: *transport.Transport, now: u64, context: ?*anyopaque, submit: Submit) !bool {
        if (self.state != .server_reply) return error.InvalidState;
        if (wire.failed) return error.Failed;
        try self.checkTime(now);
        try self.exchange.tick(self.token, now);
        if (wire.pending().len != 0 or wire.rx.payload() == null) return false;
        try self.exchange.captureReply(wire, self.token, now);
        var ciphertext: [1088]u8 = undefined;
        try self.exchange.handoff.takeCiphertext(self.token, now, &ciphertext);
        if (!submit(context, self.token, &ciphertext)) return error.WorkerSubmitFailed;
        self.state = .waiting_worker;
        return true;
    }
    /// Invoke only after the trusted backend has erased its key and stopped.
    pub fn complete(self: *Driver, wire: *transport.Transport, token: kem.Token, now: u64, secret: *const [32]u8) !void {
        if (self.state != .waiting_worker) return error.InvalidState;
        if (wire.failed) {
            self.abort(wire);
            return error.Failed;
        }
        if (token.epoch != self.token.epoch or token.request != self.token.request) return error.Stale;
        self.checkTime(now) catch |err| {
            self.abort(wire);
            return err;
        };
        self.finish(wire, token, now, secret) catch |err| {
            self.abort(wire);
            return err;
        };
    }
    fn checkTime(self: *Driver, now: u64) !void {
        if (now < self.last_time) return error.ClockRegression;
        self.last_time = now;
        if (now >= self.deadline) return error.TimedOut;
    }
    fn finish(self: *Driver, _: *transport.Transport, token: kem.Token, now: u64, secret: *const [32]u8) !void {
        try self.exchange.handoff.secretComplete(token, now, secret);
        const Context = struct {
            protocol: *handshake.Handshake,
            keys: ?kex.Keys = null,
            fn verify(raw: ?*anyopaque, packet: []const u8, shared: *const [32]u8) bool {
                const ctx: *@This() = @ptrCast(@alignCast(raw.?));
                ctx.keys = ctx.protocol.finishWithPq(packet, shared) catch return false;
                return true;
            }
        };
        var ctx: Context = .{ .protocol = &self.protocol };
        defer if (ctx.keys) |*key| std.crypto.secureZero(u8, std.mem.asBytes(key));
        if (!try self.exchange.authenticate(token, now, &ctx, &Context.verify)) return error.HostProofFailed;
        self.keys = ctx.keys orelse return error.HostProofFailed;
        self.protocol.deinit();
        self.state = .send_newkeys;
    }
    /// The owner must deliver cancellation and wait for its acknowledgement;
    /// this function does not stop the worker or release its backing.
    pub fn abort(self: *Driver, wire: *transport.Transport) void {
        self.exchange.abort();
        self.protocol.deinit();
        std.crypto.secureZero(u8, &self.cookie);
        if (self.keys) |*key| std.crypto.secureZero(u8, std.mem.asBytes(key));
        self.keys = null;
        if (self.session_id) |*id| std.crypto.secureZero(u8, id);
        self.session_id = null;
        wire.abort();
        self.state = .failed;
    }
};

test "worker response is authenticated before NEWKEYS and transport activation" {
    const vector = @import("ssh_hybrid_vector.zig");
    const raw = @embedFile("ssh_hybrid_public_vector.bin");
    const v: *const vector.Vector = @ptrCast(raw.ptr);
    var protocol = try handshake.Handshake.init(v.xsecret, v.pin, vector.server_banner, &v.pk);
    @memcpy(protocol.client_init[0..vector.client_kex.len], vector.client_kex);
    protocol.client_len = vector.client_kex.len;
    @memcpy(protocol.server_init[0..vector.server_kex.len], vector.server_kex);
    protocol.server_len = vector.server_kex.len;
    const token: kem.Token = .{ .epoch = 1, .request = 1 };
    var driver = try Driver.init(protocol, @splat(1), token, 0, 100);
    defer driver.protocol.deinit();
    driver.state = .server_reply;
    var payload: [1 + 4 + 51 + 4 + 1120 + 4 + 83]u8 = undefined;
    payload[0] = 31;
    var pos: usize = 1;
    for ([_][]const u8{ &v.host, &v.server, &v.signature }) |item| {
        std.mem.writeInt(u32, payload[pos..][0..4], @intCast(item.len), .big);
        pos += 4;
        @memcpy(payload[pos..][0..item.len], item);
        pos += item.len;
    }
    const Worker = struct {
        ct: [1088]u8 = undefined,
        called: bool = false,
        fn submit(ctx: ?*anyopaque, _: kem.Token, ct: *const [1088]u8) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.ct = ct.*;
            self.called = true;
            return true;
        }
    };
    var worker: Worker = .{};
    var wire: transport.Transport = .{};
    var peer: transport.Transport = .{};
    const padding: [32]u8 = @splat(2);
    try std.testing.expect(!(try driver.dispatchReply(&wire, 1, &worker, &Worker.submit)));
    try std.testing.expect(!worker.called and !wire.failed);
    try peer.prepare(&payload, &padding);
    _ = try wire.feed(peer.pending());
    try peer.consume(peer.pending().len);
    try std.testing.expect(try driver.dispatchReply(&wire, 1, &worker, &Worker.submit));
    try std.testing.expect(worker.called);
    try std.testing.expectEqualSlices(u8, v.server[0..1088], &worker.ct);
    try std.testing.expect(driver.keys == null and wire.pending().len == 0);
    const pair = try std.crypto.kem.ml_kem.MLKem768.KeyPair.generateDeterministic(v.seed);
    var secret = try pair.secret_key.decaps(&worker.ct);
    defer std.crypto.secureZero(u8, &secret);
    try std.testing.expectError(error.Stale, driver.complete(&wire, .{ .epoch = 1, .request = 2 }, 2, &secret));
    try driver.complete(&wire, token, 2, &secret);
    try std.testing.expect(!(try driver.step(&wire, 3, &padding, &worker, &Worker.submit)));
    try std.testing.expect(wire.pending().len != 0 and wire.cipher == null);
    try wire.consume(wire.pending().len);
    try peer.prepare(&.{ssh.SSH_MSG_NEWKEYS}, &padding);
    _ = try wire.feed(peer.pending());
    try std.testing.expect(try driver.step(&wire, 4, &padding, &worker, &Worker.submit));
    try std.testing.expect(wire.cipher != null and driver.keys == null);
    try std.testing.expectEqualSlices(u8, &v.hash, &driver.session_id.?);
    driver.abort(&wire);
}

test "worker submission failure waits for cancellation acknowledgement" {
    const token: kem.Token = .{ .epoch = 4, .request = 7 };
    const protocol = try handshake.Handshake.init(@splat(1), @splat(2), "SSH-2.0-test", &@as([1184]u8, @splat(3)));
    var driver = try Driver.init(protocol, @splat(4), token, 0, 100);
    driver.state = .server_reply;
    var reply: [1 + 4 + 4 + 1120 + 4]u8 = @splat(0);
    reply[0] = 31;
    std.mem.writeInt(u32, reply[5..9], 1120, .big);
    var peer: transport.Transport = .{};
    var wire: transport.Transport = .{};
    const padding: [32]u8 = @splat(5);
    try peer.prepare(&reply, &padding);
    _ = try wire.feed(peer.pending());
    const Worker = struct {
        fn reject(_: ?*anyopaque, _: kem.Token, _: *const [1088]u8) bool {
            return false;
        }
    };
    try std.testing.expectError(error.WorkerSubmitFailed, driver.step(&wire, 1, &padding, null, &Worker.reject));
    try std.testing.expect(wire.failed and !driver.exchange.handoff.reclaimable());
    try driver.exchange.handoff.cancelAcknowledged(token);
    try std.testing.expect(driver.exchange.handoff.reclaimable());
}

test "silent worker timeout aborts transport and retains worker backing" {
    const token: kem.Token = .{ .epoch = 5, .request = 8 };
    const protocol = try handshake.Handshake.init(@splat(1), @splat(2), "SSH-2.0-test", &@as([1184]u8, @splat(3)));
    var driver = try Driver.init(protocol, @splat(4), token, 0, 10);
    driver.state = .waiting_worker;
    var wire: transport.Transport = .{};
    const Worker = struct {
        fn unused(_: ?*anyopaque, _: kem.Token, _: *const [1088]u8) bool {
            return false;
        }
    };
    try std.testing.expectError(error.TimedOut, driver.step(&wire, 10, &@as([32]u8, @splat(1)), null, &Worker.unused));
    try std.testing.expect(wire.failed and !driver.exchange.handoff.reclaimable());
    try driver.exchange.handoff.cancelAcknowledged(token);
    try std.testing.expect(driver.exchange.handoff.reclaimable());
}

test "late verified result cannot send NEWKEYS" {
    const token: kem.Token = .{ .epoch = 6, .request = 1 };
    const protocol = try handshake.Handshake.init(@splat(1), @splat(2), "SSH-2.0-test", &@as([1184]u8, @splat(3)));
    var driver = try Driver.init(protocol, @splat(4), token, 0, 10);
    // Model a trusted worker that has already verified and erased its key.
    driver.exchange.handoff.worker_owned = false;
    driver.exchange.handoff.phase = .finished;
    driver.state = .send_newkeys;
    var wire: transport.Transport = .{};
    const Worker = struct {
        fn unused(_: ?*anyopaque, _: kem.Token, _: *const [1088]u8) bool {
            return false;
        }
    };
    try std.testing.expectError(error.TimedOut, driver.step(&wire, 10, &@as([32]u8, @splat(1)), null, &Worker.unused));
    try std.testing.expect(wire.failed and wire.pending().len == 0);
}

test "in-place initialization failure clears protocol and cookie" {
    const token: kem.Token = .{ .epoch = 3, .request = 1 };
    var driver: Driver = undefined;
    try driver.protocol.initInPlace(@splat(1), @splat(2), "SSH-2.0-test", &@as([1184]u8, @splat(3)));
    try std.testing.expectError(error.InvalidToken, driver.initInPlace(@splat(4), token, 10, 10));
    try std.testing.expect(std.mem.allEqual(u8, &driver.protocol.secret, 0));
    try std.testing.expect(std.mem.allEqual(u8, &driver.cookie, 0));
}
