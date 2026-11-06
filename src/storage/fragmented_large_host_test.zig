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
    var scratch = model.MapScratch{};
    try store.begin();
    try store.put(1, "");
    var steps: usize = 0;
    try store.requireIndexHeadroom(1);
    try search(&store, try store.mappedResizePages(1, length, &scratch), &steps);
    try store.resizeMappedPrepared(1, length, &scratch);
    var block: [page * model.max_mapped_batch_pages]u8 = undefined;
    var patches: [model.max_mapped_batch_pages]model.MappedPatch = undefined;
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
    try store.commit();
    dev.close();
    dev = try fixture.Device.open(io, tmp.dir, "store");
    defer dev.close();
    var recovered: fixture.Store = .{};
    try recovered.recover(&dev);
    try recovered.verify(1);
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
    std.debug.print("MAPPED_LARGE bytes={d} batches={d} search_steps={d} candidate={s}\n", .{ length, batches, steps, result.slice(0) });
}
