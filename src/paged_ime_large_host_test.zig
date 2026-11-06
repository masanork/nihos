//! Opt-in host integration using a caller-supplied SKK-JISYO.L NFST file.
//! The source dictionary is not vendored; run with NIHOS_NFST_PATH and -lc.
const std = @import("std");
const nfst = @import("storage/nfst_reader.zig");
const fixture = @import("storage/nfst_reader_test.zig");
const io = std.testing.io;

test "large paged dictionary drives IME after remount" {
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
    // A delayed host completion traverses the real pinned store. The page
    // coordinator never exposes its internal buffer to an I/O producer.
    var async_page: @import("storage/async_page.zig").Coordinator = .{};
    try async_page.attach(1, size);
    const request = try async_page.request(0);
    var magic: [4]u8 = undefined;
    try std.testing.expectError(error.NotReady, async_page.copy(request, 0, &magic));
    var received: [4096]u8 = undefined;
    try std.testing.expectEqual(request.length, try source.read(request.offset, received[0..request.length]));
    try async_page.complete(request, received[0..request.length]);
    try async_page.copy(request, 0, &magic);
    try std.testing.expectEqualStrings("NFST", &magic);
    const cancelled = try async_page.request(4096);
    try async_page.cancel(cancelled);
    try std.testing.expectError(error.Busy, async_page.detach());
    try std.testing.expectEqual(cancelled.length, try source.read(cancelled.offset, received[0..cancelled.length]));
    try async_page.complete(cancelled, received[0..cancelled.length]);
    try async_page.detach();
    var dict = try nfst.Dictionary(fixture.StoreReader).init(&source, size);
    defer dict.invalidate();
    var resumable_page: @import("storage/async_page.zig").Coordinator = .{};
    try resumable_page.attach(2, size);
    var page_count: usize = 0;
    for ([_][]const u8{ "かんじ", "にほん", "とうきょう", "がっこう", "ぷろぐらみんぐ" }) |key| {
        var expected: nfst.Candidates = .{};
        try dict.lookup(key, &expected);
        var lookup = try @import("storage/async_nfst.zig").Lookup.begin(&resumable_page, key);
        var work: usize = 0;
        while (true) {
            work += 1;
            try std.testing.expect(work < 100000);
            switch (try lookup.step(64)) {
                .pending => {},
                .need_page => {
                    const req = lookup.request().?;
                    var async_bytes: [4096]u8 = undefined;
                    try std.testing.expectEqual(req.length, try source.read(req.offset, async_bytes[0..req.length]));
                    try lookup.supply(req, async_bytes[0..req.length]);
                    page_count += 1;
                },
                .complete => break,
                .cancelled => return error.TestUnexpectedResult,
            }
        }
        const actual = try lookup.candidates();
        try std.testing.expectEqual(expected.count, actual.count);
        try std.testing.expectEqual(expected.truncated, actual.truncated);
        for (0..expected.count) |i| try std.testing.expectEqualStrings(expected.slice(i), actual.slice(i));
    }
    try resumable_page.detach();
    std.debug.print("ASYNC_NFST keys=5 page_requests={d}\n", .{page_count});
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
    var adapter = @import("xy/paged_conversion.zig").Adapter(fixture.StoreReader){ .dictionary = &dict };
    var ime: @import("xy/standard_ime.zig").State = .{};
    var document: @import("xy/document.zig").Document(512, 16, 512, 1, 64) = .{};
    for ("kanji") |c| try ime.key(&document, &adapter, c);
    try ime.key(&document, &adapter, ' ');
    try std.testing.expectEqualStrings("漢字", document.preedit.slice());
    try std.testing.expect(adapter.truncated);
    try ime.key(&document, &adapter, ' ');
    try std.testing.expectEqualStrings("幹事", document.preedit.slice());
    try ime.key(&document, &adapter, '\n');
    try std.testing.expectEqualStrings("幹事", document.slice());
    // Compare identical conversions from cold page caches. No device latency is
    // inferred from these host file-backed read counts.
    const cases = [_][]const u8{ "kanji", "kyouhaiitenkidesune", "watashihagakuseidesu" };
    for (cases) |keys| {
        var baseline = @import("xy/standard_ime.zig").State{};
        var optimized = @import("xy/standard_ime.zig").State{};
        var baseline_doc: @import("xy/document.zig").Document(512, 16, 512, 1, 64) = .{};
        var optimized_doc: @import("xy/document.zig").Document(512, 16, 512, 1, 64) = .{};
        for (keys) |c| {
            try baseline.key(&baseline_doc, &adapter, c);
            try optimized.key(&optimized_doc, &adapter, c);
        }
        dict.cache_valid = false;
        dict.root_cache_valid = false;
        dict.root_cache_enabled = true;
        dict.victim_valid = false;
        dict.victim_enabled = false;
        adapter.memo_enabled = true;
        const before = dict.cache_misses;
        try baseline.key(&baseline_doc, &adapter, ' ');
        const old_reads = dict.cache_misses - before;
        dict.cache_valid = false;
        dict.root_cache_valid = false;
        dict.root_cache_enabled = true;
        dict.victim_valid = false;
        dict.victim_enabled = true;
        adapter.memo_enabled = true;
        const middle = dict.cache_misses;
        try optimized.key(&optimized_doc, &adapter, ' ');
        const new_reads = dict.cache_misses - middle;
        try std.testing.expectEqualStrings(baseline_doc.preedit.slice(), optimized_doc.preedit.slice());
        try std.testing.expectEqual(baseline.engine.segment_count, optimized.engine.segment_count);
        for (0..baseline.engine.segment_count) |i| {
            try std.testing.expectEqual(baseline.engine.segments[i].cand_count, optimized.engine.segments[i].cand_count);
            for (0..baseline.engine.segments[i].cand_count) |j| {
                try std.testing.expectEqualStrings(baseline.engine.candidateText(i, j), optimized.engine.candidateText(i, j));
            }
        }
        try std.testing.expect(new_reads <= old_reads);
        std.debug.print("PAGED_IME keys={s} before={d} after={d} memo_hits={d}\n", .{ keys, old_reads, new_reads, adapter.memo_hits });
    }
    const conv = @import("xy/conv.zig");
    var reference: conv.Engine = .{};
    var sliced_engine: conv.Engine = .{};
    const reading = "きょうはいいてんきですね";
    adapter.beginConversion();
    reference.convert(&adapter, reading);
    try adapter.conversionError();
    var cursor: conv.SlicedConversion = .{};
    cursor.begin(&sliced_engine, &adapter, reading);
    var yields: usize = 0;
    while (try cursor.step(&sliced_engine, &adapter, 1) == .pending) {
        try std.testing.expectEqual(@as(usize, 0), sliced_engine.segment_count);
        yields += 1;
        try std.testing.expect(yields < 20000);
    }
    try std.testing.expect(yields > 1);
    try std.testing.expectEqual(reference.segment_count, sliced_engine.segment_count);
    for (0..reference.segment_count) |i| {
        try std.testing.expectEqual(reference.segments[i].cand_count, sliced_engine.segments[i].cand_count);
        for (0..reference.segments[i].cand_count) |j| try std.testing.expectEqualStrings(reference.candidateText(i, j), sliced_engine.candidateText(i, j));
    }
    std.debug.print("SLICED_PAGED_IME yields={d} cursor_bytes={d}\n", .{ yields, @sizeOf(conv.SlicedConversion) });
    var worker_page: @import("storage/async_page.zig").Coordinator = .{};
    try worker_page.attach(3, size);
    var async_adapter = @import("xy/async_conversion.zig").Adapter{ .coordinator = &worker_page };
    var async_engine: conv.Engine = .{};
    var async_cursor: conv.SlicedConversion = .{};
    async_cursor.begin(&async_engine, &async_adapter, "かんじ");
    var async_waits: usize = 0;
    var async_pages: usize = 0;
    while (true) {
        switch (try async_cursor.step(&async_engine, &async_adapter, 8)) {
            .pending => {},
            .waiting => {
                async_waits += 1;
                try std.testing.expect(async_waits < 1000);
                while (true) switch (try async_adapter.step(128)) {
                    .pending => {},
                    .need_page => {
                        const req = async_adapter.request().?;
                        var async_bytes: [4096]u8 = undefined;
                        try std.testing.expectEqual(req.length, try source.read(req.offset, async_bytes[0..req.length]));
                        try async_adapter.supply(req, async_bytes[0..req.length]);
                        async_pages += 1;
                    },
                    .complete => break,
                    .cancelled => return error.TestUnexpectedResult,
                };
            },
            .complete => break,
            .cancelled => return error.TestUnexpectedResult,
        }
    }
    adapter.beginConversion();
    var async_reference: conv.Engine = .{};
    async_reference.convert(&adapter, "かんじ");
    try adapter.conversionError();
    try std.testing.expectEqual(async_reference.segment_count, async_engine.segment_count);
    for (0..async_reference.segment_count) |i| {
        try std.testing.expectEqual(async_reference.segments[i].cand_count, async_engine.segments[i].cand_count);
        for (0..async_reference.segments[i].cand_count) |j| try std.testing.expectEqualStrings(async_reference.candidateText(i, j), async_engine.candidateText(i, j));
    }
    try worker_page.detach();
    std.debug.print("ASYNC_CONVERSION waits={d} page_requests={d} adapter_bytes={d}\n", .{ async_waits, async_pages, @sizeOf(@import("xy/async_conversion.zig").Adapter) });
    std.debug.print("LARGE_NFST bytes={d} cumulative_cache_misses={d} data_cache_bytes={d}\n", .{ size, dict.cache_misses, nfst.page_bytes });
}
