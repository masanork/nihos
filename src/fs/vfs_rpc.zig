//! Version 2 copy-only VFS transport. One bound kernel identity, one owner.
//! No client pointers. Destination/queues/owner workspace remain service-owned
//! and pinned through synchronous backend return, cleanup and FS destruction.
const std = @import("std");
pub const api = @import("vfs.zig");
const ring = @import("../kernel/spsc_ring.zig");
const stop = @import("io_stop.zig");
pub const version = 2;
pub const Operation = enum(u32) { open = 3, read = 4, close = 5 };
pub const Token = extern struct {
    generation: u64 = 0,
    slot: u32 = 0,
    reserved: u32 = 0,
    pub fn from(value: api.Handle) Token {
        return .{ .slot = value.slot, .generation = value.generation };
    }
    fn handle(self: Token) ?api.Handle {
        if (self.reserved != 0 or self.slot > std.math.maxInt(u16) or self.generation == 0) return null;
        return .{ .slot = @intCast(self.slot), .generation = self.generation };
    }
};
pub const Request = extern struct {
    token: Token = .{},
    offset: u64 = 0,
    version: u32 = version,
    epoch: u32 = 0,
    sequence: u32 = 0,
    operation: u32 = 0,
    length: u32 = 0,
    path_length: u32 = 0,
    path: [512]u8 = @splat(0),
};
pub const Response = extern struct {
    token: Token = .{},
    version: u32 = version,
    epoch: u32 = 0,
    sequence: u32 = 0,
    status: i32 = 0,
    length: u32 = 0,
    eof: u32 = 0,
    data: [4096]u8 = @splat(0),
};
pub const Queues = struct {
    requests: ring.SpscRing(Request, 2) = .init(),
    responses: ring.SpscRing(Response, 2) = .init(),
};
/// Optional caller workspace: keep these copies off a small task stack. They
/// belong to the client and may be reaped once the kernel stops that client.
pub const ClientFrames = struct { request: Request = .{}, response: Response = .{} };

/// Internal SRAM only in native use. IRQ/other hart may publish stopped-client
/// and exact active-read cancellation; never touch PSRAM, FS or broker here.
/// notifyExit means the kernel has STOPPED that exact client, not a kill request.
pub const Notifications = struct {
    binding: std.atomic.Value(u32) = .init(0), // epoch << 1 | stopped
    client: std.atomic.Value(u32) = .init(0),
    sequence: std.atomic.Value(u32) = .init(0),
    readable: std.atomic.Value(bool) = .init(false),
    signal: stop.Signal = .{},
    fn bind(self: *@This(), client: u32, epoch: u32) void {
        self.client.store(client, .monotonic);
        self.binding.store(epoch << 1, .release);
    }
    pub fn exited(self: *const @This(), epoch: u32) bool {
        return self.binding.load(.acquire) == ((epoch << 1) | 1);
    }
    pub fn notifyExit(self: *@This(), caller: u32, epoch: u32) bool {
        if (epoch == 0 or epoch > 0x7fffffff or self.client.load(.acquire) != caller) return false;
        const expected = epoch << 1;
        return self.binding.cmpxchgStrong(expected, expected | 1, .acq_rel, .acquire) == null;
    }
    pub fn cancelRead(self: *@This(), caller: u32, epoch: u32, sequence: u32) bool {
        const ticket = self.signal.active();
        if (ticket == 0 or self.binding.load(.acquire) != epoch << 1 or self.client.load(.acquire) != caller or
            self.sequence.load(.acquire) != sequence or !self.readable.load(.acquire)) return false;
        return self.signal.stop(ticket, 1);
    }
};

fn status(err: api.Error) i32 {
    return switch (err) {
        error.PermissionDenied => -13,
        error.ReadOnly => -30,
        error.NotFound => -2,
        error.StaleHandle => -9,
        error.Busy => -16,
        error.NoHandles => -24,
        error.TooLarge => -27,
        error.InvalidName, error.InvalidArgument => -22,
        error.Unsupported => -95,
        else => -5,
    };
}
pub fn responseMatches(response: *const Response, epoch: u32, sequence: u32) bool {
    return response.version == version and epoch != 0 and sequence != 0 and response.epoch == epoch and response.sequence == sequence;
}

