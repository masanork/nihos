//! Opt-in full-size mapped import using externally supplied NFST data.
const std = @import("std");
const nfst = @import("nfst_reader.zig");
const model = @import("checkpoint_model.zig");
const fixture = @import("nfst_reader_test.zig");
const io = std.testing.io;
const page = model.page_bytes;
fn search(store: *fixture.Store, pages: u64, steps: *usize) !void {
    try store.beginMappedSearchWithHeadroom(pages, 1);
    while (true) {
        steps.* += 1;
        switch (try store.stepPayloadSearch(.{ .leaf_visits = 8, .bitmap_pages = 128 })) {
            .pending => {},
            .found => return,
            .no_space => return error.NoSpace,
            else => return error.InvalidSearch,
        }
    }
}
test "large NFST staged mapped import remount and digest" {
    const env = std.c.getenv("NIHOS_NFST_PATH") orelse return error.SkipZigTest;
    const input = try std.Io.Dir.cwd().openFile(io, std.mem.span(env), .{});
    defer input.close(io);
    const length = (try input.stat(io)).size;
    try std.testing.expect(length > 4 * 1024 * 1024 and length < 7 * 1024 * 1024);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const image = try tmp.dir.createFile(io, "store", .{ .read = true, .exclusive = true });
    const erased: [page]u8 = @splat(0xff);
    var at: u64 = 0;
    while (at < fixture.Device.capacity) : (at += page) try image.writePositionalAll(io, &erased, at);
    try image.sync(io);
    image.close(io);
    var dev = try fixture.Device.open(io, tmp.dir, "store");
    var store: fixture.Store = .{};
    try store.format(&dev);
    // Fill five 3 MiB extents, then release alternating extents. The two
    // retained objects separate the free space into smaller physical runs.
    const part_bytes = 3 * 1024 * 1024;
    for (1..6) |key| {
        try store.begin();
        const stream = try store.beginStream(@intCast(key), part_bytes);
        const contents: [page]u8 = @splat(@intCast(key));
        var filled: usize = 0;
        while (filled < part_bytes) filled += try store.writeStream(stream, &contents);
        try store.finishStream(stream);
        try store.commit();
    }
    try store.begin();
    for ([_]u32{ 1, 3, 5 }) |key| try store.remove(key);
    try store.commit();
    try store.collectPayload();
    const space = try store.payloadSpace();
    try std.testing.expect(space.free_pages * page > length);
    try std.testing.expect(space.largest_run * page < length);
    try store.begin();
    try std.testing.expectError(error.NoSpace, store.beginStream(1, length));
    try store.rollback();
    var scratch = model.MapScratch{};
    // Plan a conservative payload budget from every fixed batch and a
    // maximum-height allowance for initial creation of the sparse map.
    var block: [page * model.max_mapped_batch_pages]u8 = @splat(0);
    var patches: [model.max_mapped_batch_pages]model.MappedPatch = undefined;
    var payload_plan: u64 = model.extent_map.max_height + 1;
    var planned_batches: u32 = 0;
    var planned: u64 = 0;
    while (planned < length) {
        const n: usize = @intCast(@min(block.len, length - planned));
        var count: usize = 0;
        var cursor: usize = 0;
        while (cursor < n) {
            const chunk = @min(page, n - cursor);
            patches[count] = .{ .offset = planned + cursor, .bytes = block[cursor..][0..chunk] };
            count += 1;
            cursor += chunk;
        }
        payload_plan += try fixture.Store.mappedBatchPages(length, patches[0..count]);
        planned += n;
        planned_batches += 1;
    }
    try store.beginBudgeted(.{ .payload_writes = payload_plan, .index_writes = planned_batches + 2, .index_peak = 2, .payload_margin = 4, .index_margin = 1 });
    try store.put(1, "");
    var steps: usize = 0;
    try store.requireIndexHeadroom(1);
    try search(&store, try store.mappedResizePages(1, length, &scratch), &steps);
    try store.resizeMappedPrepared(1, length, &scratch);
    var input_hash = std.crypto.hash.sha2.Sha256.init(.{});
    var written: u64 = 0;
    var batches: usize = 0;
    while (written < length) {
        const n: usize = @intCast(@min(block.len, length - written));
        try std.testing.expectEqual(n, try input.readPositionalAll(io, block[0..n], written));
        input_hash.update(block[0..n]);
        var count: usize = 0;
        var cursor: usize = 0;
        while (cursor < n) {
            const chunk = @min(page, n - cursor);
            patches[count] = .{ .offset = written + cursor, .bytes = block[cursor..][0..chunk] };
            count += 1;
            cursor += chunk;
        }
        try store.requireIndexHeadroom(1);
        try search(&store, try fixture.Store.mappedBatchPages(length, patches[0..count]), &steps);
        try store.patchMappedBatchPrepared(1, patches[0..count], &scratch);
        try std.testing.expectError(error.NotFound, store.get(1));
        written += n;
        batches += 1;
    }
    const used_payload = store.budget_payload_used;
    const used_index = store.budget_index_used;
    try store.commit();
    try std.testing.expectError(error.Busy, store.begin());
    try store.releaseBudget();
    dev.close();
    dev = try fixture.Device.open(io, tmp.dir, "store");
    defer dev.close();
    var recovered: fixture.Store = .{};
    try recovered.recover(&dev);
    try recovered.verify(1);
    for ([_]u32{ 2, 4 }) |key| {
        try recovered.verify(key);
        var byte: [1]u8 = undefined;
        try std.testing.expectEqual(@as(usize, 1), try recovered.read(key, 0, &byte));
        try std.testing.expectEqual(@as(u8, @intCast(key)), byte[0]);
    }
    var output_hash = std.crypto.hash.sha2.Sha256.init(.{});
    at = 0;
    while (at < length) {
        const n: usize = @intCast(@min(block.len, length - at));
        try std.testing.expectEqual(n, try recovered.read(1, at, block[0..n]));
        output_hash.update(block[0..n]);
        at += n;
    }
    var expected: [32]u8 = undefined;
    var actual: [32]u8 = undefined;
    input_hash.final(&expected);
    output_hash.final(&actual);
    try std.testing.expectEqualSlices(u8, &expected, &actual);
    const pin = try recovered.pinObject(1);
    defer recovered.release(pin) catch unreachable;
    var source = fixture.StoreReader{ .store = &recovered, .pin = pin, .base = 0 };
    var dict = try nfst.Dictionary(fixture.StoreReader).init(&source, length);
    defer dict.invalidate();
    var result: nfst.Candidates = .{};
    try dict.lookup("かんじ", &result);
    try std.testing.expectEqualStrings("漢字", result.slice(0));
    std.debug.print("BUDGET_MAPPED bytes={d} free_pages={d} largest_run_pages={d} batches={d} search_steps={d} payload={d}/{d} index={d}/{d} candidate={s}\n", .{ length, space.free_pages, space.largest_run, batches, steps, used_payload, payload_plan, used_index, planned_batches + 2, result.slice(0) });
}
