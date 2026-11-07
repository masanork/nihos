//! Opt-in budget enforcement for the synchronous experimental store.
const std = @import("std");
const m = @import("checkpoint_model.zig");
const media = @import("model_media.zig");
const page = m.page_bytes;
const Device = media.Media(64 * page);
const Store = m.Store(Device, .{ .leaf_pages = 1, .index_pages = 8, .leaf_cache_pages = 1 });

fn seed(store: *Store, device: *Device) !void {
    try store.format(device);
    try store.begin();
    try store.put(1, "old");
    try store.commit();
    try store.collectPayload();
}
fn value(store: *Store, expected: []const u8) !void {
    var buf: [32]u8 = undefined;
    const n = try store.read(1, 0, &buf);
    try std.testing.expectEqualStrings(expected, buf[0..n]);
}

test "budget admission and physical write charges keep committed margins" {
    var device = Device{};
    var store = Store{};
    try seed(&store, &device);
    const pin = try store.pin();
    const before = device.events;
    try std.testing.expectError(error.NoSpace, store.beginBudgeted(.{ .payload_writes = std.math.maxInt(u64), .index_writes = 1, .index_peak = 1, .payload_margin = 1, .index_margin = 1 }));
    try std.testing.expectEqual(before, device.events);
    try store.beginBudgeted(.{ .payload_writes = 2, .index_writes = 1, .index_peak = 1, .payload_margin = 2, .index_margin = 1 });
    try store.put(1, "new");
    try std.testing.expectEqual(@as(u64, 2), store.budget_payload_used);
    try std.testing.expectEqual(@as(u32, 1), store.budget_index_used);
    try value(&store, "old");
    try std.testing.expectError(error.Busy, store.releaseBudget());
    try store.commit();
    try value(&store, "new");
    var old: [8]u8 = undefined;
    const n = try store.readPinned(pin, 1, 0, &old);
    try std.testing.expectEqualStrings("old", old[0..n]);
    try std.testing.expectError(error.Busy, store.begin());
    try store.releaseBudget();
    try store.begin();
    try store.rollback();
    try store.release(pin);
}

test "exhaustion at the shared write point poisons commit until rollback" {
    var device = Device{};
    var store = Store{};
    try seed(&store, &device);
    try store.beginBudgeted(.{ .payload_writes = 1, .index_writes = 1, .index_peak = 1, .payload_margin = 2, .index_margin = 1 });
    try std.testing.expectError(error.ReservationExceeded, store.put(1, "new"));
    try std.testing.expect(store.budget_poisoned);
    try std.testing.expectError(error.ReservationExceeded, store.commit());
    try std.testing.expectError(error.ReservationExceeded, store.put(2, ""));
    try store.rollback();
    try value(&store, "old");
    device.powerLoss();
    var recovered = Store{};
    try recovered.recover(&device);
    try value(&recovered, "old");
}

test "index writes share the same budget even across writer APIs" {
    var device = Device{};
    var store = Store{};
    try seed(&store, &device);
    try store.beginBudgeted(.{ .payload_writes = 2, .index_writes = 1, .index_peak = 1, .payload_margin = 2, .index_margin = 1 });
    try store.put(1, "new");
    const before = device.events;
    try std.testing.expectError(error.ReservationExceeded, store.put(2, ""));
    try std.testing.expectEqual(before, device.events);
    try std.testing.expectError(error.ReservationExceeded, store.commit());
    try store.rollback();
    try value(&store, "old");
}

test "mapped resize and scattered batch charge through the same gate" {
    var device = Device{};
    var store = Store{};
    try seed(&store, &device);
    var scratch = m.MapScratch{};
    try store.beginBudgeted(.{ .payload_writes = 3, .index_writes = 3, .index_peak = 2, .payload_margin = 2, .index_margin = 1 });
    try store.put(2, "");
    try store.resizeMapped(2, page * 2, &scratch);
    const patches = [_]m.MappedPatch{.{ .offset = 0, .bytes = "A" }};
    const wanted = try Store.mappedBatchPages(page * 2, &patches);
    try store.beginMappedSearchWithHeadroom(wanted, 0);
    while (true) switch (try store.stepPayloadSearch(.{ .leaf_visits = 1, .bitmap_pages = 1 })) {
        .pending => {},
        .found => break,
        else => return error.UnexpectedSearch,
    };
    try store.patchMappedBatchPrepared(2, &patches, &scratch);
    try std.testing.expectEqual(@as(u64, 3), store.budget_payload_used);
    try std.testing.expectEqual(@as(u32, 3), store.budget_index_used);
    try store.commit();
    try store.releaseBudget();
    var out: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), try store.read(2, 0, &out));
    try std.testing.expectEqual(@as(u8, 'A'), out[0]);
}

