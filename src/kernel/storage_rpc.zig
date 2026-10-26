//! One bound client, fixed copy-only messages, one owner task. Notifications
//! are separate; queue publication transfers ownership even if a bell is late.
const std = @import("std");
pub const Operation = enum(u32) { list = 1, stat = 2, open = 3, read = 4, close = 5 };
pub const Request = extern struct {
    sequence: u32 = 0,
    operation: u32 = 0,
    handle: u32 = 0,
    offset: u32 = 0,
    length: u32 = 0,
    path_length: u32 = 0,
    path: [256]u8 = @splat(0),
};
pub const Response = extern struct {
    sequence: u32 = 0,
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
        next_sequence: u32 = 1,
        alive: bool = true,
        processed: u32 = 0,
        rejected: u32 = 0,
        const Self = @This();

        pub noinline fn dispatch(self: *Self, request: Request) Response {
            var response = Response{ .sequence = request.sequence, .status = -22 };
            if (!self.alive or self.client == 0) {
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

        /// Owner-task context only. IRQ merely publishes the exit tombstone.
        pub fn clientExited(self: *Self) i32 {
            if (!self.alive) return 0;
            self.alive = false;
            return self.backend.release(self.client);
        }
    };
}
