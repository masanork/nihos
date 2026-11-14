//! Host-only bridge to an isolated writable FatFs fixture.
const std = @import("std");
const multi = @import("fs/vfs_multi_writer.zig");
const api = @import("fs/vfs.zig");
extern fn nih_multi_fixture_init() c_int;
extern fn nih_multi_fixture_open(c_uint) c_int;
extern fn nih_multi_fixture_write(c_uint, c_ulonglong, [*]const u8, c_uint) c_int;
extern fn nih_multi_fixture_sync(c_uint) c_int;
extern fn nih_multi_fixture_close(c_uint) c_int;
extern fn nih_multi_fixture_remount_check() c_int;
extern fn nih_multi_fixture_destroy() void;
const Backend = struct {
    pub fn lookupBeneath(_: *@This(), _: u64, path: []const u8) api.Error!u64 {
        if (std.mem.eql(u8, path, "a.txt")) return 1;
        if (std.mem.eql(u8, path, "b.txt")) return 2;
        return error.NotFound;
    }
    pub fn open(_: *@This(), id: u64, _: api.Rights) api.Error!u64 {
        if (nih_multi_fixture_open(@intCast(id - 1)) != 0) return error.IoError;
        return id;
    }
    pub fn close(_: *@This(), token: u64) api.Error!void {
        if (nih_multi_fixture_close(@intCast(token - 1)) != 0) return error.IoError;
    }
    pub fn readAt(_: *@This(), _: u64, _: u64, _: []u8) api.Transfer {
        unreachable;
    }
    pub fn writeAt(_: *@This(), token: u64, offset: u64, data: []const u8) api.Transfer {
        const status = nih_multi_fixture_write(@intCast(token - 1), offset, data.ptr, @intCast(data.len));
        if (status != 0) return .{ .failure = if (status == -2) .removed else .outcome_unknown };
        return .{ .transferred = data.len };
    }
    pub fn syncFile(_: *@This(), token: u64) api.Error!void {
        if (nih_multi_fixture_sync(@intCast(token - 1)) != 0) return error.IoError;
    }
    pub fn syncVolume(_: *@This(), _: u64) api.Error!void {}
};
test "serialized multi-client writes survive FatFs sync and remount on host fixture" {
    try std.testing.expectEqual(@as(c_int, 0), nih_multi_fixture_init());
    defer nih_multi_fixture_destroy();
    var backend = Backend{};
    var service = multi.Service(Backend){};
    var queues: [2]multi.Queues = .{ .{}, .{} };
    try service.start(&backend, 1);
    var handles: [2]multi.Handle = undefined;
    for (0..2) |i| {
        _ = try service.bind(i, @intCast(i + 1), &queues[i]);
        if (i == 1) {
            var conflict = multi.Request{ .session = 1, .epoch = 1, .sequence = 1, .operation = .open, .path_length = 5 };
            @memcpy(conflict.path[0..5], "a.txt");
            try std.testing.expect(service.submit(&queues[i], i, 2, &conflict));
            try std.testing.expectEqual(i, service.step(&queues).?);
            var rejected = multi.Response{};
            try std.testing.expect(queues[i].responses.tryPopInto(&rejected));
            try std.testing.expectEqual(api.Error.Busy, rejected.result.failure);
        }
        var request = multi.Request{ .session = 1, .epoch = 1, .sequence = if (i == 0) 1 else 2, .operation = .open, .path_length = 5 };
        @memcpy(request.path[0..5], if (i == 0) "a.txt" else "b.txt");
        try std.testing.expect(service.submit(&queues[i], i, @intCast(i + 1), &request));
        try std.testing.expectEqual(i, service.step(&queues).?);
        var response = multi.Response{};
        try std.testing.expect(queues[i].responses.tryPopInto(&response));
        handles[i] = response.result.handle;
    }
    for (0..2) |i| {
        var request = multi.Request{ .session = 1, .epoch = 1, .sequence = if (i == 0) 2 else 3, .operation = .write, .handle = handles[i], .length = 4 };
        @memcpy(request.data[0..4], if (i == 0) "one!" else "two!");
        try std.testing.expect(service.submit(&queues[i], i, @intCast(i + 1), &request));
        try std.testing.expectEqual(i, service.step(&queues).?);
        var response = multi.Response{};
        try std.testing.expect(queues[i].responses.tryPopInto(&response));
        try std.testing.expectEqual(@as(usize, 4), response.result.transfer.transferred);
        request = .{ .session = 1, .epoch = 1, .sequence = if (i == 0) 3 else 4, .operation = .sync, .handle = handles[i] };
        try std.testing.expect(service.submit(&queues[i], i, @intCast(i + 1), &request));
        try std.testing.expectEqual(i, service.step(&queues).?);
        try std.testing.expect(queues[i].responses.tryPopInto(&response));
        try std.testing.expectEqual(multi.Result.ok, response.result);
    }
    try service.stop(&queues[0], 0, 1);
    try service.stop(&queues[1], 1, 2);
    try std.testing.expectEqual(@as(c_int, 0), nih_multi_fixture_remount_check());
}

