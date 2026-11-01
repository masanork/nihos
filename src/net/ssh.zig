//! Pure-Zig SSH-2 Client Protocol Engine (`src/net/ssh.zig`)
//!
//! Allocation-free, memory-safe SSH-2 (RFC 4253 / 4252 / 4254 / 8731) engine.
//! Uses `std.crypto` exclusively for:
//!  - X25519 key exchange (`curve25519-sha256`)
//!  - SHA-256 exchange hash & key derivation
//!  - AES-128-CTR encryption & decryption
//!  - HMAC-SHA-256 packet integrity

const std = @import("std");

pub const Sha256 = std.crypto.hash.sha2.Sha256;
pub const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
pub const X25519 = std.crypto.dh.X25519;
pub const Aes128 = std.crypto.core.aes.Aes128;

pub const SSH_BANNER_CLIENT = "SSH-2.0-nihos_1.0\r\n";
pub const SSH_MAX_PKT = 35000;

// SSH-2 Message Numbers
pub const SSH_MSG_DISCONNECT = 1;
pub const SSH_MSG_IGNORE = 2;
pub const SSH_MSG_UNIMPLEMENTED = 3;
pub const SSH_MSG_DEBUG = 4;
pub const SSH_MSG_SERVICE_REQUEST = 5;
pub const SSH_MSG_SERVICE_ACCEPT = 6;
pub const SSH_MSG_EXT_INFO = 7;
pub const SSH_MSG_KEXINIT = 20;
pub const SSH_MSG_NEWKEYS = 21;
pub const SSH_MSG_KEX_ECDH_INIT = 30;
pub const SSH_MSG_KEX_ECDH_REPLY = 31;
pub const SSH_MSG_USERAUTH_REQUEST = 50;
pub const SSH_MSG_USERAUTH_FAILURE = 51;
pub const SSH_MSG_USERAUTH_SUCCESS = 52;
pub const SSH_MSG_USERAUTH_BANNER = 53;
pub const SSH_MSG_GLOBAL_REQUEST = 80;
pub const SSH_MSG_CHANNEL_OPEN = 90;
pub const SSH_MSG_CHANNEL_OPEN_CONFIRMATION = 91;
pub const SSH_MSG_CHANNEL_OPEN_FAILURE = 92;
pub const SSH_MSG_CHANNEL_WINDOW_ADJUST = 93;
pub const SSH_MSG_CHANNEL_DATA = 94;
pub const SSH_MSG_CHANNEL_EXTENDED_DATA = 95;
pub const SSH_MSG_CHANNEL_EOF = 96;
pub const SSH_MSG_CHANNEL_CLOSE = 97;
pub const SSH_MSG_CHANNEL_REQUEST = 98;
pub const SSH_MSG_CHANNEL_SUCCESS = 99;
pub const SSH_MSG_CHANNEL_FAILURE = 100;

// ============================================================================
// AES-128-CTR Streaming Cipher
// ============================================================================

pub const Aes128Ctr = struct {
    ctx: @TypeOf(Aes128.initEnc(@as([16]u8, @splat(0)))),
    iv: [16]u8,
    keystream: [16]u8 = @splat(0),
    offset: u8 = 16,

    pub fn init(key: [16]u8, iv: [16]u8) Aes128Ctr {
        return .{
            .ctx = Aes128.initEnc(key),
            .iv = iv,
            .offset = 16,
        };
    }

    pub fn crypt(self: *Aes128Ctr, buf: []u8) void {
        for (buf) |*b| {
            if (self.offset == 16) {
                self.ctx.encrypt(&self.keystream, &self.iv);
                self.offset = 0;
                // Increment IV as big-endian 128-bit integer
                var i: usize = 16;
                while (i > 0) {
                    i -= 1;
                    self.iv[i] +%= 1;
                    if (self.iv[i] != 0) break;
                }
            }
            b.* ^= self.keystream[self.offset];
            self.offset += 1;
        }
    }
};

// ============================================================================
// Key Derivation (RFC 4253 Section 7.2)
// ============================================================================

pub fn deriveKey(
    k_mpint: []const u8,
    h: [32]u8,
    session_id: [32]u8,
    letter: u8,
    out: *[32]u8,
) void {
    var hasher = Sha256.init(.{});
    hasher.update(k_mpint);
    hasher.update(&h);
    hasher.update(&[_]u8{letter});
    hasher.update(&session_id);
    hasher.final(out);
}

