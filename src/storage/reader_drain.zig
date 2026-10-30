//! Serialized trusted coordinator barrier, not a scheduler or a DMA driver.
//! A stop request, a worker's clean exit and callback completion are distinct.
//! Register callbacks before handing out work; complete only after buffer use
//! ends. Native integrations must authenticate and serialize these events.
const std = @import("std");
pub const Error = error{ Busy, Denied, Exhausted, Fenced, InvalidArgument };
pub const Ticket = struct { slot: u8, token: u64 };
pub const Drain = struct {
    pub const State = enum { idle, running, stopping, ready, fenced };
    worker: u64 = 0,
    generation: u64 = 0,
    issued: u64 = 0,
    callbacks: [2]u64 = .{ 0, 0 },
    state: State = .idle,
    worker_stopped: bool = false,

    pub fn begin(self: *Drain, worker: u64) Error!u64 {
        if (self.state == .fenced) return error.Fenced;
        if (!self.canRelease()) return error.Busy;
        if (worker == 0) return error.InvalidArgument;
        if (self.generation == std.math.maxInt(u64)) return error.Exhausted;
        self.generation += 1;
        self.worker = worker;
        self.worker_stopped = false;
        self.state = .running;
        return self.generation;
    }
    fn owned(self: *const Drain, worker: u64, generation: u64) Error!void {
        if (worker == 0 or worker != self.worker or generation == 0 or generation != self.generation or self.state == .idle) return error.Denied;
    }
    pub fn enter(self: *Drain, worker: u64, generation: u64) Error!Ticket {
        try self.owned(worker, generation);
        if (self.state == .fenced) return error.Fenced;
        if (self.state != .running) return error.Busy;
        for (&self.callbacks, 0..) |*slot, index| if (slot.* == 0) {
            if (self.issued == std.math.maxInt(u64)) return error.Exhausted;
            self.issued += 1;
            slot.* = self.issued;
            return .{ .slot = @intCast(index), .token = slot.* };
        };
        return error.Busy;
    }
    pub fn complete(self: *Drain, worker: u64, generation: u64, ticket: Ticket) Error!void {
        try self.owned(worker, generation);
        if (ticket.slot >= self.callbacks.len or ticket.token == 0 or self.callbacks[ticket.slot] != ticket.token) return error.Denied;
        self.callbacks[ticket.slot] = 0;
        self.promote(); // A fenced session stays fenced, even after real drain.
    }
    pub fn requestStop(self: *Drain, worker: u64, generation: u64) Error!void {
        try self.owned(worker, generation);
        if (self.state == .fenced) return error.Fenced;
        if (self.state == .running) self.state = .stopping;
    }
    /// clean means code/VFS/heap have stopped using the resource. It says
    /// nothing about separately registered callback/DMA work still in flight.
    pub fn acknowledgeStopped(self: *Drain, worker: u64, generation: u64, clean: bool) Error!bool {
        try self.owned(worker, generation);
        if (self.state == .fenced) return error.Fenced;
        if (self.state != .stopping and self.state != .ready) return error.Busy;
        if (!clean) {
            self.state = .fenced;
            return error.Fenced;
        }
        self.worker_stopped = true;
        self.promote();
        return self.state == .ready;
    }
    fn promote(self: *Drain) void {
        if (self.state == .stopping and self.worker_stopped and self.pending() == 0) self.state = .ready;
    }
    pub fn pending(self: *const Drain) u8 {
        var result: u8 = 0;
        for (self.callbacks) |token| if (token != 0) {
            result += 1;
        };
        return result;
    }
    /// Finish this attachment before invoking the reader ledger's trusted
    /// stopped acknowledgement or reusing its heap/buffers for another worker.
    pub fn finish(self: *Drain, worker: u64, generation: u64) Error!void {
        try self.owned(worker, generation);
        if (self.state == .fenced) return error.Fenced;
        if (self.state != .ready) return error.Busy;
        self.worker = 0;
        self.worker_stopped = false;
        self.state = .idle;
    }
    pub fn canRelease(self: *const Drain) bool {
        return self.state == .idle and self.pending() == 0;
    }
};

