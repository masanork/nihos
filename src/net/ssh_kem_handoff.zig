//! Single-owner asynchronous SSH/KEM handoff, independent of transport and scheduler.
//! Worker inputs must be copied before acknowledgement. The callback is trusted,
//! non-reentrant and must publish transport keys only on successful verification.
//! Caller must choose globally fresh nonzero tokens and own worker cancellation.
//! The backend retains and must erase its own secret/result copy even when a
//! stale completion is rejected. Cancellation acknowledgement is a contract,
//! not proof that an untrusted worker actually stopped or erased its memory.
const std = @import("std");
pub const Token = struct { epoch: u64, request: u64 };
pub const Error = error{ InvalidState, Stale, ClockRegression, TimedOut, InvalidToken };
pub const Phase = enum { idle, generating, public_ready, waiting_reply, decapsulating, authenticating, cancel_pending, finished, failed };
pub const Verifier = *const fn (?*anyopaque, *const [32]u8) bool;
pub const Handoff = struct {
    phase: Phase = .idle,
    token: Token = .{ .epoch = 0, .request = 0 },
    deadline: u64 = 0,
    last: u64 = 0,
    public_key: [1184]u8 = @splat(0),
    ciphertext: [1088]u8 = @splat(0),
    secret: [32]u8 = @splat(0),
    ciphertext_taken: bool = false,
    /// The worker owns a key or an in-flight operation until completion or
    /// explicit cancellation acknowledgement. Do not free its backing early.
    worker_owned: bool = false,

    pub fn start(self: *Handoff, token: Token, now: u64, deadline: u64) Error!void {
        if (self.phase != .idle) return error.InvalidState;
        if (token.epoch == 0 or token.request == 0 or deadline <= now) return error.InvalidToken;
        self.token = token;
        self.last = now;
        self.deadline = deadline;
        self.worker_owned = true;
        self.phase = .generating;
    }
    fn valid(self: *Handoff, token: Token, now: u64) Error!void {
        if (token.epoch != self.token.epoch or token.request != self.token.request) return error.Stale;
        if (now < self.last) {
            self.abort();
            return error.ClockRegression;
        }
        self.last = now;
        if (now >= self.deadline) {
            self.abort();
            return error.TimedOut;
        }
    }
    /// Poll even when the worker/socket is silent, so deadlines are enforced.
    pub fn tick(self: *Handoff, token: Token, now: u64) Error!void {
        if (self.phase == .idle or self.phase == .finished or self.phase == .failed or self.phase == .cancel_pending) return error.InvalidState;
        try self.valid(token, now);
    }
    /// Tighten, never extend, a live deadline using the same monotonic clock.
    pub fn shortenDeadline(self: *Handoff, token: Token, now: u64, deadline: u64) Error!void {
        try self.tick(token, now);
        if (deadline <= now or deadline > self.deadline) return error.InvalidToken;
        self.deadline = deadline;
    }
    pub fn publicComplete(self: *Handoff, token: Token, now: u64, key: *const [1184]u8) Error!void {
        try self.valid(token, now);
        if (self.phase != .generating) return error.InvalidState;
        self.public_key = key.*;
        self.phase = .public_ready;
    }
    pub fn takePublic(self: *Handoff, token: Token, now: u64, out: *[1184]u8) Error!void {
        try self.valid(token, now);
        if (self.phase != .public_ready) return error.InvalidState;
        out.* = self.public_key;
        self.phase = .waiting_reply;
    }
    pub fn submitReply(self: *Handoff, token: Token, now: u64, ciphertext: *const [1088]u8) Error!void {
        try self.valid(token, now);
        if (self.phase != .waiting_reply) return error.InvalidState;
        self.ciphertext = ciphertext.*;
        self.phase = .decapsulating;
    }
    pub fn takeCiphertext(self: *Handoff, token: Token, now: u64, out: *[1088]u8) Error!void {
        try self.valid(token, now);
        if (self.phase != .decapsulating or self.ciphertext_taken) return error.InvalidState;
        out.* = self.ciphertext;
        self.ciphertext_taken = true;
    }
    pub fn secretComplete(self: *Handoff, token: Token, now: u64, secret: *const [32]u8) Error!void {
        try self.valid(token, now);
        if (self.phase != .decapsulating or !self.ciphertext_taken) return error.InvalidState;
        self.secret = secret.*;
        self.worker_owned = false;
        self.phase = .authenticating;
    }
    pub fn authenticate(self: *Handoff, token: Token, now: u64, context: ?*anyopaque, verifier: Verifier) Error!bool {
        try self.valid(token, now);
        if (self.phase != .authenticating) return error.InvalidState;
        const valid_signature = verifier(context, &self.secret);
        self.clear();
        self.phase = if (valid_signature) .finished else .failed;
        return valid_signature;
    }
    pub fn abort(self: *Handoff) void {
        if (self.phase == .idle or self.phase == .finished or self.phase == .failed or self.phase == .cancel_pending) return;
        self.clear();
        self.phase = if (self.worker_owned) .cancel_pending else .failed;
    }
    /// Caller must wait until the backend has stopped and erased its own key.
    pub fn cancelAcknowledged(self: *Handoff, token: Token) Error!void {
        if (token.epoch != self.token.epoch or token.request != self.token.request) return error.Stale;
        if (self.phase != .cancel_pending or !self.worker_owned) return error.InvalidState;
        self.worker_owned = false;
        self.phase = .failed;
    }
    pub fn reclaimable(self: *const Handoff) bool {
        return !self.worker_owned and (self.phase == .finished or self.phase == .failed);
    }
    fn clear(self: *Handoff) void {
        std.crypto.secureZero(u8, &self.secret);
        std.crypto.secureZero(u8, &self.ciphertext);
        std.crypto.secureZero(u8, &self.public_key);
    }
};

