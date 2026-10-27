//! Compile-only: instantiate the actual VFS and FatFs adapter for RV32.
const adapter = @import("fatfs_backend");
// Compile-only layout measurement symbol; never linked into the native image.
export var nih_fatfs_vfs_layout: [@sizeOf(adapter.vfs.Vfs(adapter.Backend, 1, 32))]u8 = @splat(0);
export fn nih_fatfs_vfs_contract(session: *adapter.Session, epoch: u64) callconv(.c) u32 {
    var backend = adapter.Backend{ .session = session, .epoch = epoch };
    var core = adapter.vfs.Vfs(adapter.Backend, 1, 32){};
    const mount = core.mount(&backend, 1, .{}, .{}) catch return 0;
    const root = core.grantRoot(mount, 42, .{ .read = true }) catch return 0;
    const file = core.openAt(42, root, "Memo.txt", .{ .read = true }) catch return 0;
    var bytes: [512]u8 = @splat(0);
    const result = core.readAt(42, file, 0, &bytes) catch return 0;
    core.close(42, file) catch return 0;
    core.close(42, root) catch return 0;
    core.unmount(mount) catch return 0;
    return @intCast(result.transferred);
}
