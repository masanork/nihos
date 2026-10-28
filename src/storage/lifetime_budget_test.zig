const std = @import("std");
const api = @import("checkpoint_service.zig");
const budget = api.lifetime_budget;
const model = api.model;
const equal = std.testing.expectEqual;
const expect = std.testing.expect;
const expectError = std.testing.expectError;
const Backend = @import("model_media.zig").Media(128 * 4096);
const Device = struct {
    pub const capacity: u64 = 16 * 1024 * 1024 * 1024;
    backend: Backend = .{},
    read_error: bool = false,
    pub fn read(self: *@This(), offset: u64, bytes: []u8) error{Io}!void {
        if (self.read_error) return error.Io;
        return self.backend.read(offset, bytes);
    }
    pub fn write(self: *@This(), offset: u64, bytes: []const u8) error{Io}!void {
        return self.backend.write(offset, bytes);
    }
    pub fn sync(self: *@This()) error{Io}!void {
        return self.backend.sync();
    }
};
const Store = model.Store(Device, .{ .leaf_pages = 2, .index_pages = 12 });
const Readers = budget.Readers(Store);
fn seed(store: *Store, device: *Device) !void {
    var scratch = model.MapScratch{};
    try store.format(device);
    try store.begin();
    try store.put(1, "");
    try store.put(2, "abc");
    try store.resizeMapped(1, 4 * 1024 * 1024 * 1024, &scratch);
    try store.patchMappedPage(1, 0, "A");
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
fn admit(readers: *Readers, actor: u64, now: u64, duration: u64, bytes: u64) !model.Reader {
    const reader = try readers.begin(actor, now, duration, bytes);
    while (!try readers.step(actor, reader, now, 1)) {}
    return reader;
}
test "operation budget keeps logical journal cleanup possible and latches cooperative expiry" {
    try expectError(error.InvalidArgument, budget.Operation.init(.{ .journal_span_bytes = 511, .duration_ms = 1 }, 0));
    try expectError(error.InvalidArgument, budget.Operation.init(.{ .journal_span_bytes = 512, .duration_ms = 0 }, 0));
    var operation = try budget.Operation.init(.{ .journal_span_bytes = 512, .duration_ms = 10 }, 100);
    try expect(operation.journalWrite(512));
    try expect(!operation.journalWrite(513));
    try equal(budget.Reason.journal_span, operation.poll(110));
    try expect(operation.journalWrite(28)); // rollback can zero a retained header
    try equal(@as(u64, 512), operation.journal_peak);
    operation = try budget.Operation.init(.{ .journal_span_bytes = 4096, .duration_ms = 10 }, 100);
    try equal(budget.Reason.none, operation.poll(109));
    try equal(budget.Reason.deadline, operation.poll(110));
    try equal(budget.Reason.deadline, operation.poll(0));
    operation = try budget.Operation.init(.{ .journal_span_bytes = 4096, .duration_ms = 10 }, 100);
    try equal(budget.Reason.none, operation.poll(102));
    try equal(budget.Reason.clock_regressed, operation.poll(101));
    operation = try budget.Operation.init(.{ .journal_span_bytes = 4096, .duration_ms = 3 }, std.math.maxInt(u64) - 3);
    try equal(budget.Reason.deadline, operation.poll(std.math.maxInt(u64)));
}
test "snapshot byte charge walks sparse reachable pages with bounded existing scratch" {
    var device = Device{};
    var store = Store{};
    try seed(&store, &device);
    const reader = try store.pin();
    const height = try model.extent_map.height(4 * 1024 * 1024 * 1024);
    // One index, one mapped data, height+1 map nodes, blob data+checksum.
    try equal((@as(u64, height) + 5) * 4096, try usage(&store, reader));
    try expectError(error.InvalidSearch, store.stepPayloadSearch(.{}));
    var byte: [1]u8 = undefined;
    _ = try store.readPinned(reader, 1, 0, &byte);
    try equal(@as(u8, 'A'), byte[0]);
    try equal((@as(u64, height) + 5) * 4096, try usage(&store, reader));
    try store.release(reader);
    try expectError(error.InvalidReader, store.stepPinnedUsage(reader, 1));
}
test "reader per-pin and aggregate caps include metadata and do not assume deduplication" {
    var device = Device{};
    var store = Store{};
    try seed(&store, &device);
    const temporary = try store.pin();
    const bytes = try usage(&store, temporary);
    try store.release(temporary);
    var readers = try Readers.init(&store, bytes * 2 - 1, 0);
    const too_small = try readers.begin(71, 0, 10, bytes - 1);
    var failed = false;
    while (!failed) {
        _ = readers.step(71, too_small, 0, 1) catch |err| {
            try equal(error.NoSpace, err);
            failed = true;
        };
    }
    try equal(@as(u64, 0), readers.charged_bytes);
    try expectError(error.InvalidReader, store.readPinned(too_small, 1, 0, &.{}));
    const first = try admit(&readers, 71, 0, 10, bytes);
    try equal(bytes, readers.charged_bytes);
    const second = try readers.begin(72, 0, 10, bytes);
    while (true) {
        const accepted = readers.step(72, second, 0, 1) catch |err| {
            try equal(error.NoSpace, err);
            break;
        };
        try expect(!accepted);
    }
    try equal(bytes, readers.charged_bytes);
    try readers.stopped(71, first);
    try equal(@as(u64, 0), readers.charged_bytes);
}
test "expired reader retains protected pages and charge until stopped acknowledgement" {
    var device = Device{};
    var store = Store{};
    try seed(&store, &device);
    var readers = try Readers.init(&store, 1024 * 1024, 0);
    const reader = try admit(&readers, 71, 0, 10, 1024 * 1024);
    const charged = readers.charged_bytes;
    try store.begin();
    try store.patchMappedPage(1, 0, "B");
    try store.commit();
    try store.collectPayload();
    const before = (try store.payloadSpace()).free_pages;
    var byte: [1]u8 = .{0xee};
    _ = try readers.read(71, reader, 1, 0, &byte, 9);
    try equal(@as(u8, 'A'), byte[0]);
    try readers.poll(10);
    try equal(charged, readers.charged_bytes);
    try expectError(error.Expired, readers.read(71, reader, 1, 0, &byte, 10));
    try equal(@as(u8, 0), byte[0]);
    _ = try store.readPinned(reader, 1, 0, &byte);
    try equal(@as(u8, 'A'), byte[0]); // timeout has not revoked the pin
    try equal(before, (try store.payloadSpace()).free_pages);
    try expectError(error.Denied, readers.stopped(72, reader));
    try readers.stopped(71, reader);
    try expect((try store.payloadSpace()).free_pages > before);
    try equal(@as(u64, 0), readers.charged_bytes);
    const next = try admit(&readers, 71, 10, 10, 1024 * 1024);
    try expect(next.token != reader.token);
    try expectError(error.Denied, readers.read(71, reader, 1, 0, &byte, 10));
    try readers.stopped(71, next);
}
test "reader clock regression stops admission and access without silently releasing charges" {
    var device = Device{};
    var store = Store{};
    try seed(&store, &device);
    var readers = try Readers.init(&store, 1024 * 1024, 100);
    const reader = try admit(&readers, 71, 100, 10, 1024 * 1024);
    const charged = readers.charged_bytes;
    try readers.poll(101);
    try expectError(error.ClockRegressed, readers.poll(100));
    try equal(charged, readers.charged_bytes);
    try expectError(error.ClockRegressed, readers.begin(72, 102, 10, 1024 * 1024));
    try readers.stopped(71, reader);
    try equal(@as(u64, 0), readers.charged_bytes);
}
test "raw clock provider failure stops both published readers and retains both pins" {
    var device = Device{};
    var store = Store{};
    try seed(&store, &device);
    var readers = try Readers.init(&store, 1024 * 1024, 100);
    const first = try admit(&readers, 71, 100, 10, 1024 * 1024);
    const second = try admit(&readers, 72, 101, 10, 1024 * 1024);
    const charged = readers.charged_bytes;
    readers.failClock();
    try equal(charged, readers.charged_bytes);
    try equal(Readers.State.stopping, readers.entries[first.slot].state);
    try equal(Readers.State.stopping, readers.entries[second.slot].state);
    try equal(first.token, store.readers[first.slot].token);
    try equal(second.token, store.readers[second.slot].token);
    device.read_error = true; // Clock failure must win before any backend IO.
    var byte: [1]u8 = .{0xee};
    try expectError(error.ClockRegressed, readers.read(72, second, 1, 0, &byte, 101));
    try equal(@as(u8, 0), byte[0]);
    try expectError(error.ClockRegressed, readers.begin(73, 102, 10, 1024 * 1024));
    try readers.stopped(71, first);
    try expect(readers.charged_bytes > 0);
    try readers.stopped(72, second);
    try equal(@as(u64, 0), readers.charged_bytes);
}
test "private reader admission expires or invalidates without leaking a pin or a charge" {
    var device = Device{};
    var store = Store{};
    try seed(&store, &device);
    var readers = try Readers.init(&store, 1024 * 1024, 0);
    const expired = try readers.begin(71, 0, 10, 1024 * 1024);
    try expectError(error.Expired, readers.step(71, expired, 10, 1));
    try equal(@as(u64, 0), readers.charged_bytes);
    const reader = try readers.begin(71, 10, 10, 1024 * 1024);
    try expectError(error.Busy, readers.begin(72, 10, 10, 1024 * 1024));
    try store.begin(); // low-level mutation invalidates the unaccepted proof
    try store.rollback();
    try expectError(error.InvalidSearch, readers.step(71, reader, 10, 1));
    try equal(@as(u64, 0), readers.charged_bytes);
    try expectError(error.InvalidReader, store.readPinned(reader, 1, 0, &.{}));
}
test "snapshot scan faults discard unpublished pins and published pins can be stopped after faults" {
    var device = Device{};
    var store = Store{};
    try seed(&store, &device);
    var readers = try Readers.init(&store, 1024 * 1024, 0);
    const reader = try readers.begin(71, 0, 10, 1024 * 1024);
    device.read_error = true;
    try expectError(error.Io, readers.step(71, reader, 0, 1));
    try equal(@as(u64, 0), readers.charged_bytes);
    try expectError(error.Faulted, store.readPinned(reader, 1, 0, &.{}));
    device.read_error = false;
    store = .{};
    try store.recover(&device);
    readers = try Readers.init(&store, 1024 * 1024, 0);
    const active = try admit(&readers, 71, 0, 10, 1024 * 1024);
    device.read_error = true;
    var byte: [1]u8 = .{0xee};
    try expectError(error.Io, readers.read(71, active, 1, 0, &byte, 0));
    try equal(@as(u8, 0), byte[0]);
    try expect(readers.charged_bytes > 0);
    try readers.stopped(71, active);
    try equal(@as(u64, 0), readers.charged_bytes);
}
