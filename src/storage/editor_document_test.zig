//! Host-only integration of the launcher document and experimental store.
//! This does not register a native storage driver or establish SD durability.
const std = @import("std");
const session = @import("../console/session.zig");
const checkpoint = @import("checkpoint_model.zig");
const file_media = @import("file_media.zig");
const Device = file_media.Media(32 * 4096);
const Store = checkpoint.Store(Device, .{ .leaf_pages = 2, .index_pages = 8 });
const Sink = struct {
    pub fn write(_: *@This(), _: []const u8) void {}
};

test "editor bytes survive checkpoint commit and reopen on host media" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const file = try temp.dir.createFile(io, "image", .{ .exclusive = true });
    const erased: [4096]u8 = @splat(0xff);
    for (0..32) |i| try file.writePositionalAll(io, &erased, i * erased.len);
    try file.sync(io);
    file.close(io);

    var document: session.Model = .{};
    var sink: Sink = .{};
    _ = document.handle(.{ .text = '5' }, &sink);
    _ = document.handle(.enter, &sink);
    for ("hello  ") |byte| _ = document.handle(.{ .text = byte }, &sink);
    try std.testing.expectEqualStrings("hello  ", document.editorText());
    var device = try Device.open(io, temp.dir, "image");
    var store: Store = .{};
    try store.format(&device);
    try store.begin();
    try store.put(1, document.editorText());
    try store.commit();
    device.close();

    device = try Device.open(io, temp.dir, "image");
    defer device.close();
    var recovered: Store = .{};
    try recovered.recover(&device);
    var bytes: [64]u8 = undefined;
    const length = try recovered.read(1, 0, &bytes);
    var restarted: session.Model = .{};
    try restarted.loadEditor(bytes[0..length]);
    try std.testing.expectEqualStrings("hello  ", restarted.editorText());
    try std.testing.expectEqual(@as(usize, 7), restarted.editor_cursor.column);
    try std.testing.expectError(error.UnsupportedDocument, restarted.loadEditor("bad\n"));
    try std.testing.expectEqualStrings("hello  ", restarted.editorText());
    try std.testing.expectError(error.UnsupportedDocument, restarted.loadEditor(&@as([65]u8, @splat('x'))));
    try std.testing.expectEqualStrings("hello  ", restarted.editorText());
}
