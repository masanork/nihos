//! Strict SSH Ed25519 server proof with an externally provisioned host-key pin.
//! This does not implement SSH transport or establish trust on first use.
const std = @import("std");
const Ed25519 = std.crypto.sign.Ed25519;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Error = error{ Malformed, UnsupportedAlgorithm, HostKeyMismatch, InvalidSignature };

/// RFC 8731 exchange hash for curve25519-sha256. Banners exclude CR/LF;
/// KEXINIT inputs include the SSH_MSG_KEXINIT byte but not packet framing.
pub fn exchangeHash(client_banner: []const u8, server_banner: []const u8, client_kex: []const u8, server_kex: []const u8, host_key: []const u8, client_public: [32]u8, server_public: [32]u8, shared_secret: [32]u8) error{ InputTooLong, InvalidSharedSecret }![32]u8 {
    if (std.mem.allEqual(u8, &shared_secret, 0)) return error.InvalidSharedSecret;
    var hash = Sha256.init(.{});
    for ([_][]const u8{ client_banner, server_banner, client_kex, server_kex, host_key, &client_public, &server_public }) |part| {
        if (part.len > std.math.maxInt(u32)) return error.InputTooLong;
        var length: [4]u8 = undefined;
        std.mem.writeInt(u32, &length, @intCast(part.len), .big);
        hash.update(&length);
        hash.update(part);
    }
    var mpint: [37]u8 = undefined;
    hash.update(@import("ssh.zig").formatMpint(shared_secret, &mpint));
    return hash.finalResult();
}

test "exchange hash encodes SSH strings and positive shared mpint" {
    var shared: [32]u8 = @splat(3);
    shared[0] = 128;
    const result = try exchangeHash("SSH-2.0-client", "SSH-2.0-server", "\x14c", "\x14s", "host", @splat(1), @splat(2), shared);
    const expected = [_]u8{ 0x1e, 0x38, 0x75, 0x73, 0xd2, 0x10, 0x7f, 0xf0, 0x66, 0xb2, 0x60, 0x29, 0xa9, 0x88, 0x74, 0x78, 0xd4, 0x1c, 0x18, 0xa0, 0xe7, 0xd0, 0xfd, 0x37, 0x86, 0x6f, 0x59, 0xff, 0x19, 0xeb, 0x55, 0x6e };
    try std.testing.expectEqualSlices(u8, &expected, &result);
    try std.testing.expectError(error.InvalidSharedSecret, exchangeHash("", "", "", "", "", @splat(1), @splat(2), @splat(0)));
}

const Reader = struct {
    data: []const u8,
    offset: usize = 0,

    fn string(self: *Reader) Error![]const u8 {
        if (self.data.len - self.offset < 4) return error.Malformed;
        const n = std.mem.readInt(u32, self.data[self.offset..][0..4], .big);
        self.offset += 4;
        if (n > self.data.len - self.offset) return error.Malformed;
        const result = self.data[self.offset..][0..n];
        self.offset += n;
        return result;
    }
};

/// Verify the SHA-256 pin of the complete SSH host-key blob and its signature
/// over the exchange hash. The pin must come from a trusted external source.
pub fn verify(key_blob: []const u8, signature_blob: []const u8, exchange_hash: [32]u8, pinned_sha256: [32]u8) Error!void {
    var key = Reader{ .data = key_blob };
    if (!std.mem.eql(u8, try key.string(), "ssh-ed25519")) return error.UnsupportedAlgorithm;
    const encoded_key = try key.string();
    if (encoded_key.len != 32 or key.offset != key_blob.len) return error.Malformed;
    var fingerprint: [32]u8 = undefined;
    Sha256.hash(key_blob, &fingerprint, .{});
    if (!std.mem.eql(u8, &fingerprint, &pinned_sha256)) return error.HostKeyMismatch;

    var sig = Reader{ .data = signature_blob };
    if (!std.mem.eql(u8, try sig.string(), "ssh-ed25519")) return error.UnsupportedAlgorithm;
    const encoded_sig = try sig.string();
    if (encoded_sig.len != 64 or sig.offset != signature_blob.len) return error.Malformed;
    const public_key = Ed25519.PublicKey.fromBytes(encoded_key[0..32].*) catch return error.InvalidSignature;
    const signature = Ed25519.Signature.fromBytes(encoded_sig[0..64].*);
    signature.verifyStrict(&exchange_hash, public_key) catch return error.InvalidSignature;
}

test "pinned Ed25519 host key verifies the exchange and rejects changes" {
    const pair = try Ed25519.KeyPair.generateDeterministic(@splat(7));
    const hash: [32]u8 = @splat(42);
    const signature = try pair.sign(&hash, null);
    var key_blob: [51]u8 = undefined;
    std.mem.writeInt(u32, key_blob[0..4], 11, .big);
    @memcpy(key_blob[4..15], "ssh-ed25519");
    std.mem.writeInt(u32, key_blob[15..19], 32, .big);
    @memcpy(key_blob[19..51], &pair.public_key.toBytes());
    var sig_blob: [83]u8 = undefined;
    std.mem.writeInt(u32, sig_blob[0..4], 11, .big);
    @memcpy(sig_blob[4..15], "ssh-ed25519");
    std.mem.writeInt(u32, sig_blob[15..19], 64, .big);
    @memcpy(sig_blob[19..83], &signature.toBytes());
    var pin: [32]u8 = undefined;
    Sha256.hash(&key_blob, &pin, .{});
    try verify(&key_blob, &sig_blob, hash, pin);
    var wrong_pin = pin;
    wrong_pin[0] ^= 1;
    try std.testing.expectError(error.HostKeyMismatch, verify(&key_blob, &sig_blob, hash, wrong_pin));
    var wrong_hash = hash;
    wrong_hash[0] ^= 1;
    try std.testing.expectError(error.InvalidSignature, verify(&key_blob, &sig_blob, wrong_hash, pin));
    sig_blob[82] ^= 1;
    try std.testing.expectError(error.InvalidSignature, verify(&key_blob, &sig_blob, hash, pin));
    try std.testing.expectError(error.Malformed, verify(key_blob[0..50], &sig_blob, hash, pin));
}
