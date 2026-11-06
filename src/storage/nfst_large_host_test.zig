//! Opt-in host integration using a caller-supplied SKK-JISYO.L NFST file.
//! The source dictionary is not vendored; run with NIHOS_NFST_PATH and -lc.
const std = @import("std");
const nfst = @import("nfst_reader.zig");
const fixture = @import("nfst_reader_test.zig");
const io = std.testing.io;

test "large dictionary stream remount and lookup" {
    const env = std.c.getenv("NIHOS_NFST_PATH") orelse return error.SkipZigTest;
    const input = try std.Io.Dir.cwd().openFile(io, std.mem.span(env), .{});
    defer input.close(io);
    const size = (try input.stat(io)).size;
    try std.testing.expect(size > 4 * 1024 * 1024 and size < 7 * 1024 * 1024);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const image = try tmp.dir.createFile(io, "store", .{ .read = true, .exclusive = true });
    const erased: [4096]u8 = @splat(0xff);
    var at: u64 = 0;
    while (at < fixture.Device.capacity) : (at += erased.len) try image.writePositionalAll(io, &erased, at);
    try image.sync(io);
    image.close(io);
    var device = try fixture.Device.open(io, tmp.dir, "store");
    var store: fixture.Store = .{};
    try store.format(&device);
    try store.begin();
    const stream = try store.beginStream(1, size);
    var block: [4096]u8 = undefined;
    var written: u64 = 0;
    while (written < size) {
        const n: usize = @intCast(@min(block.len, size - written));
        try std.testing.expectEqual(n, try input.readPositionalAll(io, block[0..n], written));
        try std.testing.expectEqual(n, try store.writeStream(stream, block[0..n]));
        written += n;
    }
    try store.finishStream(stream);
    try store.commit();
    device.close();
    device = try fixture.Device.open(io, tmp.dir, "store");
    defer device.close();
    var recovered: fixture.Store = .{};
    try recovered.recover(&device);
    const pin = try recovered.pinObject(1);
    defer recovered.release(pin) catch unreachable;
    var source = fixture.StoreReader{ .store = &recovered, .pin = pin, .base = 0 };
    var dict = try nfst.Dictionary(fixture.StoreReader).init(&source, size);
    defer dict.invalidate();
    var result: nfst.Candidates = .{};
    const samples = [_]struct { key: []const u8, first: []const u8, count: u8 }{
        .{ .key = "かんじ", .first = "漢字", .count = 8 },
        .{ .key = "にほん", .first = "日本", .count = 2 },
        .{ .key = "とうきょう", .first = "東京", .count = 2 },
        .{ .key = "がっこう", .first = "学校", .count = 2 },
        .{ .key = "あさ", .first = "朝", .count = 8 },
    };
    for (samples) |sample| {
        try dict.lookup(sample.key, &result);
        try std.testing.expectEqual(sample.count, result.count);
        try std.testing.expectEqualStrings(sample.first, result.slice(0));
    }
    try dict.lookup("かんじ", &result);
    const kanji = [_][]const u8{ "漢字", "幹事", "監事", "感じ", "寛治", "莞爾", "完爾", "完治" };
    try std.testing.expect(result.truncated);
    for (kanji, 0..) |expected, i| try std.testing.expectEqualStrings(expected, result.slice(i));
    try dict.lookup("ぷろぐらみんぐ", &result);
    try std.testing.expectEqual(@as(u8, 0), result.count);
    std.debug.print("LARGE_NFST bytes={d} queries=7 cache_misses={d} cache_bytes={d}\n", .{ size, dict.cache_misses, nfst.page_bytes });
}
