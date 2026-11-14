const std = @import("std");
const multi = @import("vfs_multi_writer.zig");
const api = @import("vfs.zig");
const expect = std.testing.expect;
const eq = std.testing.expectEqual;
const Fake = struct {
    data: [2][16]u8 = @splat(@splat(0)),
    writes: u32 = 0,
    syncs: u32 = 0,
    closes: u32 = 0,
    fail_close: bool = false,
    fail_write: ?api.Failure = null,
    pub fn lookupBeneath(_: *@This(), _: u64, path: []const u8) api.Error!u64 {
        if (std.mem.eql(u8, path, "a") or std.mem.eql(u8, path, "alias-a")) return 1;
        if (std.mem.eql(u8, path, "b")) return 2;
        return error.NotFound;
    }
    pub fn open(_: *@This(), identity: u64, _: api.Rights) api.Error!u64 {
        return identity;
    }
    pub fn close(self: *@This(), _: u64) api.Error!void {
        self.closes += 1;
        if (self.fail_close) return error.IoError;
    }
    pub fn readAt(_: *@This(), _: u64, _: u64, _: []u8) api.Transfer {
        unreachable;
    }
    pub fn writeAt(self: *@This(), token: u64, offset: u64, bytes: []const u8) api.Transfer {
        self.writes += 1;
        if (self.fail_write) |failure| return .{ .failure = failure };
        const pos: usize = @intCast(offset);
        @memcpy(self.data[@intCast(token - 1)][pos..][0..bytes.len], bytes);
        return .{ .transferred = bytes.len };
    }
    pub fn syncFile(self: *@This(), _: u64) api.Error!void {
        self.syncs += 1;
    }
    pub fn syncVolume(_: *@This(), _: u64) api.Error!void {}
};
const Service = multi.Service(Fake);
const Fixture = struct {
    backend: Fake = .{},
    service: Service = .{},
    queues: [2]multi.Queues = .{ .{}, .{} },
    fn init(self: *@This()) !void {
        try self.service.start(&self.backend, 1);
        try eq(@as(u32, 1), try self.service.bind(0, 10, &self.queues[0]));
        try eq(@as(u32, 1), try self.service.bind(1, 20, &self.queues[1]));
    }
    fn request(self: *@This(), lane: usize, request_value: multi.Request) !multi.Response {
        var request_copy = request_value;
        request_copy.session = 1;
        request_copy.epoch = 1;
        try expect(self.service.submit(&self.queues[lane], lane, if (lane == 0) 10 else 20, &request_copy));
        try eq(lane, self.service.step(&self.queues).?);
        var response = multi.Response{};
        try expect(self.queues[lane].responses.tryPopInto(&response));
        try eq(request_copy.session, response.session);
        try eq(request_copy.epoch, response.epoch);
        try eq(request_copy.sequence, response.sequence);
        return response;
    }
};
fn opening(sequence: u32, path: []const u8) multi.Request {
    var req = multi.Request{ .session = 1, .sequence = sequence, .operation = .open, .path_length = @intCast(path.len) };
    @memcpy(req.path[0..path.len], path);
    return req;
}
test "two clients write different files and same identity excludes conflicting writer" {
    var f = Fixture{};
    try f.init();
    const a = (try f.request(0, opening(1, "a"))).result.handle;
    try eq(api.Error.Busy, (try f.request(1, opening(1, "alias-a"))).result.failure);
    const b = (try f.request(1, opening(2, "b"))).result.handle;
    var req = multi.Request{ .session = 1, .epoch = 1, .sequence = 2, .operation = .write, .handle = a, .length = 2 };
    @memcpy(req.data[0..2], "hi");
    try expect(f.service.submit(&f.queues[0], 0, 10, &req));
    req.data[0] = 'X';
    try eq(@as(usize, 0), f.service.step(&f.queues).?);
    var response = multi.Response{};
    try expect(f.queues[0].responses.tryPopInto(&response));
    try eq(@as(usize, 2), response.result.transfer.transferred);
    try std.testing.expectEqualSlices(u8, "hi", f.backend.data[0][0..2]);
    req = .{ .session = 1, .sequence = 3, .operation = .write, .handle = a, .length = 1 };
    try eq(api.Error.PermissionDenied, (try f.request(1, req)).result.failure);
    req = .{ .session = 1, .sequence = 4, .operation = .write, .handle = b, .length = 1 };
    req.data[0] = 'b';
    _ = try f.request(1, req);
    _ = try f.request(1, .{ .sequence = 5, .operation = .sync, .handle = b });
    try eq(@as(u8, 'b'), f.backend.data[1][0]);
    try eq(@as(u32, 2), f.backend.writes);
    try eq(@as(u32, 1), f.backend.syncs);
}
test "full reply lane skips to peer and stopped client releases only its files" {
    var f = Fixture{};
    try f.init();
    const a = (try f.request(0, opening(1, "a"))).result.handle;
    const b = (try f.request(1, opening(1, "b"))).result.handle;
    try expect(f.queues[0].responses.tryPush(.{}));
    try expect(f.queues[0].responses.tryPush(.{}));
    var q = multi.Request{ .session = 1, .epoch = 1, .sequence = 2, .operation = .sync, .handle = a };
    try expect(f.service.submit(&f.queues[0], 0, 10, &q));
    q.handle = b;
    try expect(f.service.submit(&f.queues[1], 1, 20, &q));
    try eq(@as(usize, 1), f.service.step(&f.queues).?);
    try f.service.stop(&f.queues[0], 0, 10);
    try eq(@as(usize, 0), f.queues[0].requests.countApprox());
    try eq(@as(usize, 0), f.queues[0].responses.countApprox());
    var response = multi.Response{};
    try expect(f.queues[1].responses.tryPopInto(&response));
    _ = try f.request(1, .{ .sequence = 3, .operation = .sync, .handle = b });
    const reopened = (try f.request(1, opening(4, "a"))).result.handle;
    _ = try f.request(1, .{ .sequence = 5, .operation = .close, .handle = reopened });
    try eq(api.Error.StaleHandle, (try f.request(1, .{ .sequence = 6, .operation = .sync, .handle = a })).result.failure);
}
test "unknown write outcome and failed cleanup quarantine the shared session" {
    var f = Fixture{};
    try f.init();
    const a = (try f.request(0, opening(1, "a"))).result.handle;
    f.backend.fail_write = .timed_out;
    const result = try f.request(0, .{ .sequence = 2, .operation = .write, .handle = a, .length = 1 });
    try eq(api.Failure.outcome_unknown, result.result.transfer.failure.?);
    try expect(f.service.faulted);
    var request_copy = opening(1, "b");
    try expect(!f.service.submit(&f.queues[1], 1, 20, &request_copy));
    var g = Fixture{};
    try g.init();
    _ = try g.request(0, opening(1, "a"));
    g.backend.fail_close = true;
    try std.testing.expectError(error.IoError, g.service.stop(&g.queues[0], 0, 10));
    try expect(g.service.faulted);
}

