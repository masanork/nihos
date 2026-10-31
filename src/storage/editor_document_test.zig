//! Host-only integration of the xy UTF-8 document and experimental store.
//! This does not register a native storage driver or establish SD durability.
const std = @import("std");
const scratch = @import("../xy/scratch.zig");
const checkpoint = @import("checkpoint_model.zig");
const file_media = @import("file_media.zig");
const Device = file_media.Media(32 * 4096);
const Store = checkpoint.Store(Device, .{ .leaf_pages = 2, .index_pages = 8 });

test "editor bytes survive checkpoint commit and reopen on host media" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const file = try temp.dir.createFile(io, "image", .{ .exclusive = true });
    const erased: [4096]u8 = @splat(0xff);
    for (0..32) |i| try file.writePositionalAll(io, &erased, i * erased.len);
    try file.sync(io);
    file.close(io);

    var document: scratch.Model = undefined;
    document.initInPlace();
    for ("hello  ") |byte| document.handle(.{ .text = byte });
    document.insert("日本語\n  ");
    try std.testing.expectEqualStrings("hello  日本語\n  ", document.doc.slice());
    var device = try Device.open(io, temp.dir, "image");
    var store: Store = .{};
    try store.format(&device);
    try store.begin();
    try store.put(1, document.doc.slice());
    try store.commit();
    device.close();

    device = try Device.open(io, temp.dir, "image");
    defer device.close();
    var recovered: Store = .{};
    try recovered.recover(&device);
    var bytes: [64]u8 = undefined;
    const length = try recovered.read(1, 0, &bytes);
    var restarted: scratch.Model = undefined;
    restarted.initInPlace();
    try restarted.doc.insertUtf8(bytes[0..length]);
    try std.testing.expectEqualStrings("hello  日本語\n  ", restarted.doc.slice());
    try std.testing.expectEqual(length, restarted.doc.cursor);
    try std.testing.expectError(error.InvalidUtf8, restarted.doc.insertUtf8("\xff"));
    try std.testing.expectEqualStrings("hello  日本語\n  ", restarted.doc.slice());
    try std.testing.expectError(error.BufferFull, restarted.doc.insertUtf8(&@as([4096]u8, @splat('x'))));
    try std.testing.expectEqualStrings("hello  日本語\n  ", restarted.doc.slice());
}
