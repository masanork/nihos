//! Experimental serialized copy-out page request coordinator. It neither
//! submits I/O nor owns a pin: the caller must keep one immutable object pinned
//! until detach, and must authenticate/serialize completions and DMA drain.
const std = @import("std");
pub const page_bytes = 4096;
pub const Error = error{ Busy, Denied, Exhausted, InvalidArgument, Io, NotReady };
pub const Request = struct { generation: u64, serial: u64, offset: u64, length: usize };
pub const Coordinator = struct {
    const State = enum { detached, idle, pending, draining, ready, failed };
    state: State = .detached,
    generation: u64 = 0,
    serial: u64 = 0,
    pin: u64 = 0,
    length: u64 = 0,
    active: Request = .{ .generation = 0, .serial = 0, .offset = 0, .length = 0 },
    page: [page_bytes]u8 = @splat(0),

    /// `pin` is a caller-owned identity, not proof of an actual storage pin.
    pub fn attach(self: *Coordinator, pin: u64, length: u64) Error!void {
        if (self.state != .detached) return error.Busy;
        if (pin == 0 or length == 0) return error.InvalidArgument;
        if (self.generation == std.math.maxInt(u64)) return error.Exhausted;
        self.generation += 1;
        self.pin = pin;
        self.length = length;
        self.state = .idle;
    }
    /// The returned request must be completed exactly once, even after cancel.
    pub fn request(self: *Coordinator, offset: u64) Error!Request {
        if (self.state == .failed) return error.Io;
        if (self.state != .idle and self.state != .ready) return error.Busy;
        if (offset % page_bytes != 0 or offset >= self.length) return error.InvalidArgument;
        if (self.serial == std.math.maxInt(u64)) return error.Exhausted;
        self.serial += 1;
        self.active = .{ .generation = self.generation, .serial = self.serial, .offset = offset, .length = @intCast(@min(page_bytes, self.length - offset)) };
        self.state = .pending;
        return self.active;
    }
    fn matches(self: *const Coordinator, req: Request) bool {
        return req.generation == self.active.generation and req.serial == self.active.serial and req.offset == self.active.offset and req.length == self.active.length;
    }
    /// Cancellation is a request to discard the result, not an I/O stop.
    pub fn cancel(self: *Coordinator, req: Request) Error!void {
        if (!self.matches(req)) return error.Denied;
        if (self.state != .pending and self.state != .draining) return error.NotReady;
        self.state = .draining;
    }
    /// Call only once the producer has ceased using its own buffer. Null or a
    /// short completion fences the attachment; discarded results are never read.
    pub fn complete(self: *Coordinator, req: Request, bytes: ?[]const u8) Error!void {
        if (!self.matches(req)) return error.Denied;
        if (self.state == .draining) {
            self.state = .idle;
            return;
        }
        if (self.state != .pending) return error.Denied;
        const value = bytes orelse {
            self.state = .failed;
            return error.Io;
        };
        if (value.len != req.length) {
            self.state = .failed;
            return error.Io;
        }
        @memcpy(self.page[0..value.len], value);
        self.state = .ready;
    }
    pub fn copy(self: *const Coordinator, req: Request, offset: usize, out: []u8) Error!void {
        if (!self.matches(req)) return error.Denied;
        if (self.state != .ready) return error.NotReady;
        if (offset > req.length or out.len > req.length - offset) return error.InvalidArgument;
        @memcpy(out, self.page[offset..][0..out.len]);
    }
    pub fn detach(self: *Coordinator) Error!void {
        if (self.state == .pending or self.state == .draining) return error.Busy;
        if (self.state == .detached) return error.NotReady;
        self.pin = 0;
        self.length = 0;
        self.state = .detached;
    }
};

test "page request copies completed bytes and rejects stale or duplicate responses" {
    var page: Coordinator = .{};
    try page.attach(7, 4101);
    const first = try page.request(0);
    try std.testing.expectError(error.Busy, page.detach());
    var source: [page_bytes]u8 = @splat(0x4a);
    try page.complete(first, &source);
    source[3] = 0;
    var copy: [2]u8 = undefined;
    try page.copy(first, 3, &copy);
    try std.testing.expectEqualSlices(u8, &.{ 0x4a, 0x4a }, &copy);
    try std.testing.expectError(error.Denied, page.complete(first, &source));
    const next = try page.request(4096);
    try std.testing.expectEqual(@as(usize, 5), next.length);
    try std.testing.expectError(error.Denied, page.complete(first, &source));
    try std.testing.expectError(error.Io, page.complete(next, &source));
    try std.testing.expectError(error.Io, page.request(0));
    try page.detach();
    try page.attach(8, 4101);
    const fresh = try page.request(0);
    try std.testing.expectError(error.Denied, page.complete(next, &source));
    try page.complete(fresh, &source);
}

test "cancelled page remains owned until the producer drains" {
    var page: Coordinator = .{};
    try page.attach(1, 4096);
    const old = try page.request(0);
    try page.cancel(old);
    try std.testing.expectError(error.Busy, page.detach());
    try std.testing.expectError(error.Busy, page.request(0));
    try page.complete(old, null);
    const next = try page.request(0);
    try std.testing.expectError(error.Denied, page.complete(old, null));
    const bytes: [page_bytes]u8 = @splat(3);
    try page.complete(next, &bytes);
    try page.detach();
}
