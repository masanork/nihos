const std = @import("std");
const dict = @import("dict");

fn readFileAll(allocator: std.mem.Allocator, path: [:0]const u8) ![]u8 {
    const fd = std.c.open(path, .{}, @as(c_int, 0));
    if (fd < 0) return error.OpenFailed;
    defer _ = std.c.close(fd);
    const end = std.c.lseek(fd, 0, 2);
    if (end < 0) return error.SeekFailed;
    _ = std.c.lseek(fd, 0, 0);
    const size: usize = @intCast(end);
    const buf = try allocator.alloc(u8, size);
    errdefer allocator.free(buf);
    var total: usize = 0;
    while (total < size) {
        const n = std.c.read(fd, buf.ptr + total, size - total);
        if (n <= 0) break;
        total += @intCast(n);
    }
    return buf[0..total];
}

fn getNanoseconds() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("=== nihos vs MeOS Japanese Dictionary Benchmark ===\n\n", .{});

    // Load binaries into memory (simulating memory-mapped flash)
    const meos_bytes = readFileAll(allocator, "build/dict/jisyo_l_meos.bin") catch |err| {
        std.debug.print("Failed to open build/dict/jisyo_l_meos.bin: {s}\n", .{@errorName(err)});
        return;
    };
    defer allocator.free(meos_bytes);

    const nfst_bytes = readFileAll(allocator, "build/dict/jisyo_l_nfst.bin") catch |err| {
        std.debug.print("Failed to open build/dict/jisyo_l_nfst.bin: {s}\n", .{@errorName(err)});
        return;
    };
    defer allocator.free(nfst_bytes);

    const meos = try dict.MeosDict.init(meos_bytes);
    const nfst = try dict.NfstDict.init(nfst_bytes);

    std.debug.print("Dictionary loaded:\n", .{});
    std.debug.print("  MeOS IMD1 size:  {d:>10} bytes ({d:.2} MB), {d} entries\n", .{ meos_bytes.len, @as(f64, @floatFromInt(meos_bytes.len)) / (1024 * 1024), meos.count });
    std.debug.print("  nihos NFST size: {d:>10} bytes ({d:.2} MB), {d} entries\n", .{ nfst_bytes.len, @as(f64, @floatFromInt(nfst_bytes.len)) / (1024 * 1024), nfst.entry_count });
    const diff_bytes = @as(i64, @intCast(nfst_bytes.len)) - @as(i64, @intCast(meos_bytes.len));
    const diff_pct = (@as(f64, @floatFromInt(nfst_bytes.len)) / @as(f64, @floatFromInt(meos_bytes.len)) - 1.0) * 100.0;
    std.debug.print("  Size Delta:      {d:>10} bytes ({d:.1}%)\n\n", .{ diff_bytes, diff_pct });

    // Test query keys
    const test_keys = [_][]const u8{
        "かんじ",
        "うつくしi",
        "にほん",
        "とうきょう",
        "ぷろぐらみんぐ",
        "すき",
        "はたらk",
        "あいさつ",
        "がっこう",
        "あさ",
    };

    var cands: [16][]const u8 = undefined;

    // Verify lookup parity on sample keys
    std.debug.print("Parity verification on sample keys:\n", .{});
    for (test_keys) |k| {
        const nm = meos.lookup(k, &cands);
        const m_first = if (nm > 0) cands[0] else "(none)";
        const nn = nfst.lookup(k, &cands);
        const n_first = if (nn > 0) cands[0] else "(none)";
        std.debug.print("  Key: {s:<15} -> MeOS: {d} cands (1st: {s}), NFST: {d} cands (1st: {s})\n", .{ k, nm, m_first, nn, n_first });
    }
    std.debug.print("\n", .{});

    // Benchmark 1: Repeated Exact Lookups (1,000,000 iterations across test keys)
    const iterations: u64 = 1_000_000;
    std.debug.print("Running Benchmark 1: Exact Match ({d} lookups)...\n", .{iterations});

    var t0 = getNanoseconds();
    var dummy: usize = 0;
    for (0..iterations) |i| {
        const k = test_keys[i % test_keys.len];
        dummy += meos.lookup(k, &cands);
    }
    const meos_time_ns = getNanoseconds() - t0;
    const meos_ns_per_op = @as(f64, @floatFromInt(meos_time_ns)) / @as(f64, @floatFromInt(iterations));

    t0 = getNanoseconds();
    for (0..iterations) |i| {
        const k = test_keys[i % test_keys.len];
        dummy += nfst.lookup(k, &cands);
    }
    const nfst_time_ns = getNanoseconds() - t0;
    const nfst_ns_per_op = @as(f64, @floatFromInt(nfst_time_ns)) / @as(f64, @floatFromInt(iterations));

    std.debug.print("  MeOS IMD1 (Binary Search): {d:>8.2} ms ({d:>6.1} ns/op, {d:.1} M ops/sec)\n", .{
        @as(f64, @floatFromInt(meos_time_ns)) / 1_000_000.0,
        meos_ns_per_op,
        1000.0 / meos_ns_per_op,
    });
    std.debug.print("  nihos NFST (Radix Tree):   {d:>8.2} ms ({d:>6.1} ns/op, {d:.1} M ops/sec)\n", .{
        @as(f64, @floatFromInt(nfst_time_ns)) / 1_000_000.0,
        nfst_ns_per_op,
        1000.0 / nfst_ns_per_op,
    });
    const speedup = meos_ns_per_op / nfst_ns_per_op;
    std.debug.print("  Speedup:                   {d:>8.2}x\n\n", .{speedup});

    // Benchmark 2: Common Prefix Search (Simulating Bunsetsu phrase segment search)
    // Phrase: "きょうはいいてんきですね" (Today is nice weather, isn't it)
    const phrase = "きょうはいいてんきですね";
    const prefix_iterations: u64 = 500_000;
    std.debug.print("Running Benchmark 2: Common Prefix Search on \"{s}\" ({d} passes)...\n", .{ phrase, prefix_iterations });

    const DummyContext = struct {
        hits: usize = 0,
        fn cb(ctx_ptr: *anyopaque, prefix_len: usize, cs: []const []const u8) bool {
            _ = prefix_len;
            const self: *@This() = @ptrCast(@alignCast(ctx_ptr));
            self.hits += cs.len;
            return true;
        }
    };
    var nfst_ctx: DummyContext = .{};

    // MeOS simulated prefix search (calling lookup for every prefix length)
    t0 = getNanoseconds();
    var meos_prefix_hits: usize = 0;
    for (0..prefix_iterations) |_| {
        // Japanese character prefixes: 3 bytes per hiragana character
        var char_idx: usize = 3;
        while (char_idx <= phrase.len) : (char_idx += 3) {
            meos_prefix_hits += meos.lookup(phrase[0..char_idx], &cands);
        }
    }
    const meos_prefix_time_ns = getNanoseconds() - t0;
    const meos_prefix_ns_per_op = @as(f64, @floatFromInt(meos_prefix_time_ns)) / @as(f64, @floatFromInt(prefix_iterations));

    // NFST native single-pass commonPrefixSearch
    t0 = getNanoseconds();
    for (0..prefix_iterations) |_| {
        nfst.commonPrefixSearch(phrase, &nfst_ctx, DummyContext.cb);
    }
    const nfst_prefix_time_ns = getNanoseconds() - t0;
    const nfst_prefix_ns_per_op = @as(f64, @floatFromInt(nfst_prefix_time_ns)) / @as(f64, @floatFromInt(prefix_iterations));

    std.debug.print("  MeOS IMD1 (N x Binary Search): {d:>8.2} ms ({d:>6.1} ns/pass)\n", .{
        @as(f64, @floatFromInt(meos_prefix_time_ns)) / 1_000_000.0,
        meos_prefix_ns_per_op,
    });
    std.debug.print("  nihos NFST (Single Tree Walk):  {d:>8.2} ms ({d:>6.1} ns/pass)\n", .{
        @as(f64, @floatFromInt(nfst_prefix_time_ns)) / 1_000_000.0,
        nfst_prefix_ns_per_op,
    });
    const prefix_speedup = meos_prefix_ns_per_op / nfst_prefix_ns_per_op;
    std.debug.print("  Prefix Search Speedup:          {d:>8.2}x faster!\n\n", .{prefix_speedup});

    if (dummy == 0 and nfst_ctx.hits == 0) return error.Unexpected;
}
