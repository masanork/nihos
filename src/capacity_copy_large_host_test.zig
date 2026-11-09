//! Opt-in, disposable host-image migration. Both supplied paths are controlled
//! by the test caller; the legacy image is copied before any store is opened.
const std = @import("std");
const media = @import("storage/file_media.zig");
const model = @import("storage/checkpoint_model.zig");
const migration = @import("storage/capacity_copy.zig");
const nfst = @import("storage/nfst_reader.zig");
// Linked from the separately compiled host-only 32 MiB ABI root.
extern fn nih_store_size() callconv(.c) usize;
extern fn nih_store_mount(*anyopaque, usize, *const Callbacks, c_int) callconv(.c) c_int;
extern fn nih_store_dictionary_begin(*anyopaque, u64, *u64) callconv(.c) c_int;
extern fn nih_store_dictionary_write(*anyopaque, u64, [*]const u8, usize) callconv(.c) c_int;
extern fn nih_store_dictionary_finish(*anyopaque, u64) callconv(.c) c_int;
extern fn nih_store_sync(*anyopaque) callconv(.c) c_int;
const io = std.testing.io;
const OldDevice = media.Media(4 * 1024 * 1024);
const NewDevice = media.Media(32 * 1024 * 1024);
const OldStore = model.Store(OldDevice, .{ .leaf_pages = 2, .index_pages = 64, .reader_slots = 4 });
const NewStore = model.Store(NewDevice, .{ .leaf_pages = 2, .index_pages = 64, .reader_slots = 4 });
const DictReader = struct {
    store: *NewStore,
    pin: model.Reader,
    pub fn read(self: *@This(), offset: u64, output: []u8) model.Error!usize {
        return self.store.readPinned(self.pin, 64, offset, output);
    }
};
fn digest(file: std.Io.File, length: u64) ![32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var bytes: [4096]u8 = undefined;
    var at: u64 = 0;
    while (at < length) {
        const n: usize = @intCast(@min(bytes.len, length - at));
        try std.testing.expectEqual(n, try file.readPositionalAll(io, bytes[0..n], at));
        hash.update(bytes[0..n]);
        at += n;
    }
    return hash.finalResult();
}
const Callbacks = extern struct {
    context: ?*anyopaque,
    read: *const fn (?*anyopaque, u64, [*]u8, usize) callconv(.c) c_int,
    write: *const fn (?*anyopaque, u64, [*]const u8, usize) callconv(.c) c_int,
    sync: *const fn (?*anyopaque) callconv(.c) c_int,
};
const AbiMedia = struct {
    fn read(ctx: ?*anyopaque, offset: u64, out: [*]u8, count: usize) callconv(.c) c_int {
        const device: *NewDevice = @ptrCast(@alignCast(ctx.?));
        device.read(offset, out[0..count]) catch return -1;
        return 0;
    }
    fn write(ctx: ?*anyopaque, offset: u64, data: [*]const u8, count: usize) callconv(.c) c_int {
        const device: *NewDevice = @ptrCast(@alignCast(ctx.?));
        device.write(offset, data[0..count]) catch return -1;
        return 0;
    }
    fn sync(ctx: ?*anyopaque) callconv(.c) c_int {
        const device: *NewDevice = @ptrCast(@alignCast(ctx.?));
        device.sync() catch return -1;
        return 0;
    }
};

