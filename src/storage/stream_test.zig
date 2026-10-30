const std = @import("std");
const model = @import("checkpoint_model.zig");
const media = @import("model_media.zig");
const equal = std.testing.expectEqual;
const expect = std.testing.expect;
const expectError = std.testing.expectError;
const page = model.page_bytes;
const Backend = media.Media(40 * page);
const Device = struct {
    pub const capacity = Backend.capacity;
    backend: *Backend,
    read_bytes: usize = 0,
    write_bytes: usize = 0,
    pub fn read(self: *@This(), offset: u64, bytes: []u8) error{Io}!void {
        self.read_bytes += bytes.len;
        return self.backend.read(offset, bytes);
    }
    pub fn write(self: *@This(), offset: u64, bytes: []const u8) error{Io}!void {
        self.write_bytes += bytes.len;
        return self.backend.write(offset, bytes);
    }
    pub fn sync(self: *@This()) error{Io}!void {
        return self.backend.sync();
    }
};
const Store = model.Store(Device, .{ .leaf_pages = 2, .index_pages = 8, .leaf_cache_pages = 2 });
const payload: [5003]u8 = bytes: {
    @setEvalBranchQuota(20000);
    var result: [5003]u8 = undefined;
    for (&result, 0..) |*byte, i| byte.* = @truncate(i *% 17 +% 0x31);
    break :bytes result;
};
fn append(store: *Store, device: *Device, stream: model.Stream, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const before = device.write_bytes;
        const n = try store.writeStream(stream, bytes[offset..@min(offset + 777, bytes.len)]);
        try expect(n != 0 and n <= page);
        try expect(device.write_bytes - before <= 2 * page);
        offset += n;
    }
}
fn object(store: *Store, expected: []const u8) !void {
    var bytes: [8192]u8 = undefined;
    try equal(expected.len, try store.read(1, 0, &bytes));
    try std.testing.expectEqualSlices(u8, expected, bytes[0..expected.len]);
}
fn initial(device: *Device) !void {
    var store = Store{};
    try store.format(device);
    try store.begin();
    try store.put(1, "old");
    try store.commit();
    device.backend.powerLoss();
}

test "stream chunks stay unpublished and interleaved reads do not clobber writer buffers" {
    var backend = Backend{};
    var device = Device{ .backend = &backend };
    try initial(&device);
    var store = Store{};
    try store.recover(&device);
    const reader = try store.pin();
    try store.begin();
    const stream = try store.beginStream(1, payload.len);
    try expectError(error.Busy, store.commit());
    try expectError(error.Busy, store.put(2, "blocked"));
    try expectError(error.Busy, store.remove(1));
    try expectError(error.Busy, store.beginPayloadSpace());
    var offset: usize = 0;
    while (offset < payload.len) {
        const before = device.write_bytes;
        offset += try store.writeStream(stream, payload[offset..@min(offset + 777, payload.len)]);
        try expect(device.write_bytes - before <= 2 * page);
        try object(&store, "old");
        var old: [3]u8 = undefined;
        try equal(old.len, try store.readPinned(reader, 1, 0, &old));
        try std.testing.expectEqualSlices(u8, "old", &old);
    }
    try store.finishStream(stream);
    try object(&store, "old");
    try store.commit();
    try object(&store, &payload);
    try store.verify(1);
    try store.release(reader);
}

test "stream cancellation preserves earlier staged work and rollback cancels a finished stream" {
    var backend = Backend{};
    var device = Device{ .backend = &backend };
    try initial(&device);
    var store = Store{};
    try store.recover(&device);
    try store.begin();
    try store.put(2, "prior staged");
    const cancelled = try store.beginStream(1, payload.len);
    try append(&store, &device, cancelled, payload[0..4097]);
    try expectError(error.IncompleteStream, store.finishStream(cancelled));
    try store.abortStream(cancelled);
    try expectError(error.InvalidStream, store.writeStream(cancelled, "x"));
    const replacement = try store.beginStream(1, 3);
    try expect(cancelled.token != replacement.token);
    try expectError(error.InvalidStream, store.abortStream(cancelled));
    _ = try store.writeStream(replacement, "new");
    try store.finishStream(replacement);
    try store.rollback();
    try object(&store, "old");
    try expectError(error.NotFound, store.get(2));
    try store.begin();
    try store.put(2, "prior staged");
    const again = try store.beginStream(1, 4097);
    try append(&store, &device, again, payload[0..4097]);
    try store.abortStream(again);
    try store.commit();
    try object(&store, "old");
    try equal(@as(u64, 12), (try store.get(2)).length);
    try store.begin();
    const interrupted = try store.beginStream(1, payload.len);
    try append(&store, &device, interrupted, payload[0..4097]);
    try store.rollback();
    try store.begin();
    const fresh = try store.beginStream(1, 3);
    try expectError(error.InvalidStream, store.writeStream(interrupted, "x"));
    try store.abortStream(fresh);
    try store.rollback();
    try object(&store, "old");
}