/// Formats a 256-bit raw integer as an SSH `mpint` (RFC 4251 Section 5).
pub fn formatMpint(raw_be: [32]u8, out_buf: *[37]u8) []const u8 {
    var first_nz: usize = 0;
    while (first_nz < 32 and raw_be[first_nz] == 0) : (first_nz += 1) {}

    if (first_nz == 32) {
        std.mem.writeInt(u32, out_buf[0..4], 0, .big);
        return out_buf[0..4];
    }

    const rem = 32 - first_nz;
    const need_zero = (raw_be[first_nz] & 0x80) != 0;
    const len: u32 = @intCast(rem + if (need_zero) @as(usize, 1) else 0);

    std.mem.writeInt(u32, out_buf[0..4], len, .big);
    var off: usize = 4;
    if (need_zero) {
        out_buf[off] = 0x00;
        off += 1;
    }
    @memcpy(out_buf[off .. off + rem], raw_be[first_nz..32]);
    return out_buf[0 .. off + rem];
}

// ============================================================================
// Packet Packing & Unpacking
// ============================================================================

pub const PacketError = error{
    PacketTooLarge,
    PacketTooShort,
    InvalidPadding,
    MacVerificationFailed,
    BufferTooSmall,
};

pub fn packPacket(
    payload: []const u8,
    seq: u32,
    encrypted: bool,
    enc_cipher: ?*Aes128Ctr,
    mac_key: ?*[32]u8,
    random_bytes: []const u8,
    out_buf: []u8,
) PacketError!usize {
    const block_sz: usize = if (encrypted) 16 else 8;
    const unpadded = 5 + payload.len;
    var pad_len = block_sz - (unpadded & (block_sz - 1));
    if (pad_len < 4) pad_len += block_sz;

    const pkt_len = 1 + payload.len + pad_len;
    const total_len = 4 + pkt_len;
    const mac_len: usize = if (encrypted) 32 else 0;

    if (total_len + mac_len > out_buf.len) return error.BufferTooSmall;

    std.mem.writeInt(u32, out_buf[0..4], @intCast(pkt_len), .big);
    out_buf[4] = @intCast(pad_len);
    @memcpy(out_buf[5 .. 5 + payload.len], payload);

    // Fill padding bytes with provided random bytes or zeroes
    for (0..pad_len) |i| {
        out_buf[5 + payload.len + i] = if (i < random_bytes.len) random_bytes[i] else 0;
    }

    if (encrypted) {
        const cipher = enc_cipher orelse return error.BufferTooSmall;
        const key = mac_key orelse return error.BufferTooSmall;

        // Compute HMAC over seq_num || unencrypted packet
        var mac: [32]u8 = undefined;
        var hmac = HmacSha256.init(key);
        var seq_be: [4]u8 = undefined;
        std.mem.writeInt(u32, &seq_be, seq, .big);
        hmac.update(&seq_be);
        hmac.update(out_buf[0..total_len]);
        hmac.final(&mac);

        // Encrypt packet with AES-CTR
        cipher.crypt(out_buf[0..total_len]);

        // Append MAC tag
        @memcpy(out_buf[total_len .. total_len + 32], &mac);
        return total_len + 32;
    }

    return total_len;
}

pub fn unpackPacket(
    raw_packet: []u8,
    seq: u32,
    encrypted: bool,
    dec_cipher: ?*Aes128Ctr,
    mac_key: ?*[32]u8,
) PacketError![]const u8 {
    if (encrypted) {
        if (raw_packet.len < 16 + 32) return error.PacketTooShort;
        const cipher = dec_cipher orelse return error.BufferTooSmall;
        const key = mac_key orelse return error.BufferTooSmall;

        const total_len = raw_packet.len - 32;
        const rx_mac = raw_packet[total_len .. total_len + 32];

        // Decrypt entire packet
        cipher.crypt(raw_packet[0..total_len]);

        // Verify HMAC
        var exp_mac: [32]u8 = undefined;
        var hmac = HmacSha256.init(key);
        var seq_be: [4]u8 = undefined;
        std.mem.writeInt(u32, &seq_be, seq, .big);
        hmac.update(&seq_be);
        hmac.update(raw_packet[0..total_len]);
        hmac.final(&exp_mac);

        if (!std.mem.eql(u8, rx_mac, &exp_mac)) {
            return error.MacVerificationFailed;
        }

        const pkt_len = std.mem.readInt(u32, raw_packet[0..4], .big);
        if (pkt_len < 12 or 4 + pkt_len != total_len) return error.PacketTooShort;

        const pad_len = raw_packet[4];
        if (1 + @as(usize, pad_len) >= pkt_len) return error.InvalidPadding;

        const payload_len = pkt_len - 1 - pad_len;
        return raw_packet[5 .. 5 + payload_len];
    } else {
        if (raw_packet.len < 5) return error.PacketTooShort;
        const pkt_len = std.mem.readInt(u32, raw_packet[0..4], .big);
        if (4 + pkt_len > raw_packet.len) return error.PacketTooShort;

        const pad_len = raw_packet[4];
        if (1 + @as(usize, pad_len) >= pkt_len) return error.InvalidPadding;

        const payload_len = pkt_len - 1 - pad_len;
        return raw_packet[5 .. 5 + payload_len];
    }
}

