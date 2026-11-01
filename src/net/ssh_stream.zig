//! Bounded SSH packet stream reassembly. A failed decoder cannot be reused.
const std = @import("std");
const ssh = @import("ssh.zig");

pub const Error = ssh.PacketError || error{ Failed, PacketPending };

pub const Decoder = struct {
    buffer: [ssh.SSH_MAX_PKT + 4 + 32]u8 = undefined,
    used: usize = 0,
    expected: ?usize = null,
    payload_start: usize = 0,
    payload_len: usize = 0,
    sequence: u32 = 0,
    cipher: ?ssh.Aes128Ctr = null,
    mac_key: ?[32]u8 = null,
    failed: bool = false,
    pending: bool = false,

    /// Install keys only at a packet boundary, after the peer's NEWKEYS.
    pub fn enableEncryption(self: *Decoder, cipher: ssh.Aes128Ctr, mac_key: [32]u8) Error!void {
        if (self.failed) return error.Failed;
        if (self.used != 0 or self.pending or self.cipher != null) return error.PacketPending;
        self.cipher = cipher;
        self.mac_key = mac_key;
    }

    /// Returns the number consumed. Stop when a packet is pending and release
    /// it before submitting more input; input after that packet stays with caller.
    pub fn feed(self: *Decoder, input: []const u8) Error!usize {
        if (self.failed) return error.Failed;
        if (self.pending) return error.PacketPending;
        var pos: usize = 0;
        const header_size: usize = if (self.cipher != null) 16 else 8;
        while (pos < input.len) {
            const target = self.expected orelse header_size;
            const count = @min(target - self.used, input.len - pos);
            @memcpy(self.buffer[self.used..][0..count], input[pos..][0..count]);
            self.used += count;
            pos += count;
            if (self.expected == null and self.used == header_size) {
                var first: [16]u8 = @splat(0);
                @memcpy(first[0..header_size], self.buffer[0..header_size]);
                if (self.cipher) |cipher| {
                    var peek = cipher;
                    peek.crypt(first[0..header_size]);
                }
                const packet_len = std.mem.readInt(u32, first[0..4], .big);
                const total = @as(usize, packet_len) + 4;
                if (packet_len < 12 or packet_len > ssh.SSH_MAX_PKT or total % header_size != 0) return self.fail(error.InvalidPacketLength);
                self.expected = total + if (self.cipher != null) @as(usize, 32) else 0;
            }
            if (self.expected) |expected| if (self.used == expected) {
                const cipher = if (self.cipher) |*c| c else null;
                const mac = if (self.mac_key) |*m| m else null;
                const decoded = ssh.unpackPacket(self.buffer[0..self.used], self.sequence, cipher != null, cipher, mac) catch |err| return self.fail(err);
                self.payload_start = @intFromPtr(decoded.ptr) - @intFromPtr(&self.buffer);
                self.payload_len = decoded.len;
                self.pending = true;
                self.sequence +%= 1;
                break;
            };
        }
        return pos;
    }

    pub fn payload(self: *const Decoder) ?[]const u8 {
        if (!self.pending) return null;
        return self.buffer[self.payload_start..][0..self.payload_len];
    }

    pub fn release(self: *Decoder) void {
        if (!self.pending) return;
        @memset(self.buffer[0..self.used], 0);
        self.used = 0;
        self.expected = null;
        self.pending = false;
        self.payload_len = 0;
    }

    fn fail(self: *Decoder, err: ssh.PacketError) Error {
        self.failed = true;
        @memset(&self.buffer, 0);
        if (self.mac_key) |*key| std.crypto.secureZero(u8, key);
        if (self.cipher) |*cipher| std.crypto.secureZero(u8, std.mem.asBytes(cipher));
        return err;
    }
};

test "fragmented encrypted packets and authentication failure" {
    const key: [16]u8 = @splat(1);
    const iv: [16]u8 = @splat(2);
    var mac: [32]u8 = @splat(3);
    var enc = ssh.Aes128Ctr.init(key, iv);
    var bytes: [256]u8 = undefined;
    const first = try ssh.packPacket("first", 0, true, &enc, &mac, &@as([32]u8, @splat(4)), &bytes);
    const second = try ssh.packPacket("second", 1, true, &enc, &mac, &@as([32]u8, @splat(5)), bytes[first..]);
    var decoder: Decoder = .{};
    try decoder.enableEncryption(ssh.Aes128Ctr.init(key, iv), mac);
    for (bytes[0 .. first - 1]) |b| try std.testing.expectEqual(@as(usize, 1), try decoder.feed(&.{b}));
    try std.testing.expect(decoder.payload() == null);
    try std.testing.expectEqual(@as(usize, 1), try decoder.feed(bytes[first - 1 .. first + second]));
    try std.testing.expectEqualStrings("first", decoder.payload().?);
    try std.testing.expectError(error.PacketPending, decoder.feed("x"));
    decoder.release();
    bytes[first + second - 1] ^= 1;
    try std.testing.expectError(error.MacVerificationFailed, decoder.feed(bytes[first .. first + second]));
    try std.testing.expectError(error.Failed, decoder.feed("x"));
}

test "multiple plaintext packets preserve boundaries and reject oversized headers" {
    var bytes: [128]u8 = undefined;
    const first = try ssh.packPacket("one", 0, false, null, null, &@as([16]u8, @splat(1)), &bytes);
    const second = try ssh.packPacket("two", 1, false, null, null, &@as([16]u8, @splat(2)), bytes[first..]);
    var decoder: Decoder = .{};
    try std.testing.expectEqual(first, try decoder.feed(bytes[0 .. first + second]));
    try std.testing.expectEqualStrings("one", decoder.payload().?);
    decoder.release();
    try std.testing.expectEqual(second, try decoder.feed(bytes[first .. first + second]));
    try std.testing.expectEqualStrings("two", decoder.payload().?);
    decoder.release();
    try std.testing.expectError(error.InvalidPacketLength, decoder.feed(&.{ 0xff, 0xff, 0xff, 0xff, 0, 0, 0, 0 }));
    try std.testing.expectError(error.Failed, decoder.feed(&.{}));
}