test "stream declared length prepared allocation and empty object have explicit boundaries" {
    var backend = Backend{};
    var device = Device{ .backend = &backend };
    var store = Store{};
    try store.format(&device);
    try store.begin();
    try expectError(error.SearchRequired, store.beginStreamPrepared(1, 3));
    try store.beginPayloadSearch(2);
    switch (try store.stepPayloadSearch(.{})) {
        .found => {},
        else => return error.BadSearch,
    }
    const stream = try store.beginStreamPrepared(1, 3);
    const writes = device.write_bytes;
    try expectError(error.InvalidArgument, store.writeStream(stream, "four"));
    try equal(writes, device.write_bytes);
    try expectError(error.IncompleteStream, store.finishStream(stream));
    _ = try store.writeStream(stream, "abc");
    try expectError(error.InvalidArgument, store.writeStream(stream, "x"));
    try store.finishStream(stream);
    const empty = try store.beginStream(2, 0);
    try equal(@as(usize, 0), try store.writeStream(empty, ""));
    try store.finishStream(empty);
    try store.commit();
    try object(&store, "abc");
    try equal(@as(u64, 0), (try store.get(2)).length);
}

test "patch steps preserve prefix suffix and earlier staged changes with bounded I/O" {
    var backend = Backend{};
    var device = Device{ .backend = &backend };
    var store = Store{};
    try store.format(&device);
    try store.begin();
    try store.put(1, &payload);
    const patch = try store.beginPatch(1, page - 3, 7);
    try expectError(error.InvalidArgument, store.writeStream(patch, "bypass"));
    const replacement = "CHANGED";
    var consumed: usize = 0;
    while (true) {
        const reads = device.read_bytes;
        const writes = device.write_bytes;
        const result = try store.stepPatch(patch, replacement[consumed..]);
        try expect(device.read_bytes - reads <= 2 * page);
        try expect(device.write_bytes - writes <= 2 * page);
        consumed += result.consumed;
        if (result.done) break;
        try expect(!result.need_input);
    }
    try equal(replacement.len, consumed);
    try store.finishStream(patch);
    const second = try store.beginPatch(1, 1, 1);
    var second_consumed: usize = 0;
    while (true) {
        const result = try store.stepPatch(second, "Z"[second_consumed..]);
        second_consumed += result.consumed;
        if (result.done) break;
    }
    try store.finishStream(second);
    try store.commit();
    var expected = payload;
    @memcpy(expected[page - 3 ..][0..replacement.len], replacement);
    expected[1] = 'Z';
    try object(&store, &expected);
    try store.verify(1);
}

test "patch waits for input can be cancelled and rejects invalid ranges" {
    var backend = Backend{};
    var device = Device{ .backend = &backend };
    try initial(&device);
    var store = Store{};
    try store.recover(&device);
    try store.begin();
    try expectError(error.InvalidArgument, store.beginPatch(1, 4, 0));
    try expectError(error.InvalidArgument, store.beginPatch(1, 1, 3));
    const patch = try store.beginPatch(1, 0, 1);
    const writes = device.write_bytes;
    const result = try store.stepPatch(patch, "");
    try expect(result.need_input and !result.done and result.consumed == 0);
    try equal(writes, device.write_bytes);
    try store.abortStream(patch);
    try store.commit();
    try object(&store, "old");
}