test "request buffers are copied, one-shot, and secret is erased after authentication" {
    const token = Token{ .epoch = 7, .request = 11 };
    var h: Handoff = .{};
    var pk: [1184]u8 = @splat(3);
    var ct: [1088]u8 = @splat(4);
    var out_pk: [1184]u8 = undefined;
    var out_ct: [1088]u8 = undefined;
    try h.start(token, 10, 100);
    try h.publicComplete(token, 11, &pk);
    @memset(&pk, 9);
    try h.takePublic(token, 12, &out_pk);
    try std.testing.expect(std.mem.allEqual(u8, &out_pk, 3));
    try h.submitReply(token, 13, &ct);
    @memset(&ct, 9);
    try h.takeCiphertext(token, 14, &out_ct);
    try std.testing.expect(std.mem.allEqual(u8, &out_ct, 4));
    try std.testing.expectError(error.InvalidState, h.takeCiphertext(token, 14, &out_ct));
    try h.secretComplete(token, 15, &@as([32]u8, @splat(8)));
    const Verify = struct {
        fn run(_: ?*anyopaque, secret: *const [32]u8) bool {
            return std.mem.allEqual(u8, secret, 8);
        }
    };
    try std.testing.expect(try h.authenticate(token, 16, null, &Verify.run));
    try std.testing.expect(h.reclaimable() and std.mem.allEqual(u8, &h.secret, 0));
}

test "stale completions do not release worker and timeout requires acknowledgement" {
    const token = Token{ .epoch = 5, .request = 17 };
    var h: Handoff = .{};
    try h.start(token, 0, 10);
    try std.testing.expectError(error.Stale, h.publicComplete(.{ .epoch = 4, .request = 17 }, 1, &@as([1184]u8, @splat(1))));
    try std.testing.expectEqual(Phase.generating, h.phase);
    try std.testing.expectError(error.TimedOut, h.publicComplete(token, 10, &@as([1184]u8, @splat(1))));
    try std.testing.expectEqual(Phase.cancel_pending, h.phase);
    try std.testing.expect(!h.reclaimable());
    try std.testing.expectError(error.TimedOut, h.secretComplete(token, 11, &@as([32]u8, @splat(9))));
    try std.testing.expect(std.mem.allEqual(u8, &h.secret, 0) and !h.reclaimable());
    try std.testing.expectError(error.Stale, h.cancelAcknowledged(.{ .epoch = 5, .request = 18 }));
    try h.cancelAcknowledged(token);
    try std.testing.expect(h.reclaimable());
    var silent: Handoff = .{};
    try silent.start(token, 0, 10);
    try std.testing.expectError(error.TimedOut, silent.tick(token, 10));
    try std.testing.expectEqual(Phase.cancel_pending, silent.phase);
    var shortened: Handoff = .{};
    try shortened.start(token, 0, 100);
    try std.testing.expectError(error.InvalidToken, shortened.shortenDeadline(token, 1, 101));
    try shortened.shortenDeadline(token, 2, 4);
    try std.testing.expectError(error.TimedOut, shortened.tick(token, 4));
    try std.testing.expect(!shortened.reclaimable());
}

