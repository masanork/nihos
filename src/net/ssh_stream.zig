//! Bounded SSH packet stream reassembly. A failed decoder cannot be reused.
const std = @import("std");
const ssh = @import("ssh.zig");

pub const Error = ssh.PacketError || error{ Failed, PacketPending, EncryptionUnavailable, InvalidTransition, SequenceExhausted };

pub const Cipher = ssh.Aes128Ctr;
pub const Decoder = DecoderFor(true);
/// For the first key exchange only; never accepts encrypted packets.
pub const InitialDecoder = DecoderFor(false);
fn DecoderFor(comptime allow_encryption: bool) type {
    return struct {
        buffer: [ssh.SSH_MAX_PKT + 4 + 32]u8 = @splat(0),
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
        pub fn enableEncryption(self: *@This(), cipher: ssh.Aes128Ctr, mac_key: [32]u8) Error!void {
            if (!allow_encryption) return error.EncryptionUnavailable;
            if (self.failed) return error.Failed;
            if (self.used != 0 or self.pending or self.cipher != null) return error.PacketPending;
            self.cipher = cipher;
            self.mac_key = mac_key;
        }

        /// Consume exactly peer NEWKEYS before transferring the receive sequence.
        /// Caller must first verify the host and complete its own NEWKEYS send.
        /// Caller retains unread socket bytes and installs keys on dst next.
        pub fn transferAfterNewKeys(self: *@This(), dst: *Decoder) Error!void {
            if (allow_encryption) return error.InvalidTransition;
            if (self.failed or !self.pending) return error.InvalidTransition;
            const packet = self.payload() orelse return error.InvalidTransition;
            if (!std.mem.eql(u8, packet, &.{ssh.SSH_MSG_NEWKEYS})) return error.InvalidTransition;
            if (self.sequence == std.math.maxInt(u32)) return error.SequenceExhausted;
            if (dst.failed or dst.pending or dst.used != 0 or dst.expected != null or dst.sequence != 0 or dst.cipher != null or dst.mac_key != null) return error.InvalidTransition;
            dst.sequence = self.sequence;
            self.release();
            self.failed = true;
        }

        /// Returns the number consumed. Stop when a packet is pending and release
        /// it before submitting more input; input after that packet stays with caller.
        pub fn feed(self: *@This(), input: []const u8) Error!usize {
            if (self.failed) return error.Failed;
            if (self.pending) return error.PacketPending;
            var pos: usize = 0;
            const header_size: usize = if (allow_encryption and self.cipher != null) 16 else 8;
            while (pos < input.len) {
                const target = self.expected orelse header_size;
                const count = @min(target - self.used, input.len - pos);
                @memcpy(self.buffer[self.used..][0..count], input[pos..][0..count]);
                self.used += count;
                pos += count;
                if (self.expected == null and self.used == header_size) {
                    var first: [16]u8 = @splat(0);
                    @memcpy(first[0..header_size], self.buffer[0..header_size]);
                    if (allow_encryption) {
                        if (self.cipher) |cipher| {
                            var peek = cipher;
                            peek.crypt(first[0..header_size]);
                        }
                    }
                    const packet_len = std.mem.readInt(u32, first[0..4], .big);
                    const total = @as(usize, packet_len) + 4;
                    if (packet_len < 12 or packet_len > ssh.SSH_MAX_PKT or total % header_size != 0) return self.fail(error.InvalidPacketLength);
                    self.expected = total + if (allow_encryption and self.cipher != null) @as(usize, 32) else 0;
                }
                if (self.expected) |expected| if (self.used == expected) {
                    const cipher = if (self.cipher) |*c| c else null;
                    const mac = if (self.mac_key) |*m| m else null;
                    const decoded = if (allow_encryption)
                        ssh.unpackPacket(self.buffer[0..self.used], self.sequence, cipher != null, cipher, mac) catch |err| return self.fail(err)
                    else
                        unpackInitial(self.buffer[0..self.used]) catch |err| return self.fail(err);
                    self.payload_start = @intFromPtr(decoded.ptr) - @intFromPtr(&self.buffer);
                    self.payload_len = decoded.len;
                    self.pending = true;
                    self.sequence +%= 1;
                    break;
                };
            }
            return pos;
        }

        pub fn payload(self: *const @This()) ?[]const u8 {
            if (!self.pending) return null;
            return self.buffer[self.payload_start..][0..self.payload_len];
        }

        pub fn release(self: *@This()) void {
            if (!self.pending) return;
            @memset(self.buffer[0..self.used], 0);
            self.used = 0;
            self.expected = null;
            self.pending = false;
            self.payload_len = 0;
        }

        fn fail(self: *@This(), err: ssh.PacketError) Error {
            self.failed = true;
            @memset(&self.buffer, 0);
            if (self.mac_key) |*key| std.crypto.secureZero(u8, key);
            if (self.cipher) |*cipher| std.crypto.secureZero(u8, std.mem.asBytes(cipher));
            return err;
        }
    };
}

