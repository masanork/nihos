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
const CachedStore = checkpoint.Store(Device, .{ .leaf_cache_pages = 128 });
var device = Device{};
var store = Store{};
var cached_store = CachedStore{};
comptime {
    if (@sizeOf(usize) != 4 or @sizeOf(Store) > 32 * 1024) @compileError("expected RV32 with a bounded descriptor");
    if (@sizeOf(CachedStore) > 640 * 1024) @compileError("metadata cache exceeds its host experiment envelope");
}
pub export const checkpoint_probe_state_bytes: u32 = @sizeOf(Store);
pub export const checkpoint_probe_cached_state_bytes: u32 = @sizeOf(CachedStore);
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
pub export fn checkpoint_probe_verify(key: u32) c_int {
    store.verify(key) catch return -1;
    return 0;
}
pub export fn checkpoint_probe_collect_index() c_int {
    _ = store.collectIndex() catch return -1;
    return 0;
}
pub export fn checkpoint_probe_pin(slot: *u8, token: *u64) c_int {
    const reader = store.pin() catch return -1;
    slot.* = reader.slot;
    token.* = reader.token;
    return 0;
}
pub export fn checkpoint_probe_release(slot: u8, token: u64) c_int {
    store.release(.{ .slot = slot, .token = token }) catch return -1;
    return 0;
}
pub export fn checkpoint_probe_read_pinned(slot: u8, token: u64, key: u32, offset: u64, bytes: [*]u8, length: usize) c_int {
    _ = store.readPinned(.{ .slot = slot, .token = token }, key, offset, bytes[0..length]) catch return -1;
    return 0;
}
pub export fn checkpoint_probe_collect_payload() c_int {
    store.collectPayload() catch return -1;
    return 0;
}
pub export fn checkpoint_probe_payload_free() u64 {
    return (store.payloadSpace() catch return 0).free_pages;
}
pub export fn checkpoint_probe_cached_recover() c_int {
    cached_store.recover(&device) catch return -1;
    return 0;
}
pub export fn checkpoint_probe_cached_begin() c_int {
    cached_store.begin() catch return -1;
    return 0;
}
pub export fn checkpoint_probe_cached_search(pages: u64) c_int {
    cached_store.beginPayloadSearch(pages) catch return -1;
    return 0;
}
pub export fn checkpoint_probe_cached_step() c_int {
    return switch (cached_store.stepPayloadSearch(.{}) catch return -1) {
        .pending => 0,
        .found => 1,
        .no_space => 2,
        .space => 3,
    };
}
pub export fn checkpoint_probe_cached_put(key: u32, bytes: [*]const u8, length: usize) c_int {
    cached_store.putPrepared(key, bytes[0..length]) catch return -1;
    return 0;
}
pub export fn checkpoint_probe_cached_commit() c_int {
    cached_store.commit() catch return -1;
    return 0;
}
var stream: checkpoint.Stream = .{ .token = 0 };
pub export fn checkpoint_probe_stream_begin(key: u32, length: u64) c_int {
    stream = cached_store.beginStreamPrepared(key, length) catch return -1;
    return 0;
}
pub export fn checkpoint_probe_stream_write(bytes: [*]const u8, length: usize) c_int {
    _ = cached_store.writeStream(stream, bytes[0..length]) catch return -1;
    return 0;
}
pub export fn checkpoint_probe_stream_finish() c_int {
    cached_store.finishStream(stream) catch return -1;
    return 0;
}
pub export fn checkpoint_probe_stream_abort() c_int {
    cached_store.abortStream(stream) catch return -1;
    return 0;
}
pub export fn checkpoint_probe_patch_begin(key: u32, offset: u64, length: u64) c_int {
    stream = cached_store.beginPatchPrepared(key, offset, length) catch return -1;
    return 0;
}
pub export fn checkpoint_probe_patch_step(bytes: [*]const u8, length: usize) c_int {
    const progress = cached_store.stepPatch(stream, bytes[0..length]) catch return -1;
    return if (progress.done) 1 else 0;
}
