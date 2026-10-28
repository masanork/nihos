//! Single-coordinator admission of whole application intents, never VFS I/O.
//! Calls must be serialized. Native peers need an external command transport.
const std = @import("std");
const model = @import("checkpoint_model.zig");
pub const Ticket = struct { epoch: u64 = 0, sequence: u64 = 0 };
pub const Intent = struct { ticket: Ticket = .{}, actor: u64 = 0, operation: u64 = 0 };
pub const Mode = enum { recovering, ready, maintenance, faulted };
pub const Cancellation = enum { unknown, cancelled_waiting, requested_active };
pub const Completion = enum { clean, recovery_required };
pub const Error = model.Error || error{InvalidTicket};
pub const capacity = 2;
pub fn Gate(comptime Store: type, comptime Owner: type, comptime Queues: type) type {
    return struct {
        const Self = @This();
        owner: *Owner,
        queues: *Queues,
        epoch: u64,
        next_sequence: u64 = 1,
        journal_key: u32,
        mode: Mode = .recovering,
        waiting: [capacity]Intent = @splat(.{}),
        count: u8 = 0,
        active: ?Intent = null,
        cancel_requested: bool = false,
        maintenance_requested: bool = false,

        /// Epoch must be fresh across coordinator lifetimes, supplied by the
        /// trusted runtime. This module does not generate/persist boot IDs.
        pub fn init(owner: *Owner, queues: *Queues, epoch: u64, journal_key: u32) Error!Self {
            if (epoch == 0 or journal_key == 0) return error.InvalidArgument;
            if (!owner.store.ready) return error.NotReady;
            if (owner.recovery_required or owner.store.faulted) return error.Faulted;
            return .{ .owner = owner, .queues = queues, .epoch = epoch, .journal_key = journal_key };
        }
        fn matches(intent: Intent, actor: u64, ticket: Ticket) bool {
            return actor != 0 and intent.actor == actor and ticket.epoch != 0 and ticket.sequence != 0 and
                intent.ticket.epoch == ticket.epoch and intent.ticket.sequence == ticket.sequence;
        }
        fn remove(self: *Self, index: usize) Intent {
            const item = self.waiting[index];
            var i = index;
            while (i + 1 < self.count) : (i += 1) self.waiting[i] = self.waiting[i + 1];
            self.count -= 1;
            self.waiting[self.count] = .{};
            return item;
        }
        /// actor is authenticated by the caller, not taken from a public body.
        /// Only IDs are queued; application buffers remain separately charged.
        pub fn submit(self: *Self, actor: u64, operation: u64) Error!Ticket {
            if (self.mode == .faulted or self.owner.recovery_required or self.owner.store.faulted) {
                self.fail();
                return error.Faulted;
            }
            if (actor == 0 or operation == 0) return error.InvalidArgument;
            if (self.count == capacity) return error.Busy;
            if (self.next_sequence == std.math.maxInt(u64)) return error.GenerationExhausted;
            const ticket = Ticket{ .epoch = self.epoch, .sequence = self.next_sequence };
            self.next_sequence += 1;
            self.waiting[self.count] = .{ .actor = actor, .operation = operation, .ticket = ticket };
            self.count += 1;
            return ticket;
        }
        pub fn cancel(self: *Self, actor: u64, ticket: Ticket) Cancellation {
            for (self.waiting[0..self.count], 0..) |intent, i| if (matches(intent, actor, ticket)) {
                _ = self.remove(i);
                return .cancelled_waiting;
            };
            if (self.active) |intent| if (matches(intent, actor, ticket)) {
                self.cancel_requested = true;
                return .requested_active; // Not a claim that SQL was rolled back.
            };
            return .unknown;
        }
        pub fn cancellationRequested(self: *const Self, actor: u64, ticket: Ticket) bool {
            return if (self.active) |intent| matches(intent, actor, ticket) and self.cancel_requested else false;
        }
        fn quiescent(self: *const Self) bool {
            return !self.owner.alive and !self.owner.pending and !self.owner.store.in_transaction and
                self.queues.requests.countApprox() == 0 and self.queues.responses.countApprox() == 0;
        }
        fn fail(self: *Self) void {
            self.mode = .faulted;
            self.owner.recovery_required = true;
        }
        /// A conservative barrier, not a general SQLite journal parser.
        /// Nonzero headers require the SQL driver to recover before service.
        fn journalCold(self: *Self) Error!bool {
            const store: *Store = self.owner.store;
            const value = store.get(self.journal_key) catch |err| {
                self.fail();
                return err;
            };
            if (value.length == 0) return true;
            var bytes: [8]u8 = @splat(0);
            const n = store.read(self.journal_key, 0, &bytes) catch |err| {
                self.fail();
                return err;
            };
            for (bytes[0..n]) |byte| if (byte != 0) return false;
            return true;
        }
        /// Only after mount, SQL recovery/check and stopped binding teardown.
        pub fn recoveryComplete(self: *Self) Error!void {
            if (self.mode == .faulted or self.owner.recovery_required or self.owner.store.faulted) {
                self.fail();
                return error.Faulted;
            }
            if (self.mode != .recovering or self.active != null or !self.quiescent()) return error.Busy;
            if (!try self.journalCold()) return error.NotReady;
            self.mode = .ready;
        }
        /// Dispatch only after the caller can create a fresh worker binding.
        /// No raw handles, SQL continuations or old epochs are retained here.
        pub fn take(self: *Self, worker: u64) Error!?Intent {
            if (self.mode == .faulted or self.owner.recovery_required or self.owner.store.faulted) {
                self.fail();
                return error.Faulted;
            }
            if (self.mode == .recovering) return error.NotReady;
            if (self.mode != .ready or self.active != null or self.maintenance_requested or !self.quiescent()) return error.Busy;
            if (self.count == 0) return null;
            if (worker == 0 or worker == self.owner.client) return error.InvalidArgument;
            if (!self.owner.rebind(worker, self.queues)) return error.GenerationExhausted;
            const intent = self.remove(0);
            self.active = intent;
            self.cancel_requested = false;
            return intent;
        }
        /// Complete only after SQLite returned and its worker was torn down.
        /// clean describes the storage barrier, not COMMIT/cancel UI success.
        pub fn finish(self: *Self, actor: u64, ticket: Ticket) Error!Completion {
            const intent = self.active orelse return error.InvalidTicket;
            if (!matches(intent, actor, ticket)) return error.InvalidTicket;
            if (!self.quiescent()) return error.Busy;
            self.active = null;
            self.cancel_requested = false;
            if (self.owner.recovery_required or self.owner.store.faulted) {
                self.fail();
                return .recovery_required;
            }
            if (!try self.journalCold()) {
                self.mode = .recovering;
                return .recovery_required;
            }
            return .clean;
        }
        pub fn requestMaintenance(self: *Self) Error!void {
            if (self.mode == .faulted or self.owner.recovery_required or self.owner.store.faulted) {
                self.fail();
                return error.Faulted;
            }
            self.maintenance_requested = true;
        }
        /// Synchronous fixed-anchor maintenance. Enqueue/cancel may be pumped
        /// by the same coordinator; dispatch/SQL cannot run during callbacks.
        pub fn stepMaintenance(self: *Self) Error!?model.IndexSpace {
            if (self.mode == .faulted or self.owner.recovery_required or self.owner.store.faulted) {
                self.fail();
                return error.Faulted;
            }
            if (self.mode == .recovering) return error.NotReady;
            if (!self.maintenance_requested) return null;
            if (self.mode != .ready or self.active != null or !self.quiescent()) return error.Busy;
            if (!try self.journalCold()) {
                self.mode = .recovering;
                return error.NotReady;
            }
            self.mode = .maintenance;
            const space = self.owner.retirePrevious(self.queues) catch |err| {
                self.fail();
                return err;
            };
            self.mode = .ready;
            self.maintenance_requested = false;
            return space;
        }
    };
}