test "failed authentication and clock regression fail closed" {
    const token = Token{ .epoch = 1, .request = 1 };
    var h: Handoff = .{};
    try h.start(token, 3, 20);
    try h.publicComplete(token, 4, &@as([1184]u8, @splat(2)));
    var pk: [1184]u8 = undefined;
    try h.takePublic(token, 5, &pk);
    try h.submitReply(token, 6, &@as([1088]u8, @splat(3)));
    var ct: [1088]u8 = undefined;
    try h.takeCiphertext(token, 7, &ct);
    try h.secretComplete(token, 8, &@as([32]u8, @splat(4)));
    const Verify = struct {
        fn reject(_: ?*anyopaque, _: *const [32]u8) bool {
            return false;
        }
    };
    try std.testing.expect(!(try h.authenticate(token, 9, null, &Verify.reject)));
    try std.testing.expect(h.reclaimable() and std.mem.allEqual(u8, &h.secret, 0));
    var other: Handoff = .{};
    try other.start(token, 10, 20);
    try std.testing.expectError(error.ClockRegression, other.publicComplete(token, 9, &@as([1184]u8, @splat(2))));
    try std.testing.expectEqual(Phase.cancel_pending, other.phase);
}

test "completion racing a cancellation is discarded before worker acknowledgement" {
    const token = Token{ .epoch = 9, .request = 2 };
    var h: Handoff = .{};
    try h.start(token, 0, 100);
    try h.publicComplete(token, 1, &@as([1184]u8, @splat(1)));
    var pk: [1184]u8 = undefined;
    try h.takePublic(token, 2, &pk);
    try h.submitReply(token, 3, &@as([1088]u8, @splat(2)));
    var ct: [1088]u8 = undefined;
    try h.takeCiphertext(token, 4, &ct);
    h.abort();
    try std.testing.expectError(error.InvalidState, h.secretComplete(token, 5, &@as([32]u8, @splat(3))));
    try std.testing.expect(std.mem.allEqual(u8, &h.secret, 0) and !h.reclaimable());
    try h.cancelAcknowledged(token);
    try std.testing.expect(h.reclaimable());
}

test "worker completion only publishes SSH transport keys after pinned host proof" {
    const hybrid = @import("ssh_hybrid_transcript.zig");
    const proof = @import("ssh_host_key.zig");
    const ssh = @import("ssh.zig");
    const vectors = @import("ssh_hybrid_vector.zig");
    const K = std.crypto.kem.ml_kem.MLKem768;
    const X = std.crypto.dh.X25519;
    const raw = @embedFile("ssh_hybrid_public_vector.bin");
    const v: *const vectors.Vector = @ptrCast(raw.ptr);
    const keys = try K.KeyPair.generateDeterministic(v.seed);
    const pq = try keys.secret_key.decaps(v.server[0..1088]);
    const VerifierContext = struct {
        pin: [32]u8,
        v: *const vectors.Vector,
        produced: ?[32]u8 = null,
        fn verify(ctx: ?*anyopaque, shared: *const [32]u8) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            var classic = X.scalarmult(self.v.xsecret, self.v.server[1088..][0..32].*) catch return false;
            defer std.crypto.secureZero(u8, &classic);
            var combined = hybrid.combine(shared.*, classic) catch return false;
            defer std.crypto.secureZero(u8, &combined);
            var client: [1216]u8 = undefined;
            client[0..1184].* = self.v.pk;
            client[1184..].* = X.recoverPublicKey(self.v.xsecret);
            const hash = hybrid.exchangeHash(vectors.client_banner, vectors.server_banner, vectors.client_kex, vectors.server_kex, &self.v.host, &client, &self.v.server, combined) catch return false;
            proof.verify(&self.v.host, &self.v.signature, hash, self.pin) catch return false;
            var encoded: [36]u8 = undefined;
            defer std.crypto.secureZero(u8, &encoded);
            std.mem.writeInt(u32, encoded[0..4], 32, .big);
            encoded[4..].* = combined;
            var result: [32]u8 = undefined;
            ssh.deriveKey(&encoded, hash, hash, 'C', &result);
            self.produced = result;
            return true;
        }
    };
    for ([_]bool{ false, true }) |wrong_pin| {
        const token = Token{ .epoch = 3, .request = 19 };
        var h: Handoff = .{};
        var ctx = VerifierContext{ .pin = v.pin, .v = v };
        if (wrong_pin) ctx.pin[0] ^= 1;
        try h.start(token, 1, 20);
        try h.publicComplete(token, 2, &v.pk);
        var public: [1184]u8 = undefined;
        try h.takePublic(token, 3, &public);
        try h.submitReply(token, 4, v.server[0..1088]);
        var ct: [1088]u8 = undefined;
        try h.takeCiphertext(token, 5, &ct);
        try h.secretComplete(token, 6, &pq);
        try std.testing.expect(ctx.produced == null);
        try std.testing.expectEqual(!wrong_pin, try h.authenticate(token, 7, &ctx, &VerifierContext.verify));
        try std.testing.expectEqual(!wrong_pin, ctx.produced != null);
        try std.testing.expect(h.reclaimable() and std.mem.allEqual(u8, &h.secret, 0));
    }
}
