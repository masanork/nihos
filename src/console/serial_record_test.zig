const std = @import("std");
const session = @import("session.zig");
const record = @import("../diagnostics/record.zig");
const Discard = struct {
    pub fn write(_: *@This(), _: []const u8) void {}
};
const Buffer = struct {
    bytes: [2048]u8 = @splat(0),
    length: usize = 0,
    fn write(self: *@This(), bytes: []const u8) void {
        @memcpy(self.bytes[self.length..][0..bytes.len], bytes);
        self.length += bytes.len;
    }
};
test "a diagnostic record redraws the unsubmitted serial line at its cursor" {
    const HookSink = struct {
        model: *session.Model,
        buffer: Buffer = .{},
        pub fn write(self: *@This(), bytes: []const u8) void {
            self.buffer.write(bytes);
        }
        pub fn beginRecord(self: *@This()) bool {
            self.write("\r\x1b[2K");
            return true;
        }
        pub fn endRecord(self: *@This(), active: bool) void {
            if (active) self.model.redrawLine(self);
        }
    };
    var model: session.Model = .{};
    var discard: Discard = .{};
    model.startTerminal(&discard);
    for ("abc") |byte| _ = model.handle(.{ .text = byte }, &discard);
    _ = model.handle(.left, &discard);
    var output = HookSink{ .model = &model };
    var writer = record.Writer(*HookSink){ .sink = &output };
    const value: extern struct { count: u32 } = .{ .count = 1 };
    writer.record("EVENT", null, .{"count"}, &value);
    try std.testing.expectEqualStrings("\r\x1b[2KEVENT count=00000001\n\r\x1b[2Knihos> abc\x1b[D", output.buffer.bytes[0..output.buffer.length]);
    try std.testing.expectEqual(@as(usize, 2), model.line_cursor);
    try std.testing.expectEqualStrings("abc", model.line[0..model.length]);
}
