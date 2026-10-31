//! Caller-owned checkpoint store. No allocator, paths, MMIO or native mounting.
const std = @import("std");
const model = @import("checkpoint_model.zig");
const Callbacks = extern struct {
    context: ?*anyopaque,
    read: *const fn (?*anyopaque, u64, [*]u8, usize) callconv(.c) c_int,
    write: *const fn (?*anyopaque, u64, [*]const u8, usize) callconv(.c) c_int,
    sync: *const fn (?*anyopaque) callconv(.c) c_int,
};
const Device = struct {
    pub const capacity = 4 * 1024 * 1024;
    callbacks: Callbacks,
    pub fn read(self: *@This(), offset: u64, bytes: []u8) error{Io}!void {
        if (self.callbacks.read(self.callbacks.context, offset, bytes.ptr, bytes.len) != 0) return error.Io;
    }
    pub fn write(self: *@This(), offset: u64, bytes: []const u8) error{Io}!void {
        if (self.callbacks.write(self.callbacks.context, offset, bytes.ptr, bytes.len) != 0) return error.Io;
    }
    pub fn sync(self: *@This()) error{Io}!void {
        if (self.callbacks.sync(self.callbacks.context) != 0) return error.Io;
    }
};
const Store = model.Store(Device, .{ .leaf_pages = 2, .index_pages = 64, .reader_slots = 4 });
const State = struct {
    device: Device,
    store: Store = .{},
    scratch: model.ResizeScratch = .{},
    pins: [4]?model.Reader = @splat(null),
    tokens: [4]u32 = @splat(0),
    serial: u32 = 0,
};
fn state(raw: *anyopaque) *State {
    return @ptrCast(@alignCast(raw));
}
fn failure(err: model.Error) c_int {
    return switch (err) {
        error.NotFound => -2,
        error.NoSpace, error.ReaderLimit => -28,
        error.Busy => -16,
        error.Corrupt, error.Unformatted => -84,
        error.InvalidArgument, error.InvalidReader, error.GenerationExhausted => -22,
        else => -5,
    };
}
fn begin(s: *State) model.Error!void {
    if (!s.store.in_transaction) try s.store.begin();
}
fn value(s: *State, key: u32) model.Error!model.Value {
    return if (s.store.in_transaction) s.store.getStaged(key) else s.store.get(key);
}
pub export fn nih_store_size() usize {
    return @sizeOf(State);
}
pub export fn nih_store_alignment() usize {
    return @alignOf(State);
}
pub export fn nih_store_mount(raw: *anyopaque, bytes: usize, callbacks: *const Callbacks, format: c_int) c_int {
    if (@intFromPtr(raw) % @alignOf(State) != 0 or bytes < @sizeOf(State)) return -22;
    const s = state(raw);
    s.* = .{ .device = .{ .callbacks = callbacks.* } };
    if (format != 0) s.store.format(&s.device) catch |err| return failure(err) else s.store.recover(&s.device) catch |err| return failure(err);
    return 0;
}
pub export fn nih_store_stat(raw: *anyopaque, key: u32, size: *u64) c_int {
    size.* = (value(state(raw), key) catch |err| return failure(err)).length;
    return 0;
}
pub export fn nih_store_create(raw: *anyopaque, key: u32) c_int {
    const s = state(raw);
    if (value(s, key)) |_| return -16 else |err| {
        if (err != error.NotFound) return failure(err);
    }
    begin(s) catch |err| return failure(err);
    s.store.put(key, "") catch |err| return failure(err);
    return 0;
}
pub export fn nih_store_read(raw: *anyopaque, key: u32, offset: u64, out: [*]u8, bytes: usize) c_int {
    if (bytes > 4096) return -22;
    const s = state(raw);
    const n = (if (s.store.in_transaction) s.store.readStaged(key, offset, out[0..bytes]) else s.store.read(key, offset, out[0..bytes])) catch |err| return failure(err);
    return @intCast(n);
}
pub export fn nih_store_resize(raw: *anyopaque, key: u32, bytes: u64) c_int {
    if (bytes > 1024 * 1024) return -28;
    const s = state(raw);
    begin(s) catch |err| return failure(err);
    const v = value(s, key) catch |err| return failure(err);
    if (v.length == bytes) return 0;
    if (v.kind != .mapped) s.store.promoteMapped(key) catch |err| return failure(err);
    s.store.resizeMapped(key, bytes, &s.scratch) catch |err| return failure(err);
    return 0;
}
pub export fn nih_store_write(raw: *anyopaque, key: u32, offset: u64, data: [*]const u8, bytes: usize) c_int {
    if (bytes > 4096 or offset > 1024 * 1024 or bytes > 1024 * 1024 - offset) return -28;
    if (bytes == 0) return 0;
    const s = state(raw);
    const v = value(s, key) catch |err| return failure(err);
    const wanted = @max(v.length, offset + bytes);
    const resized = nih_store_resize(raw, key, wanted);
    if (resized != 0) return resized;
    var done: usize = 0;
    while (done < bytes) {
        const amount = @min(bytes - done, 4096 - (offset + done) % 4096);
        s.store.patchMappedPage(key, offset + done, data[done..][0..amount]) catch |err| return failure(err);
        done += amount;
    }
    return 0;
}
pub export fn nih_store_remove(raw: *anyopaque, key: u32) c_int {
    const s = state(raw);
    _ = value(s, key) catch |err| return failure(err);
    begin(s) catch |err| return failure(err);
    s.store.remove(key) catch |err| return failure(err);
    return 0;
}
pub export fn nih_store_sync(raw: *anyopaque) c_int {
    const s = state(raw);
    if (s.store.in_transaction) s.store.commit() catch |err| return failure(err) else s.device.sync() catch return -5;
    return 0;
}
pub export fn nih_store_rollback(raw: *anyopaque) c_int {
    const s = state(raw);
    if (s.store.in_transaction) s.store.rollback() catch |err| return failure(err);
    return 0;
}
pub export fn nih_store_snapshot(raw: *anyopaque, token: *u32) c_int {
    const s = state(raw);
    if (s.store.in_transaction) return -16;
    if (s.serial == std.math.maxInt(i32)) return -28;
    for (&s.pins, 0..) |*p, i| if (p.* == null) {
        p.* = s.store.pin() catch |err| return failure(err);
        s.serial += 1;
        s.tokens[i] = s.serial;
        token.* = s.serial;
        return 0;
    };
    return -28;
}
fn slot(s: *State, token: u32) ?usize {
    for (s.tokens, 0..) |t, i| if (t == token and token != 0 and s.pins[i] != null) return i;
    return null;
}
pub export fn nih_store_release(raw: *anyopaque, token: u32) c_int {
    const s = state(raw);
    const i = slot(s, token) orelse return -22;
    s.store.release(s.pins[i].?) catch |err| return failure(err);
    s.pins[i] = null;
    return 0;
}
pub export fn nih_store_restore(raw: *anyopaque, token: u32) c_int {
    const s = state(raw);
    const i = slot(s, token) orelse return -22;
    s.store.restore(s.pins[i].?) catch |err| return failure(err);
    return 0;
}
pub export fn nih_store_snapshot_valid(raw: *anyopaque, token: u32) c_int {
    return if (slot(state(raw), token) != null) 0 else -22;
}
pub export fn nih_store_collect(raw: *anyopaque) c_int {
    const s = state(raw);
    _ = s.store.collectIndex() catch |err| return failure(err);
    s.store.collectPayload() catch |err| return failure(err);
    return 0;
}
pub export fn nih_store_generation(raw: *anyopaque) u64 {
    return state(raw).store.generation();
}
const Space = extern struct { capacity: u64, free_bytes: u64, largest_run: u64, index_free_bytes: u64 };
pub export fn nih_store_space(raw: *anyopaque, out: *Space) c_int {
    const s = state(raw);
    const payload = s.store.payloadSpace() catch |err| return failure(err);
    const index = s.store.indexSpace() catch |err| return failure(err);
    out.* = .{ .capacity = Device.capacity, .free_bytes = payload.free_pages * 4096, .largest_run = payload.largest_run * 4096, .index_free_bytes = @as(u64, index.available_pages) * 4096 };
    return 0;
}
pub export fn nih_store_verify(raw: *anyopaque, key: u32) c_int {
    state(raw).store.verify(key) catch |err| return failure(err);
    return 0;
}