test "stop and clean worker acknowledgement retain two callbacks until both drain" {
    var drain = Drain{};
    const session = try drain.begin(71);
    const a = try drain.enter(71, session);
    const b = try drain.enter(71, session);
    try std.testing.expectError(error.Busy, drain.enter(71, session));
    try std.testing.expectError(error.Busy, drain.acknowledgeStopped(71, session, true));
    try drain.requestStop(71, session);
    try std.testing.expect(!try drain.acknowledgeStopped(71, session, true));
    try std.testing.expectError(error.Busy, drain.finish(71, session));
    try std.testing.expectError(error.Busy, drain.begin(72));
    try std.testing.expectError(error.Busy, drain.enter(71, session));
    try drain.complete(71, session, b);
    try std.testing.expect(!drain.canRelease());
    try std.testing.expectError(error.Busy, drain.finish(71, session));
    try drain.complete(71, session, a);
    try std.testing.expectEqual(Drain.State.ready, drain.state);
    try std.testing.expect(!drain.canRelease());
    try drain.finish(71, session);
    try std.testing.expect(drain.canRelease());
}
test "callback completion cannot substitute for a clean worker exit" {
    var drain = Drain{};
    const session = try drain.begin(71);
    const work = try drain.enter(71, session);
    try drain.requestStop(71, session);
    try drain.complete(71, session, work);
    try std.testing.expectError(error.Busy, drain.finish(71, session));
    try std.testing.expect(try drain.acknowledgeStopped(71, session, true));
    try drain.finish(71, session);
}
test "wrong owner session duplicate and reused slot completion preserve outstanding work" {
    var drain = Drain{};
    const session = try drain.begin(71);
    const old = try drain.enter(71, session);
    try drain.complete(71, session, old);
    const next = try drain.enter(71, session);
    try std.testing.expectEqual(old.slot, next.slot);
    try std.testing.expect(old.token != next.token);
    try std.testing.expectError(error.Denied, drain.complete(71, session, old));
    try std.testing.expectError(error.Denied, drain.complete(72, session, next));
    try std.testing.expectError(error.Denied, drain.complete(71, session + 1, next));
    try std.testing.expectError(error.Denied, drain.complete(71, session, .{ .slot = 2, .token = next.token }));
    try std.testing.expectEqual(@as(u8, 1), drain.pending());
    try drain.requestStop(71, session);
    try drain.complete(71, session, next);
    _ = try drain.acknowledgeStopped(71, session, true);
    try drain.finish(71, session);
    const successor = try drain.begin(72);
    try std.testing.expectError(error.Denied, drain.acknowledgeStopped(71, session, true));
    try std.testing.expectError(error.Denied, drain.complete(72, successor, next));
    try std.testing.expectEqual(Drain.State.running, drain.state);
}
test "unclean worker fences permanently even after outstanding callbacks complete" {
    var drain = Drain{};
    const session = try drain.begin(71);
    const work = try drain.enter(71, session);
    try drain.requestStop(71, session);
    try std.testing.expectError(error.Fenced, drain.acknowledgeStopped(71, session, false));
    try drain.complete(71, session, work);
    try std.testing.expectEqual(@as(u8, 0), drain.pending());
    try std.testing.expectError(error.Fenced, drain.acknowledgeStopped(71, session, true));
    try std.testing.expectError(error.Fenced, drain.finish(71, session));
    try std.testing.expectError(error.Fenced, drain.begin(72));
    try std.testing.expect(!drain.canRelease());
}
test "identity exhaustion never wraps to an earlier worker or callback" {
    var drain = Drain{};
    try std.testing.expectError(error.InvalidArgument, drain.begin(0));
    drain.generation = std.math.maxInt(u64);
    try std.testing.expectError(error.Exhausted, drain.begin(71));
    try std.testing.expect(drain.canRelease());
    drain.generation = 0;
    const session = try drain.begin(71);
    drain.issued = std.math.maxInt(u64);
    try std.testing.expectError(error.Exhausted, drain.enter(71, session));
    try std.testing.expectEqual(@as(u8, 0), drain.pending());
}
