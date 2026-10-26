//! One bound client, fixed copy-only messages, one owner task. Notifications
//! are separate; queue publication transfers ownership even if a bell is late.
const std = @import("std");
pub const Operation = enum(u32) { list = 1, stat = 2, open = 3, read = 4, close = 5 };
pub const Request = extern struct {
    sequence: u32 = 0,
    epoch: u32 = 0,
    operation: u32 = 0,
    handle: u32 = 0,
    offset: u32 = 0,
    length: u32 = 0,
    path_length: u32 = 0,
    path: [256]u8 = @splat(0),
};
pub const Response = extern struct {
    sequence: u32 = 0,
    epoch: u32 = 0,
    status: i32 = 0,
    handle: u32 = 0,
    kind: u32 = 0,
    size: u32 = 0,
    length: u32 = 0,
    data: [512]u8 = @splat(0),
};
pub fn Queues(comptime ring: type) type {
    return struct {
        requests: ring.SpscRing(Request, 2) = .init(),
        responses: ring.SpscRing(Response, 2) = .init(),
    };
}

pub fn Owner(comptime Backend: type) type {
    return struct {
        backend: Backend,
        client: u32,
        epoch: u32 = 1,
        next_sequence: u32 = 1,
        alive: bool = true,
        rebind_ready: bool = false,
        processed: u32 = 0,
        rejected: u32 = 0,
        discarded_requests: u32 = 0,
        discarded_responses: u32 = 0,
        const Self = @This();

        pub noinline fn dispatch(self: *Self, request: Request) Response {
            var response = Response{ .sequence = request.sequence, .epoch = self.epoch, .status = -22 };
            if (!self.alive or self.client == 0) {
                response.status = -13;
                return response;
            }
            if (request.epoch == 0 or request.epoch != self.epoch) {
                self.rejected += 1;
                response.status = -13;
                return response;
            }
            if (request.sequence == 0 or request.sequence != self.next_sequence) {
                self.rejected += 1;
                return response;
            }
            self.next_sequence +%= 1; // Zero permanently closes sequence admission.
            const operation = std.enums.fromInt(Operation, request.operation) orelse {
                self.rejected += 1;
                return response;
            };
            if (request.path_length > 255 or request.length > 512) {
                self.rejected += 1;
                return response;
            }
            self.processed += 1;
            switch (operation) {
                .list => response.status = self.backend.list(request.offset, &response),
                .stat => response.status = self.backend.stat(request.path[0..request.path_length], &response),
                .open => response.status = self.backend.open(self.client, request.path[0..request.path_length], &response.handle),
                .read => {
                    response.status = self.backend.read(self.client, request.handle, request.offset, response.data[0..request.length]);
                    if (response.status > 0) {
                        if (@as(u32, @intCast(response.status)) > request.length) {
                            response.status = -5;
                            response.data = @splat(0);
                            return response;
                        }
                        response.length = @intCast(response.status);
                    }
                },
                .close => response.status = self.backend.close(self.client, request.handle),
            }
            if (response.status < 0) {
                self.rejected += 1;
                response.data = @splat(0);
            }
            return response;
        }

        /// Reserve reply credit before consuming a request. There is one
        /// reply producer, so only the client can increase available credit.
        pub noinline fn step(self: *Self, queues: anytype) bool {
            if (!self.alive or queues.responses.countApprox() == 2) return false;
            const request = queues.requests.tryPop() orelse return false;
            const response = self.dispatch(request);
            if (!queues.responses.tryPush(response)) unreachable;
            return true;
        }

        /// Reopen only after stopped-client cleanup and queue drain. Keep the
        /// backend workspace/token counter alive: tokens must not alias across
        /// bindings. Epoch zero/wrap is never admitted, even after rebind.
        pub noinline fn rebind(self: *Self, client: u32, queues: anytype) bool {
            if (self.alive or !self.rebind_ready or client == 0 or client == self.client or self.epoch == std.math.maxInt(u32) or
                queues.requests.countApprox() != 0 or queues.responses.countApprox() != 0) return false;
            self.client = client;
            self.epoch += 1;
            self.next_sequence = 1;
            self.alive = true;
            self.rebind_ready = false;
            return true;
        }

        /// Owner-task context only. IRQ merely publishes the exit tombstone.
        pub noinline fn clientExited(self: *Self, queues: anytype) i32 {
            // The scheduler must publish the tombstone only after the client
            // is stopped. The owner has finished its current dispatch before
            // entering here. It can now take over the reply-consumer cursor;
            // neither peer can concurrently publish or consume a message.

            if (!self.alive) return 0;
            self.alive = false;
            const code = self.backend.release(self.client);
            self.rebind_ready = code == 0;
            while (queues.requests.tryPop() != null) self.discarded_requests += 1;
            while (queues.responses.tryPop() != null) self.discarded_responses += 1;
            return code;
        }
    };
}

/// Sequence alone is insufficient after an endpoint restarts at sequence 1.
pub fn responseMatches(response: *const Response, epoch: u32, sequence: u32) bool {
    return epoch != 0 and sequence != 0 and response.epoch == epoch and response.sequence == sequence;
}