extern fn nih_multi_fixture_arm(c_uint) void;
extern fn nih_multi_fixture_triggered() c_uint;
extern fn nih_multi_fixture_writes() c_ulonglong;
extern fn nih_multi_fixture_open_mask() c_uint;

test "FatFs write and sync failures quarantine both endpoints" {
    for (1..5) |mode| {
        try std.testing.expectEqual(@as(c_int, 0), nih_multi_fixture_init());
        defer nih_multi_fixture_destroy();
        var backend = Backend{};
        var service = multi.Service(Backend){};
        var queues: [2]multi.Queues = .{ .{}, .{} };
        var handles: [2]multi.Handle = undefined;
        try service.start(&backend, 1);
        for (0..2) |i| {
            _ = try service.bind(i, @intCast(i + 1), &queues[i]);
            var request = multi.Request{ .session = 1, .epoch = 1, .sequence = 1, .operation = .open, .path_length = 5 };
            @memcpy(request.path[0..5], if (i == 0) "a.txt" else "b.txt");
            try std.testing.expect(service.submit(&queues[i], i, @intCast(i + 1), &request));
            try std.testing.expectEqual(i, service.step(&queues).?);
            var response = multi.Response{};
            try std.testing.expect(queues[i].responses.tryPopInto(&response));
            handles[i] = response.result.handle;
        }
        if (mode >= 3) {
            var write = multi.Request{ .session = 1, .epoch = 1, .sequence = 2, .operation = .write, .handle = handles[0], .length = 4 };
            @memcpy(write.data[0..4], "data");
            try std.testing.expect(service.submit(&queues[0], 0, 1, &write));
            try std.testing.expectEqual(@as(usize, 0), service.step(&queues).?);
            var response = multi.Response{};
            try std.testing.expect(queues[0].responses.tryPopInto(&response));
            try std.testing.expectEqual(@as(usize, 4), response.result.transfer.transferred);
            var peer_sync = multi.Request{ .session = 1, .epoch = 1, .sequence = 2, .operation = .sync, .handle = handles[1] };
            try std.testing.expect(service.submit(&queues[1], 1, 2, &peer_sync));
            try std.testing.expectEqual(@as(usize, 1), service.step(&queues).?);
            try std.testing.expect(queues[1].responses.tryPopInto(&response));
            try std.testing.expectEqual(multi.Result.ok, response.result);
        }
        var pending = multi.Request{ .session = 1, .epoch = 1, .sequence = if (mode >= 3) 3 else 2, .operation = .sync, .handle = handles[1] };
        try std.testing.expect(service.submit(&queues[1], 1, 2, &pending));
        var request = multi.Request{ .session = 1, .epoch = 1, .sequence = if (mode >= 3) 3 else 2, .operation = if (mode >= 3) .sync else .write, .handle = handles[0], .length = if (mode >= 3) 0 else 4096 };
        @memset(&request.data, 0x5a);
        nih_multi_fixture_arm(@intCast(mode));
        try std.testing.expect(service.submit(&queues[0], 0, 1, &request));
        try std.testing.expectEqual(@as(usize, 0), service.step(&queues).?);
        try std.testing.expectEqual(@as(c_uint, @intCast(mode)), nih_multi_fixture_triggered());
        var failed = multi.Response{};
        try std.testing.expect(queues[0].responses.tryPopInto(&failed));
        if (mode < 3) {
            try std.testing.expectEqual(api.Failure.outcome_unknown, failed.result.transfer.failure.?);
        } else {
            try std.testing.expectEqual(api.Error.IoError, failed.result.failure);
        }
        try std.testing.expect(service.faulted);
        const writes = nih_multi_fixture_writes();
        try std.testing.expect(service.step(&queues) == null);
        try std.testing.expectEqual(@as(usize, 1), queues[1].requests.countApprox());
        try std.testing.expect(!service.submit(&queues[1], 1, 2, &pending));
        try std.testing.expectEqual(writes, nih_multi_fixture_writes());
    }
}

