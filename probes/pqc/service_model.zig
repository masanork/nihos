//! Host-only model of a proposed verify-service lifecycle. No OS or crypto API.
const std = @import("std");
const testing = std.testing;

const Owner = struct { hart: u8, slot: u16, generation: u16 };
const Token = struct { owner: Owner, sequence: u32 };
const Phase = enum { idle, queued, running, cleaning, complete, quarantined };
const Outcome = enum { valid, invalid, cancelled, unavailable };
const Job = struct {
    phase: Phase = .idle,
    serial: u32 = 0,
    token: ?Token = null,
    cancelled: bool = false,
    outcome: ?Outcome = null,

    fn matches(self: *const Job, token: Token) bool {
        return if (self.token) |current| std.meta.eql(current, token) else false;
    }
    fn submit(self: *Job, owner: Owner) ?Token {
        if (self.phase != .idle or owner.generation == 0 or self.serial == std.math.maxInt(u32)) return null;
        self.serial += 1;
        const token: Token = .{ .owner = owner, .sequence = self.serial };
        self.* = .{ .phase = .queued, .serial = self.serial, .token = token };
        return token;
    }
    fn start(self: *Job, token: Token, workspace_ready: bool) bool {
        if (self.phase != .queued or !self.matches(token)) return false;
        if (workspace_ready) {
            self.phase = .running;
        } else {
            self.outcome = .unavailable;
            self.phase = .cleaning;
        }
        return true;
    }
    fn cancel(self: *Job, token: Token) bool {
        if (!self.matches(token)) return false;
        switch (self.phase) {
            .queued => {
                self.outcome = .cancelled;
                self.phase = .cleaning;
            },
            .running => self.cancelled = true,
            else => return false,
        }
        return true;
    }
    // Only worker completion proves that borrowed inputs and arena are no longer in use.
    fn workerDone(self: *Job, token: Token, valid: bool) bool {
        if (self.phase != .running or !self.matches(token)) return false;
        self.outcome = if (self.cancelled) .cancelled else if (valid) .valid else .invalid;
        self.phase = .cleaning;
        return true;
    }
    // Release is permitted only after the worker stopped and cleanup succeeded.
    fn cleanup(self: *Job, token: Token, ok: bool) bool {
        if (self.phase != .cleaning or !self.matches(token)) return false;
        self.phase = if (ok) .complete else .quarantined;
        return true;
    }
    fn take(self: *Job, token: Token) ?Outcome {
        if (self.phase != .complete or !self.matches(token)) return null;
        const outcome = self.outcome orelse return null;
        const serial = self.serial;
        self.* = .{ .serial = serial };
        return outcome;
    }
};

test "cancel during running defers cleanup and never exposes valid result" {
    var job: Job = .{};
    const token = job.submit(.{ .hart = 0, .slot = 1, .generation = 4 }).?;
    try testing.expect(job.start(token, true));
    try testing.expect(job.cancel(token));
    try testing.expect(!job.cleanup(token, true));
    try testing.expect(job.take(token) == null);
    try testing.expect(job.workerDone(token, true));
    try testing.expect(job.cleanup(token, true));
    try testing.expectEqual(Outcome.cancelled, job.take(token).?);
}

test "stale owner and job token cannot cancel or consume replacement" {
    var job: Job = .{};
    const old = job.submit(.{ .hart = 0, .slot = 1, .generation = 4 }).?;
    try testing.expect(job.cancel(old));
    try testing.expect(job.cleanup(old, true));
    try testing.expectEqual(Outcome.cancelled, job.take(old).?);
    const next = job.submit(.{ .hart = 0, .slot = 1, .generation = 5 }).?;
    try testing.expect(!job.cancel(old));
    try testing.expect(job.take(old) == null);
    try testing.expect(job.start(next, false));
    try testing.expect(job.cleanup(next, true));
    try testing.expectEqual(Outcome.unavailable, job.take(next).?);
}

test "failed cleanup quarantines workspace and blocks reuse" {
    var job: Job = .{};
    const owner: Owner = .{ .hart = 1, .slot = 2, .generation = 1 };
    const token = job.submit(owner).?;
    try testing.expect(job.start(token, true));
    try testing.expect(job.workerDone(token, false));
    try testing.expect(job.cleanup(token, false));
    try testing.expect(job.take(token) == null);
    try testing.expect(job.submit(owner) == null);
}

test "completed verification cannot be relabelled by a later cancellation" {
    var job: Job = .{};
    const token = job.submit(.{ .hart = 0, .slot = 1, .generation = 1 }).?;
    try testing.expect(job.start(token, true));
    try testing.expect(job.workerDone(token, false));
    try testing.expect(!job.cancel(token));
    try testing.expect(job.cleanup(token, true));
    try testing.expectEqual(Outcome.invalid, job.take(token).?);
}

test "admission is bounded and serial exhaustion fails closed" {
    var job: Job = .{};
    const owner: Owner = .{ .hart = 0, .slot = 1, .generation = 1 };
    const first = job.submit(owner).?;
    try testing.expect(job.submit(owner) == null);
    try testing.expect(job.start(first, true));
    try testing.expect(job.workerDone(first, true));
    try testing.expect(job.cleanup(first, true));
    try testing.expectEqual(Outcome.valid, job.take(first).?);
    job.serial = std.math.maxInt(u32);
    try testing.expect(job.submit(owner) == null);
}