test "rebind changes epoch and rejects old copied requests and handles" {
    var f = Fixture{};
    try f.init();
    const old = (try f.request(0, opening(1, "a"))).result.handle;
    try f.service.stop(&f.queues[0], 0, 10);
    try eq(@as(u32, 2), try f.service.bind(0, 11, &f.queues[0]));
    var request = multi.Request{ .session = 1, .epoch = 1, .sequence = 1, .operation = .sync, .handle = old };
    try expect(!f.service.submit(&f.queues[1], 0, 10, &request));
    try expect(!f.service.submit(&f.queues[0], 0, 10, &request));
    try expect(!f.service.submit(&f.queues[0], 0, 11, &request));
    request.epoch = 2;
    try expect(f.service.submit(&f.queues[0], 0, 11, &request));
    try eq(@as(usize, 0), f.service.step(&f.queues).?);
    var response = multi.Response{};
    try expect(f.queues[0].responses.tryPopInto(&response));
    try eq(api.Error.StaleHandle, response.result.failure);
}

// Test-only adapter over two already-opened host files. Its fixed mapping is
// deliberate: it does not model path lookup, aliases, or external writers.
const HostFiles = struct {
    files: [2]std.Io.File,
    pub fn lookupBeneath(_: *@This(), _: u64, path: []const u8) api.Error!u64 {
        if (std.mem.eql(u8, path, "a")) return 1;
        if (std.mem.eql(u8, path, "b")) return 2;
        return error.NotFound;
    }
    pub fn open(_: *@This(), identity: u64, _: api.Rights) api.Error!u64 {
        return identity;
    }
    pub fn close(_: *@This(), _: u64) api.Error!void {}
    pub fn readAt(_: *@This(), _: u64, _: u64, _: []u8) api.Transfer {
        unreachable;
    }
    pub fn writeAt(self: *@This(), token: u64, offset: u64, bytes: []const u8) api.Transfer {
        // A host error after submission does not prove that no bytes changed.
        self.files[@intCast(token - 1)].writePositionalAll(std.testing.io, bytes, offset) catch return .{ .failure = .outcome_unknown };
        return .{ .transferred = bytes.len };
    }
    pub fn syncFile(self: *@This(), token: u64) api.Error!void {
        self.files[@intCast(token - 1)].sync(std.testing.io) catch return error.IoError;
    }
    pub fn syncVolume(_: *@This(), _: u64) api.Error!void {}
};