fn unpackInitial(raw: []const u8) ssh.PacketError![]const u8 {
    if (raw.len < 5) return error.PacketTooShort;
    const len = std.mem.readInt(u32, raw[0..4], .big);
    if (len > ssh.SSH_MAX_PKT or len < 12 or (@as(usize, len) + 4) % 8 != 0 or @as(usize, len) + 4 != raw.len) return error.InvalidPacketLength;
    const pad = raw[4];
    if (pad < 4 or 1 + @as(usize, pad) >= len) return error.InvalidPadding;
    return raw[5 .. 5 + len - 1 - pad];
}

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

test "initial decoder matches normal plaintext decoder on fragmented and invalid packets" {
    var raw: [128]u8 = undefined;
    const n = try ssh.packPacket("hello", 0, false, null, null, &@as([32]u8, @splat(3)), &raw);
    var initial: InitialDecoder = .{};
    var full: Decoder = .{};
    for (raw[0..n]) |b| {
        try std.testing.expectEqual(try full.feed(&.{b}), try initial.feed(&.{b}));
    }
    try std.testing.expectEqualSlices(u8, full.payload().?, initial.payload().?);
    try std.testing.expectError(error.PacketPending, initial.feed(&.{0}));
    initial.release();
    try std.testing.expectError(error.EncryptionUnavailable, initial.enableEncryption(ssh.Aes128Ctr.init(@splat(0), @splat(0)), @splat(0)));
    raw[4] = 3;
    try std.testing.expectError(error.InvalidPadding, initial.feed(raw[0..n]));
    try std.testing.expectError(error.Failed, initial.feed(&.{}));
}

test "initial NEWKEYS transfers sequence and leaves subsequent encrypted bytes unread" {
    const padding: [32]u8 = @splat(3);
    const key: [16]u8 = @splat(1);
    const iv: [16]u8 = @splat(2);
    var mac: [32]u8 = @splat(4);
    var frame: [256]u8 = undefined;
    const first = try ssh.packPacket(&.{21}, 0, false, null, null, &padding, &frame);
    var enc = ssh.Aes128Ctr.init(key, iv);
    const second = try ssh.packPacket("encrypted", 1, true, &enc, &mac, &padding, frame[first..]);
    var initial: InitialDecoder = .{};
    var full: Decoder = .{};
    try std.testing.expectEqual(@as(usize, 2), try initial.feed(frame[0..2]));
    try std.testing.expectError(error.InvalidTransition, initial.transferAfterNewKeys(&full));
    try std.testing.expectEqual(first - 2, try initial.feed(frame[2 .. first + second]));
    try std.testing.expectEqualSlices(u8, &.{21}, initial.payload().?);
    try initial.transferAfterNewKeys(&full);
    try std.testing.expectEqual(@as(u32, 1), full.sequence);
    try std.testing.expectError(error.Failed, initial.feed(&.{}));
    try std.testing.expectError(error.InvalidTransition, initial.transferAfterNewKeys(&full));
    try full.enableEncryption(ssh.Aes128Ctr.init(key, iv), mac);
    try std.testing.expectEqual(second, try full.feed(frame[first .. first + second]));
    try std.testing.expectEqualStrings("encrypted", full.payload().?);
    var bad_initial: InitialDecoder = .{};
    var bad_full: Decoder = .{};
    _ = try bad_initial.feed(frame[0..first]);
    try bad_initial.transferAfterNewKeys(&bad_full);
    try bad_full.enableEncryption(ssh.Aes128Ctr.init(key, iv), mac);
    frame[first + second - 1] ^= 1;
    try std.testing.expectError(error.MacVerificationFailed, bad_full.feed(frame[first .. first + second]));
    try std.testing.expectError(error.Failed, bad_full.feed(&.{}));
}

test "initial transfer rejects wrong packet, dirty destination and exhausted sequence" {
    var bytes: [64]u8 = undefined;
    const padding: [32]u8 = @splat(1);
    var initial: InitialDecoder = .{};
    var full: Decoder = .{};
    const wrong = try ssh.packPacket(&.{20}, 0, false, null, null, &padding, &bytes);
    _ = try initial.feed(bytes[0..wrong]);
    try std.testing.expectError(error.InvalidTransition, initial.transferAfterNewKeys(&full));
    initial.release();
    const n = try ssh.packPacket(&.{21}, 1, false, null, null, &padding, &bytes);
    _ = try initial.feed(bytes[0..n]);
    full.sequence = 1;
    try std.testing.expectError(error.InvalidTransition, initial.transferAfterNewKeys(&full));
    try std.testing.expect(initial.payload() != null and !initial.failed);
    full.sequence = 0;
    initial.sequence = std.math.maxInt(u32);
    try std.testing.expectError(error.SequenceExhausted, initial.transferAfterNewKeys(&full));
    try std.testing.expectEqual(@as(u32, 0), full.sequence);
}
