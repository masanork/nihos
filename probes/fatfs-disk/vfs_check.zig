const std = @import("std");
const adapter = @import("fatfs_backend");
const api = adapter.vfs;
extern fn host_backend_session() *adapter.Session;
extern fn host_backend_epoch() u64;
extern fn host_backend_reads() u32;
extern fn host_backend_fail_after(u32) void;
extern fn host_backend_remove() c_int;
extern fn host_backend_rebind() c_int;
extern fn host_test_failure([*:0]const u8) void;
const read = api.Rights{ .read = true };

fn check() !void {
    var backend = adapter.Backend{ .session = host_backend_session(), .epoch = host_backend_epoch() };
    var core = api.Vfs(adapter.Backend, 1, 32){};
    const mount = try core.mount(&backend, 1, .{}, .{});
    const root = try core.grantRoot(mount, 42, read);
    const before = host_backend_reads();
    try std.testing.expectError(error.PermissionDenied, core.openAt(7, root, "Memo.txt", read));
    try std.testing.expectError(error.InvalidName, core.openAt(42, root, "../Memo.txt", read));
    try std.testing.expectError(error.PermissionDenied, core.openAt(42, root, "Memo.txt", .{ .write = true }));
    try std.testing.expectEqual(before, host_backend_reads());
    const file = try core.openAt(42, root, "Memo.txt", read);
    const alias = try core.openAt(42, root, "MEMO.TXT", read);
    var bytes: [4096]u8 = @splat(0xa5);
    const result = try core.readAt(42, file, 0, &bytes);
    try std.testing.expectEqualStrings("nihos read-only fixture\n", bytes[0..result.transferred]);
    try std.testing.expect(result.eof and result.failure == null);
    try core.close(42, file);
    try std.testing.expectError(error.StaleHandle, core.readAt(42, file, 0, &bytes));
    try core.close(42, alias);
    const fragment = try core.openAt(42, root, "fragment.bin", read);
    bytes = @splat(0xa5);
    host_backend_fail_after(2);
    const failed = try core.readAt(42, fragment, 0, &bytes);
    try std.testing.expectEqual(@as(usize, 0), failed.transferred);
    try std.testing.expectEqual(api.Failure.io_error, failed.failure.?);
    for (bytes) |byte| try std.testing.expectEqual(@as(u8, 0xa5), byte);
    try std.testing.expectEqual(api.State.faulted, (try core.queryMount(mount)).state);
    const after = host_backend_reads();
    try std.testing.expectError(error.RecoveryRequired, core.openAt(42, root, "Memo.txt", read));
    try std.testing.expectError(error.RecoveryRequired, core.readAt(42, fragment, 0, &bytes));
    try std.testing.expectEqual(after, host_backend_reads());
    try core.detachQuiescent(mount);
    try std.testing.expectError(error.StaleHandle, core.readAt(42, fragment, 0, &bytes));
    // Destroy private tokens only after VFS revocation, then bind a new epoch.
    try std.testing.expectEqual(@as(c_int, 0), host_backend_rebind());
    const reads = host_backend_reads();
    try std.testing.expectError(error.StaleHandle, backend.lookupBeneath(1, "Memo.txt"));
    try std.testing.expectEqual(reads, host_backend_reads());
    var replacement = adapter.Backend{ .session = host_backend_session(), .epoch = host_backend_epoch() };
    const fresh_mount = try core.mount(&replacement, 1, .{}, .{});
    try std.testing.expect(mount.slot == fresh_mount.slot and mount.generation != fresh_mount.generation);
    try std.testing.expectError(error.StaleHandle, core.openAt(42, root, "Memo.txt", read));
    const fresh_root = try core.grantRoot(fresh_mount, 42, read);
    const fresh_file = try core.openAt(42, fresh_root, "Memo.txt", read);
    const fresh = try core.readAt(42, fresh_file, 0, bytes[0..1]);
    try std.testing.expectEqual(@as(usize, 1), fresh.transferred);
    bytes = @splat(0xa5);
    const cached_reads = host_backend_reads();
    try std.testing.expectEqual(@as(c_int, 0), host_backend_remove());
    const removed = try core.readAt(42, fresh_file, 0, bytes[0..1]);
    try std.testing.expectEqual(api.Failure.removed, removed.failure.?);
    try std.testing.expectEqual(@as(usize, 0), removed.transferred);
    try std.testing.expectEqual(@as(u8, 0xa5), bytes[0]);
    try std.testing.expectEqual(cached_reads, host_backend_reads());
    try std.testing.expectEqual(api.State.removed, (try core.queryMount(fresh_mount)).state);
    try core.detachQuiescent(fresh_mount);
}
export fn nih_check_vfs() callconv(.c) c_int {
    check() catch |err| {
        host_test_failure(@errorName(err).ptr);
        return 1;
    };
    return 0;
}
