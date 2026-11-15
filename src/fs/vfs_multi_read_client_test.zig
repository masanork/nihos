const std = @import("std");
const api = @import("vfs.zig");
const multi = @import("vfs_multi_writer.zig");
const client = @import("vfs_multi_read_client.zig");
const expect = std.testing.expect;
const eq = std.testing.expectEqual;
const Backend = struct {
    size: usize = 4096,
    chunk: usize = 512,
    fail_at: ?usize = null,
    fail_close: bool = false,
    closes: usize = 0,
    pub fn lookupBeneath(_: *@This(), _: u64, path: []const u8) api.Error!u64 {
        if (std.mem.eql(u8, path, "file")) return 1;
        return error.NotFound;
    }
    pub fn open(_: *@This(), id: u64, _: api.Rights) api.Error!u64 {
        return id;
    }
    pub fn close(self: *@This(), _: u64) api.Error!void {
        self.closes += 1;
        if (self.fail_close) return error.IoError;
    }
    pub fn readAt(self: *@This(), _: u64, offset: u64, data: []u8) api.Transfer {
        const pos: usize = @intCast(offset);
        if (self.fail_at) |at| if (pos >= at) return .{ .failure = .io_error };
        const n = @min(@min(data.len, self.chunk), self.size - @min(pos, self.size));
        for (data[0..n], 0..) |*byte, i| byte.* = @intCast((pos + i) % 251);
        return .{ .transferred = n, .eof = pos + n >= self.size };
    }
    pub fn writeAt(_: *@This(), _: u64, _: u64, _: []const u8) api.Transfer {
        return .{ .failure = .io_error };
    }
    pub fn syncFile(_: *@This(), _: u64) api.Error!void {
        return error.Unsupported;
    }
    pub fn syncVolume(_: *@This(), _: u64) api.Error!void {
        return error.Unsupported;
    }
};
const Service = multi.Service(Backend);
const Fixture = struct {
    backend: Backend = .{},
    issuer: multi.Issuer = .{},
    service: Service = .{},
    queues: [2]multi.Queues = .{ .{}, .{} },
    reader: client.Reader = .{},
    req: multi.Request = .{},
    out: [4096]u8 = @splat(0xaa),
    fn init(self: *@This()) !void {
        try self.service.startReadOnly(&self.backend, 1, &self.issuer);
        _ = try self.service.bind(0, 10, &self.queues[0], .{ .read = true });
        _ = try self.service.bind(1, 20, &self.queues[1], .{ .read = true });
        try expect(self.reader.begin(1, 1, 0, "file", &self.out, &self.req));
    }
    fn exchange(self: *@This()) !client.Progress {
        try expect(self.service.submit(&self.queues[0], 0, 10, &self.req));
        try eq(@as(usize, 0), self.service.step(&self.queues).?);
        var response = multi.Response{};
        try expect(self.queues[0].responses.tryPopInto(&response));
        return self.reader.accept(&response, &self.req);
    }
};

test "bounded read assembles chunks and publishes only after close" {
    for ([_]usize{ 0, 127, 4096, 5000 }) |size| {
        var f = Fixture{};
        try f.init();
        f.backend.size = size;
        f.backend.chunk = 137;
        var progress: client.Progress = .request;
        while (progress == .request) progress = try f.exchange();
        try eq(client.Progress.complete, progress);
        const n = @min(size, 4096);
        try eq(n, f.reader.bytes);
        try eq(size <= 4096, f.reader.eof);
        try eq(@as(usize, 1), f.backend.closes);
        for (f.out[0..n], 0..) |byte, i| try eq(@as(u8, @intCast(i % 251)), byte);
        for (f.out[n..]) |byte| try eq(@as(u8, 0), byte);
    }
}
test "failed later read scrubs output and lane cleanup closes the file" {
    var f = Fixture{};
    try f.init();
    f.backend.fail_at = 512;
    try eq(client.Progress.request, try f.exchange());
    try eq(client.Progress.request, try f.exchange());
    try expect(f.out[1] != 0);
    try eq(client.Progress.stop_lane, try f.exchange());
    for (f.out) |byte| try eq(@as(u8, 0), byte);
    try f.service.stop(&f.queues[0], 0, 10);
    try eq(@as(usize, 1), f.backend.closes);
}
test "failed close, malformed reply and transport abort require lane stop" {
    var f = Fixture{};
    try f.init();
    f.backend.size = 4;
    f.backend.fail_close = true;
    try eq(client.Progress.request, try f.exchange());
    try eq(client.Progress.request, try f.exchange());
    try eq(client.Progress.stop_lane, try f.exchange());
    for (f.out) |byte| try eq(@as(u8, 0), byte);
    var g = Fixture{};
    try g.init();
    var bad = multi.Response{ .session = 1, .epoch = 1, .sequence = 2 };
    try eq(client.Progress.stop_lane, g.reader.accept(&bad, &g.req));
    var h = Fixture{};
    try h.init();
    try eq(client.Progress.request, try h.exchange());
    try eq(client.Progress.stop_lane, h.reader.abort());
    for (h.out) |byte| try eq(@as(u8, 0), byte);
}

test "peer progresses between reader chunks" {
    var f = Fixture{};
    try f.init();
    try eq(client.Progress.request, try f.exchange());
    var peer = multi.Request{ .session = 1, .epoch = 1, .sequence = 1, .operation = .open, .rights = .{ .read = true }, .path_length = 4 };
    @memcpy(peer.path[0..4], "file");
    try expect(f.service.submit(&f.queues[1], 1, 20, &peer));
    try expect(f.service.submit(&f.queues[0], 0, 10, &f.req));
    try eq(@as(usize, 1), f.service.step(&f.queues).?);
    var response = multi.Response{};
    try expect(f.queues[1].responses.tryPopInto(&response));
    const handle = response.result.handle;
    try eq(@as(usize, 0), f.service.step(&f.queues).?);
    try expect(f.queues[0].responses.tryPopInto(&response));
    try eq(client.Progress.request, f.reader.accept(&response, &f.req));
    try eq(@as(usize, 512), f.reader.bytes);
    peer = .{ .session = 1, .epoch = 1, .sequence = 2, .operation = .close, .handle = handle };
    try expect(f.service.submit(&f.queues[1], 1, 20, &peer));
    try eq(@as(usize, 1), f.service.step(&f.queues).?);
    try expect(f.queues[1].responses.tryPopInto(&response));
    try eq(multi.Result.ok, response.result);
    var progress: client.Progress = .request;
    while (progress == .request) progress = try f.exchange();
    try eq(client.Progress.complete, progress);
}

test "invalid transfers and exhausted sequences stop the lane" {
    for ([_]usize{ 0, 513 }) |count| {
        var f = Fixture{};
        try f.init();
        try eq(client.Progress.request, try f.exchange());
        const response = multi.Response{ .session = 1, .epoch = 1, .sequence = 2, .result = .{ .transfer = .{ .transferred = count } } };
        try eq(client.Progress.stop_lane, f.reader.accept(&response, &f.req));
        for (f.out) |byte| try eq(@as(u8, 0), byte);
    }
    var reader = client.Reader{};
    var output: [8]u8 = undefined;
    var req = multi.Request{};
    try expect(reader.begin(1, 1, 0xfffffffe, "file", &output, &req));
    const response = multi.Response{ .session = 1, .epoch = 1, .sequence = 0xffffffff, .result = .{ .handle = .{ .session = 1, .token = 1 } } };
    try eq(client.Progress.stop_lane, reader.accept(&response, &req));
}
