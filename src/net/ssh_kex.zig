//! First SSH key exchange: a deliberately narrow curve25519/Ed25519 profile.
//! Callers own transport ordering, entropy, pins, and NEWKEYS transitions.
const std = @import("std");
const ssh = @import("ssh.zig");
const proof = @import("ssh_host_key.zig");
const X25519 = std.crypto.dh.X25519;

pub const Error = error{ Malformed, Unsupported, BufferTooSmall, InvalidPeerKey } || proof.Error || error{ InputTooLong, InvalidSharedSecret };
const algorithms = [_][]const u8{
    "curve25519-sha256", "ssh-ed25519",   "aes128-ctr", "aes128-ctr",
    "hmac-sha2-256",     "hmac-sha2-256", "none",       "none",
    "",                  "",
};

const Reader = struct {
    input: []const u8,
    pos: usize = 0,
    fn take(self: *Reader, n: usize) Error![]const u8 {
        if (n > self.input.len - self.pos) return error.Malformed;
        const result = self.input[self.pos..][0..n];
        self.pos += n;
        return result;
    }
    fn string(self: *Reader) Error![]const u8 {
        const n = std.mem.readInt(u32, (try self.take(4))[0..4], .big);
        return self.take(n);
    }
};

fn putString(out: []u8, pos: *usize, value: []const u8) Error!void {
    if (pos.* > out.len or out.len - pos.* < 4 or value.len > out.len - pos.* - 4) return error.BufferTooSmall;
    std.mem.writeInt(u32, out[pos.*..][0..4], @intCast(value.len), .big);
    pos.* += 4;
    @memcpy(out[pos.*..][0..value.len], value);
    pos.* += value.len;
}

/// cookie must be 16 bytes from a cryptographically secure random source.
pub fn clientInit(out: []u8, cookie: [16]u8) Error![]const u8 {
    if (out.len < 17) return error.BufferTooSmall;
    out[0] = ssh.SSH_MSG_KEXINIT;
    @memcpy(out[1..17], &cookie);
    var pos: usize = 17;
    for (algorithms) |algorithm| try putString(out, &pos, algorithm);
    if (out.len - pos < 5) return error.BufferTooSmall;
    @memset(out[pos..][0..5], 0);
    return out[0 .. pos + 5];
}

fn hasName(list: []const u8, name: []const u8) bool {
    var iter = std.mem.splitScalar(u8, list, ',');
    while (iter.next()) |part| if (std.mem.eql(u8, part, name)) return true;
    return false;
}

/// No speculative packet is accepted: peers setting first_kex_packet_follows
/// are rejected until the transport implements the required discard semantics.
pub fn validateServerInit(payload: []const u8) Error!void {
    var r = Reader{ .input = payload };
    if ((try r.take(1))[0] != ssh.SSH_MSG_KEXINIT) return error.Malformed;
    _ = try r.take(16);
    for (algorithms, 0..) |algorithm, i| {
        const list = try r.string();
        if (i < 8 and !hasName(list, algorithm)) return error.Unsupported;
        if (list.len > 0) {
            var iter = std.mem.splitScalar(u8, list, ',');
            while (iter.next()) |item| {
                if (item.len == 0) return error.Malformed;
                for (item) |c| if (c < 33 or c > 126) return error.Malformed;
            }
        }
    }
    const follows = (try r.take(1))[0];
    if (follows > 1) return error.Malformed;
    if (follows == 1) return error.Unsupported;
    if (std.mem.readInt(u32, (try r.take(4))[0..4], .big) != 0 or r.pos != payload.len) return error.Malformed;
}

pub const Keys = struct {
    exchange_hash: [32]u8,
    iv_client: [16]u8,
    iv_server: [16]u8,
    key_client: [16]u8,
    key_server: [16]u8,
    mac_client: [32]u8,
    mac_server: [32]u8,
};

