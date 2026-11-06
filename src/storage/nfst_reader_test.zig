const std = @import("std");
const nfst = @import("nfst_reader.zig");
const media = @import("file_media.zig");
const checkpoint = @import("checkpoint_model.zig");
const io = std.testing.io;
pub const Device = media.Media(16 * 1024 * 1024);
pub const Store = checkpoint.Store(Device, .{ .leaf_pages = 2, .index_pages = 8 });

// Tiny hand-written NFST: "a" -> "漢字". The arena straddles 4 KiB.
fn fixture() [4101]u8 {
    var b: [4101]u8 = @splat(0);
    @memcpy(b[0..4], "NFST");
    std.mem.writeInt(u16, b[4..6], 1, .little);
    std.mem.writeInt(u32, b[8..12], 1, .little);
    std.mem.writeInt(u32, b[12..16], 36, .little);
    std.mem.writeInt(u32, b[16..20], 17, .little);
    std.mem.writeInt(u32, b[20..24], 53, .little);
    std.mem.writeInt(u32, b[24..28], 4042, .little);
    std.mem.writeInt(u32, b[28..32], 4095, .little);
    std.mem.writeInt(u32, b[32..36], 6, .little);
    b[36] = 0;
    std.mem.writeInt(u32, b[37..41], 0xffffffff, .little);
    b[41] = 1;
    std.mem.writeInt(u32, b[42..46], 10, .little);
    b[46] = 1;
    b[47] = 'a';
    std.mem.writeInt(u32, b[48..52], 0, .little);
    b[52] = 0;
    b[53] = 1;
    std.mem.writeInt(u32, b[54..58], 6 << 24, .little);
    @memcpy(b[4095..4101], "漢字");
    return b;
}
const Bytes = struct {
    bytes: []const u8,
    fail: bool = false,
    short: bool = false,
    calls: usize = 0,
    pub fn read(self: *@This(), offset: u64, out: []u8) error{Io}!usize {
        self.calls += 1;
        if (self.fail) return error.Io;
        if (offset > self.bytes.len or out.len > self.bytes.len - offset) return error.Io;
        const n = if (self.short and out.len > 0) out.len - 1 else out.len;
        @memcpy(out[0..n], self.bytes[@intCast(offset)..][0..n]);
        return n;
    }
};

test "paged NFST copies results across cache boundaries and fails closed" {
    var bytes = fixture();
    var source = Bytes{ .bytes = &bytes };
    var dict = try nfst.Dictionary(Bytes).init(&source, bytes.len);
    var result: nfst.Candidates = .{};
    try dict.lookup("a", &result);
    try std.testing.expectEqual(@as(u8, 1), result.count);
    try std.testing.expectEqualStrings("漢字", result.slice(0));
    try std.testing.expectEqual(@as(u64, 2), dict.cache_misses);
    try dict.lookup("z", &result);
    try std.testing.expectEqual(@as(u8, 0), result.count);
    try std.testing.expectError(error.InvalidKey, dict.lookup("", &result));
    try std.testing.expectEqual(@as(u8, 0), result.count);
    // A self-referential child must not hang or return stale candidates.
    std.mem.writeInt(u32, bytes[42..46], 0, .little);
    dict = try nfst.Dictionary(Bytes).init(&source, bytes.len);
    try std.testing.expectError(error.Corrupt, dict.lookup("a", &result));
    try std.testing.expectEqual(@as(u8, 0), result.count);
    bytes = fixture();
    source.fail = true;
    try std.testing.expectError(error.Io, nfst.Dictionary(Bytes).init(&source, bytes.len));
    source.fail = false;
    source.short = true;
    try std.testing.expectError(error.Io, nfst.Dictionary(Bytes).init(&source, bytes.len));
    source.short = false;
    dict = try nfst.Dictionary(Bytes).init(&source, bytes.len);
    source.fail = true; // Candidate straddles a second page.
    try std.testing.expectError(error.Io, dict.lookup("a", &result));
    try std.testing.expectEqual(@as(u8, 0), result.count);
    source.fail = false;
    try std.testing.expectError(error.Io, dict.lookup("a", &result));

    bytes = fixture();
    std.mem.writeInt(u32, bytes[28..32], 0xffffffff, .little);
    try std.testing.expectError(error.Corrupt, nfst.Dictionary(Bytes).init(&source, bytes.len));
    bytes = fixture();
    // A candidate extending beyond the arena is not silently shortened.
    std.mem.writeInt(u32, bytes[54..58], (6 << 24) | 1, .little);
    dict = try nfst.Dictionary(Bytes).init(&source, bytes.len);
    try std.testing.expectError(error.Corrupt, dict.lookup("a", &result));
    try std.testing.expectEqual(@as(u8, 0), result.count);
    bytes = fixture();
    bytes[4095] = 0xff;
    dict = try nfst.Dictionary(Bytes).init(&source, bytes.len);
    try std.testing.expectError(error.Corrupt, dict.lookup("a", &result));
}

