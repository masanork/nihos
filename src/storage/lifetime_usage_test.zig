const std = @import("std");
const model = @import("checkpoint_model.zig");
const Backend = @import("model_media.zig").Media(256 * 4096);
const Device = struct {
    pub const capacity: u64 = 16 * 1024 * 1024 * 1024;
    backend: Backend = .{},
    pub fn read(self: *@This(), offset: u64, bytes: []u8) error{Io}!void {
        return self.backend.read(offset, bytes);
    }
    pub fn write(self: *@This(), offset: u64, bytes: []const u8) error{Io}!void {
        return self.backend.write(offset, bytes);
    }
    pub fn sync(self: *@This()) error{Io}!void {
        return self.backend.sync();
    }
};
test "pinned multibranch map charge agrees with independent bounded physical occupancy scan" {
    const Store = model.Store(Device, .{ .leaf_pages = 2, .index_pages = 12 });
    var device = Device{};
    var store = Store{};
    var scratch = model.MapScratch{};
    try store.format(&device);
    try store.begin();
    try store.put(1, "");
    try store.put(2, "abc");
    const length: u64 = 4 * 1024 * 1024 * 1024;
    try store.resizeMapped(1, length, &scratch);
    try store.patchMappedBatch(1, &.{ .{ .offset = 0, .bytes = "A" }, .{ .offset = 2 * 1024 * 1024, .bytes = "B" }, .{ .offset = length - 4096, .bytes = "C" } }, &scratch);
    try store.commit();
    try store.collectPayload(); // both disk roots now describe exactly this view
    const reader = try store.pin();
    try store.beginPinnedUsage(reader);
    var charge: u64 = 0;
    while (true) {
        if (try store.stepPinnedUsage(reader, 1)) |bytes| {
            charge = bytes;
            break;
        }
        try std.testing.expect(store.step_leaf_visits <= 1);
    }
    const space = try store.payloadSpace();
    const index = try store.indexSpace();
    try std.testing.expectEqual((space.usable_pages - space.free_pages + index.protected_pages) * 4096, charge);
    try std.testing.expect(charge < 64 * 1024);
    const object = try store.pinObject(1);
    try store.beginPinnedUsage(object);
    var object_charge: u64 = 0;
    while (true) if (try store.stepPinnedUsage(object, 1)) |bytes| {
        object_charge = bytes;
        break;
    };
    try std.testing.expectEqual(charge - 3 * 4096, object_charge); // no blob data/checksum or namespace leaf
    try store.release(object);
    try store.release(reader);
}
