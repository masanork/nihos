//! Host prototype: two copied endpoints share one serialized VFS and mount.
//! The caller owns scheduling and must stop a producer before calling stop.
//! This is not a native syscall, DMA fence, or durability implementation.
const api = @import("vfs.zig");
const ring = @import("../kernel/spsc_ring.zig");
pub const Operation = enum { open, write, sync, close };
/// The caller supplies a never-reused session ID for each new service.
pub const Handle = struct { session: u64, inner: api.Handle };
pub const Request = struct {
    session: u64 = 0,
    epoch: u32 = 0,
    sequence: u32 = 0,
    operation: Operation = .open,
    handle: ?Handle = null,
    offset: u64 = 0,
    length: u32 = 0,
    path_length: u32 = 0,
    path: [512]u8 = @splat(0),
    data: [4096]u8 = @splat(0),
};
pub const Result = union(enum) { ok, handle: Handle, transfer: api.Transfer, failure: api.Error };
pub const Response = struct { session: u64 = 0, epoch: u32 = 0, sequence: u32 = 0, result: Result = .ok };
pub const Queues = struct {
    requests: ring.SpscRing(Request, 2) = .init(),
    responses: ring.SpscRing(Response, 2) = .init(),
};
pub fn Service(comptime Backend: type) type {
    return struct {
        const Self = @This();
        const Lane = struct {
            principal: u32 = 0,
            queues: ?*Queues = null,
            root: ?api.Handle = null,
            files: [8]?api.Handle = @splat(null),
            epoch: u32 = 0,
            next_sequence: u32 = 1,
            alive: bool = false,
        };
        core: api.Vfs(Backend, 1, 32) = .{},
        mount: ?api.Mount = null,
        lanes: [2]Lane = .{ .{}, .{} },
        next: usize = 0,
        faulted: bool = false,
        session: u64 = 0,
        request: Request = .{},
        response: Response = .{},
        pub fn start(self: *Self, backend: *Backend, session: u64) api.Error!void {
            if (self.mount != null) return error.Busy;
            if (session == 0) return error.InvalidArgument;
            self.mount = try self.core.mount(backend, 1, .{ .write_at = true, .sync_file = true }, .{ .writable = true });
            self.session = session;
        }
        /// Trusted serialized owner notification; not an interrupt or DMA fence.
        pub fn markRemoved(self: *Self) api.Error!void {
            const mount = self.mount orelse return error.Busy;
            self.faulted = true;
            try self.core.markRemoved(mount);
        }
        fn checkedHandle(self: *const Self, handle: ?Handle) api.Error!api.Handle {
            const value = handle orelse return error.StaleHandle;
            if (value.session != self.session) return error.StaleHandle;
            return value.inner;
        }
        pub fn bind(self: *Self, index: usize, principal: u32, queues: *Queues) api.Error!u32 {
            if (index >= 2 or principal == 0 or self.faulted) return error.InvalidArgument;
            if (self.lanes[index].alive or self.lanes[1 - index].principal == principal or self.lanes[1 - index].queues == queues or queues.requests.countApprox() != 0 or queues.responses.countApprox() != 0) return error.Busy;
            if (self.lanes[index].epoch == 0xffffffff) return error.NoHandles;
            const epoch = self.lanes[index].epoch + 1;
            const mount = self.mount orelse return error.Busy;
            const root = try self.core.grantRoot(mount, principal, .{ .write = true });
            self.lanes[index] = .{ .principal = principal, .root = root, .alive = true, .epoch = epoch, .queues = queues };
            return epoch;
        }
        /// Identity is supplied by a trusted binding, never request bytes.
        pub fn submit(self: *Self, queues: *Queues, index: usize, caller: u32, request: *const Request) bool {
            if (index >= 2 or self.faulted) return false;
            const lane = &self.lanes[index];
            if (!lane.alive or lane.principal != caller or lane.queues != queues or request.session != self.session or request.epoch != lane.epoch) return false;
            return queues.requests.tryPushFrom(request);
        }
        fn execute(self: *Self, index: usize) api.Error!Result {
            const lane = &self.lanes[index];
            const req = &self.request;
            if (req.session != self.session or req.epoch != lane.epoch or req.sequence == 0 or req.sequence != lane.next_sequence) return error.InvalidArgument;
            lane.next_sequence +%= 1;
            switch (req.operation) {
                .open => {
                    if (req.path_length > 511) return error.TooLarge;
                    const slot = for (lane.files, 0..) |file, i| {
                        if (file == null) break i;
                    } else return error.NoHandles;
                    const file = try self.core.openAt(lane.principal, lane.root.?, req.path[0..req.path_length], .{ .write = true });
                    lane.files[slot] = file;
                    return .{ .handle = .{ .session = self.session, .inner = file } };
                },
                .write => {
                    if (req.length > req.data.len) return error.TooLarge;
                    return .{ .transfer = try self.core.writeAt(lane.principal, try self.checkedHandle(req.handle), req.offset, req.data[0..req.length]) };
                },
                .sync => {
                    try self.core.syncFile(lane.principal, try self.checkedHandle(req.handle));
                    return .ok;
                },
                .close => {
                    const handle = try self.checkedHandle(req.handle);
                    for (&lane.files) |*file| {
                        const value = file.* orelse continue;
                        if (value.slot != handle.slot or value.generation != handle.generation) continue;
                        self.core.close(lane.principal, value) catch |err| {
                            if (err != error.Busy) file.* = null;
                            return err;
                        };
                        file.* = null;
                        return .ok;
                    }
                    return error.StaleHandle;
                },
            }
        }
        /// One backend callback at a time. A full reply lane cannot block its peer.
        pub fn step(self: *Self, queues: *[2]Queues) ?usize {
            if (self.faulted) return null;
            for (0..2) |offset| {
                const i = (self.next + offset) % 2;
                if (!self.lanes[i].alive or self.lanes[i].queues != &queues[i] or queues[i].responses.countApprox() == 2) continue;
                if (!queues[i].requests.tryPopInto(&self.request)) continue;
                self.response = .{ .session = self.request.session, .epoch = self.request.epoch, .sequence = self.request.sequence, .result = self.execute(i) catch |err| .{ .failure = err } };
                self.request = .{};
                if (!queues[i].responses.tryPushFrom(&self.response)) unreachable;
                self.response = .{};
                self.next = (i + 1) % 2;
                const info = self.core.queryMount(self.mount.?) catch {
                    self.faulted = true;
                    return i;
                };
                if (info.state != .mounted) self.faulted = true;
                return i;
            }
            return null;
        }
        /// The producer is already stopped and the synchronous callback returned.
        /// An unsuccessful close quarantines the shared session.
        pub fn stop(self: *Self, queues: *Queues, index: usize, caller: u32) api.Error!void {
            if (index >= 2 or !self.lanes[index].alive or self.lanes[index].principal != caller or self.lanes[index].queues != queues) return error.PermissionDenied;
            const lane = &self.lanes[index];
            lane.alive = false;
            var failed = false;
            for (&lane.files) |*file| {
                if (file.*) |value| self.core.close(caller, value) catch {
                    failed = true;
                };
                file.* = null;
            }
            if (lane.root) |root| self.core.close(caller, root) catch {
                failed = true;
            };
            lane.root = null;
            lane.queues = null;
            while (queues.requests.tryPopInto(&self.request)) {}
            while (queues.responses.tryPopInto(&self.response)) {}
            self.request = .{};
            self.response = .{};
            if (failed) {
                self.faulted = true;
                return error.IoError;
            }
        }
    };
}
