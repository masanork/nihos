//! Host integration of the native owner's mailbox with the real store ABI.
const std = @import("std");
const mailbox = @import("platform/native/sqld_ime_mailbox.zig");
const store = @import("storage/store_abi.zig");
const Media = struct {
    bytes: []u8,
    fn read(ctx: ?*anyopaque, offset: u64, out: [*]u8, count: usize) callconv(.c) c_int {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        if (offset > self.bytes.len or count > self.bytes.len - @as(usize, @intCast(offset))) return -1;
        @memcpy(out[0..count], self.bytes[@intCast(offset)..][0..count]);
        return 0;
    }
    fn write(ctx: ?*anyopaque, offset: u64, data: [*]const u8, count: usize) callconv(.c) c_int {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        if (offset > self.bytes.len or count > self.bytes.len - @as(usize, @intCast(offset))) return -1;
        @memcpy(self.bytes[@intCast(offset)..][0..count], data[0..count]);
        return 0;
    }
    fn sync(_: ?*anyopaque) callconv(.c) c_int {
        return 0;
    }
};
const Callbacks = extern struct {
    context: ?*anyopaque,
    read: *const fn (?*anyopaque, u64, [*]u8, usize) callconv(.c) c_int,
    write: *const fn (?*anyopaque, u64, [*]const u8, usize) callconv(.c) c_int,
    sync: *const fn (?*anyopaque) callconv(.c) c_int,
};
const Backend = struct {
    raw: *anyopaque,
    pub fn pin(self: @This(), key: u32, token: *u32, length: *u64) i32 {
        return store.nih_store_pin_object(self.raw, key, token, length);
    }
    pub fn read(self: @This(), token: u32, offset: u64, out: []u8) i32 {
        return store.nih_store_read_object(self.raw, token, offset, out.ptr, out.len);
    }
    pub fn release(self: @This(), token: u32) i32 {
        return store.nih_store_release(self.raw, token);
    }
};

test "owner mailbox reads the pinned real store version" {
    const alloc = std.testing.allocator;
    const bytes = try alloc.alloc(u8, 4 * 1024 * 1024);
    defer alloc.free(bytes);
    @memset(bytes, 0xff);
    var media = Media{ .bytes = bytes };
    const memory = try alloc.alignedAlloc(u8, .@"16", store.nih_store_size());
    defer alloc.free(memory);
    const raw: *anyopaque = @ptrCast(memory.ptr);
    const callbacks = Callbacks{ .context = &media, .read = Media.read, .write = Media.write, .sync = Media.sync };
    try std.testing.expectEqual(@as(c_int, 0), store.nih_store_mount(raw, memory.len, @ptrCast(&callbacks), 1));
    try std.testing.expectEqual(@as(c_int, 0), store.nih_store_create(raw, mailbox.dictionary_key));
    try std.testing.expectEqual(@as(c_int, 0), store.nih_store_write(raw, mailbox.dictionary_key, 0, "old", 3));
    try std.testing.expectEqual(@as(c_int, 0), store.nih_store_sync(raw));
    var box: mailbox.Mailbox = .{};
    const backend = Backend{ .raw = raw };
    var q = mailbox.Request{ .operation = 1 };
    var r: mailbox.Response = .{};
    try std.testing.expectEqual(@as(i32, 0), box.submit(&q));
    try std.testing.expect(box.service(backend, true));
    try std.testing.expectEqual(@as(i32, 1), box.take(&r));
    try std.testing.expectEqual(@as(i32, 0), r.status);
    try std.testing.expectEqual(@as(c_int, 0), store.nih_store_write(raw, mailbox.dictionary_key, 0, "new", 3));
    try std.testing.expectEqual(@as(c_int, 0), store.nih_store_sync(raw));
    q = .{ .operation = 2, .length = 3 };
    try std.testing.expectEqual(@as(i32, 0), box.submit(&q));
    try std.testing.expect(box.service(backend, true));
    try std.testing.expectEqual(@as(i32, 1), box.take(&r));
    try std.testing.expectEqual(@as(i32, 0), r.status);
    try std.testing.expectEqualStrings("old", r.bytes[0..r.length]);
    q = .{ .operation = 3 };
    try std.testing.expectEqual(@as(i32, 0), box.submit(&q));
    try std.testing.expect(box.service(backend, true));
    try std.testing.expectEqual(@as(i32, 1), box.take(&r));
    try std.testing.expectEqual(@as(i32, 0), r.status);
}
