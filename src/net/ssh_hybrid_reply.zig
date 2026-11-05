//! Parse the complete SSH hybrid KEX reply before submitting its ciphertext.
//! Returned slices borrow the input; retain it unchanged through verification.
const std = @import("std");
const hybrid = @import("ssh_hybrid_transcript.zig");
pub const Reply = struct {
    host: []const u8,
    server: *const [hybrid.server_len]u8,
    signature: []const u8,
    pub fn ciphertext(self: Reply) *const [1088]u8 {
        return self.server[0..1088];
    }
};
const Reader = struct {
    input: []const u8,
    pos: usize = 0,
    fn take(self: *Reader, n: usize) error{Malformed}![]const u8 {
        if (n > self.input.len - self.pos) return error.Malformed;
        const result = self.input[self.pos..][0..n];
        self.pos += n;
        return result;
    }
    fn string(self: *Reader) error{Malformed}![]const u8 {
        const n = std.mem.readInt(u32, (try self.take(4))[0..4], .big);
        return self.take(n);
    }
};
pub fn parse(input: []const u8) error{Malformed}!Reply {
    var r: Reader = .{ .input = input };
    if ((try r.take(1))[0] != 31) return error.Malformed;
    const host = try r.string();
    const server = try r.string();
    const signature = try r.string();
    if (server.len != hybrid.server_len or r.pos != input.len) return error.Malformed;
    return .{ .host = host, .server = server[0..hybrid.server_len], .signature = signature };
}

test "complete reply is required before ciphertext is exposed" {
    var input: [1 + 4 + 1 + 4 + hybrid.server_len + 4 + 1]u8 = @splat(0);
    input[0] = 31;
    std.mem.writeInt(u32, input[1..5], 1, .big);
    input[5] = 7;
    std.mem.writeInt(u32, input[6..10], hybrid.server_len, .big);
    input[10] = 42;
    const sigpos = 10 + hybrid.server_len;
    std.mem.writeInt(u32, input[sigpos..][0..4], 1, .big);
    input[sigpos + 4] = 9;
    const reply = try parse(&input);
    try std.testing.expectEqual(@as(u8, 42), reply.ciphertext()[0]);
    try std.testing.expectEqualSlices(u8, &.{7}, reply.host);
    try std.testing.expectEqualSlices(u8, &.{9}, reply.signature);
    for (0..input.len) |n| try std.testing.expectError(error.Malformed, parse(input[0..n]));
    var extra: [input.len + 1]u8 = @splat(0);
    @memcpy(extra[0..input.len], &input);
    try std.testing.expectError(error.Malformed, parse(&extra));
    input[0] = 30;
    try std.testing.expectError(error.Malformed, parse(&input));
    input[0] = 31;
    input[1..5].* = @splat(0xff);
    try std.testing.expectError(error.Malformed, parse(&input));
    std.mem.writeInt(u32, input[1..5], 1, .big);
    std.mem.writeInt(u32, input[6..10], hybrid.server_len - 1, .big);
    try std.testing.expectError(error.Malformed, parse(&input));
    std.mem.writeInt(u32, input[6..10], hybrid.server_len, .big);
    input[sigpos..][0..4].* = @splat(0xff);
    try std.testing.expectError(error.Malformed, parse(&input));
}
