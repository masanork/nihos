const std = @import("std");
const file_media = @import("file_media.zig");
const model = @import("cow_model.zig");
const Io = std.Io;
const Device = file_media.Media(12 * 4096);
const Store = model.Store(Device, 8);
const io = std.testing.io;

fn fixture(dir: Io.Dir, name: []const u8, length: usize) !void {
    const file = try dir.createFile(io, name, .{ .read = true, .exclusive = true });
    defer file.close(io);
    const page: [4096]u8 = @splat(0xff);
    var position: usize = 0;
    while (position < length) {
        const n = @min(page.len, length - position);
        try file.writePositionalAll(io, page[0..n], position);
        position += n;
    }
    try file.sync(io);
}

test "file backend commits then closes and reopens without a media-sized RAM cache" {
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    try fixture(dir.dir, "store", Device.capacity);
    var device = try Device.open(io, dir.dir, "store");
    var store = try Store.format(&device);
    try store.begin();
    const payload: [5003]u8 = @splat(0x39);
    try store.put(1, &payload);
    try store.commit();
    try std.testing.expectEqual(@as(usize, 3), device.syncs);
    device.close();
    device = try Device.open(io, dir.dir, "store");
    defer device.close();
    var recovered = try Store.recover(&device);
    var buffer: [5003]u8 = undefined;
    try std.testing.expectEqual(@as(u64, 2), recovered.generation());
    try std.testing.expectEqual(buffer.len, try recovered.read(1, 0, &buffer));
    try std.testing.expectEqualSlices(u8, &payload, &buffer);
    try std.testing.expectEqual(@sizeOf(Device), @sizeOf(file_media.Media(16 * 1024 * 1024 * 1024)));
}

test "file backend rejects a second writer missing paths wrong size and symlinks" {
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    try std.testing.expectError(error.FileNotFound, Device.open(io, dir.dir, "missing"));
    try fixture(dir.dir, "short", 17);
    try std.testing.expectError(error.WrongSize, Device.open(io, dir.dir, "short"));
    const info = try dir.dir.statFile(io, "short", .{});
    try std.testing.expectEqual(@as(u64, 17), info.size);
    try fixture(dir.dir, "store", Device.capacity);
    var first = try Device.open(io, dir.dir, "store");
    defer first.close();
    try std.testing.expectError(error.WouldBlock, Device.open(io, dir.dir, "store"));
    first.close();
    try dir.dir.symLink(io, "store", "link", .{});
    try std.testing.expectError(error.SymLinkLoop, Device.open(io, dir.dir, "link"));
}

test "file backend treats a short read or out-of-range access as a terminal I/O fault" {
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    try fixture(dir.dir, "store", Device.capacity);
    var device = try Device.open(io, dir.dir, "store");
    defer device.close();
    try device.file.setLength(io, 1);
    var buffer: [512]u8 = undefined;
    try std.testing.expectError(error.Io, device.read(0, &buffer));
    try std.testing.expectError(error.Io, device.sync());
    try std.testing.expect(device.faulted);
    try fixture(dir.dir, "other", Device.capacity);
    var other = try Device.open(io, dir.dir, "other");
    defer other.close();
    try std.testing.expectError(error.Io, other.write(Device.capacity, &buffer));
    try std.testing.expect(other.faulted);
    other.close();
    try std.testing.expectError(error.Io, other.read(0, &buffer));
}

