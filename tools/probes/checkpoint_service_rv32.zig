//! Compile-only service ownership/queue layout; external functions are not drivers.
const api = @import("checkpoint_service");
const model = api.model;
extern fn service_media_read(offset: u64, bytes: [*]u8, length: usize) c_int;
extern fn service_media_write(offset: u64, bytes: [*]const u8, length: usize) c_int;
extern fn service_media_sync() c_int;
const Device = struct {
    pub const capacity: u64 = 16 * 1024 * 1024 * 1024;
    pub fn read(_: *@This(), offset: u64, bytes: []u8) error{Io}!void {
        if (service_media_read(offset, bytes.ptr, bytes.len) != 0) return error.Io;
    }
    pub fn write(_: *@This(), offset: u64, bytes: []const u8) error{Io}!void {
        if (service_media_write(offset, bytes.ptr, bytes.len) != 0) return error.Io;
    }
    pub fn sync(_: *@This()) error{Io}!void {
        if (service_media_sync() != 0) return error.Io;
    }
};
const Store = model.Store(Device, .{ .leaf_cache_pages = 128 });
const Owner = api.Owner(Store);
const Queues = api.Queues(@import("spsc_ring"));
var store = Store{};
var device = Device{};
var queues = Queues{};
var owner = Owner{ .store = &store, .client = 11, .last_durable_generation = 0 };
comptime {
    if (@sizeOf(usize) != 4 or @sizeOf(Store) + @sizeOf(Owner) + @sizeOf(Queues) > 2 * 1024 * 1024) @compileError("service envelope exceeds its RV32 budget");
}
pub export const service_store_bytes: u32 = @sizeOf(Store);
pub export const service_owner_bytes: u32 = @sizeOf(Owner);
pub export const service_queues_bytes: u32 = @sizeOf(Queues);
pub export const service_request_bytes: u32 = @sizeOf(api.Request);
pub export const service_response_bytes: u32 = @sizeOf(api.Response);
pub export fn service_format() c_int {
    store.format(&device) catch return -1;
    owner = Owner.init(&store, 11) catch return -1;
    return 0;
}
pub export fn service_recover() c_int {
    store.recover(&device) catch return -1;
    owner = Owner.init(&store, 11) catch return -1;
    return 0;
}
pub export fn service_grant(key: u32, writable: bool, handle: *api.Handle) c_int {
    handle.* = owner.grant(key, writable) catch return -1;
    return 0;
}
pub export fn service_submit(request: *const api.Request) c_int {
    return if (queues.requests.tryPush(request.*)) 0 else -1;
}
pub export fn service_step() c_int {
    return @backingInt(owner.step(&queues, .{}));
}
pub export fn service_reply(reply: *api.Response) c_int {
    reply.* = queues.responses.tryPop() orelse return -1;
    return 0;
}
pub export fn service_exit(client: u64) c_int {
    return @backingInt(owner.clientExited(client, &queues) catch return -1);
}
pub export fn service_rebind(client: u64) c_int {
    return if (owner.rebind(client, &queues)) 0 else -1;
}