fn update(store: *Store, device: *Device) !void {
    try store.begin();
    const stream = try store.beginStream(1, payload.len);
    try append(store, device, stream, &payload);
    try store.finishStream(stream);
    try store.commit();
}
const patched: [payload.len]u8 = bytes: {
    var result = payload;
    @memcpy(result[page - 3 ..][0..7], "CHANGED");
    break :bytes result;
};
fn patchUpdate(store: *Store) !void {
    try store.begin();
    const stream = try store.beginPatch(1, page - 3, 7);
    var consumed: usize = 0;
    while (true) {
        const progress = try store.stepPatch(stream, "CHANGED"[consumed..]);
        consumed += progress.consumed;
        if (progress.done) break;
    }
    try store.finishStream(stream);
    try store.commit();
}
fn campaign(comptime patch_mode: bool) !void {
    var base = Backend{};
    var initial_device = Device{ .backend = &base };
    if (patch_mode) {
        var initial_store = Store{};
        try initial_store.format(&initial_device);
        try initial_store.begin();
        try initial_store.put(1, &payload);
        try initial_store.commit();
        base.powerLoss();
    } else try initial(&initial_device);
    var cases: usize = 0;
    for ([_]media.Background{ .none, .alternating, .all }) |background| {
        for ([_]media.Order{ .ascending, .descending }) |order| {
            var clean = base;
            clean.background = background;
            clean.order = order;
            var device = Device{ .backend = &clean };
            var store = Store{};
            try store.recover(&device);
            if (patch_mode) try patchUpdate(&store) else try update(&store, &device);
            const events = clean.events;
            try equal(@as(usize, 82), events);
            clean.powerLoss();
            var acknowledged = Store{};
            try acknowledged.recover(&device);
            try equal(@as(u64, 3), acknowledged.generation());
            try object(&acknowledged, if (patch_mode) &patched else &payload);
            for (0..events) |event| {
                for ([_]usize{ 0, 1, 31, 255, 511, 512 }) |prefix| {
                    var broken = base;
                    broken.background = background;
                    broken.order = order;
                    var failing = Device{ .backend = &broken };
                    var interrupted = Store{};
                    try interrupted.recover(&failing);
                    broken.cut = .{ .event = event, .prefix = prefix };
                    if (patch_mode) try expectError(error.Io, patchUpdate(&interrupted)) else try expectError(error.Io, update(&interrupted, &failing));
                    try expectError(error.Faulted, interrupted.begin());
                    try equal(@as(u64, 0), interrupted.writer.token);
                    broken.powerLoss();
                    var recovered = Store{};
                    try recovered.recover(&failing);
                    try expect(recovered.generation() == 2 or recovered.generation() == 3);
                    try object(&recovered, if (recovered.generation() == 2) (if (patch_mode) &payload else "old") else (if (patch_mode) &patched else &payload));
                    cases += 1;
                }
            }
        }
    }
    try equal(@as(usize, 2952), cases);
    std.debug.print("{s}_CAMPAIGN events=82 crash_cases=2952 acknowledged_cases=6\n", .{if (patch_mode) "PATCH" else "STREAM"});
}

test "every streaming payload table metadata and publication cut recovers whole old or new data" {
    try campaign(false);
}
test "every partial patch publication cut preserves prefix suffix and atomic visibility" {
    try campaign(true);
}

test "stream length and progress remain u64 without a large input buffer" {
    const Sparse = struct {
        pub const capacity: u64 = 16 * 1024 * 1024 * 1024;
        roots: [2 * page]u8 = @splat(0xff),
        pub fn read(self: *@This(), offset: u64, bytes: []u8) error{Io}!void {
            if (offset > self.roots.len or bytes.len > self.roots.len - offset) return error.Io;
            @memcpy(bytes, self.roots[@intCast(offset)..][0..bytes.len]);
        }
        pub fn write(self: *@This(), offset: u64, bytes: []const u8) error{Io}!void {
            if (offset > self.roots.len or bytes.len > self.roots.len - offset) return error.Io;
            @memcpy(self.roots[@intCast(offset)..][0..bytes.len], bytes);
        }
        pub fn sync(_: *@This()) error{Io}!void {}
    };
    const Large = model.Store(Sparse, .{});
    var device = Sparse{};
    var store = Large{};
    try store.format(&device);
    try store.begin();
    const length: u64 = (1 << 32) + 17;
    const stream = try store.beginStream(1, length);
    _ = try store.writeStream(stream, "x");
    try equal(length, store.writer.length);
    try equal(@as(u64, 1), store.writer.received);
    try store.abortStream(stream);
    try store.rollback();
}
