//! Exercise the legacy serial-control admission used by the native session.
const std = @import("std");
const session = @import("session.zig");
const storage = @import("../storage/control.zig");
const devices = @import("../device/control.zig");
const Sink = struct {
    bytes: [2048]u8 = @splat(0),
    len: usize = 0,
    pub fn write(self: *@This(), data: []const u8) void {
        @memcpy(self.bytes[self.len..][0..data.len], data);
        self.len += data.len;
    }
};
const Router = struct {
    model: session.Model = .{},
    decoder: session.input.Serial = .{},
    fs: storage.Parser = .{},
    device: devices.Parser = .{},
    fs_commands: u32 = 0,
    device_commands: u32 = 0,
    sink: Sink = .{},
    fn feed(self: *@This(), byte: u8) void {
        var consumed = false;
        if (session.input.allowDiagnostic(true, self.model.view == .shell, self.model.length, self.fs.collecting)) {
            var command: ?storage.Command = null;
            consumed = self.fs.feed(byte, &command);
            if (command != null) self.fs_commands += 1;
        }
        if (session.input.allowDiagnostic(true, self.model.view == .shell, self.model.length, self.device.collecting)) {
            var command: ?devices.Command = null;
            if (self.device.feed(byte, &command)) {
                if (command != null) self.device_commands += 1;
                consumed = true;
            }
        }
        if (!consumed) if (self.decoder.feed(byte, 0)) |key| {
            _ = self.model.handle(key, &self.sink);
        };
    }
};
test "colon inside shell text and editor text bypasses legacy control commands" {
    var router: Router = .{};
    router.model.startTerminal(&router.sink);
    for ("echo a:b\r") |byte| router.feed(byte);
    try std.testing.expect(std.mem.endsWith(u8, router.sink.bytes[0..router.sink.len], "a:b\r\n"));
    try std.testing.expectEqual(@as(u32, 0), router.fs_commands);
    try std.testing.expectEqual(@as(u32, 0), router.device_commands);
    for ("edit\r") |byte| router.feed(byte);
    for ("x:y") |byte| router.feed(byte);
    try std.testing.expectEqualStrings("x:y", router.model.editorText());
    try std.testing.expect(!router.fs.collecting and !router.device.collecting);
}
test "empty shell prompt still accepts legacy storage and device commands" {
    var router: Router = .{};
    router.model.startTerminal(&router.sink);
    for (":storage\r:devices\r") |byte| router.feed(byte);
    try std.testing.expectEqual(@as(u32, 1), router.fs_commands);
    try std.testing.expectEqual(@as(u32, 1), router.device_commands);
    try std.testing.expectEqual(@as(usize, 0), router.model.length);
}