pub fn Owner(comptime Backend: type) type {
    return struct {
        const Self = @This();
        pub const Core = api.Vfs(Backend, 1, 32);
        core: Core = .{},
        mount: ?api.Mount = null,
        root: ?api.Handle = null,
        files: [16]?api.Handle = @splat(null),
        notifications: *Notifications,
        client: u32,
        epoch: u32 = 1,
        next_sequence: u32 = 1,
        alive: bool = false,
        in_step: bool = false,
        rebind_ready: bool = false,
        discarded_requests: u32 = 0,
        discarded_responses: u32 = 0,
        request: Request = .{},
        response: Response = .{},

        pub fn start(self: *Self, backend: *Backend) api.Error!Token {
            if (self.mount != null or self.alive or self.client == 0 or self.epoch == 0 or self.epoch > 0x7fffffff or
                self.notifications.signal.active() != 0 or self.notifications.signal.next_ticket >= 1 << 30) return error.Busy;
            const mount = try self.core.mount(backend, 1, .{}, .{});
            self.root = self.core.grantRoot(mount, self.client, .{ .read = true }) catch |err| {
                self.core.unmount(mount) catch @panic("VFS RPC mount rollback failed");
                return err;
            };
            self.mount = mount;
            self.alive = true;
            self.notifications.bind(self.client, self.epoch);
            return Token.from(self.root.?);
        }
        /// Caller identity comes from the kernel endpoint binding, never from
        /// message bytes. The sole producer is stopped before cleanup/rebind.
        pub fn submit(self: *Self, queues: *Queues, caller: u32, request: *const Request) bool {
            if (!self.alive or caller != self.client or request.epoch != self.epoch or self.notifications.exited(self.epoch)) return false;
            return queues.requests.tryPushFrom(request);
        }
        fn errorReply(self: *Self, code: i32) void {
            self.response.token = .{};
            self.response.status = code;
            self.response.length = 0;
            self.response.eof = 0;
            @memset(&self.response.data, 0);
        }
        fn dispatch(self: *Self) void {
            const request = &self.request;
            if (request.version != version or request.epoch != self.epoch) return self.errorReply(-13);
            if (request.sequence == 0 or request.sequence != self.next_sequence) return self.errorReply(-22);
            self.next_sequence +%= 1;
            const operation = std.enums.fromInt(Operation, request.operation) orelse return self.errorReply(-95);
            if (request.path_length > 511 or request.length > 4096) return self.errorReply(-27);
            const handle = request.token.handle() orelse return self.errorReply(-9);
            switch (operation) {
                .open => {
                    const slot = for (self.files, 0..) |file, i| {
                        if (file == null) break i;
                    } else return self.errorReply(-24);
                    const file = self.core.openAt(self.client, handle, request.path[0..request.path_length], .{ .read = true }) catch |err| return self.errorReply(status(err));
                    self.files[slot] = file;
                    self.response.token = Token.from(file);
                },
                .read => {
                    const result = self.core.readAt(self.client, handle, request.offset, self.response.data[0..request.length]) catch |err| return self.errorReply(status(err));
                    if (result.failure != null) return self.errorReply(-5);
                    self.response.length = @intCast(result.transferred);
                    self.response.eof = @intFromBool(result.eof);
                },
                .close => {
                    // Root lifetime belongs to the endpoint, never a client
                    // close request. Only a tracked file token is admitted.
                    for (&self.files) |*file| {
                        if (file.*) |value| {
                            if (value.slot != handle.slot or value.generation != handle.generation) continue;
                            self.core.close(self.client, value) catch |err| {
                                if (err != error.Busy) file.* = null;
                                return self.errorReply(status(err));
                            };
                            file.* = null;
                            return;
                        }
                    }
                    self.errorReply(-9);
                },
            }
        }
        fn cleanup(self: *Self, queues: *Queues) void {
            self.alive = false;
            var clean = true;
            for (&self.files) |*file| {
                if (file.*) |value| self.core.close(self.client, value) catch {
                    clean = false;
                };
                file.* = null;
            }
            if (self.root) |root| self.core.close(self.client, root) catch {
                clean = false;
            };
            self.root = null;
            while (queues.requests.tryPopInto(&self.request)) self.discarded_requests += 1;
            while (queues.responses.tryPopInto(&self.response)) self.discarded_responses += 1;
            self.request = .{};
            self.response = .{};
            self.rebind_ready = clean and (self.core.queryMount(self.mount.?) catch return).state == .mounted;
        }
        /// Each backend return must imply quiescence, even on error. Cancellation
        /// defers to that return, then scrubs the copied reply; it does not abort
        /// the controller or assert rollback. Unproved native fences never return.
        pub fn step(self: *Self, queues: *Queues) bool {
            if (!self.alive or self.in_step) return false;
            if (self.notifications.exited(self.epoch)) {
                self.cleanup(queues);
                return true;
            }
            if (queues.responses.countApprox() == 2) return false;
            if (!queues.requests.tryPopInto(&self.request)) return false;
            self.in_step = true;
            defer self.in_step = false;
            self.response = .{ .epoch = self.epoch, .sequence = self.request.sequence };
            self.notifications.sequence.store(self.request.sequence, .monotonic);
            self.notifications.readable.store(self.request.operation == @backingInt(Operation.read), .monotonic);
            const control = self.notifications.signal.begin() orelse {
                self.errorReply(-28);
                if (!queues.responses.tryPushFrom(&self.response)) unreachable;
                return true;
            };
            self.dispatch();
            const reason = control.finishReason();
            self.notifications.readable.store(false, .release);
            if (reason != .none) self.errorReply(-125);
            if (self.notifications.exited(self.epoch)) {
                self.discarded_responses += 1;
                self.cleanup(queues);
            } else if (!queues.responses.tryPushFrom(&self.response)) unreachable;
            return true;
        }
        pub fn rebind(self: *Self, queues: *Queues, client: u32) bool {
            if (self.alive or self.in_step or !self.rebind_ready or client == 0 or client == self.client or
                self.epoch == 0x7fffffff or self.notifications.signal.active() != 0 or
                self.notifications.signal.next_ticket >= 1 << 30 or
                queues.requests.countApprox() != 0 or queues.responses.countApprox() != 0) return false;
            const root = self.core.grantRoot(self.mount.?, client, .{ .read = true }) catch return false;
            self.root = root;
            self.client = client;
            self.epoch += 1;
            self.next_sequence = 1;
            self.alive = true;
            self.rebind_ready = false;
            self.notifications.bind(client, self.epoch);
            return true;
        }
        pub fn shutdown(self: *Self, queues: *Queues) api.Error!void {
            if (self.alive or self.in_step or self.root != null or self.notifications.signal.active() != 0 or
                queues.requests.countApprox() != 0 or queues.responses.countApprox() != 0) return error.Busy;
            if (self.mount) |mount| try self.core.detachQuiescent(mount);
            self.mount = null;
            self.rebind_ready = false;
        }
    };
}
