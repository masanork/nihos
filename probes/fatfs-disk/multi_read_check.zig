//! Host-only integration of the chunked client with the real read-only FatFs adapter.
const std = @import("std");
const storage = @import("storage_vfs");
const multi = storage.multi;
const reader = storage.multi_reader;
const adapter = storage.fatfs;
extern fn host_backend_session() *adapter.Session;
extern fn host_backend_epoch() u64;
extern fn host_backend_reads() u32;
extern fn host_backend_fail_after(u32) void;
extern fn host_backend_remove() c_int;
extern fn host_test_failure([*:0]const u8) void;

fn check(mode: c_int, cluster_bytes: u32) !void {
    try std.testing.expect(cluster_bytes >= 512);
    var backend = adapter.Backend{ .session = host_backend_session(), .epoch = host_backend_epoch() };
    var service = multi.Service(adapter.Backend){};
    var issuer = multi.Issuer{};
    var queues: [2]multi.Queues = .{ .{}, .{} };
    var clients: [2]reader.Reader = .{ .{}, .{} };
    var requests: [2]multi.Request = .{ .{}, .{} };
    var outputs: [2][4096]u8 = .{ @splat(0xa5), @splat(0xa5) };
    var progress: [2]reader.Progress = .{ .request, .request };
    var outstanding: [2]bool = .{ false, false };
    var armed = false;
    const session = host_backend_epoch();
    try service.startReadOnly(&backend, session, &issuer);
    for (0..2) |i| {
        const epoch = try service.bind(i, @intCast(i + 1), &queues[i], .{ .read = true });
        try std.testing.expect(clients[i].begin(session, epoch, 0, if (i == 0) "fragment.bin" else "Memo.txt", &outputs[i], &requests[i]));
    }
    var steps: usize = 0;
    while (progress[0] == .request or progress[1] == .request) {
        steps += 1;
        try std.testing.expect(steps < 64);
        if (mode != 0 and !armed and clients[0].bytes >= 512 and progress[1] == .complete) {
            if (mode == 1) host_backend_fail_after(1) else try std.testing.expectEqual(@as(c_int, 0), host_backend_remove());
            armed = true;
        }
        for (0..2) |i| {
            if (progress[i] != .request or outstanding[i]) continue;
            try std.testing.expect(service.submit(&queues[i], i, @intCast(i + 1), &requests[i]));
            outstanding[i] = true;
        }
        const index = service.step(&queues) orelse return error.TestUnexpectedResult;
        var response = multi.Response{};
        try std.testing.expect(queues[index].responses.tryPopInto(&response));
        outstanding[index] = false;
        progress[index] = clients[index].accept(&response, &requests[index]);
        if (progress[index] == .stop_lane) break;
    }
    try std.testing.expectEqual(reader.Progress.complete, progress[1]);
    try std.testing.expectEqualStrings("nihos read-only fixture\n", outputs[1][0..clients[1].bytes]);
    if (mode != 0) {
        try std.testing.expect(armed);
        try std.testing.expectEqual(reader.Progress.stop_lane, progress[0]);
        for (outputs[0]) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
        const calls = host_backend_reads();
        try std.testing.expect(service.step(&queues) == null);
        try std.testing.expectEqual(calls, host_backend_reads());
    } else {
        try std.testing.expectEqual(reader.Progress.complete, progress[0]);
        try std.testing.expectEqual(@as(usize, 4096), clients[0].bytes);
        for (outputs[0], 0..) |byte, offset| {
            try std.testing.expectEqual(@as(u8, @intCast(0x30 + offset / cluster_bytes)), byte);
        }
    }
    try service.stop(&queues[0], 0, 1);
    try service.stop(&queues[1], 1, 2);
    if (mode == 1) {
        try std.testing.expectError(error.IoError, service.shutdown());
    } else try service.shutdown();
}
export fn nih_check_multi_read(inject: c_int, cluster_bytes: u32) callconv(.c) c_int {
    check(inject, cluster_bytes) catch |err| {
        host_test_failure(@errorName(err).ptr);
        return 1;
    };
    return 0;
}