const FaultIo = struct {
    inner: Io,
    table: Io.VTable,
    fail_sync: bool = false,
    fail_write: bool = false,
    zero_write: bool = false,
    max_write: usize = 17,
    sync_calls: usize = 0,
    fail_on_sync: ?usize = null,

    fn init(inner: Io) FaultIo {
        var table = inner.vtable.*;
        table.fileClose = close;
        table.fileWritePositional = write;
        table.fileReadPositional = read;
        table.fileSync = sync;
        return .{ .inner = inner, .table = table };
    }
    fn context(self: *FaultIo) Io {
        return .{ .userdata = self, .vtable = &self.table };
    }
    fn close(raw: ?*anyopaque, files: []const Io.File) void {
        const self: *FaultIo = @ptrCast(@alignCast(raw));
        self.inner.vtable.fileClose(self.inner.userdata, files);
    }
    fn write(raw: ?*anyopaque, file: Io.File, header: []const u8, data: []const []const u8, splat: usize, offset: u64) Io.File.WritePositionalError!usize {
        const self: *FaultIo = @ptrCast(@alignCast(raw));
        if (self.fail_write) return error.InputOutput;
        if (self.zero_write) return 0;
        if (header.len != 0 or data.len != 1 or splat != 1) return error.InputOutput;
        const chunk = data[0][0..@min(self.max_write, data[0].len)];
        return self.inner.vtable.fileWritePositional(self.inner.userdata, file, &.{}, &.{chunk}, 1, offset);
    }
    fn read(raw: ?*anyopaque, file: Io.File, data: []const []u8, offset: u64) Io.File.ReadPositionalError!usize {
        const self: *FaultIo = @ptrCast(@alignCast(raw));
        return self.inner.vtable.fileReadPositional(self.inner.userdata, file, data, offset);
    }
    fn sync(raw: ?*anyopaque, file: Io.File) Io.File.SyncError!void {
        const self: *FaultIo = @ptrCast(@alignCast(raw));
        self.sync_calls += 1;
        if (self.fail_sync or self.fail_on_sync == self.sync_calls) return error.InputOutput;
        return self.inner.vtable.fileSync(self.inner.userdata, file);
    }
};

test "file backend completes partial writes and fails closed on zero progress write and sync errors" {
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    var data: [512]u8 = undefined;
    for (&data, 0..) |*byte, i| byte.* = @truncate(i *% 17 +% 0x73);
    for (0..4) |mode| {
        const name = try std.fmt.allocPrint(std.testing.allocator, "case{d}", .{mode});
        defer std.testing.allocator.free(name);
        try fixture(dir.dir, name, Device.capacity);
        var device = try Device.open(io, dir.dir, name);
        defer device.close();
        var fault = FaultIo.init(io);
        fault.zero_write = mode == 1;
        fault.fail_write = mode == 2;
        fault.fail_sync = mode == 3;
        device.io = fault.context();
        if (mode == 1 or mode == 2) {
            try std.testing.expectError(error.Io, device.write(0, &data));
        } else {
            try device.write(0, &data);
            try std.testing.expect(device.writes > 1);
            if (mode == 3) try std.testing.expectError(error.Io, device.sync()) else try device.sync();
            if (mode == 0) {
                var actual: [512]u8 = undefined;
                try device.read(0, &actual);
                try std.testing.expectEqualSlices(u8, &data, &actual);
            }
        }
        if (mode != 0) {
            try std.testing.expect(device.faulted);
            try std.testing.expectEqual(@as(usize, 0), device.syncs);
            try std.testing.expectError(error.Io, device.write(512, &data));
        }
    }
}

test "failed root sync never acknowledges a new store generation and recovery accepts only complete data" {
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    try fixture(dir.dir, "store", Device.capacity);
    var device = try Device.open(io, dir.dir, "store");
    defer device.close();
    var store = try Store.format(&device);
    var fault = FaultIo.init(io);
    fault.fail_on_sync = 2;
    device.io = fault.context();
    try store.begin();
    const data: [512]u8 = @splat(0x59);
    try store.put(1, &data);
    try std.testing.expectError(error.Io, store.commit());
    try std.testing.expectEqual(@as(u64, 1), store.generation());
    try std.testing.expectError(error.Faulted, store.begin());
    device.close();
    var reopened = try Device.open(io, dir.dir, "store");
    defer reopened.close();
    var recovered = try Store.recover(&reopened);
    if (recovered.generation() == 2) {
        var actual: [512]u8 = undefined;
        try std.testing.expectEqual(actual.len, try recovered.read(1, 0, &actual));
        try std.testing.expectEqualSlices(u8, &data, &actual);
    } else try std.testing.expectEqual(@as(u64, 1), recovered.generation());
}
