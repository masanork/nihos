//! Compile-only address-width contract; external media functions are not drivers.
const checkpoint = @import("checkpoint_model");
extern fn checkpoint_media_read(offset: u64, bytes: [*]u8, length: usize) c_int;
extern fn checkpoint_media_write(offset: u64, bytes: [*]const u8, length: usize) c_int;
extern fn checkpoint_media_sync() c_int;
const Device = struct {
    pub const capacity: u64 = 16 * 1024 * 1024 * 1024;
    pub fn read(_: *@This(), offset: u64, bytes: []u8) error{Io}!void {
        if (checkpoint_media_read(offset, bytes.ptr, bytes.len) != 0) return error.Io;
    }
    pub fn write(_: *@This(), offset: u64, bytes: []const u8) error{Io}!void {
        if (checkpoint_media_write(offset, bytes.ptr, bytes.len) != 0) return error.Io;
    }
    pub fn sync(_: *@This()) error{Io}!void {
        if (checkpoint_media_sync() != 0) return error.Io;
    }
};
const Store = checkpoint.Store(Device, .{});
var device = Device{};
var store = Store{};
comptime {
    if (@sizeOf(usize) != 4 or @sizeOf(Store) > 16 * 1024) @compileError("expected RV32 with a bounded descriptor");
}
pub export const checkpoint_probe_state_bytes: u32 = @sizeOf(Store);
pub export fn checkpoint_probe_format() c_int {
    store.format(&device) catch return -1;
    return 0;
}
pub export fn checkpoint_probe_recover() c_int {
    store.recover(&device) catch return -1;
    return 0;
}
pub export fn checkpoint_probe_begin() c_int {
    store.begin() catch return -1;
    return 0;
}
pub export fn checkpoint_probe_put(key: u32, bytes: [*]const u8, length: usize) c_int {
    store.put(key, bytes[0..length]) catch return -1;
    return 0;
}
pub export fn checkpoint_probe_remove(key: u32) c_int {
    store.remove(key) catch return -1;
    return 0;
}
pub export fn checkpoint_probe_commit() c_int {
    store.commit() catch return -1;
    return 0;
}
pub export fn checkpoint_probe_read(key: u32, offset: u64, bytes: [*]u8, length: usize) c_int {
    _ = store.read(key, offset, bytes[0..length]) catch return -1;
    return 0;
}
