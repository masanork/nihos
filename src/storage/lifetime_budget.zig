//! Trusted, serialized coordinator policy. Deadlines request a stop; they do
//! not revoke a live worker, a pin, DMA, or an acknowledged SQL commit.
const model = @import("checkpoint_model.zig");
pub const Reason = enum { none, journal_span, deadline, clock_regressed };
pub const Limits = struct { journal_span_bytes: u64, duration_ms: u64 };
pub const Operation = struct {
    limits: Limits,
    started_ms: u64,
    last_ms: u64,
    journal_peak: u64 = 0,
    reason: Reason = .none,

    pub fn init(limits: Limits, now_ms: u64) error{InvalidArgument}!Operation {
        if (limits.journal_span_bytes < 512 or limits.duration_ms == 0) return error.InvalidArgument;
        return .{ .limits = limits, .started_ms = now_ms, .last_ms = now_ms };
    }
    /// Logical journal write end, including headers/padding, not retained file
    /// length, RAM use, unique DB dirty bytes or physical COW amplification.
    /// Rewrites within the limit stay possible during trusted SQL rollback.
    pub fn journalWrite(self: *Operation, end: u64) bool {
        if (end > self.limits.journal_span_bytes) {
            if (self.reason == .none) self.reason = .journal_span;
            return false;
        }
        self.journal_peak = @max(self.journal_peak, end);
        return true;
    }
    /// Called only at ordinary SQL progress points. Unwind/recovery is not
    /// interrupted by the expired ordinary-work deadline.
    pub fn poll(self: *Operation, now_ms: u64) Reason {
        if (self.reason != .none) return self.reason;
        if (now_ms < self.last_ms) {
            self.reason = .clock_regressed;
        } else {
            self.last_ms = now_ms;
            if (now_ms - self.started_ms >= self.limits.duration_ms) self.reason = .deadline;
        }
        return self.reason;
    }
};
pub const Error = model.Error || error{ Expired, ClockRegressed, Denied };
pub fn Readers(comptime Store: type) type {
    return struct {
        const Self = @This();
        pub const State = enum { empty, measuring, active, stopping };
        const Entry = struct {
            state: State = .empty,
            actor: u64 = 0,
            reader: model.Reader = .{ .slot = 0, .token = 0 },
            started_ms: u64 = 0,
            duration_ms: u64 = 0,
            limit_bytes: u64 = 0,
            bytes: u64 = 0,
        };
        store: *Store,
        limit_bytes: u64,
        charged_bytes: u64 = 0,
        last_ms: u64,
        clock_failed: bool = false,
        entries: [Store.reader_limit]Entry = @splat(.{}),

        pub fn init(store: *Store, limit_bytes: u64, now_ms: u64) Error!Self {
            if (limit_bytes == 0) return error.InvalidArgument;
            if (!store.ready) return error.NotReady;
            if (store.faulted) return error.Faulted;
            for (store.readers) |reader| if (reader.token != 0) return error.Busy;
            return .{ .store = store, .limit_bytes = limit_bytes, .last_ms = now_ms };
        }
        fn time(self: *Self, now_ms: u64) Error!void {
            if (self.clock_failed or now_ms < self.last_ms) {
                self.failClock();
                return error.ClockRegressed;
            }
            self.last_ms = now_ms;
        }
        /// Trusted clock provider reports a missing/reset raw counter. Latch
        /// the whole ledger stopped before rounding can hide the failure.
        /// Charge/pins remain until genuine stopped acknowledgement.
        pub fn failClock(self: *Self) void {
            self.clock_failed = true;
            for (&self.entries) |*entry| if (entry.state != .empty) {
                entry.state = .stopping;
            };
        }
        fn owned(self: *Self, actor: u64, reader: model.Reader) Error!*Entry {
            if (actor == 0 or reader.slot >= self.entries.len) return error.Denied;
            const entry = &self.entries[reader.slot];
            if (entry.state == .empty or entry.actor != actor or entry.reader.token != reader.token or reader.token == 0) return error.Denied;
            return entry;
        }
        /// Provisional pin is coordinator-private. Finish/abort admission before
        /// dispatching a writer. Only one scan may use the shared Store scratch.
        pub fn begin(self: *Self, actor: u64, now_ms: u64, duration_ms: u64, limit_bytes: u64) Error!model.Reader {
            return self.beginScope(actor, null, now_ms, duration_ms, limit_bytes);
        }
        pub fn beginObject(self: *Self, actor: u64, key: u32, now_ms: u64, duration_ms: u64, limit_bytes: u64) Error!model.Reader {
            return self.beginScope(actor, key, now_ms, duration_ms, limit_bytes);
        }
        fn beginScope(self: *Self, actor: u64, key: ?u32, now_ms: u64, duration_ms: u64, limit_bytes: u64) Error!model.Reader {
            try self.time(now_ms);
            if (actor == 0 or duration_ms == 0 or limit_bytes == 0) return error.InvalidArgument;
            if (self.store.in_transaction) return error.Busy;
            for (self.entries) |entry| if (entry.state == .measuring) return error.Busy;
            const reader = if (key) |object| try self.store.pinObject(object) else try self.store.pin();
            if (self.entries[reader.slot].state != .empty) {
                try self.store.release(reader);
                return error.Busy;
            }
            self.store.beginPinnedUsage(reader) catch |err| {
                try self.store.release(reader);
                return err;
            };
            self.entries[reader.slot] = .{ .state = .measuring, .actor = actor, .reader = reader, .started_ms = now_ms, .duration_ms = duration_ms, .limit_bytes = limit_bytes };
            return reader;
        }
        fn discard(self: *Self, entry: *Entry) Error!void {
            try self.store.release(entry.reader);
            self.charged_bytes -= entry.bytes;
            entry.* = .{};
        }
        pub fn step(self: *Self, actor: u64, reader: model.Reader, now_ms: u64, visits: u16) Error!bool {
            const entry = try self.owned(actor, reader);
            try self.time(now_ms);
            if (entry.state != .measuring) return error.Busy;
            if (now_ms - entry.started_ms >= entry.duration_ms) {
                try self.discard(entry); // No reader was published or allowed I/O.
                return error.Expired;
            }
            const bytes = (self.store.stepPinnedUsage(reader, visits) catch |err| {
                try self.discard(entry);
                return err;
            }) orelse return false;
            if (bytes > entry.limit_bytes or bytes > self.limit_bytes - self.charged_bytes) {
                try self.discard(entry);
                return error.NoSpace;
            }
            entry.bytes = bytes;
            self.charged_bytes += bytes;
            entry.state = .active;
            return true;
        }
        pub fn poll(self: *Self, now_ms: u64) Error!void {
            try self.time(now_ms);
            for (&self.entries) |*entry| if (entry.state == .active and now_ms - entry.started_ms >= entry.duration_ms) {
                entry.state = .stopping;
            };
        }
        pub fn read(self: *Self, actor: u64, reader: model.Reader, key: u32, offset: u64, bytes: []u8, now_ms: u64) Error!usize {
            errdefer @memset(bytes, 0);
            const entry = try self.owned(actor, reader);
            try self.poll(now_ms);
            if (entry.state == .stopping) return error.Expired;
            if (entry.state != .active) return error.Busy;
            return self.store.readPinned(reader, key, offset, bytes);
        }
        pub fn requestStop(self: *Self, actor: u64, reader: model.Reader) Error!void {
            const entry = try self.owned(actor, reader);
            entry.state = .stopping;
        }
        pub fn readWithScratch(self: *Self, actor: u64, reader: model.Reader, key: u32, offset: u64, bytes: []u8, now_ms: u64, scratch: *[model.page_bytes]u8) Error!usize {
            errdefer @memset(bytes, 0);
            const entry = try self.owned(actor, reader);
            try self.poll(now_ms);
            if (entry.state == .stopping) return error.Expired;
            if (entry.state != .active) return error.Busy;
            return self.store.readPinnedWithScratch(reader, key, offset, bytes, scratch);
        }
        /// Trusted coordinator acknowledges stopped code/callbacks/DMA before
        /// calling this. A timeout or cancellation request alone is not proof.
        /// Also aborts a private provisional admission that never exposed I/O.
        pub fn stopped(self: *Self, actor: u64, reader: model.Reader) Error!void {
            const entry = try self.owned(actor, reader);
            try self.discard(entry);
        }
    };
}
