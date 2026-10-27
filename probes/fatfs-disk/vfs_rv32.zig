//! Compile-only: instantiate the actual VFS and FatFs adapter for RV32.
const support = @import("storage_vfs");
const adapter = support.fatfs;
const RpcOwner = support.rpc.Owner(adapter.Backend);
pub const panic = @import("std").debug.no_panic;
// Compile-only layout measurement symbol; never linked into the native image.
export var nih_fatfs_vfs_layout: [@sizeOf(adapter.vfs.Vfs(adapter.Backend, 1, 32))]u8 = @splat(0);
export var nih_fatfs_rpc_layout: [@sizeOf(RpcOwner)]u8 = @splat(0);
export var nih_fatfs_queues_layout: [@sizeOf(support.rpc.Queues)]u8 = @splat(0);
export var nih_fatfs_notifications_layout: [@sizeOf(support.rpc.Notifications)]u8 = @splat(0);
export var nih_fatfs_request_layout: [@sizeOf(support.rpc.Request)]u8 = @splat(0);
export var nih_fatfs_response_layout: [@sizeOf(support.rpc.Response)]u8 = @splat(0);
export var nih_fatfs_parent_control_layout: [@sizeOf(support.memory.Parent)]u8 = @splat(0);
export var nih_fatfs_client_frames_layout: [@sizeOf(support.rpc.ClientFrames)]u8 = @splat(0);
export fn nih_rpc_compile_contract(endpoint: *RpcOwner, queues: *support.rpc.Queues) callconv(.c) u32 {
    return @intFromBool(endpoint.step(queues));
}
export fn nih_rpc_exit_contract(n: *support.rpc.Notifications, client: u32, epoch: u32) callconv(.c) u32 {
    return @intFromBool(n.notifyExit(client, epoch));
}
export fn nih_rpc_cancel_contract(n: *support.rpc.Notifications, client: u32, epoch: u32, sequence: u32) callconv(.c) u32 {
    return @intFromBool(n.cancelRead(client, epoch, sequence));
}
export fn nih_parent_reserve_contract(manager: *support.development.Manager, owner: *const support.development.api.Owner, parent: *support.memory.Parent) callconv(.c) u32 {
    parent.* = support.memory.Parent.reserve(manager, owner.*) catch return 0;
    return 1;
}
extern fn nih_fatfs_backend_destroy(*adapter.Session, u64) c_int;
export fn nih_parent_retire_contract(manager: *support.development.Manager, parent: *support.memory.Parent, endpoint: *RpcOwner, queues: *support.rpc.Queues, session: *adapter.Session, epoch: u64) callconv(.c) u32 {
    const Lifetime = struct {
        session: *adapter.Session,
        epoch: u64,
        pub fn destroy(self: @This()) error{Busy}!void {
            if (nih_fatfs_backend_destroy(self.session, self.epoch) != 0) return error.Busy;
        }
    };
    const lease = parent.retire(manager, endpoint, queues, Lifetime{ .session = session, .epoch = epoch }) catch return 0;
    manager.free(lease.owner, lease) catch return 0;
    return 1;
}
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