// ============================================================================
// Unit Tests
// ============================================================================

test "AES-128-CTR round-trip encryption" {
    const key: [16]u8 = @splat(0x55);
    const iv: [16]u8 = @splat(0xAA);

    var enc = Aes128Ctr.init(key, iv);
    var dec = Aes128Ctr.init(key, iv);

    var msg: [32]u8 = undefined;
    @memcpy(msg[0..13], "Hello, nihos!");
    for (13..32) |i| msg[i] = @intCast(i);

    const orig = msg;
    enc.crypt(&msg);

    // Ciphertext must differ from plaintext
    try std.testing.expect(!std.mem.eql(u8, &orig, &msg));

    dec.crypt(&msg);
    try std.testing.expectEqualSlices(u8, &orig, &msg);
}

test "SSH packet packing and unpacking (unencrypted)" {
    var out_buf: [128]u8 = undefined;
    const payload = "SSH-TEST-PAYLOAD";

    const pad: [8]u8 = @splat(0);
    const packed_len = try packPacket(payload, 0, false, null, null, &pad, &out_buf);
    try std.testing.expect(packed_len > payload.len);

    const unpacked = try unpackPacket(out_buf[0..packed_len], 0, false, null, null);
    try std.testing.expectEqualStrings(payload, unpacked);
}

test "SSH packet packing and unpacking (encrypted with AES-128-CTR and HMAC-SHA256)" {
    const key: [16]u8 = @splat(0x11);
    const iv: [16]u8 = @splat(0x22);
    var mac_key: [32]u8 = @splat(0x33);

    var enc = Aes128Ctr.init(key, iv);
    var dec = Aes128Ctr.init(key, iv);

    var out_buf: [256]u8 = undefined;
    const payload = "SSH-ENCRYPTED-STREAM-DATA";

    const pad16: [16]u8 = @splat(0);
    const packed_len = try packPacket(payload, 1, true, &enc, &mac_key, &pad16, &out_buf);
    try std.testing.expect(packed_len >= payload.len + 32);

    const unpacked = try unpackPacket(out_buf[0..packed_len], 1, true, &dec, &mac_key);
    try std.testing.expectEqualStrings(payload, unpacked);
}

test "formatMpint for SSH integers" {
    var buf: [37]u8 = undefined;

    // Zero
    const z_raw: [32]u8 = @splat(0);
    const z_mpint = formatMpint(z_raw, &buf);
    try std.testing.expectEqual(@as(usize, 4), z_mpint.len);
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, z_mpint[0..4], .big));

    // MSB set requires leading 0x00
    var msb_raw: [32]u8 = @splat(0);
    msb_raw[0] = 0x80;
    const msb_mpint = formatMpint(msb_raw, &buf);
    try std.testing.expectEqual(@as(usize, 37), msb_mpint.len);
    try std.testing.expectEqual(@as(u8, 0x00), msb_mpint[4]);
    try std.testing.expectEqual(@as(u8, 0x80), msb_mpint[5]);
}

test "SSH key derivation (RFC 4253 section 7.2) using std.crypto" {
    var k_mpint_buf: [36]u8 = undefined;
    std.mem.writeInt(u32, k_mpint_buf[0..4], 32, .big);
    @memset(k_mpint_buf[4..36], 0x42);
    const k_mpint = &k_mpint_buf;
    const h: [32]u8 = @splat(0xAA);
    const session_id: [32]u8 = @splat(0xBB);

    var iv_c2s: [32]u8 = undefined;
    var iv_s2c: [32]u8 = undefined;
    var key_c2s: [32]u8 = undefined;

    deriveKey(k_mpint, h, session_id, 'A', &iv_c2s);
    deriveKey(k_mpint, h, session_id, 'B', &iv_s2c);
    deriveKey(k_mpint, h, session_id, 'C', &key_c2s);

    // Keys for different letters must be unique
    try std.testing.expect(!std.mem.eql(u8, &iv_c2s, &iv_s2c));
    try std.testing.expect(!std.mem.eql(u8, &iv_c2s, &key_c2s));
}
