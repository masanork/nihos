const std = @import("std");
const rpc = @import("storage_rpc.zig");
const Backend = struct {
    opened: bool = false,
    releases: u32 = 0,
    reads: u32 = 0,
    release_error: i32 = 0,
    pub fn list(_: *@This(), _: u32, response: *rpc.Response) i32 {
        response.kind = 1;
        return 1;
    }
    pub fn stat(_: *@This(), _: []const u8, response: *rpc.Response) i32 {
        response.size = 3;
        return 0;
    }
    pub fn open(self: *@This(), owner: u32, path: []const u8, handle: *u32) i32 {
        if (owner != 0x01010002 or !std.mem.eql(u8, path, "/a")) return -13;
        self.opened = true;
        handle.* = 8;
        return 0;
    }
    pub fn read(self: *@This(), _: u32, _: u32, _: u32, data: []u8) i32 {
        self.reads += 1;
        if (!self.opened) return -9;
        @memset(data, 42);
        return @intCast(data.len);
    }
    pub fn close(self: *@This(), _: u32, _: u32) i32 {
        self.opened = false;
        return 0;
    }
    pub fn release(self: *@This(), _: u32) i32 {
        self.opened = false;
        self.releases += 1;
        return self.release_error;
    }
};
test "RPC copies paths and data and binds owner outside client messages" {
    var owner = rpc.Owner(Backend){ .backend = .{}, .client = 0x01010002 };
    var q = rpc.Queues(@import("spsc_ring.zig")){};
    var request = rpc.Request{ .epoch = 1, .sequence = 1, .operation = 3, .path_length = 2 };
    @memcpy(request.path[0..2], "/a");
    try std.testing.expect(q.requests.tryPush(request));
    request.path[1] = 'z';
    try std.testing.expect(owner.step(&q));
    const opened = q.responses.tryPop().?;
    try std.testing.expectEqual(@as(i32, 0), opened.status);
    try std.testing.expectEqual(@as(u32, 8), opened.handle);
    const response = owner.dispatch(.{ .epoch = 1, .sequence = 2, .operation = 4, .handle = 8, .length = 3 });
    try std.testing.expectEqual(@as(u32, 3), response.length);
    try std.testing.expectEqualSlices(u8, &.{ 42, 42, 42 }, response.data[0..3]);
    try std.testing.expectEqual(@as(u8, 0), response.data[3]);
    try std.testing.expectEqual(@as(i32, 0), owner.clientExited(&q));
    try std.testing.expectEqual(@as(i32, 0), owner.clientExited(&q));
    try std.testing.expectEqual(@as(u32, 1), owner.backend.releases);
    try std.testing.expectEqual(@as(i32, -13), owner.dispatch(.{ .epoch = 1, .sequence = 3, .operation = 4 }).status);
}
test "RPC reserves reply credit and rejects replay invalid sizes and unknown operations" {
    var owner = rpc.Owner(Backend){ .backend = .{}, .client = 0x01010002 };
    var q = rpc.Queues(@import("spsc_ring.zig")){};
    try std.testing.expect(q.responses.tryPush(.{}));
    try std.testing.expect(q.responses.tryPush(.{}));
    try std.testing.expect(q.requests.tryPush(.{ .epoch = 1, .sequence = 1, .operation = 4 }));
    try std.testing.expect(!owner.step(&q));
    try std.testing.expectEqual(@as(usize, 1), q.requests.countApprox());
    _ = q.responses.tryPop();
    try std.testing.expect(owner.step(&q));
    try std.testing.expectEqual(@as(i32, -22), owner.dispatch(.{ .epoch = 1, .sequence = 1, .operation = 4 }).status);
    try std.testing.expectEqual(@as(i32, -22), owner.dispatch(.{ .epoch = 1, .sequence = 2, .operation = 99 }).status);
    try std.testing.expectEqual(@as(i32, -22), owner.dispatch(.{ .epoch = 1, .sequence = 3, .operation = 4, .length = 513 }).status);
    try std.testing.expectEqual(@as(i32, -22), owner.dispatch(.{ .epoch = 1, .sequence = 4, .operation = 3, .path_length = 256 }).status);
    try std.testing.expectEqual(@as(u32, 1), owner.backend.reads);
}

