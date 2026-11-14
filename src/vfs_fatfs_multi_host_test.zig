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
        if (nih_multi_fixture_write(@intCast(token - 1), offset, data.ptr, @intCast(data.len)) != 0) return .{ .failure = .outcome_unknown };
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
    try service.start(&backend);
    var handles: [2]api.Handle = undefined;
    for (0..2) |i| {
        _ = try service.bind(i, @intCast(i + 1), &queues[i]);
        if (i == 1) {
            var conflict = multi.Request{ .epoch = 1, .sequence = 1, .operation = .open, .path_length = 5 };
            @memcpy(conflict.path[0..5], "a.txt");
            try std.testing.expect(service.submit(&queues[i], i, 2, &conflict));
            try std.testing.expectEqual(i, service.step(&queues).?);
            var rejected = multi.Response{};
            try std.testing.expect(queues[i].responses.tryPopInto(&rejected));
            try std.testing.expectEqual(api.Error.Busy, rejected.result.failure);
        }
        var request = multi.Request{ .epoch = 1, .sequence = if (i == 0) 1 else 2, .operation = .open, .path_length = 5 };
        @memcpy(request.path[0..5], if (i == 0) "a.txt" else "b.txt");
        try std.testing.expect(service.submit(&queues[i], i, @intCast(i + 1), &request));
        try std.testing.expectEqual(i, service.step(&queues).?);
        var response = multi.Response{};
        try std.testing.expect(queues[i].responses.tryPopInto(&response));
        handles[i] = response.result.handle;
    }
    for (0..2) |i| {
        var request = multi.Request{ .epoch = 1, .sequence = if (i == 0) 2 else 3, .operation = .write, .handle = handles[i], .length = 4 };
        @memcpy(request.data[0..4], if (i == 0) "one!" else "two!");
        try std.testing.expect(service.submit(&queues[i], i, @intCast(i + 1), &request));
        try std.testing.expectEqual(i, service.step(&queues).?);
        var response = multi.Response{};
        try std.testing.expect(queues[i].responses.tryPopInto(&response));
        try std.testing.expectEqual(@as(usize, 4), response.result.transfer.transferred);
        request = .{ .epoch = 1, .sequence = if (i == 0) 3 else 4, .operation = .sync, .handle = handles[i] };
        try std.testing.expect(service.submit(&queues[i], i, @intCast(i + 1), &request));
        try std.testing.expectEqual(i, service.step(&queues).?);
        try std.testing.expect(queues[i].responses.tryPopInto(&response));
        try std.testing.expectEqual(multi.Result.ok, response.result);
    }
    try service.stop(&queues[0], 0, 1);
    try service.stop(&queues[1], 1, 2);
    try std.testing.expectEqual(@as(c_int, 0), nih_multi_fixture_remount_check());
}
