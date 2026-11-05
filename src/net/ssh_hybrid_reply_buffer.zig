//! Own a validated server reply across asynchronous KEM work. Single-owner;
//! never mutate or clear this buffer while verification borrows its contents.
const std = @import("std");
const transport = @import("ssh_transport.zig");
const reply = @import("ssh_hybrid_reply.zig");
/// Deliberate profile limit, including host key, KEM value, and signature.
pub const capacity = 2048;
pub const Error = error{ Busy, NoPacket, TooLarge, Malformed, Failed };
pub const Buffer = struct {
    bytes: [capacity]u8 = @splat(0),
    len: usize = 0,

    /// Copies only a complete and structurally valid reply. On success the
    /// decoder packet is released; on error its ownership remains unchanged.
    pub fn capture(self: *Buffer, wire: *transport.Transport) Error!void {
        if (self.len != 0) return error.Busy;
        if (wire.failed) return error.Failed;
        const packet = wire.rx.payload() orelse return error.NoPacket;
        if (packet.len > self.bytes.len) return error.TooLarge;
        _ = reply.parse(packet) catch return error.Malformed;
        @memcpy(self.bytes[0..packet.len], packet);
        self.len = packet.len;
        wire.rx.release();
    }
    pub fn get(self: *const Buffer) Error!reply.Reply {
        if (self.len == 0) return error.NoPacket;
        return reply.parse(self.bytes[0..self.len]) catch error.Malformed;
    }
    pub fn clear(self: *Buffer) void {
        std.crypto.secureZero(u8, &self.bytes);
        self.len = 0;
    }
};

test "fragmented transport reply remains owned after release and abort" {
    const hybrid = @import("ssh_hybrid_transcript.zig");
    var packet: [1 + 4 + 1 + 4 + hybrid.server_len + 4 + 1]u8 = @splat(0);
    packet[0] = 31;
    std.mem.writeInt(u32, packet[1..5], 1, .big);
    packet[5] = 7;
    std.mem.writeInt(u32, packet[6..10], hybrid.server_len, .big);
    packet[10] = 42;
    const sigpos = 10 + hybrid.server_len;
    std.mem.writeInt(u32, packet[sigpos..][0..4], 1, .big);
    packet[sigpos + 4] = 9;
    var sender: transport.Transport = .{};
    var receiver: transport.Transport = .{};
    var owned: Buffer = .{};
    try std.testing.expectError(error.NoPacket, owned.capture(&receiver));
    try sender.prepare(&packet, &@as([32]u8, @splat(3)));
    const wire = sender.pending();
    for (wire) |*byte| try std.testing.expectEqual(@as(usize, 1), try receiver.feed(@as([*]const u8, @ptrCast(byte))[0..1]));
    try owned.capture(&receiver);
    try std.testing.expect(receiver.rx.payload() == null);
    try std.testing.expectError(error.Busy, owned.capture(&receiver));
    receiver.abort();
    const saved = try owned.get();
    try std.testing.expectEqual(@as(u8, 42), saved.ciphertext()[0]);
    try std.testing.expectEqualSlices(u8, &.{7}, saved.host);
    try std.testing.expectEqualSlices(u8, &.{9}, saved.signature);
    owned.clear();
    try std.testing.expect(std.mem.allEqual(u8, &owned.bytes, 0));
    try std.testing.expectError(error.NoPacket, owned.get());
}

test "malformed reply does not consume decoder packet" {
    var sender: transport.Transport = .{};
    var receiver: transport.Transport = .{};
    var owned: Buffer = .{};
    try sender.prepare(&.{ 31, 0, 0, 0, 1 }, &@as([32]u8, @splat(1)));
    _ = try receiver.feed(sender.pending());
    try std.testing.expectError(error.Malformed, owned.capture(&receiver));
    try std.testing.expect(receiver.rx.payload() != null);
    try std.testing.expectEqual(@as(usize, 0), owned.len);
}

test "oversized packet remains with decoder" {
    var sender: transport.Transport = .{};
    var receiver: transport.Transport = .{};
    var owned: Buffer = .{};
    const packet: [capacity + 1]u8 = @splat(31);
    try sender.prepare(&packet, &@as([32]u8, @splat(1)));
    _ = try receiver.feed(sender.pending());
    try std.testing.expectError(error.TooLarge, owned.capture(&receiver));
    try std.testing.expect(receiver.rx.payload() != null);
    try std.testing.expectEqual(@as(usize, 0), owned.len);
}