test "stopped client drops queued work and replies without executing abandoned requests" {
    var owner = rpc.Owner(Backend){ .backend = .{ .opened = true }, .client = 0x01010002 };
    var q = rpc.Queues(@import("spsc_ring.zig")){};
    // One response was unread, a second dispatch completed after the stop.
    try std.testing.expect(q.responses.tryPush(.{ .epoch = 1, .sequence = 1 }));
    try std.testing.expect(q.requests.tryPush(.{ .epoch = 1, .sequence = 1, .operation = 4, .handle = 8, .length = 3 }));
    try std.testing.expect(owner.step(&q));
    try std.testing.expect(q.requests.tryPush(.{ .epoch = 1, .sequence = 2, .operation = 4, .length = 512 }));
    try std.testing.expect(q.requests.tryPush(.{ .epoch = 1, .sequence = 3, .operation = 3 }));
    try std.testing.expect(!owner.step(&q));
    try std.testing.expectEqual(@as(i32, 0), owner.clientExited(&q));
    try std.testing.expectEqual(@as(u32, 2), owner.discarded_requests);
    try std.testing.expectEqual(@as(u32, 2), owner.discarded_responses);
    try std.testing.expectEqual(@as(u32, 1), owner.backend.reads);
    try std.testing.expectEqual(@as(u32, 1), owner.backend.releases);
    try std.testing.expect(!owner.backend.opened);
    try std.testing.expect(!owner.step(&q));
    try std.testing.expectEqual(@as(usize, 0), q.requests.countApprox());
    try std.testing.expectEqual(@as(usize, 0), q.responses.countApprox());
    try std.testing.expectEqual(@as(i32, 0), owner.clientExited(&q));
    try std.testing.expectEqual(@as(u32, 1), owner.backend.releases);
    try std.testing.expectEqual(@as(i32, -13), owner.dispatch(.{ .epoch = 1, .sequence = 2, .operation = 3 }).status);
}

test "rebind excludes live dirty reused and exhausted endpoints and rejects previous epoch before sequence admission" {
    var owner = rpc.Owner(Backend){ .backend = .{}, .client = 0x01010002 };
    var q = rpc.Queues(@import("spsc_ring.zig")){};
    try std.testing.expect(!owner.rebind(0x01010003, &q));
    try std.testing.expectEqual(@as(i32, 0), owner.clientExited(&q));
    try std.testing.expect(!owner.rebind(0, &q));
    try std.testing.expect(!owner.rebind(0x01010002, &q));
    try std.testing.expect(q.requests.tryPush(.{ .epoch = 1, .sequence = 1 }));
    try std.testing.expect(!owner.rebind(0x01010003, &q));
    _ = q.requests.tryPop();
    try std.testing.expect(q.responses.tryPush(.{ .epoch = 1, .sequence = 1 }));
    try std.testing.expect(!owner.rebind(0x01010003, &q));
    _ = q.responses.tryPop();
    try std.testing.expect(owner.rebind(0x01010003, &q));
    const stale = owner.dispatch(.{ .epoch = 1, .sequence = 1, .operation = 4 });
    try std.testing.expectEqual(@as(i32, -13), stale.status);
    try std.testing.expectEqual(@as(u32, 1), owner.next_sequence);
    try std.testing.expectEqual(@as(u32, 0), owner.backend.reads);
    const fresh = owner.dispatch(.{ .epoch = 2, .sequence = 1, .operation = 2 });
    try std.testing.expectEqual(@as(i32, 0), fresh.status);
    try std.testing.expect(rpc.responseMatches(&fresh, 2, 1));
    try std.testing.expect(!rpc.responseMatches(&.{ .epoch = 1, .sequence = 1 }, 2, 1));
    try std.testing.expect(!rpc.responseMatches(&fresh, 2, 2));
    try std.testing.expect(!rpc.responseMatches(&.{}, 0, 0));
    try std.testing.expectEqual(@as(i32, 0), owner.clientExited(&q));
    owner.epoch = std.math.maxInt(u32);
    try std.testing.expect(!owner.rebind(0x01010004, &q));
    try std.testing.expect(!owner.alive);
}

test "release failure leaves endpoint closed and prevents rebind even after repeated cleanup" {
    var owner = rpc.Owner(Backend){ .backend = .{ .release_error = -5 }, .client = 0x01010002 };
    var q = rpc.Queues(@import("spsc_ring.zig")){};
    try std.testing.expectEqual(@as(i32, -5), owner.clientExited(&q));
    try std.testing.expect(!owner.rebind(0x01010003, &q));
    try std.testing.expectEqual(@as(i32, 0), owner.clientExited(&q));
    try std.testing.expect(!owner.rebind(0x01010003, &q));
    try std.testing.expectEqual(@as(u32, 1), owner.backend.releases);
}
