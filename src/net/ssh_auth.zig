//! Ed25519 SSH user authentication payload construction. The caller must
//! authenticate the server and protect the private seed before invoking this.
const std = @import("std");
const Ed25519 = std.crypto.sign.Ed25519;
pub const Error = error{ InvalidUsername, BufferTooSmall, KeyError };
const Writer = struct {
    out: []u8,
    pos: usize = 0,
    fn put(self: *Writer, data: []const u8) Error!void {
        if (data.len > self.out.len - self.pos) return error.BufferTooSmall;
        @memcpy(self.out[self.pos..][0..data.len], data);
        self.pos += data.len;
    }
    fn string(self: *Writer, data: []const u8) Error!void {
        if (data.len > std.math.maxInt(u32)) return error.BufferTooSmall;
        var length: [4]u8 = undefined;
        std.mem.writeInt(u32, &length, @intCast(data.len), .big);
        try self.put(&length);
        try self.put(data);
    }
};

/// Seed must be a cryptographically generated Ed25519 private seed. Returns
/// only the SSH payload; its caller is responsible for secure transmission.
pub fn request(out: []u8, user: []const u8, session_id: [32]u8, seed: [32]u8) Error![]const u8 {
    if (user.len == 0 or user.len > 255 or std.mem.indexOfScalar(u8, user, 0) != null) return error.InvalidUsername;
    var pair = Ed25519.KeyPair.generateDeterministic(seed) catch return error.KeyError;
    defer std.crypto.secureZero(u8, std.mem.asBytes(&pair));
    var pub_buf: [51]u8 = undefined;
    var pub_writer = Writer{ .out = &pub_buf };
    try pub_writer.string("ssh-ed25519");
    try pub_writer.string(&pair.public_key.toBytes());
    var w = Writer{ .out = out };
    try w.put(&.{50});
    try w.string(user);
    try w.string("ssh-connection");
    try w.string("publickey");
    try w.put(&.{1});
    try w.string("ssh-ed25519");
    try w.string(pub_buf[0..pub_writer.pos]);
    var signed: [512]u8 = undefined;
    defer std.crypto.secureZero(u8, &signed);
    var signing = Writer{ .out = &signed };
    try signing.string(&session_id);
    try signing.put(out[0..w.pos]);
    const signature = pair.sign(signed[0..signing.pos], null) catch return error.KeyError;
    var sig_buf: [83]u8 = undefined;
    var sig_writer = Writer{ .out = &sig_buf };
    try sig_writer.string("ssh-ed25519");
    try sig_writer.string(&signature.toBytes());
    try w.string(sig_buf[0..sig_writer.pos]);
    return out[0..w.pos];
}

test "reject invalid username and insufficient output" {
    var out: [512]u8 = undefined;
    try std.testing.expectError(error.InvalidUsername, request(&out, "", @splat(0), @splat(1)));
    try std.testing.expectError(error.InvalidUsername, request(&out, "a\x00b", @splat(0), @splat(1)));
    try std.testing.expectError(error.BufferTooSmall, request(out[0..20], "user", @splat(0), @splat(1)));
    const result = try request(&out, "user", @splat(0), @splat(1));
    try std.testing.expectEqual(@as(u8, 50), result[0]);
}
