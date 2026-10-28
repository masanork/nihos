const std = @import("std");
const api = @import("checkpoint_service.zig");
const model = api.model;
const Backend = @import("model_media.zig").Media(64 * 4096);
const Device = struct {
    pub const capacity = Backend.capacity;
    media: Backend = .{},
    reads: u64 = 0,
    read_error: bool = false,
    pub fn read(self: *@This(), offset: u64, bytes: []u8) error{Io}!void {
        self.reads += 1;
        if (self.read_error) return error.Io;
        return self.media.read(offset, bytes);
    }
    pub fn write(self: *@This(), offset: u64, bytes: []const u8) error{Io}!void {
        return self.media.write(offset, bytes);
    }
    pub fn sync(self: *@This()) error{Io}!void {
        return self.media.sync();
    }
};
const Store = model.Store(Device, .{ .leaf_pages = 1, .index_pages = 6, .payload_reserve_pages = 2 });
const Readers = api.lifetime_budget.Readers(Store);

test "caller scratch reads pinned blob and mapped pages without losing scope or expiry checks" {
    var device = Device{};
    var store = Store{};
    try store.format(&device);
    const payload: [5000]u8 = @splat(0x6d);
    var map_scratch = model.MapScratch{};
    try store.begin();
    try store.put(1, &payload);
    try store.put(2, "");
    try store.resizeMapped(2, 8192, &map_scratch);
    try store.patchMappedPage(2, 4094, "te");
    try store.patchMappedPage(2, 4096, "st");
    try store.commit();
    var readers = try Readers.init(&store, 1024 * 1024, 0);
    const blob = try readers.beginObject(71, 1, 0, 10, 1024 * 1024);
    while (!try readers.step(71, blob, 0, 8)) {}
    const mapped = try readers.beginObject(72, 2, 0, 10, 1024 * 1024);
    while (!try readers.step(72, mapped, 0, 8)) {}
    var scratch: [4096]u8 = undefined;
    var result: [32]u8 = @splat(0);
    try equal(@as(usize, 32), try readers.readWithScratch(71, blob, 1, 4088, &result, 1, &scratch));
    try expect(std.mem.allEqual(u8, &result, 0x6d));
    try equal(@as(usize, 4), try readers.readWithScratch(72, mapped, 2, 4094, result[0..4], 1, &scratch));
    try std.testing.expectEqualSlices(u8, "test", result[0..4]);
    try expectError(error.NotFound, readers.readWithScratch(71, blob, 2, 0, &result, 1, &scratch));
    try expect(std.mem.allEqual(u8, &result, 0));
    try expectError(error.Expired, readers.readWithScratch(72, mapped, 2, 0, &result, 10, &scratch));
    try expect(std.mem.allEqual(u8, &result, 0));
    try readers.stopped(71, blob);
    try readers.stopped(72, mapped);
}
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const expectError = std.testing.expectError;
fn seed(store: *Store, device: *Device) !void {
    var scratch = model.MapScratch{};
    try store.format(device);
    try store.begin();
    try store.put(1, "");
    try store.resizeMapped(1, 4096, &scratch);
    try store.patchMappedPage(1, 0, "A");
    const asset: [64 * 1024]u8 = @splat('Z');
    try store.put(2, &asset);
    try store.commit();
}
fn usage(store: *Store, reader: model.Reader) !u64 {
    try store.beginPinnedUsage(reader);
    while (true) {
        const result = try store.stepPinnedUsage(reader, 1);
        try expect(store.step_leaf_visits <= 1);
        if (result) |bytes| return bytes;
    }
}
test "object pin charges only captured data and map pages and denies another key before IO" {
    var device = Device{};
    var store = Store{};
    try seed(&store, &device);
    const root = try store.pin();
    try expect(try usage(&store, root) > 64 * 1024);
    const object = try store.pinObject(1);
    try equal(@as(u64, 8192), try usage(&store, object));
    const before = device.reads;
    var byte: [1]u8 = .{0xee};
    try expectError(error.NotFound, store.getPinned(object, 2));
    try expectError(error.NotFound, store.readPinned(object, 2, 0, &byte));
    try equal(before, device.reads);
    _ = try store.readPinned(object, 1, 0, &byte);
    try equal(@as(u8, 'A'), byte[0]);
    try store.release(object);
    try store.release(root);
}
test "object pin releases unrelated asset and index pages while old data survives repeated reuse" {
    var device = Device{};
    var store = Store{};
    try seed(&store, &device);
    const old_index = store.current.refs[0].page;
    const root = try store.pin();
    const object = try store.pinObject(1);
    try store.begin();
    try store.remove(2);
    try store.patchMappedPage(1, 0, "B");
    try store.commit();
    try store.collectPayload();
    const before = try store.payloadSpace();
    try store.release(root);
    const after = try store.payloadSpace();
    try expect(after.free_pages >= before.free_pages + 17);
    try equal(@as(u32, 1), (try store.indexSpace()).protected_pages);
    var reused = false;
    for (0..96) |_| {
        try store.begin();
        try store.patchMappedPage(1, 0, "C");
        try store.commit();
        if (store.current.refs[0].page == old_index) reused = true;
        try store.collectPayload();
        var byte: [1]u8 = undefined;
        _ = try store.readPinned(object, 1, 0, &byte);
        try equal(@as(u8, 'A'), byte[0]);
    }
    try expect(reused);
    const held = (try store.payloadSpace()).free_pages;
    try store.release(object);
    try equal(held + 2, (try store.payloadSpace()).free_pages);
}
test "captured object survives deletion and recreation with the same key and a different kind" {
    var device = Device{};
    var store = Store{};
    try seed(&store, &device);
    const object = try store.pinObject(1);
    try store.begin();
    try store.remove(1);
    try store.commit();
    try store.collectPayload();
    try expectError(error.NotFound, store.get(1));
    try store.begin();
    try store.put(1, "NEW");
    try store.commit();
    try store.collectPayload();
    try equal(model.Kind.mapped, (try store.getPinned(object, 1)).kind);
    try equal(model.Kind.blob, (try store.get(1)).kind);
    var byte: [1]u8 = undefined;
    _ = try store.readPinned(object, 1, 0, &byte);
    try equal(@as(u8, 'A'), byte[0]);
    try store.release(object);
    const next = try store.pinObject(1);
    const before = device.reads;
    try expectError(error.InvalidReader, store.readPinned(object, 1, 0, &byte));
    try equal(before, device.reads);
    _ = try store.readPinned(next, 1, 0, &byte);
    try equal(@as(u8, 'N'), byte[0]);
    try store.release(next);
}
test "object reader quota admits small DB beside large asset and retains charge through expiry" {
    var device = Device{};
    var store = Store{};
    try seed(&store, &device);
    var readers = try Readers.init(&store, 8192, 0);
    const object = try readers.beginObject(71, 1, 0, 10, 8192);
    while (!try readers.step(71, object, 0, 1)) {}
    try equal(@as(u64, 8192), readers.charged_bytes);
    var byte: [1]u8 = .{0xee};
    try expectError(error.NotFound, readers.read(71, object, 2, 0, &byte, 0));
    try equal(@as(u8, 0), byte[0]);
    try readers.poll(10);
    try expectError(error.Expired, readers.read(71, object, 1, 0, &byte, 10));
    try equal(@as(u64, 8192), readers.charged_bytes);
    _ = try store.readPinned(object, 1, 0, &byte);
    try equal(@as(u8, 'A'), byte[0]);
    try expectError(error.Denied, readers.stopped(72, object));
    try readers.stopped(71, object);
    try equal(@as(u64, 0), readers.charged_bytes);
}
test "object quota rejection and cancelled admission release provisional captures" {
    var device = Device{};
    var store = Store{};
    try seed(&store, &device);
    var readers = try Readers.init(&store, 8192, 0);
    const rejected = try readers.beginObject(71, 1, 0, 10, 8191);
    while (true) {
        const done = readers.step(71, rejected, 0, 1) catch |err| {
            try equal(error.NoSpace, err);
            break;
        };
        try expect(!done);
    }
    try equal(@as(u64, 0), readers.charged_bytes);
    try expectError(error.InvalidReader, store.getPinned(rejected, 1));
    const aborted = try readers.beginObject(71, 1, 0, 10, 8192);
    try store.begin();
    try store.rollback();
    try expectError(error.InvalidSearch, readers.step(71, aborted, 0, 1));
    try equal(@as(u64, 0), readers.charged_bytes);
    try expectError(error.InvalidReader, store.getPinned(aborted, 1));
}
test "empty and blob object pins charge checksums but no namespace leaf and survive payload reuse" {
    var device = Device{};
    var store = Store{};
    try store.format(&device);
    try store.begin();
    try store.put(1, "");
    try store.put(2, "abc");
    try store.commit();
    const empty = try store.pinObject(1);
    const blob = try store.pinObject(2);
    try equal(@as(u64, 0), try usage(&store, empty));
    try equal(@as(u64, 8192), try usage(&store, blob));
    try store.begin();
    try store.remove(2);
    try store.commit();
    try store.collectPayload();
    for (0..96) |_| {
        try store.begin();
        try store.put(3, "replacement");
        try store.commit();
        try store.collectPayload();
        var bytes: [3]u8 = undefined;
        try equal(@as(usize, 3), try store.readPinned(blob, 2, 0, &bytes));
        try expect(std.mem.eql(u8, &bytes, "abc"));
    }
    try store.release(empty);
    try store.release(blob);
}
test "object capture and read faults fence IO without leaking or revoking another live pin" {
    var device = Device{};
    var store = Store{};
    try seed(&store, &device);
    const existing = try store.pinObject(1);
    device.read_error = true;
    try expectError(error.Io, store.pinObject(2));
    try expect(store.readers[existing.slot].token != 0);
    try equal(@as(u64, 0), store.readers[1].token);
    try store.release(existing);
    device.read_error = false;
    store = .{};
    try store.recover(&device);
    var readers = try Readers.init(&store, 8192, 0);
    const object = try readers.beginObject(71, 1, 0, 10, 8192);
    while (!try readers.step(71, object, 0, 1)) {}
    device.read_error = true;
    var byte: [1]u8 = .{0xee};
    try expectError(error.Io, readers.read(71, object, 1, 0, &byte, 0));
    try equal(@as(u8, 0), byte[0]);
    try equal(@as(u64, 8192), readers.charged_bytes);
    try readers.stopped(71, object);
    try equal(@as(u64, 0), readers.charged_bytes);
}