test "two endpoints sync real host files and reopen their bytes" {
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const io = std.testing.io;
    var backend = HostFiles{ .files = .{
        try dir.dir.createFile(io, "a", .{ .read = true }),
        try dir.dir.createFile(io, "b", .{ .read = true }),
    } };
    var service = multi.Service(HostFiles){};
    var queues: [2]multi.Queues = .{ .{}, .{} };
    try service.start(&backend, 1);
    _ = try service.bind(0, 10, &queues[0]);
    _ = try service.bind(1, 20, &queues[1]);
    var files: [2]multi.Handle = undefined;
    for (0..2) |i| {
        var req = opening(1, if (i == 0) "a" else "b");
        req.epoch = 1;
        try expect(service.submit(&queues[i], i, if (i == 0) 10 else 20, &req));
        try eq(i, service.step(&queues).?);
        var response = multi.Response{};
        try expect(queues[i].responses.tryPopInto(&response));
        files[i] = response.result.handle;
    }
    for (0..2) |i| {
        var req = multi.Request{ .session = 1, .epoch = 1, .sequence = 2, .operation = .write, .handle = files[i], .length = 4 };
        @memcpy(req.data[0..4], if (i == 0) "one!" else "two!");
        try expect(service.submit(&queues[i], i, if (i == 0) 10 else 20, &req));
        try eq(i, service.step(&queues).?);
        var response = multi.Response{};
        try expect(queues[i].responses.tryPopInto(&response));
        try eq(@as(usize, 4), response.result.transfer.transferred);
        req = .{ .session = 1, .epoch = 1, .sequence = 3, .operation = .sync, .handle = files[i] };
        try expect(service.submit(&queues[i], i, if (i == 0) 10 else 20, &req));
        try eq(i, service.step(&queues).?);
        try expect(queues[i].responses.tryPopInto(&response));
        try eq(multi.Result.ok, response.result);
    }
    try service.stop(&queues[0], 0, 10);
    try service.stop(&queues[1], 1, 20);
    for (backend.files) |file| file.close(io);
    for (0..2) |i| {
        const file = try dir.dir.openFile(io, if (i == 0) "a" else "b", .{});
        defer file.close(io);
        var bytes: [4]u8 = undefined;
        try eq(@as(usize, 4), try file.readPositionalAll(io, &bytes, 0));
        try std.testing.expectEqualSlices(u8, if (i == 0) "one!" else "two!", &bytes);
    }
}

test "media removal stops both lanes and a fresh session rejects stale messages and handles" {
    var old_backend = Fake{};
    var old = Service{};
    var queues: [2]multi.Queues = .{ .{}, .{} };
    try std.testing.expectError(error.InvalidArgument, old.start(&old_backend, 0));
    try old.start(&old_backend, 1);
    _ = try old.bind(0, 10, &queues[0]);
    _ = try old.bind(1, 20, &queues[1]);
    var request = opening(1, "a");
    request.epoch = 1;
    try expect(old.submit(&queues[0], 0, 10, &request));
    try eq(@as(usize, 0), old.step(&queues).?);
    var response = multi.Response{};
    try expect(queues[0].responses.tryPopInto(&response));
    const stale_handle = response.result.handle;
    var pending = opening(1, "b");
    pending.epoch = 1;
    try expect(old.submit(&queues[1], 1, 20, &pending));
    try old.markRemoved();
    try expect(old.step(&queues) == null);
    try expect(!old.submit(&queues[0], 0, 10, &request));
    try old.stop(&queues[0], 0, 10);
    try old.stop(&queues[1], 1, 20);
    try eq(@as(u32, 0), old_backend.closes);
    try eq(@as(usize, 0), queues[1].requests.countApprox());

    var backend = Fake{};
    var fresh = Service{};
    try fresh.start(&backend, 2);
    _ = try fresh.bind(0, 10, &queues[0]);
    _ = try fresh.bind(1, 20, &queues[1]);
    try expect(!fresh.submit(&queues[0], 0, 10, &request));
    // A stale copy already in the ring is rejected again by the owner.
    try expect(queues[0].requests.tryPushFrom(&request));
    try eq(@as(usize, 0), fresh.step(&queues).?);
    try expect(queues[0].responses.tryPopInto(&response));
    try eq(api.Error.InvalidArgument, response.result.failure);
    request.session = 2;
    try expect(fresh.submit(&queues[0], 0, 10, &request));
    try eq(@as(usize, 0), fresh.step(&queues).?);
    try expect(queues[0].responses.tryPopInto(&response));
    const new_handle = response.result.handle;
    try eq(stale_handle.inner.slot, new_handle.inner.slot);
    try eq(stale_handle.inner.generation, new_handle.inner.generation);
    request = .{ .session = 2, .epoch = 1, .sequence = 2, .operation = .write, .handle = stale_handle, .length = 1 };
    try expect(fresh.submit(&queues[0], 0, 10, &request));
    try eq(@as(usize, 0), fresh.step(&queues).?);
    try expect(queues[0].responses.tryPopInto(&response));
    try eq(api.Error.StaleHandle, response.result.failure);
    try eq(@as(u32, 0), backend.writes);
}