pub const StoreReader = struct {
    store: *Store,
    pin: checkpoint.Reader,
    base: u64,
    pub fn read(self: *@This(), offset: u64, out: []u8) checkpoint.Error!usize {
        return self.store.readPinned(self.pin, 1, self.base + offset, out);
    }
};

test "five MiB object streams, remounts, and supports pinned paged lookup" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const f = try tmp.dir.createFile(io, "store", .{ .read = true, .exclusive = true });
    const erased: [4096]u8 = @splat(0xff);
    var at: u64 = 0;
    while (at < Device.capacity) : (at += erased.len) try f.writePositionalAll(io, &erased, at);
    try f.sync(io);
    f.close(io);
    var dev = try Device.open(io, tmp.dir, "store");
    var store: Store = .{};
    try store.format(&dev);
    const base = 5 * 1024 * 1024;
    const bytes = fixture();
    try store.begin();
    const stream = try store.beginStream(1, base + bytes.len);
    const zeros: [4096]u8 = @splat(0);
    var written: usize = 0;
    while (written < base) written += try store.writeStream(stream, &zeros);
    written = 0;
    while (written < bytes.len) written += try store.writeStream(stream, bytes[written..]);
    try store.finishStream(stream);
    try store.commit();
    dev.close();
    dev = try Device.open(io, tmp.dir, "store");
    defer dev.close();
    var recovered: Store = .{};
    try recovered.recover(&dev);
    const pin = try recovered.pinObject(1);
    var source = StoreReader{ .store = &recovered, .pin = pin, .base = base };
    var dict = try nfst.Dictionary(StoreReader).init(&source, bytes.len);
    var result: nfst.Candidates = .{};
    try dict.lookup("a", &result);
    try std.testing.expectEqualStrings("漢字", result.slice(0));
    // An oversized replacement must not disturb the published dictionary.
    try recovered.begin();
    try std.testing.expectError(error.NoSpace, recovered.beginStream(2, Device.capacity));
    try recovered.rollback();
    try dict.lookup("a", &result);
    try std.testing.expectEqualStrings("漢字", result.slice(0));
    try recovered.begin();
    try recovered.put(1, "replacement");
    try recovered.commit();
    // Even after replacement the pinned version and its cached data stay valid.
    try dict.lookup("a", &result);
    try std.testing.expectEqualStrings("漢字", result.slice(0));
    dict.invalidate();
    try recovered.release(pin);
    try std.testing.expectError(error.Io, dict.lookup("a", &result));
}

test "root page cache is pinned to dictionary lifetime and fails closed" {
    const bytes = fixture();
    var source = Bytes{ .bytes = &bytes };
    var dict = try nfst.Dictionary(Bytes).init(&source, bytes.len);
    var result: nfst.Candidates = .{};
    try dict.lookup("a", &result);
    const misses = dict.cache_misses;
    // The candidate is on page 1, but the trie root stays on page 0.
    try dict.lookup("a", &result);
    try std.testing.expectEqual(misses, dict.cache_misses);
    try std.testing.expectEqualStrings("漢字", result.slice(0));
    // A failed page read invalidates both caches, including the pinned root.
    dict.cache_valid = false;
    source.fail = true;
    try std.testing.expectError(error.Io, dict.lookup("a", &result));
    try std.testing.expect(!dict.root_cache_valid);
    try std.testing.expect(!dict.cache_valid);
    source.fail = false;
    try std.testing.expectError(error.Io, dict.lookup("a", &result));
}