/// Verify the server's reply and only then return transport keys. This is the
/// first exchange, so the exchange hash also serves as the session ID.
pub fn finish(client_banner: []const u8, server_banner: []const u8, client_init: []const u8, server_init: []const u8, secret: [32]u8, pinned_sha256: [32]u8, reply: []const u8) Error!Keys {
    var expected_init: [512]u8 = undefined;
    if (client_init.len < 17) return error.Malformed;
    const canonical = try clientInit(&expected_init, client_init[1..17].*);
    if (!std.mem.eql(u8, canonical, client_init)) return error.Unsupported;
    try validateServerInit(server_init);
    var r = Reader{ .input = reply };
    if ((try r.take(1))[0] != ssh.SSH_MSG_KEX_ECDH_REPLY) return error.Malformed;
    const host_key = try r.string();
    const server_public = try r.string();
    const signature = try r.string();
    if (server_public.len != 32 or r.pos != reply.len) return error.Malformed;
    const public = X25519.recoverPublicKey(secret);
    var shared = X25519.scalarmult(secret, server_public[0..32].*) catch return error.InvalidPeerKey;
    defer std.crypto.secureZero(u8, &shared);
    const hash = try proof.exchangeHash(client_banner, server_banner, client_init, server_init, host_key, public, server_public[0..32].*, shared);
    try proof.verify(host_key, signature, hash, pinned_sha256);
    var mpint: [37]u8 = undefined;
    defer std.crypto.secureZero(u8, &mpint);
    const k = ssh.formatMpint(shared, &mpint);
    var values: [6][32]u8 = undefined;
    defer std.crypto.secureZero(u8, std.mem.asBytes(&values));
    for (&values, 0..) |*value, i| ssh.deriveKey(k, hash, hash, @as(u8, 'A') + @as(u8, @intCast(i)), value);
    return .{ .exchange_hash = hash, .iv_client = values[0][0..16].*, .iv_server = values[1][0..16].*, .key_client = values[2][0..16].*, .key_server = values[3][0..16].*, .mac_client = values[4], .mac_server = values[5] };
}

test "server proof gates exchange keys" {
    var client_storage: [512]u8 = undefined;
    var server_storage: [512]u8 = undefined;
    const client_init = try clientInit(&client_storage, @splat(1));
    const server_init = try clientInit(&server_storage, @splat(2));
    const client_secret: [32]u8 = @splat(3);
    const server_secret: [32]u8 = @splat(4);
    const client_public = X25519.recoverPublicKey(client_secret);
    const server_public = X25519.recoverPublicKey(server_secret);
    const host = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(@splat(5));
    var host_buf: [100]u8 = undefined;
    var host_len: usize = 0;
    try putString(&host_buf, &host_len, "ssh-ed25519");
    try putString(&host_buf, &host_len, &host.public_key.toBytes());
    const host_blob = host_buf[0..host_len];
    var pin: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(host_blob, &pin, .{});
    const shared = try X25519.scalarmult(server_secret, client_public);
    const hash = try proof.exchangeHash("SSH-2.0-client", "SSH-2.0-server", client_init, server_init, host_blob, client_public, server_public, shared);
    const signature = try host.sign(&hash, null);
    var sig_buf: [100]u8 = undefined;
    var sig_len: usize = 0;
    try putString(&sig_buf, &sig_len, "ssh-ed25519");
    try putString(&sig_buf, &sig_len, &signature.toBytes());
    var reply: [256]u8 = undefined;
    reply[0] = ssh.SSH_MSG_KEX_ECDH_REPLY;
    var len: usize = 1;
    try putString(&reply, &len, host_blob);
    try putString(&reply, &len, &server_public);
    try putString(&reply, &len, sig_buf[0..sig_len]);
    const keys = try finish("SSH-2.0-client", "SSH-2.0-server", client_init, server_init, client_secret, pin, reply[0..len]);
    try std.testing.expectEqualSlices(u8, &hash, &keys.exchange_hash);
    var bad_pin = pin;
    bad_pin[0] ^= 1;
    try std.testing.expectError(error.HostKeyMismatch, finish("SSH-2.0-client", "SSH-2.0-server", client_init, server_init, client_secret, bad_pin, reply[0..len]));
    reply[len - 1] ^= 1;
    try std.testing.expectError(error.InvalidSignature, finish("SSH-2.0-client", "SSH-2.0-server", client_init, server_init, client_secret, pin, reply[0..len]));
}

test "KEXINIT requires every supported direction and no speculative packet" {
    var storage: [512]u8 = undefined;
    const init = try clientInit(&storage, @splat(7));
    try validateServerInit(init);
    try std.testing.expectError(error.Malformed, validateServerInit(init[0 .. init.len - 1]));
    storage[init.len - 5] = 1;
    try std.testing.expectError(error.Unsupported, validateServerInit(init));
    storage[init.len - 5] = 0;
    storage[21] = 'X';
    try std.testing.expectError(error.Unsupported, validateServerInit(init));
}