test "index peak allows repeated replacements without reserving one page per write" {
    var device = Device{};
    var store = Store{};
    try seed(&store, &device);
    try store.beginBudgeted(.{ .payload_writes = 20, .index_writes = 10, .index_peak = 2, .payload_margin = 2, .index_margin = 1 });
    for (0..10) |i| {
        const byte = [_]u8{@intCast('a' + i)};
        try store.put(1, &byte);
    }
    try std.testing.expectEqual(@as(u32, 10), store.budget_index_used);
    try store.commit();
    try store.releaseBudget();
    try value(&store, "j");
}

test "underestimated index peak fences the staged transaction" {
    var device = Device{};
    var store = Store{};
    try seed(&store, &device);
    try store.beginBudgeted(.{ .payload_writes = 4, .index_writes = 2, .index_peak = 1, .payload_margin = 2, .index_margin = 1 });
    try store.put(1, "a");
    try std.testing.expectError(error.ReservationExceeded, store.put(1, "b"));
    try std.testing.expectError(error.ReservationExceeded, store.commit());
    try store.rollback();
    try value(&store, "old");
}

test "aborted stream cannot refund an already written page" {
    var device = Device{};
    var store = Store{};
    try seed(&store, &device);
    try store.beginBudgeted(.{ .payload_writes = 1, .index_writes = 1, .index_peak = 1, .payload_margin = 2, .index_margin = 1 });
    const stream = try store.beginStream(2, page * 2);
    const bytes: [page]u8 = @splat(1);
    try std.testing.expectEqual(@as(usize, page), try store.writeStream(stream, &bytes));
    try store.abortStream(stream);
    const replacement = try store.beginStream(2, 1);
    try std.testing.expectError(error.ReservationExceeded, store.writeStream(replacement, "x"));
    try std.testing.expectError(error.ReservationExceeded, store.commit());
    try store.rollback();
    try value(&store, "old");
}

test "failed allocation search poisons an already staged budgeted transaction" {
    var device = Device{};
    var store = Store{};
    try seed(&store, &device);
    try store.beginBudgeted(.{ .payload_writes = 2, .index_writes = 1, .index_peak = 1, .payload_margin = 2, .index_margin = 1 });
    try store.put(1, "new");
    try store.beginMappedSearchWithHeadroom(1, std.math.maxInt(u64));
    try std.testing.expect(try store.stepPayloadSearch(.{}) == .no_space);
    try std.testing.expectError(error.ReservationExceeded, store.commit());
    try store.rollback();
    try value(&store, "old");
}

test "unknown publication fences the store and requires a fresh recovery" {
    var device = Device{};
    var store = Store{};
    try seed(&store, &device);
    try store.beginBudgeted(.{ .payload_writes = 2, .index_writes = 1, .index_peak = 1, .payload_margin = 2, .index_margin = 1 });
    try store.put(1, "new");
    device.cut = .{ .event = device.events, .prefix = 0 };
    try std.testing.expectError(error.Io, store.commit());
    try std.testing.expectError(error.Faulted, store.releaseBudget());
    try std.testing.expectError(error.Faulted, store.begin());
    device.powerLoss();
    var recovered = Store{};
    try recovered.recover(&device);
    try value(&recovered, "old");
    try std.testing.expectError(error.InvalidArgument, recovered.releaseBudget());
}

fn update(store: *Store) !void {
    try store.beginBudgeted(.{ .payload_writes = 2, .index_writes = 1, .index_peak = 1, .payload_margin = 2, .index_margin = 1 });
    try store.put(1, "new");
    try store.commit();
    try store.releaseBudget();
}

test "budgeted publication recovers old or new across modeled cuts" {
    var base = Device{};
    var initial = Store{};
    try seed(&initial, &base);
    base.powerLoss();
    var clean = base;
    var normal = Store{};
    try normal.recover(&clean);
    try update(&normal);
    const events = clean.events;
    var cases: usize = 0;
    for ([_]media.Background{ .none, .all }) |background| {
        for (0..events) |event| {
            var broken = base;
            broken.background = background;
            var attempt = Store{};
            try attempt.recover(&broken);
            broken.cut = .{ .event = event, .prefix = 31 };
            try std.testing.expectError(error.Io, update(&attempt));
            try std.testing.expectError(error.Faulted, attempt.begin());
            broken.powerLoss();
            var recovered = Store{};
            try recovered.recover(&broken);
            var bytes: [8]u8 = undefined;
            const n = try recovered.read(1, 0, &bytes);
            try std.testing.expect(std.mem.eql(u8, bytes[0..n], "old") or std.mem.eql(u8, bytes[0..n], "new"));
            try recovered.verify(1);
            cases += 1;
        }
    }
    std.debug.print("WRITE_BUDGET_CUTS events={d} cases={d}\n", .{ events, cases });
}