test "larger host store copies real SQLite image and imports external dictionary" {
    const image_path = std.c.getenv("NIHOS_LEGACY_IMAGE") orelse return error.SkipZigTest;
    const dictionary_path = std.c.getenv("NIHOS_NFST_PATH") orelse return error.SkipZigTest;
    const output_path = std.c.getenv("NIHOS_MIGRATED_DB") orelse return error.SkipZigTest;
    const image = try std.Io.Dir.cwd().openFile(io, std.mem.span(image_path), .{});
    defer image.close(io);
    try std.testing.expectEqual(OldDevice.capacity, (try image.stat(io)).size);
    const dictionary = try std.Io.Dir.cwd().openFile(io, std.mem.span(dictionary_path), .{});
    defer dictionary.close(io);
    const dictionary_size = (try dictionary.stat(io)).size;
    try std.testing.expect(dictionary_size > OldDevice.capacity and dictionary_size < 7 * 1024 * 1024);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const source_file = try tmp.dir.createFile(io, "source", .{ .read = true, .exclusive = true });
    var block: [4096]u8 = undefined;
    var offset: u64 = 0;
    while (offset < OldDevice.capacity) : (offset += block.len) {
        try std.testing.expectEqual(block.len, try image.readPositionalAll(io, &block, offset));
        try source_file.writePositionalAll(io, &block, offset);
    }
    try source_file.sync(io);
    source_file.close(io);
    const destination_file = try tmp.dir.createFile(io, "destination", .{ .read = true, .exclusive = true });
    const erased: [4096]u8 = @splat(0xff);
    offset = 0;
    while (offset < NewDevice.capacity) : (offset += erased.len) try destination_file.writePositionalAll(io, &erased, offset);
    try destination_file.sync(io);
    destination_file.close(io);
    var source_device = try OldDevice.open(io, tmp.dir, "source");
    defer source_device.close();
    var target_device = try NewDevice.open(io, tmp.dir, "destination");
    var source: OldStore = .{};
    var target: NewStore = .{};
    try source.recover(&source_device);
    try target.format(&target_device);
    const source_hash = try digest(source_device.file, OldDevice.capacity);
    var scratch: migration.Scratch = .{};
    const report = try migration.copy(&source, &target, 1, 2, &scratch);
    try std.testing.expect(report.objects > 0);
    try std.testing.expectError(error.NotFound, source.get(64));
    const source_pin = try source.pin();
    defer source.release(source_pin) catch unreachable;
    const storage = try std.testing.allocator.alignedAlloc(u8, .@"16", nih_store_size());
    defer std.testing.allocator.free(storage);
    const raw: *anyopaque = @ptrCast(storage.ptr);
    const callbacks = Callbacks{ .context = &target_device, .read = AbiMedia.read, .write = AbiMedia.write, .sync = AbiMedia.sync };
    try std.testing.expectEqual(@as(c_int, 0), nih_store_mount(raw, storage.len, &callbacks, 0));
    var stream: u64 = 0;
    try std.testing.expectEqual(@as(c_int, 0), nih_store_dictionary_begin(raw, dictionary_size, &stream));
    offset = 0;
    while (offset < dictionary_size) {
        const n: usize = @intCast(@min(block.len, dictionary_size - offset));
        try std.testing.expectEqual(n, try dictionary.readPositionalAll(io, block[0..n], offset));
        try std.testing.expectEqual(@as(c_int, @intCast(n)), nih_store_dictionary_write(raw, stream, &block, n));
        offset += n;
    }
    try std.testing.expectEqual(@as(c_int, 0), nih_store_dictionary_finish(raw, stream));
    try std.testing.expectEqual(@as(c_int, 0), nih_store_sync(raw));
    target_device.close();
    target_device = try NewDevice.open(io, tmp.dir, "destination");
    defer target_device.close();
    var recovered: NewStore = .{};
    try recovered.recover(&target_device);
    // Compare every original key after reopening; permit only the new dictionary.
    for (1..OldStore.max_objects + 1) |raw_key| {
        const key: u32 = @intCast(raw_key);
        if (key == 64) continue;
        const original = source.getPinned(source_pin, key) catch |err| {
            if (err != error.NotFound) return err;
            try std.testing.expectError(error.NotFound, recovered.get(key));
            continue;
        };
        const actual = try recovered.get(key);
        try std.testing.expectEqual(original.kind, actual.kind);
        try std.testing.expectEqual(original.length, actual.length);
        offset = 0;
        while (offset < original.length) {
            const n: usize = @intCast(@min(block.len, original.length - offset));
            try std.testing.expectEqual(n, try source.readPinnedWithScratch(source_pin, key, offset, scratch.data[0..n], &scratch.read));
            try std.testing.expectEqual(n, try recovered.read(key, offset, scratch.compare[0..n]));
            try std.testing.expectEqualSlices(u8, scratch.data[0..n], scratch.compare[0..n]);
            offset += n;
        }
    }
    try std.testing.expectEqualSlices(u8, &source_hash, &(try digest(source_device.file, OldDevice.capacity)));
    const db = try recovered.get(1);
    const exported = try std.Io.Dir.cwd().createFile(io, std.mem.span(output_path), .{ .exclusive = true });
    defer exported.close(io);
    offset = 0;
    while (offset < db.length) {
        const n: usize = @intCast(@min(block.len, db.length - offset));
        try std.testing.expectEqual(n, try recovered.read(1, offset, block[0..n]));
        try exported.writePositionalAll(io, block[0..n], offset);
        offset += n;
    }
    try exported.sync(io);
    const dict_pin = try recovered.pinObject(64);
    offset = 0;
    while (offset < dictionary_size) {
        const n: usize = @intCast(@min(block.len, dictionary_size - offset));
        try std.testing.expectEqual(n, try dictionary.readPositionalAll(io, scratch.data[0..n], offset));
        try std.testing.expectEqual(n, try recovered.readPinnedWithScratch(dict_pin, 64, offset, scratch.compare[0..n], &scratch.read));
        try std.testing.expectEqualSlices(u8, scratch.data[0..n], scratch.compare[0..n]);
        offset += n;
    }
    var source_reader = DictReader{ .store = &recovered, .pin = dict_pin };
    var dict = try nfst.Dictionary(DictReader).init(&source_reader, dictionary_size);
    var candidates: nfst.Candidates = .{};
    try dict.lookup("かんじ", &candidates);
    try std.testing.expectEqualStrings("漢字", candidates.slice(0));
    dict.invalidate();
    try recovered.release(dict_pin);
    std.debug.print("CAPACITY_COPY objects={d} bytes={d} dictionary={d} source_unchanged=1\n", .{ report.objects, report.bytes, dictionary_size });
}
