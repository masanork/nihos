//! Bounded CCID framing; command failures remain data for diagnostics.
const std = @import("std");
pub const Error = error{ Malformed, Sequence, Length, ExtensionLimit, Failed };
pub const Response = struct { payload: []const u8, state: u2, status: u2, code: u8 };
pub fn request(output: []u8, kind: u8, sequence: u8, payload: []const u8) Error![]u8 {
    if (payload.len > 502 or output.len < payload.len + 10) return error.Length;
    const size: u32 = @intCast(payload.len);
    output[0] = kind;
    for (0..4) |index| output[1 + index] = @truncate(size >> @as(u5, @intCast(index * 8)));
    output[5] = 0;
    output[6] = sequence;
    @memset(output[7..10], 0);
    @memcpy(output[10..][0..payload.len], payload);
    return output[0 .. 10 + payload.len];
}
pub fn response(bytes: []const u8, kind: u8, sequence: u8) Error!Response {
    if (bytes.len < 10 or bytes[0] != kind or bytes[5] != 0 or bytes[7] & 0x3c != 0 or bytes[7] & 3 == 3 or
        (if (kind == 0x81) bytes[9] > 3 else bytes[9] != 0)) return error.Malformed;
    if (bytes[6] != sequence) return error.Sequence;
    var size: u32 = 0;
    for (0..4) |index| size |= @as(u32, bytes[1 + index]) << @as(u5, @intCast(index * 8));
    if (size != bytes.len - 10) return error.Length;
    const status: u2 = @intCast(bytes[7] >> 6);
    if (status == 3 or (status == 2 and size != 0)) return error.Malformed;
    return .{ .payload = bytes[10..], .state = @intCast(bytes[7] & 3), .status = status, .code = bytes[8] };
}
test "CCID frame validates declared size, slot, sequence and time extensions" {
    var buffer: [32]u8 = @splat(0);
    const frame = try request(&buffer, 0x80, 7, &.{ 0x90, 0 });
    try std.testing.expectEqual(@as(usize, 2), (try response(frame, 0x80, 7)).payload.len);
    try std.testing.expectError(error.Sequence, response(frame, 0x80, 8));
    buffer[1] = 3;
    try std.testing.expectError(error.Length, response(frame, 0x80, 7));
    buffer[1] = 2;
    buffer[5] = 1;
    try std.testing.expectError(error.Malformed, response(frame, 0x80, 7));
    buffer[5] = 0;
    buffer[7] = 0x80;
    try std.testing.expectError(error.Malformed, response(frame, 0x80, 7));
    buffer[1] = 0;
    try std.testing.expectEqual(@as(u2, 2), (try response(frame[0..10], 0x80, 7)).status);
}
