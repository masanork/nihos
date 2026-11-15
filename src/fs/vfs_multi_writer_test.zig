const std = @import("std");
const multi = @import("vfs_multi_writer.zig");
const api = @import("vfs.zig");
const expect = std.testing.expect;
const eq = std.testing.expectEqual;
const Fake = struct {
    data: [2][16]u8 = @splat(@splat(0)),
    lookups: u32 = 0,
    writes: u32 = 0,
    syncs: u32 = 0,
    closes: u32 = 0,
    fail_close: bool = false,
    fail_write: ?api.Failure = null,
    fail_read: bool = false,
    invalid_read_count: bool = false,
    pub fn lookupBeneath(self: *@This(), _: u64, path: []const u8) api.Error!u64 {
        self.lookups += 1;
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
    pub fn readAt(self: *@This(), token: u64, offset: u64, bytes: []u8) api.Transfer {
        if (self.fail_read or self.invalid_read_count) {
            @memset(bytes, 0x5a);
            return if (self.fail_read) .{ .transferred = 4, .eof = true, .failure = .io_error } else .{ .transferred = bytes.len + 1 };
        }
        const pos: usize = @intCast(@min(offset, 16));
        const count = @min(bytes.len, 16 - pos);
        @memcpy(bytes[0..count], self.data[@intCast(token - 1)][pos..][0..count]);
        return .{ .transferred = count, .eof = pos + count == 16 };
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
    issuer: multi.Issuer = .{},
    service: Service = .{},
    queues: [2]multi.Queues = .{ .{}, .{} },
    fn init(self: *@This()) !void {
        try self.service.start(&self.backend, 1, &self.issuer);
        try eq(@as(u32, 1), try self.service.bind(0, 10, &self.queues[0], .{ .read = true, .write = true }));
        try eq(@as(u32, 1), try self.service.bind(1, 20, &self.queues[1], .{ .read = true, .write = true }));
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
    try eq(api.Error.StaleHandle, (try f.request(1, req)).result.failure);
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
    try eq(@as(u32, 2), try f.service.bind(0, 11, &f.queues[0], .{ .read = true, .write = true }));
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
    writes: u32 = 0,
    fail_after_write: ?u32 = null,
    pub fn lookupBeneath(_: *@This(), _: u64, path: []const u8) api.Error!u64 {
        if (std.mem.eql(u8, path, "a")) return 1;
        if (std.mem.eql(u8, path, "b")) return 2;
        return error.NotFound;
    }
    pub fn open(_: *@This(), identity: u64, _: api.Rights) api.Error!u64 {
        return identity;
    }
    pub fn close(_: *@This(), _: u64) api.Error!void {}
    pub fn readAt(self: *@This(), token: u64, offset: u64, bytes: []u8) api.Transfer {
        const n = self.files[@intCast(token - 1)].readPositionalAll(std.testing.io, bytes, offset) catch return .{ .failure = .io_error };
        return .{ .transferred = n, .eof = n < bytes.len };
    }
    pub fn writeAt(self: *@This(), token: u64, offset: u64, bytes: []const u8) api.Transfer {
        // A host error after submission does not prove that no bytes changed.
        self.files[@intCast(token - 1)].writePositionalAll(std.testing.io, bytes, offset) catch return .{ .failure = .outcome_unknown };
        self.writes += 1;
        if (self.fail_after_write == self.writes) return .{ .failure = .timed_out };
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
    var issuer = multi.Issuer{};
    var queues: [2]multi.Queues = .{ .{}, .{} };
    try service.start(&backend, 1, &issuer);
    _ = try service.bind(0, 10, &queues[0], .{ .read = true, .write = true });
    _ = try service.bind(1, 20, &queues[1], .{ .read = true, .write = true });
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
    var issuer = multi.Issuer{};
    var old = Service{};
    var queues: [2]multi.Queues = .{ .{}, .{} };
    try std.testing.expectError(error.InvalidArgument, old.start(&old_backend, 0, &issuer));
    try old.start(&old_backend, 1, &issuer);
    _ = try old.bind(0, 10, &queues[0], .{ .read = true, .write = true });
    _ = try old.bind(1, 20, &queues[1], .{ .read = true, .write = true });
    var request = opening(1, "a");
    request.epoch = 1;
    try expect(old.submit(&queues[0], 0, 10, &request));
    try eq(@as(usize, 0), old.step(&queues).?);
    var response = multi.Response{};
    try expect(queues[0].responses.tryPopInto(&response));
    const stale_handle = response.result.handle;
    const old_inner = old.lanes[0].files[0].?.inner;
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
    try fresh.start(&backend, 2, &issuer);
    _ = try fresh.bind(0, 10, &queues[0], .{ .read = true, .write = true });
    _ = try fresh.bind(1, 20, &queues[1], .{ .read = true, .write = true });
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
    try expect(stale_handle.token != new_handle.token);
    const new_inner = fresh.lanes[0].files[0].?.inner;
    try eq(old_inner.slot, new_inner.slot);
    try eq(old_inner.generation, new_inner.generation);
    // Rewriting the correlation field still cannot register the old token.
    var relabelled = stale_handle;
    relabelled.session = 2;
    request = .{ .session = 2, .epoch = 1, .sequence = 2, .operation = .write, .handle = relabelled, .length = 1 };
    try expect(fresh.submit(&queues[0], 0, 10, &request));
    try eq(@as(usize, 0), fresh.step(&queues).?);
    try expect(queues[0].responses.tryPopInto(&response));
    try eq(api.Error.StaleHandle, response.result.failure);
    try eq(@as(u32, 0), backend.writes);
}

test "issuer exhaustion fails closed before backend lookup" {
    var f = Fixture{};
    try f.init();
    f.issuer.next = std.math.maxInt(u64);
    const last = (try f.request(0, opening(1, "a"))).result.handle;
    try eq(std.math.maxInt(u64), last.token);
    try eq(@as(u64, 0), f.issuer.next);
    const lookups = f.backend.lookups;
    try eq(api.Error.NoHandles, (try f.request(1, opening(1, "b"))).result.failure);
    try eq(lookups, f.backend.lookups);
}

test "failed open burns its reserved token" {
    var f = Fixture{};
    try f.init();
    try eq(api.Error.NotFound, (try f.request(0, opening(1, "missing"))).result.failure);
    const file = (try f.request(0, opening(2, "a"))).result.handle;
    try eq(@as(u64, 2), file.token);
}

test "read-only grants cannot open for write while a different file is writable" {
    var backend = Fake{};
    @memcpy(backend.data[0][0..4], "text");
    var issuer = multi.Issuer{};
    var service = Service{};
    var queues: [2]multi.Queues = .{ .{}, .{} };
    try service.start(&backend, 1, &issuer);
    _ = try service.bind(0, 10, &queues[0], .{ .read = true });
    _ = try service.bind(1, 20, &queues[1], .{ .read = true, .write = true });
    var request = opening(1, "a");
    request.epoch = 1;
    try expect(service.submit(&queues[0], 0, 10, &request));
    try eq(@as(usize, 0), service.step(&queues).?);
    var response = multi.Response{};
    try expect(queues[0].responses.tryPopInto(&response));
    try eq(api.Error.PermissionDenied, response.result.failure);
    request = opening(2, "a");
    request.epoch = 1;
    request.rights = .{ .read = true };
    try expect(service.submit(&queues[0], 0, 10, &request));
    try eq(@as(usize, 0), service.step(&queues).?);
    try expect(queues[0].responses.tryPopInto(&response));
    const file = response.result.handle;
    request = .{ .session = 1, .epoch = 1, .sequence = 3, .operation = .read, .handle = file, .offset = 0, .length = 4 };
    try expect(service.submit(&queues[0], 0, 10, &request));
    try eq(@as(usize, 0), service.step(&queues).?);
    try expect(queues[0].responses.tryPopInto(&response));
    try eq(@as(usize, 4), response.result.transfer.transferred);
    try std.testing.expectEqualSlices(u8, "text", response.data[0..4]);
    for (response.data[4..]) |byte| try eq(@as(u8, 0), byte);
    request = .{ .session = 1, .epoch = 1, .sequence = 4, .operation = .write, .handle = file, .length = 1 };
    try expect(service.submit(&queues[0], 0, 10, &request));
    try eq(@as(usize, 0), service.step(&queues).?);
    try expect(queues[0].responses.tryPopInto(&response));
    try eq(api.Error.PermissionDenied, response.result.failure);
    request = opening(1, "a");
    request.epoch = 1;
    try expect(service.submit(&queues[1], 1, 20, &request));
    try eq(@as(usize, 1), service.step(&queues).?);
    try expect(queues[1].responses.tryPopInto(&response));
    try eq(api.Error.Busy, response.result.failure);
    request = opening(2, "b");
    request.epoch = 1;
    try expect(service.submit(&queues[1], 1, 20, &request));
    try eq(@as(usize, 1), service.step(&queues).?);
    try expect(queues[1].responses.tryPopInto(&response));
    _ = response.result.handle;
}

test "read errors and backend contract violations scrub reply data" {
    for (0..2) |mode| {
        var f = Fixture{};
        try f.init();
        var req = opening(1, "a");
        req.rights = .{ .read = true };
        const file = (try f.request(0, req)).result.handle;
        f.backend.fail_read = mode == 0;
        f.backend.invalid_read_count = mode == 1;
        const response = try f.request(0, .{ .sequence = 2, .operation = .read, .handle = file, .length = 16 });
        if (mode == 0) {
            try eq(api.Failure.io_error, response.result.transfer.failure.?);
            try eq(@as(usize, 0), response.result.transfer.transferred);
            try expect(!response.result.transfer.eof);
        } else try eq(api.Error.BackendContract, response.result.failure);
        for (response.data) |byte| try eq(@as(u8, 0), byte);
        try expect(f.service.faulted);
    }
}

test "two endpoints manually transfer four KiB in bounded round-robin chunks" {
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const io = std.testing.io;
    var backend = HostFiles{ .files = .{
        try dir.dir.createFile(io, "a", .{ .read = true }),
        try dir.dir.createFile(io, "b", .{ .read = true }),
    } };
    defer for (backend.files) |file| file.close(io);
    var service = multi.Service(HostFiles){};
    var issuer = multi.Issuer{};
    var queues: [2]multi.Queues = .{ .{}, .{} };
    var handles: [2]multi.Handle = undefined;
    try service.start(&backend, 1, &issuer);
    for (0..2) |i| {
        const caller: u32 = if (i == 0) 10 else 20;
        _ = try service.bind(i, caller, &queues[i], .{ .read = true, .write = true });
        var req = opening(1, if (i == 0) "a" else "b");
        req.epoch = 1;
        req.rights = .{ .read = true, .write = true };
        try expect(service.submit(&queues[i], i, caller, &req));
        try eq(i, service.step(&queues).?);
        var response = multi.Response{};
        try expect(queues[i].responses.tryPopInto(&response));
        handles[i] = response.result.handle;
    }
    for (0..8) |chunk| {
        for (0..2) |i| {
            var req = multi.Request{ .session = 1, .epoch = 1, .sequence = @intCast(2 + chunk), .operation = .write, .handle = handles[i], .offset = chunk * multi.transfer_bytes, .length = multi.transfer_bytes };
            @memset(&req.data, @intCast(1 + chunk + 16 * i));
            try expect(service.submit(&queues[i], i, if (i == 0) 10 else 20, &req));
        }
        for (0..2) |i| {
            try eq(i, service.step(&queues).?);
            var response = multi.Response{};
            try expect(queues[i].responses.tryPopInto(&response));
            try eq(@as(usize, multi.transfer_bytes), response.result.transfer.transferred);
        }
    }
    for (0..8) |chunk| {
        for (0..2) |i| {
            var req = multi.Request{ .session = 1, .epoch = 1, .sequence = @intCast(10 + chunk), .operation = .read, .handle = handles[i], .offset = chunk * multi.transfer_bytes, .length = multi.transfer_bytes };
            try expect(service.submit(&queues[i], i, if (i == 0) 10 else 20, &req));
        }
        for (0..2) |i| {
            try eq(i, service.step(&queues).?);
            var response = multi.Response{};
            try expect(queues[i].responses.tryPopInto(&response));
            try eq(@as(usize, multi.transfer_bytes), response.result.transfer.transferred);
            for (response.data) |byte| try eq(@as(u8, @intCast(1 + chunk + 16 * i)), byte);
        }
    }
    try service.stop(&queues[0], 0, 10);
    try service.stop(&queues[1], 1, 20);
}

test "oversized transfer is rejected before backend write" {
    var f = Fixture{};
    try f.init();
    const file = (try f.request(0, opening(1, "a"))).result.handle;
    const response = try f.request(0, .{ .sequence = 2, .operation = .write, .handle = file, .length = multi.transfer_bytes + 1 });
    try eq(api.Error.TooLarge, response.result.failure);
    try eq(@as(u32, 0), f.backend.writes);
}

test "failure after a chunk leaves an unknown outcome and blocks the queued peer" {
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const io = std.testing.io;
    var backend = HostFiles{ .files = .{
        try dir.dir.createFile(io, "a", .{ .read = true }),
        try dir.dir.createFile(io, "b", .{ .read = true }),
    }, .fail_after_write = 3 };
    defer for (backend.files) |file| file.close(io);
    var service = multi.Service(HostFiles){};
    var issuer = multi.Issuer{};
    var queues: [2]multi.Queues = .{ .{}, .{} };
    var handles: [2]multi.Handle = undefined;
    try service.start(&backend, 1, &issuer);
    for (0..2) |i| {
        const caller: u32 = if (i == 0) 10 else 20;
        _ = try service.bind(i, caller, &queues[i], .{ .write = true });
        var request = opening(1, if (i == 0) "a" else "b");
        request.epoch = 1;
        try expect(service.submit(&queues[i], i, caller, &request));
        try eq(i, service.step(&queues).?);
        var response = multi.Response{};
        try expect(queues[i].responses.tryPopInto(&response));
        handles[i] = response.result.handle;
    }
    for (0..2) |chunk| {
        var request = multi.Request{ .session = 1, .epoch = 1, .sequence = @intCast(2 + chunk), .operation = .write, .handle = handles[0], .offset = chunk * multi.transfer_bytes, .length = multi.transfer_bytes };
        @memset(&request.data, @intCast(chunk + 1));
        try expect(service.submit(&queues[0], 0, 10, &request));
        try eq(@as(usize, 0), service.step(&queues).?);
        var response = multi.Response{};
        try expect(queues[0].responses.tryPopInto(&response));
        try eq(@as(usize, multi.transfer_bytes), response.result.transfer.transferred);
    }
    var peer = multi.Request{ .session = 1, .epoch = 1, .sequence = 2, .operation = .sync, .handle = handles[1] };
    try expect(service.submit(&queues[1], 1, 20, &peer));
    try eq(@as(usize, 1), service.step(&queues).?);
    var response = multi.Response{};
    try expect(queues[1].responses.tryPopInto(&response));
    peer.sequence = 3;
    try expect(service.submit(&queues[1], 1, 20, &peer));
    var failed = multi.Request{ .session = 1, .epoch = 1, .sequence = 4, .operation = .write, .handle = handles[0], .offset = 2 * multi.transfer_bytes, .length = multi.transfer_bytes };
    @memset(&failed.data, 3);
    try expect(service.submit(&queues[0], 0, 10, &failed));
    try eq(@as(usize, 0), service.step(&queues).?);
    try expect(queues[0].responses.tryPopInto(&response));
    try eq(api.Failure.outcome_unknown, response.result.transfer.failure.?);
    try expect(service.faulted and service.step(&queues) == null);
    try eq(@as(usize, 1), queues[1].requests.countApprox());
    try eq(@as(u32, 3), backend.writes);
    // This injected error occurs after the third host write: failure does not
    // imply that only the two acknowledged chunks changed the file.
    var bytes: [3 * multi.transfer_bytes]u8 = undefined;
    try eq(bytes.len, try backend.files[0].readPositionalAll(io, &bytes, 0));
    for (bytes, 0..) |byte, i| try eq(@as(u8, @intCast(1 + i / multi.transfer_bytes)), byte);
}

test "read-only mount rejects write grants before backend access" {
    var backend = Fake{};
    @memcpy(backend.data[0][0..4], "data");
    var issuer = multi.Issuer{};
    var service = Service{};
    var queues: [2]multi.Queues = .{ .{}, .{} };
    try service.startReadOnly(&backend, 1, &issuer);
    try std.testing.expectError(error.ReadOnly, service.bind(0, 10, &queues[0], .{ .read = true, .write = true }));
    try eq(@as(u32, 0), backend.lookups);
    _ = try service.bind(0, 10, &queues[0], .{ .read = true });
    var request = opening(1, "a");
    request.epoch = 1;
    request.rights = .{ .read = true };
    try expect(service.submit(&queues[0], 0, 10, &request));
    try eq(@as(usize, 0), service.step(&queues).?);
    var response = multi.Response{};
    try expect(queues[0].responses.tryPopInto(&response));
    const file = response.result.handle;
    request = .{ .session = 1, .epoch = 1, .sequence = 2, .operation = .read, .handle = file, .length = 4 };
    try expect(service.submit(&queues[0], 0, 10, &request));
    try eq(@as(usize, 0), service.step(&queues).?);
    try expect(queues[0].responses.tryPopInto(&response));
    try std.testing.expectEqualSlices(u8, "data", response.data[0..4]);
    request = .{ .session = 1, .epoch = 1, .sequence = 3, .operation = .write, .handle = file, .length = 4 };
    try expect(service.submit(&queues[0], 0, 10, &request));
    try eq(@as(usize, 0), service.step(&queues).?);
    try expect(queues[0].responses.tryPopInto(&response));
    try eq(api.Error.PermissionDenied, response.result.failure);
    try eq(@as(u32, 0), backend.writes);
}

test "read-only shutdown waits for both lanes and permits a fresh mount" {
    var backend = Fake{};
    var issuer = multi.Issuer{};
    var service = Service{};
    var queues: [2]multi.Queues = .{ .{}, .{} };
    try service.startReadOnly(&backend, 1, &issuer);
    _ = try service.bind(0, 10, &queues[0], .{ .read = true });
    _ = try service.bind(1, 20, &queues[1], .{ .read = true });
    var request = opening(1, "a");
    request.epoch = 1;
    request.rights = .{ .read = true };
    try expect(service.submit(&queues[0], 0, 10, &request));
    try eq(@as(usize, 0), service.step(&queues).?);
    var response = multi.Response{};
    try expect(queues[0].responses.tryPopInto(&response));
    const old_handle = response.result.handle;
    try std.testing.expectError(error.Busy, service.shutdown());
    try service.stop(&queues[0], 0, 10);
    try std.testing.expectError(error.Busy, service.shutdown());
    try service.stop(&queues[1], 1, 20);
    try service.shutdown();
    try service.startReadOnly(&backend, 2, &issuer);
    const epoch = try service.bind(0, 10, &queues[0], .{ .read = true });
    try eq(@as(u32, 2), epoch);
    try expect(!service.submit(&queues[0], 0, 10, &request));
    request.session = 2;
    request.epoch = epoch;
    try expect(service.submit(&queues[0], 0, 10, &request));
    try eq(@as(usize, 0), service.step(&queues).?);
    try expect(queues[0].responses.tryPopInto(&response));
    try expect(response.result.handle.token != old_handle.token);
    try service.stop(&queues[0], 0, 10);
    try service.shutdown();
}

test "shutdown detaches removed media but retains failed and unsynced mounts" {
    var removed = Fixture{};
    try removed.init();
    _ = try removed.request(0, opening(1, "a"));
    try removed.service.markRemoved();
    try removed.service.stop(&removed.queues[0], 0, 10);
    try removed.service.stop(&removed.queues[1], 1, 20);
    try removed.service.shutdown();
    try eq(@as(u32, 0), removed.backend.closes);
    try removed.service.startReadOnly(&removed.backend, 2, &removed.issuer);

    var dirty = Fixture{};
    try dirty.init();
    try dirty.service.stop(&dirty.queues[0], 0, 10);
    try dirty.service.stop(&dirty.queues[1], 1, 20);
    try std.testing.expectError(error.Unsupported, dirty.service.shutdown());
    try std.testing.expectError(error.Busy, dirty.service.startReadOnly(&dirty.backend, 2, &dirty.issuer));

    var failed = Fixture{};
    try failed.init();
    _ = try failed.request(0, opening(1, "a"));
    failed.backend.fail_close = true;
    try std.testing.expectError(error.IoError, failed.service.stop(&failed.queues[0], 0, 10));
    try failed.service.stop(&failed.queues[1], 1, 20);
    try std.testing.expectError(error.IoError, failed.service.shutdown());
    try std.testing.expectError(error.Busy, failed.service.startReadOnly(&failed.backend, 2, &failed.issuer));
    try failed.service.markRemoved();
    try std.testing.expectError(error.IoError, failed.service.shutdown());
}