test "client exit releases only its FatFs handle and peer can finish" {
    try std.testing.expectEqual(@as(c_int, 0), nih_multi_fixture_init());
    defer nih_multi_fixture_destroy();
    var backend = Backend{};
    var service = multi.Service(Backend){};
    var queues: [2]multi.Queues = .{ .{}, .{} };
    var handles: [2]multi.Handle = undefined;
    try service.start(&backend, 1);
    for (0..2) |i| {
        _ = try service.bind(i, @intCast(i + 1), &queues[i]);
        var request = multi.Request{ .session = 1, .epoch = 1, .sequence = 1, .operation = .open, .path_length = 5 };
        @memcpy(request.path[0..5], if (i == 0) "a.txt" else "b.txt");
        try std.testing.expect(service.submit(&queues[i], i, @intCast(i + 1), &request));
        try std.testing.expectEqual(i, service.step(&queues).?);
        var response = multi.Response{};
        try std.testing.expect(queues[i].responses.tryPopInto(&response));
        handles[i] = response.result.handle;
    }
    try service.stop(&queues[0], 0, 1);
    var request = multi.Request{ .session = 1, .epoch = 1, .sequence = 2, .operation = .write, .handle = handles[1], .length = 4 };
    @memcpy(request.data[0..4], "peer");
    try std.testing.expect(service.submit(&queues[1], 1, 2, &request));
    try std.testing.expectEqual(@as(usize, 1), service.step(&queues).?);
    var response = multi.Response{};
    try std.testing.expect(queues[1].responses.tryPopInto(&response));
    try std.testing.expectEqual(@as(usize, 4), response.result.transfer.transferred);
    request = .{ .session = 1, .epoch = 1, .sequence = 3, .operation = .sync, .handle = handles[1] };
    try std.testing.expect(service.submit(&queues[1], 1, 2, &request));
    try std.testing.expectEqual(@as(usize, 1), service.step(&queues).?);
    try std.testing.expect(queues[1].responses.tryPopInto(&response));
    try std.testing.expectEqual(multi.Result.ok, response.result);
    try service.stop(&queues[1], 1, 2);
}

test "simulated media removal during FatFs write halts peer and skips backend close" {
    for (5..7) |mode| {
        try std.testing.expectEqual(@as(c_int, 0), nih_multi_fixture_init());
        defer nih_multi_fixture_destroy();
        var backend = Backend{};
        var service = multi.Service(Backend){};
        var queues: [2]multi.Queues = .{ .{}, .{} };
        var handles: [2]multi.Handle = undefined;
        try service.start(&backend, 1);
        for (0..2) |i| {
            _ = try service.bind(i, @intCast(i + 1), &queues[i]);
            var request = multi.Request{ .session = 1, .epoch = 1, .sequence = 1, .operation = .open, .path_length = 5 };
            @memcpy(request.path[0..5], if (i == 0) "a.txt" else "b.txt");
            try std.testing.expect(service.submit(&queues[i], i, @intCast(i + 1), &request));
            try std.testing.expectEqual(i, service.step(&queues).?);
            var response = multi.Response{};
            try std.testing.expect(queues[i].responses.tryPopInto(&response));
            handles[i] = response.result.handle;
        }
        var pending = multi.Request{ .session = 1, .epoch = 1, .sequence = 2, .operation = .sync, .handle = handles[1] };
        try std.testing.expect(service.submit(&queues[1], 1, 2, &pending));
        var request = multi.Request{ .session = 1, .epoch = 1, .sequence = 2, .operation = .write, .handle = handles[0], .length = 4096 };
        @memset(&request.data, 0x61);
        nih_multi_fixture_arm(@intCast(mode));
        try std.testing.expect(service.submit(&queues[0], 0, 1, &request));
        try std.testing.expectEqual(@as(usize, 0), service.step(&queues).?);
        try std.testing.expectEqual(@as(c_uint, @intCast(mode)), nih_multi_fixture_triggered());
        var response = multi.Response{};
        try std.testing.expect(queues[0].responses.tryPopInto(&response));
        try std.testing.expectEqual(api.Failure.removed, response.result.transfer.failure.?);
        try std.testing.expect(service.faulted);
        try std.testing.expect(service.step(&queues) == null);
        const writes = nih_multi_fixture_writes();
        try service.stop(&queues[0], 0, 1);
        try service.stop(&queues[1], 1, 2);
        try std.testing.expectEqual(@as(c_uint, 3), nih_multi_fixture_open_mask());
        try std.testing.expectEqual(writes, nih_multi_fixture_writes());
        try std.testing.expectEqual(@as(usize, 0), queues[1].requests.countApprox());
    }
}
