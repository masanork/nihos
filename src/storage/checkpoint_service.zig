//! Host service core for one authenticated binding and one serialized owner.
//! Fixed copies, existing object grants, explicit resize, staged write and sync.
//! Device callbacks must stop accessing buffers before returning. Not a driver.
const std = @import("std");
pub const model = @import("checkpoint_model.zig");
pub const io_bytes = 4096;
pub const handle_limit = 16;
pub const Operation = enum(u32) { read = 1, write = 2, batch = 3, truncate = 4, sync = 5, cancel = 6, close = 7, stat = 8 };
pub const Status = enum(i32) { ok = 0, denied = -13, invalid = -22, stale = -9, busy = -16, no_space = -28, not_found = -2, recovery_required = -5, publication_unknown = -115 };
pub const Visibility = enum(u32) { committed = 0, staged = 1, unknown = 2 };
pub const Handle = extern struct { slot: u32 = 0, generation: u64 = 0 };
pub const Part = extern struct { offset: u64 = 0, data_offset: u32 = 0, length: u32 = 0 };
pub const Request = extern struct {
    epoch: u64 = 0,
    sequence: u64 = 0,
    handle: Handle = .{},
    operation: u32 = 0,
    offset: u64 = 0,
    length: u32 = 0,
    part_count: u32 = 0,
    parts: [16]Part = @splat(.{}),
    data: [io_bytes]u8 = @splat(0),
};
pub const Response = extern struct {
    epoch: u64 = 0,
    sequence: u64 = 0,
    generation: u64 = 0,
    size: u64 = 0,
    status: Status = .ok,
    visibility: Visibility = .committed,
    transferred: u32 = 0,
    length: u32 = 0,
    data: [io_bytes]u8 = @splat(0),
};
pub fn Queues(comptime ring: type) type {
    return struct { requests: ring.SpscRing(Request, 2) = .init(), responses: ring.SpscRing(Response, 2) = .init() };
}
pub const Work = enum { idle, pending, completed };
pub const Exit = enum { clean, cancelled_staging, recovery_required };
pub fn matches(response: *const Response, epoch: u64, sequence: u64) bool {
    return epoch != 0 and sequence != 0 and response.epoch == epoch and response.sequence == sequence;
}
pub fn Owner(comptime Store: type) type {
    return struct {
        const Self = @This();
        const Capability = struct { generation: u64 = 1, key: u32 = 0, writable: bool = false, retired: bool = false };
        store: *Store,
        client: u64,
        epoch: u64 = 1,
        next_sequence: u64 = 1,
        alive: bool = true,
        recovery_required: bool = false,
        last_durable_generation: u64,
        handles: [handle_limit]Capability = @splat(.{}),
        scratch: model.MapScratch = .{},
        request: Request = .{},
        pending: bool = false,
        phase: enum { start, write_search, resize_search } = .start,
        key: u32 = 0,
        discarded_requests: u32 = 0,
        discarded_responses: u32 = 0,
        discarded_pending: u32 = 0,

        pub fn init(store: *Store, client: u64) model.Error!Self {
            if (client == 0) return error.InvalidArgument;
            if (!store.ready) return error.NotReady;
            if (store.faulted) return error.Faulted;
            if (store.in_transaction) return error.Busy;
            return .{ .store = store, .client = client, .last_durable_generation = store.generation() };
        }
        /// Trusted owner grants keys; no request supplies a principal or key.
        pub fn grant(self: *Self, key: u32, writable: bool) model.Error!Handle {
            if (!self.alive or self.recovery_required) return error.Faulted;
            if (self.pending) return error.Busy;
            const value = try self.view(key);
            if (writable and value.kind != .mapped and value.length != 0) return error.NotMapped;
            for (&self.handles, 0..) |*cap, i| if (cap.key == 0 and !cap.retired) {
                cap.key = key;
                cap.writable = writable;
                return .{ .slot = @intCast(i), .generation = cap.generation };
            };
            return error.NoSpace;
        }
        fn invalidate(cap: *Capability) void {
            cap.key = 0;
            cap.writable = false;
            if (cap.generation == std.math.maxInt(u64)) cap.retired = true else cap.generation += 1;
        }
        fn view(self: *Self, key: u32) model.Error!model.Value {
            return if (self.store.in_transaction) self.store.getStaged(key) else self.store.get(key);
        }
        fn begin(self: *Self) model.Error!void {
            if (!self.store.in_transaction) try self.store.begin();
        }
        fn status(self: *Self, err: model.Error) Status {
            return switch (err) {
                error.NoSpace => .no_space,
                error.NotFound => .not_found,
                error.InvalidArgument, error.NotMapped => .invalid,
                error.Busy, error.ReaderLimit => .busy,
                else => result: {
                    self.recovery_required = true;
                    break :result .recovery_required;
                },
            };
        }
        fn response(self: *Self) Response {
            return .{ .epoch = self.epoch, .sequence = self.request.sequence, .generation = self.last_durable_generation, .visibility = if (self.recovery_required) .unknown else if (self.store.in_transaction) .staged else .committed };
        }
        fn patches(self: *Self, out: *[16]model.MappedPatch) model.Error!usize {
            const req = &self.request;
            if (req.operation == @backingInt(Operation.write)) {
                if (req.length == 0) return error.InvalidArgument;
                const first = @min(req.length, io_bytes - req.offset % io_bytes);
                out[0] = .{ .offset = req.offset, .bytes = req.data[0..@intCast(first)] };
                if (first == req.length) return 1;
                out[1] = .{ .offset = req.offset + first, .bytes = req.data[@intCast(first)..req.length] };
                return 2;
            }
            if (req.part_count == 0 or req.part_count > 16) return error.InvalidArgument;
            for (req.parts[0..req.part_count], 0..) |part, i| {
                if (part.data_offset > req.length or part.length > req.length - part.data_offset) return error.InvalidArgument;
                out[i] = .{ .offset = part.offset, .bytes = req.data[part.data_offset..][0..part.length] };
            }
            return req.part_count;
        }
        fn finish(self: *Self, queues: anytype, reply: Response) Work {
            var result = reply;
            if (self.recovery_required) result.visibility = .unknown;
            if (!queues.responses.tryPush(result)) unreachable; // credit before request consumption
            self.pending = false;
            self.request = .{};
            return .completed;
        }
        /// One search budget per call; batch I/O and commit remain synchronous.
        /// Only this owner may produce replies or call Store while attached.
        pub fn step(self: *Self, queues: anytype, budget: model.SearchBudget) Work {
            if (!self.alive) return .idle;
            if (!self.pending) {
                if (queues.responses.countApprox() == 2) return .idle;
                self.request = queues.requests.tryPop() orelse return .idle;
                self.pending = true;
                self.phase = .start;
            }
            var reply = self.response();
            if (self.recovery_required) {
                reply.status = .recovery_required;
                return self.finish(queues, reply);
            }
            const req = &self.request;
            if (self.phase == .start) {
                if (req.epoch != self.epoch or req.epoch == 0) {
                    reply.status = .denied;
                    return self.finish(queues, reply);
                }
                if (req.sequence == 0 or req.sequence != self.next_sequence) {
                    reply.status = .invalid;
                    return self.finish(queues, reply);
                }
                self.next_sequence +%= 1; // zero closes this epoch permanently
                const op = std.enums.fromInt(Operation, req.operation) orelse {
                    reply.status = .invalid;
                    return self.finish(queues, reply);
                };
                if (req.length > io_bytes or req.handle.slot >= self.handles.len) {
                    reply.status = .invalid;
                    return self.finish(queues, reply);
                }
                const cap = &self.handles[req.handle.slot];
                if (cap.key == 0 or cap.generation != req.handle.generation) {
                    reply.status = .stale;
                    return self.finish(queues, reply);
                }
                if (op != .read and op != .stat and op != .close and !cap.writable) {
                    reply.status = .denied;
                    return self.finish(queues, reply);
                }
                if ((op == .read or op == .write) and (req.offset > Store.capacity_bytes or req.length > Store.capacity_bytes - req.offset)) {
                    reply.status = .invalid;
                    return self.finish(queues, reply);
                }
                self.key = cap.key;
                const value = self.view(self.key) catch |err| {
                    reply.status = self.status(err);
                    return self.finish(queues, reply);
                };
                reply.size = value.length;
                switch (op) {
                    .read => {
                        const n = (if (self.store.in_transaction) self.store.readStaged(self.key, req.offset, reply.data[0..req.length]) else self.store.read(self.key, req.offset, reply.data[0..req.length])) catch |err| {
                            reply.status = self.status(err);
                            reply.data = @splat(0);
                            return self.finish(queues, reply);
                        };
                        reply.length = @intCast(n);
                        reply.transferred = @intCast(n);
                    },
                    .stat => {},
                    .close => {
                        if (self.store.in_transaction) reply.status = .busy else invalidate(cap);
                    },
                    .cancel => {
                        if (self.store.in_transaction) self.store.rollback() catch |err| {
                            reply.status = self.status(err);
                            return self.finish(queues, reply);
                        };
                        reply.visibility = .committed;
                        reply.size = (self.view(self.key) catch |err| {
                            reply.status = self.status(err);
                            return self.finish(queues, reply);
                        }).length;
                    },
                    .sync => {
                        if (self.store.in_transaction) self.store.commit() catch {
                            self.recovery_required = true;
                            reply.status = .publication_unknown;
                            reply.visibility = .unknown;
                            return self.finish(queues, reply);
                        };
                        self.last_durable_generation = self.store.generation();
                        reply.generation = self.last_durable_generation;
                        reply.visibility = .committed;
                    },
                    .truncate => {
                        if (req.offset > Store.capacity_bytes) {
                            reply.status = .invalid;
                            return self.finish(queues, reply);
                        }
                        if (req.offset == value.length) return self.finish(queues, reply);
                        self.begin() catch |err| {
                            reply.status = self.status(err);
                            return self.finish(queues, reply);
                        };
                        const wanted = self.store.mappedResizePages(self.key, req.offset, &self.scratch) catch |err| {
                            reply.status = self.status(err);
                            return self.finish(queues, reply);
                        };
                        self.store.beginPayloadSearch(wanted) catch |err| {
                            reply.status = self.status(err);
                            return self.finish(queues, reply);
                        };
                        self.phase = .resize_search;
                        return .pending;
                    },
                    .write, .batch => {
                        if (op == .write and req.length == 0) return self.finish(queues, reply);
                        var parts: [16]model.MappedPatch = undefined;
                        const count = self.patches(&parts) catch |err| {
                            reply.status = self.status(err);
                            return self.finish(queues, reply);
                        };
                        const wanted = Store.mappedBatchPages(value.length, parts[0..count]) catch |err| {
                            reply.status = self.status(err);
                            return self.finish(queues, reply);
                        };
                        self.begin() catch |err| {
                            reply.status = self.status(err);
                            return self.finish(queues, reply);
                        };
                        self.store.beginPayloadSearch(wanted) catch |err| {
                            reply.status = self.status(err);
                            return self.finish(queues, reply);
                        };
                        self.phase = .write_search;
                        return .pending;
                    },
                }
                return self.finish(queues, reply);
            }
            switch (self.store.stepPayloadSearch(budget) catch |err| {
                reply.status = self.status(err);
                return self.finish(queues, reply);
            }) {
                .pending => return .pending,
                .found => {},
                .no_space => {
                    reply.status = .no_space;
                    return self.finish(queues, reply);
                },
                .space => {
                    self.recovery_required = true;
                    reply.status = .recovery_required;
                    return self.finish(queues, reply);
                },
            }
            if (self.phase == .resize_search) {
                self.store.resizeMappedPrepared(self.key, req.offset, &self.scratch) catch |err| {
                    reply.status = self.status(err);
                    return self.finish(queues, reply);
                };
                reply.size = req.offset;
            } else {
                var parts: [16]model.MappedPatch = undefined;
                const count = self.patches(&parts) catch |err| {
                    reply.status = self.status(err);
                    return self.finish(queues, reply);
                };
                self.store.patchMappedBatchPrepared(self.key, parts[0..count], &self.scratch) catch |err| {
                    reply.status = self.status(err);
                    return self.finish(queues, reply);
                };
                for (parts[0..count]) |part| reply.transferred += @intCast(part.bytes.len);
                reply.size = (self.view(self.key) catch |err| {
                    reply.status = self.status(err);
                    return self.finish(queues, reply);
                }).length;
            }
            reply.visibility = .staged;
            return self.finish(queues, reply);
        }
        /// Trusted scheduler hook after this exact client has stopped and the
        /// owner has returned from any synchronous device callback.
        pub fn clientExited(self: *Self, client: u64, queues: anytype) model.Error!Exit {
            if (client == 0 or client != self.client) return error.InvalidArgument;
            if (!self.alive) return if (self.recovery_required) .recovery_required else .clean;
            self.alive = false;
            const had_staging = self.store.in_transaction;
            if (had_staging and !self.recovery_required) self.store.rollback() catch {
                self.recovery_required = true;
            };
            if (self.pending) self.discarded_pending += 1;
            self.pending = false;
            self.request = .{};
            for (&self.handles) |*cap| invalidate(cap);
            while (queues.requests.tryPop() != null) self.discarded_requests += 1;
            while (queues.responses.tryPop() != null) self.discarded_responses += 1;
            for (&queues.requests.slots) |*slot| slot.* = .{};
            for (&queues.responses.slots) |*slot| slot.* = .{};
            return if (self.recovery_required) .recovery_required else if (had_staging) .cancelled_staging else .clean;
        }
        pub fn rebind(self: *Self, client: u64, queues: anytype) bool {
            if (self.alive or self.recovery_required or client == 0 or client == self.client or self.epoch == std.math.maxInt(u64) or self.store.in_transaction or
                queues.requests.countApprox() != 0 or queues.responses.countApprox() != 0) return false;
            self.client = client;
            self.epoch += 1;
            self.next_sequence = 1;
            self.alive = true;
            return true;
        }
    };
}
